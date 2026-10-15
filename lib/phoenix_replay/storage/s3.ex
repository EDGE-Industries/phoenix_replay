if Code.ensure_loaded?(ExAws.S3) do
  defmodule PhoenixReplay.Storage.S3 do
    @moduledoc """
    Stores recordings in an S3-compatible object store.

    Recordings and summaries are separate objects. Summaries are listed and
    decoded for the dashboard without reading the recording objects. Running
    sessions are appended as immutable chunk objects, which lets a node recover
    after a crash and lets repeated writes from one writer coexist safely.

    ## Options

      * `:bucket` — the object-store bucket name (required)
      * `:prefix` — the key prefix for this application's recordings (required)
      * `:request` — a function receiving an ExAws operation and returning its
        result; defaults to `&ExAws.request/1`
      * `:writer_node` — required non-empty binary identity that is unique per
        node and stable across restarts; it partitions partials for recovery
      * `:writer_pid` — process id for the current writer; defaults to the
        operating-system process id
      * `:writer_alive?` — function receiving a writer process id and returning
        whether it is alive; overrides the default local OS process check

    `:prefix` is trimmed at both ends. The adapter stores recordings below
    `<prefix>/recordings/`, summaries below `<prefix>/summaries/`, and partial
    chunks below `<prefix>/partials/`.

    ExAws and ExAws S3 are optional dependencies. This module is available when
    the `ExAws.S3` module is present in the consuming application.

    ## Example

        config :phoenix_replay,
          storage: {
            PhoenixReplay.Storage.S3,
            bucket: "my-replay-bucket",
            prefix: "my-app/replays",
            writer_node: "my-app-node-1"
          }

    Configure ExAws credentials and the S3 endpoint through ExAws as usual.
    """

    @behaviour PhoenixReplay.Storage

    alias PhoenixReplay.Recording
    alias PhoenixReplay.Recording.{Event, Summary}
    alias PhoenixReplay.Storage.Codec

    @impl true
    def save(%Recording{} = recording, opts) do
      writer_node(opts)
      saved_at = Keyword.get(opts, :publication_saved_at, System.system_time(:millisecond))
      summary = Summary.new(recording, saved_at: saved_at)

      opts = Keyword.put(opts, :publication_saved_at, saved_at)

      with :ok <- put_recording(recording, opts),
           :ok <- put(recording.id, "summary", Codec.encode(summary), opts),
           :ok <- delete_publication_checkpoint(recording.id, opts) do
        with {:ok, keys} <- list_objects(opts, partial_prefix(recording.id, opts)) do
          delete_objects(keys, opts)
        end
      end
    end

    @impl true
    def append(%Recording{id: id} = recording, [_ | _] = chunk, opts) do
      if valid_chunk?(chunk) do
        {first, last} = chunk |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
        range = padded_sequence(first) <> "-" <> padded_sequence(last)
        key = partial_prefix(id, opts) <> writer_pid(opts) <> "/" <> range <> ".chunk"

        bucket(opts)
        |> ExAws.S3.put_object(key, Codec.encode({%{recording | events: []}, chunk}),
          content_type: "application/octet-stream"
        )
        |> request(opts)
        |> result()
      else
        {:error, :invalid_chunk}
      end
    end

    def append(_recording, _chunk, _opts), do: {:error, :invalid_chunk}

    @impl true
    def fetch_partial(id, opts, fetch_completed \\ &fetch_recording/2) do
      case fetch_publication_state(id, opts, fetch_completed) do
        {:ok, _state, recording} -> {:ok, recording}
        {:error, :not_found} -> fetch_chunks(id, opts)
        error -> error
      end
    end

    @impl true
    def partials(opts) do
      partial_ids(opts)
      |> Enum.filter(fn id ->
        case fetch_publication_state(id, opts) do
          {:ok, state, recording} ->
            case state do
              :published ->
                if publication_current?(recording, opts) do
                  cleanup_partial(id, opts)
                else
                  case save(recording, opts) do
                    :ok ->
                      false

                    {:error, reason} ->
                      raise "Replay publication retry failed: #{inspect(reason)}"
                  end
                end

              {:pending, saved_at} ->
                case save(recording, Keyword.put(opts, :publication_saved_at, saved_at)) do
                  :ok ->
                    false

                  {:error, reason} ->
                    raise "Replay publication retry failed: #{inspect(reason)}"
                end
            end

          {:error, :not_found} ->
            true

          {:error, reason} ->
            raise "Replay recording read failed: #{inspect(reason)}"
        end
      end)
    end

    @impl true
    def fetch(id, opts), do: get(id, "recording", Recording, opts)

    @doc "Lists objects below a configured S3 key prefix."
    def list_objects(opts, key_prefix), do: list_keys(opts, key_prefix, nil)

    @doc "Deletes the supplied S3 object keys."
    def delete_objects(keys, opts), do: delete_keys(keys, opts)

    @doc "Deletes all partial chunks for a recording across writer nodes."
    def delete_partial_chunks(id, opts) do
      if not Recording.valid_id?(id), do: raise(ArgumentError, "Invalid replay recording id")

      base = prefix(opts) <> "/partials/"

      with {:ok, keys} <- list_objects(opts, base) do
        keys
        |> Enum.filter(&partial_key?(&1, base, id))
        |> delete_objects(opts)
      end
    end

    @doc "Returns recoverable recording IDs for this writer node."
    def partial_ids(opts) do
      base = prefix(opts) <> "/partials/" <> writer_node(opts) <> "/"

      object_keys(opts, base, nil)
      |> Enum.map(fn key -> key |> String.replace_prefix(base, "") |> String.split("/") end)
      |> Enum.flat_map(fn
        [id, "publication.pending"] ->
          if Recording.valid_id?(id) do
            case read_checkpoint(id, opts) do
              {:ok, pid, _saved_at, _body} -> [{id, pid}]
              {:error, :not_found} -> []
              {:error, reason} -> raise "Replay checkpoint read failed: #{inspect(reason)}"
            end
          else
            []
          end

        [id, pid, _chunk] ->
          if Recording.valid_id?(id) and valid_pid?(pid), do: [{id, pid}], else: []

        _path ->
          []
      end)
      |> Enum.uniq()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.filter(fn {id, pids} ->
        Enum.all?(pids, &writer_stopped?(id, &1, opts))
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
    end

    @doc "Returns the storage namespace for a bucket and prefix."
    def namespace(opts), do: prefix(opts) <> "|" <> bucket(opts)

    @doc "Returns the normalized configured S3 prefix."
    def prefix(opts), do: opts |> Keyword.fetch!(:prefix) |> String.trim("/")

    @doc "Builds the S3 key for a complete recording object."
    def recording_key(id, opts), do: key(id, "recording", opts)

    @doc "Deletes one S3 object by key."
    def delete_object(object_key, opts) do
      bucket(opts)
      |> ExAws.S3.delete_object(object_key)
      |> request(opts)
      |> result()
    end

    @doc "Removes a writer node's pending publication after metadata is saved."
    def delete_publication_checkpoint(id, opts),
      do: delete_object(publication_key(id, opts), opts)

    @doc "Returns the stable writer-node key used for partial storage."
    def writer_node(opts) do
      name = Keyword.get(opts, :writer_node)

      if not is_binary(name) or String.trim(name) == "" do
        raise ArgumentError,
              "PhoenixReplay.Storage.S3 requires a non-empty :writer_node identity"
      end

      :crypto.hash(:sha256, name) |> Base.url_encode64(padding: false)
    end

    @doc "Stores a publication checkpoint and recording without publishing an S3 summary."
    @spec put_recording(Recording.t(), keyword()) :: :ok | {:error, term()}
    def put_recording(%Recording{} = recording, opts) do
      body = Codec.encode(recording)

      checkpoint = publication_key(recording.id, opts)

      saved_at = Keyword.get(opts, :publication_saved_at, System.system_time(:millisecond))

      operation =
        ExAws.S3.put_object(
          bucket(opts),
          checkpoint,
          :erlang.term_to_binary({writer_pid(opts), saved_at, body}),
          content_type: "application/octet-stream"
        )

      with :ok <- operation |> request(opts) |> result(),
           do: put(recording.id, "recording", body, opts)
    end

    @doc "Fetches a recording object without requiring an S3 summary."
    @spec fetch_recording(Recording.id(), keyword()) ::
            {:ok, Recording.t()} | {:error, term()}
    def fetch_recording(id, opts), do: get(id, "recording", Recording, opts)

    @doc "Fetches a completed recording or its pending publication checkpoint."
    def fetch_publication(id, opts) do
      case fetch_publication_state(id, opts) do
        {:ok, _state, recording} -> {:ok, recording}
        error -> error
      end
    end

    @doc "Fetches publication state, using the adapter's lookup for completed recordings."
    def fetch_publication_state(id, opts, fetch_completed \\ &fetch_recording/2) do
      case read_checkpoint(id, opts) do
        {:ok, _pid, saved_at, body} ->
          with {:ok, term} <- Codec.decode_non_executable(body),
               {:ok, %Recording{id: ^id} = recording} <- decode_shape(term, Recording) do
            {:ok, {:pending, saved_at}, recording}
          else
            {:ok, _other_recording} -> {:error, :undecodable}
            error -> error
          end

        {:error, :not_found} ->
          case fetch_completed.(id, opts) do
            {:ok, recording} -> {:ok, :published, recording}
            error -> error
          end

        error ->
          error
      end
    end

    @doc "Fetches a recording object from an exact stored S3 key."
    @spec fetch_recording_key(String.t(), keyword()) ::
            {:ok, Recording.t()} | {:error, term()}
    def fetch_recording_key(object_key, opts), do: get_key(object_key, Recording, opts)

    @impl true
    def list(opts) do
      base = prefix(opts) <> "/summaries/"

      opts
      |> object_keys(base, nil)
      |> Enum.flat_map(fn object_key ->
        id = object_key |> String.replace_prefix(base, "") |> String.trim_trailing(".summary")

        if Recording.valid_id?(id) and object_key == base <> id <> ".summary" do
          case get(id, "summary", Summary, opts) do
            {:ok, summary} -> [summary]
            {:error, :not_found} -> []
            {:error, :undecodable} -> []
            {:error, reason} -> raise "Replay summary read failed: #{inspect(reason)}"
          end
        else
          []
        end
      end)
      |> Summary.sort()
    end

    @impl true
    def delete(id, opts) do
      with :ok <- delete_partial_chunks(id, opts),
           :ok <- remove(id, "summary", opts) do
        remove(id, "recording", opts)
      end
    end

    @impl true
    def clear(opts) do
      delete_keys(object_keys(opts, prefix(opts) <> "/", nil), opts)
    end

    defp delete_keys(keys, opts) do
      Enum.reduce_while(keys, :ok, fn key, :ok ->
        case bucket(opts) |> ExAws.S3.delete_object(key) |> request(opts) |> result() do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end

    defp partial_key?(key, base, id) do
      match?(
        [_node, ^id | _rest],
        key |> String.replace_prefix(base, "") |> String.split("/")
      )
    end

    defp cleanup_partial(id, opts) do
      case delete_partial_chunks(id, opts) do
        :ok -> false
        {:error, reason} -> raise "Replay partial cleanup failed: #{inspect(reason)}"
      end
    end

    defp publication_current?(recording, opts) do
      case get(recording.id, "summary", Summary, opts) do
        {:ok, summary} ->
          Summary.new(recording, saved_at: summary.saved_at, live?: summary.live?) == summary

        {:error, :not_found} ->
          false

        {:error, reason} ->
          raise "Replay summary read failed: #{inspect(reason)}"
      end
    end

    defp fetch_chunks(id, opts) do
      object_keys(opts, partial_prefix(id, opts), nil)
      |> Enum.reject(&(Path.basename(&1) == "publication.pending"))
      |> Enum.sort_by(&Path.basename/1)
      |> Enum.reduce_while({:error, :not_found}, fn key, accumulated ->
        with {:ok, {%Recording{id: ^id} = recording, chunk}} <- read_term(key, opts),
             true <- is_list(chunk) and valid_chunk?(chunk) do
          previous =
            case accumulated do
              {:ok, _recording, events} -> events
              _empty -> %{}
            end

          {:cont, {:ok, recording, Map.merge(previous, Map.new(chunk))}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
          _invalid -> {:halt, {:error, :undecodable}}
        end
      end)
      |> complete_partial()
    end

    defp publication_key(id, opts), do: partial_prefix(id, opts) <> "publication.pending"

    defp read_checkpoint(id, opts) do
      case read_term(publication_key(id, opts), opts) do
        {:ok, {pid, saved_at, body}}
        when is_binary(pid) and is_integer(saved_at) and saved_at >= 0 and is_binary(body) ->
          if valid_pid?(pid), do: {:ok, pid, saved_at, body}, else: {:error, :undecodable}

        {:ok, _invalid} ->
          {:error, :undecodable}

        error ->
          error
      end
    end

    defp complete_partial({:ok, recording, events}) do
      ordered = events |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
      decode_shape(%{recording | events: ordered}, Recording)
    end

    defp complete_partial(error), do: error

    defp valid_chunk?([_ | _] = chunk) do
      Enum.all?(chunk, fn
        {sequence, %Event{at: at, data: data}} ->
          is_integer(sequence) and sequence >= 0 and is_integer(at) and at >= 0 and is_map(data)

        _entry ->
          false
      end)
    end

    defp valid_chunk?(_chunk), do: false

    defp partial_prefix(id, opts) do
      if not Recording.valid_id?(id), do: raise(ArgumentError, "Invalid replay recording id")
      prefix(opts) <> "/partials/" <> writer_node(opts) <> "/" <> id <> "/"
    end

    defp padded_sequence(sequence),
      do: sequence |> Integer.to_string() |> String.pad_leading(20, "0")

    defp writer_pid(opts), do: opts[:writer_pid] || List.to_string(:os.getpid())
    defp valid_pid?(pid), do: Regex.match?(~r/^[1-9][0-9]*$/, pid)

    defp writer_alive?(pid) do
      {command, args} = PhoenixReplay.Storage.Writer.command(pid)

      case System.find_executable(command) do
        nil ->
          true

        executable ->
          {output, status} = System.cmd(executable, args, stderr_to_stdout: true)

          if command == "tasklist",
            do: status != 0 or String.contains?(output, " #{pid} "),
            else: status == 0 or String.contains?(output, "not permitted")
      end
    end

    defp writer_stopped?(id, pid, opts) do
      if pid == writer_pid(opts),
        do: PhoenixReplay.Session.Buffer.config(id) == :error,
        else: not Keyword.get(opts, :writer_alive?, &writer_alive?/1).(pid)
    end

    defp object_keys(opts, key_prefix, token) do
      case list_keys(opts, key_prefix, token) do
        {:ok, keys} -> keys
        {:error, reason} -> raise "Replay object listing failed: #{inspect(reason)}"
      end
    end

    defp list_keys(opts, key_prefix, token) do
      query = [prefix: key_prefix]
      query = if token, do: Keyword.put(query, :continuation_token, token), else: query

      case request(ExAws.S3.list_objects_v2(bucket(opts), query), opts) do
        {:ok, %{body: body}} ->
          keys = Enum.map(body.contents, & &1.key)

          if body.is_truncated == "true" do
            with {:ok, remaining} <-
                   list_keys(opts, key_prefix, Map.fetch!(body, :next_continuation_token)),
                 do: {:ok, keys ++ remaining}
          else
            {:ok, keys}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp put(id, extension, data, opts) do
      bucket(opts)
      |> ExAws.S3.put_object(key(id, extension, opts), data,
        content_type: "application/octet-stream"
      )
      |> request(opts)
      |> result()
    end

    defp get(id, extension, shape, opts) do
      get_key(key(id, extension, opts), shape, opts)
    end

    defp get_key(object_key, shape, opts) do
      with {:ok, term} <- read_term(object_key, opts), do: decode_shape(term, shape)
    end

    defp decode_shape(%{__struct__: shape} = term, shape) do
      {:ok, shape |> struct(Map.from_struct(term)) |> upgrade()}
    rescue
      _error in [ArgumentError, FunctionClauseError, KeyError] -> {:error, :undecodable}
    end

    defp decode_shape(_term, _shape), do: {:error, :undecodable}

    defp read_term(key, opts) do
      case request(ExAws.S3.get_object(bucket(opts), key), opts) do
        {:ok, %{body: body}} -> Codec.decode_non_executable(body)
        {:error, {:http_error, 404, _}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    rescue
      ArgumentError -> {:error, :undecodable}
    end

    defp upgrade(%Recording{} = recording), do: Recording.upgrade(recording)
    defp upgrade(%Summary{} = summary), do: Summary.upgrade(summary)

    defp remove(id, extension, opts) do
      bucket(opts)
      |> ExAws.S3.delete_object(key(id, extension, opts))
      |> request(opts)
      |> result()
    end

    defp result({:ok, _response}), do: :ok
    defp result({:error, reason}), do: {:error, reason}

    defp key(id, extension, opts) do
      if not Recording.valid_id?(id), do: raise(ArgumentError, "Invalid replay recording id")
      directory = if extension == "summary", do: "summaries", else: "recordings"
      "#{prefix(opts)}/#{directory}/#{id}.#{extension}"
    end

    defp bucket(opts), do: Keyword.fetch!(opts, :bucket)
    defp request(operation, opts), do: Keyword.get(opts, :request, &ExAws.request/1).(operation)
  end
end
