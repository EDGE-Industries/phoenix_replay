defmodule PhoenixReplay.Storage.S3Test do
  use ExUnit.Case, async: true

  alias PhoenixReplay.Recording
  alias PhoenixReplay.Recording.{Event, Summary}
  alias PhoenixReplay.Storage.Codec
  alias PhoenixReplay.Storage.S3

  setup do
    {:ok, store} = PhoenixReplay.Test.ReplayObjectStore.start_link()
    opts = PhoenixReplay.Test.ReplayObjectStore.options(store, "replay-trial")
    recording = %Recording{id: "trial", view: __MODULE__, connected_at: 100}
    %{opts: opts, recording: recording, store: store}
  end

  test "repeated saves replace the same recording and list only summaries", context do
    assert :ok = S3.save(context.recording, context.opts)
    assert :ok = S3.save(context.recording, context.opts)
    assert {:ok, recording} = S3.fetch("trial", context.opts)
    assert recording == context.recording
    assert [%Summary{id: "trial"}] = S3.list(context.opts)
    assert map_size(Agent.get(context.store, & &1)) == 2

    assert :ok = S3.delete("trial", context.opts)
    assert [] = S3.list(context.opts)
    assert {:error, :not_found} = S3.fetch("trial", context.opts)
  end

  test "invalid writer identity fails before publishing objects", context do
    for identity <- [nil, "", "  ", :invalid] do
      opts = Keyword.put(context.opts, :writer_node, identity)
      assert_raise ArgumentError, fn -> S3.save(context.recording, opts) end
      assert Agent.get(context.store, & &1) == %{}
    end
  end

  test "listing skips non-canonical summary object keys", context do
    assert :ok = S3.save(context.recording, context.opts)

    Agent.update(context.store, fn objects ->
      objects
      |> Map.put("replay-trial/summaries/.summary", "invalid")
      |> Map.put("replay-trial/summaries/nested/trial.summary", "invalid")
      |> Map.put("replay-trial/summaries/trial.txt", "invalid")
    end)

    assert [%Summary{id: "trial"}] = S3.list(context.opts)
  end

  test "a cold node can list stored summaries", context do
    recording = %{
      context.recording
      | client: %PhoenixReplay.Recording.Client{
          viewport: %{
            width: 1280,
            height: 720,
            dpr: 2,
            pointer: :fine,
            color_scheme: :dark,
            contrast: :no_preference,
            hover: :hover
          }
        }
    }

    body = recording |> Summary.new() |> Codec.encode() |> Base.encode64()

    code = """
    body = Base.decode64!(#{inspect(body)})
    request = fn
      %{path: "/"} -> {:ok, %{body: %{contents: [%{key: "cold/summaries/trial.summary"}], is_truncated: "false"}}}
      _operation -> {:ok, %{body: body}}
    end
    result = PhoenixReplay.Storage.S3.list(bucket: "bucket", prefix: "cold", writer_node: "cold", request: request)
    if length(result) != 1, do: raise("cold summary read failed")
    """

    args = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)]) ++ ["-e", code]

    {output, status} =
      System.cmd(System.find_executable("elixir"), args,
        env: [{"ERL_FLAGS", "+S 2:2"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "clear preserves unrelated objects", context do
    Agent.update(context.store, &Map.put(&1, "/media/image.jpg", "image"))
    assert :ok = S3.save(context.recording, context.opts)
    assert :ok = S3.clear(context.opts)
    assert Agent.get(context.store, & &1) == %{"/media/image.jpg" => "image"}
  end

  test "clear removes orphan recordings and corrupt summaries", context do
    Agent.update(context.store, fn objects ->
      objects
      |> Map.put("replay-trial/recordings/orphan.recording", "orphan")
      |> Map.put("replay-trial/summaries/broken.summary", "broken")
      |> Map.put("replay-trial-other/keep.recording", "keep")
    end)

    assert :ok = S3.clear(context.opts)
    assert Agent.get(context.store, & &1) == %{"replay-trial-other/keep.recording" => "keep"}
  end

  test "failed recording writes never publish a summary", context do
    request = fn operation ->
      assert operation.path == "replay-trial/recordings/trial.recording"
      {:error, :timeout}
    end

    opts = Keyword.put(context.opts, :request, request)
    assert {:error, :timeout} = S3.save(context.recording, opts)
  end

  test "failed summary writes can be retried", context do
    request = fn operation ->
      if String.ends_with?(operation.path, ".summary"),
        do: {:error, :timeout},
        else: context.opts[:request].(operation)
    end

    assert {:error, :timeout} =
             S3.save(context.recording, Keyword.put(context.opts, :request, request))

    assert [] = S3.list(context.opts)
    assert :ok = S3.save(context.recording, context.opts)
    assert [%Summary{id: "trial"}] = S3.list(context.opts)
  end

  test "listing follows continuation tokens without reading full recordings", context do
    request = fn operation ->
      case operation do
        %{path: "/", params: %{"continuation-token" => "next"}} ->
          {:ok,
           %{
             body: %{
               contents: [%{key: "replay-trial/summaries/second.summary"}],
               is_truncated: "false"
             }
           }}

        %{path: "/"} ->
          {:ok,
           %{
             body: %{
               contents: [%{key: "replay-trial/summaries/first.summary"}],
               is_truncated: "true",
               next_continuation_token: "next"
             }
           }}

        %{path: path} ->
          id = path |> Path.basename() |> String.trim_trailing(".summary")
          assert id in ["first", "second"]
          summary = Summary.new(%{context.recording | id: id})
          {:ok, %{body: Codec.encode(summary)}}
      end
    end

    assert S3.list(Keyword.put(context.opts, :request, request))
           |> Enum.map(& &1.id)
           |> Enum.sort() == ["first", "second"]
  end

  test "read, list and delete errors are not reported as success", context do
    opts = Keyword.put(context.opts, :request, fn _ -> {:error, :timeout} end)
    assert {:error, :timeout} = S3.fetch("trial", opts)
    assert {:error, :timeout} = S3.delete("trial", opts)
    assert_raise RuntimeError, ~r/listing failed/, fn -> S3.list(opts) end
  end

  test "malformed terms are rejected without loading application modules", context do
    for body <- ["invalid", <<131, 80, 0, 0, 0, 1, 0>>, Codec.encode(:wrong_shape)] do
      opts = Keyword.put(context.opts, :request, fn _ -> {:ok, %{body: body}} end)
      assert {:error, :undecodable} = S3.fetch("trial", opts)
    end
  end

  test "invalid nested recording and summary fields are rejected", context do
    for term <- [
          %{context.recording | client: :invalid},
          %{Summary.new(context.recording) | viewport: :invalid}
        ] do
      opts =
        Keyword.put(context.opts, :request, fn operation ->
          if operation.path == "/" do
            {:ok,
             %{
               body: %{
                 contents: [%{key: "replay-trial/summaries/trial.summary"}],
                 is_truncated: "false"
               }
             }}
          else
            {:ok, %{body: Codec.encode(term)}}
          end
        end)

      if term.__struct__ == Recording do
        assert {:error, :undecodable} = S3.fetch("trial", opts)
      else
        assert [] = S3.list(opts)
      end
    end
  end

  test "invalid recording metadata in partial chunks is rejected", context do
    event = %Event{type: :render, at: 0, data: %{assigns: %{}}}
    assert :ok = S3.append(context.recording, [{0, event}], context.opts)

    Agent.update(context.store, fn objects ->
      Map.new(objects, fn {key, _body} ->
        {key, Codec.encode({%{context.recording | client: :invalid}, [{0, event}]})}
      end)
    end)

    assert {:error, :undecodable} = S3.fetch_partial("trial", context.opts)
  end

  test "unknown recording fields are discarded", context do
    term = Map.put(context.recording, :future_field, true)
    opts = Keyword.put(context.opts, :request, fn _ -> {:ok, %{body: Codec.encode(term)}} end)
    assert {:ok, recording} = S3.fetch("trial", opts)
    assert recording == context.recording
  end

  test "recordings cannot contain executable terms", context do
    recording = %{context.recording | params: %{callback: &Enum.count/1}}

    opts =
      Keyword.put(context.opts, :request, fn _ -> {:ok, %{body: Codec.encode(recording)}} end)

    assert {:error, :undecodable} = S3.fetch("trial", opts)
  end

  test "clear returns object deletion failures", context do
    assert :ok = S3.save(context.recording, context.opts)

    request = fn
      %{http_method: :delete} -> {:error, :timeout}
      operation -> context.opts[:request].(operation)
    end

    opts = Keyword.put(context.opts, :request, request)
    assert {:error, :timeout} = S3.clear(opts)
  end

  test "summary read errors are not hidden", context do
    assert :ok = S3.save(context.recording, context.opts)

    request = fn
      %{http_method: :get, path: "replay-trial/summaries/trial.summary"} -> {:error, :timeout}
      operation -> context.opts[:request].(operation)
    end

    opts = Keyword.put(context.opts, :request, request)
    assert_raise RuntimeError, ~r/summary read failed/, fn -> S3.list(opts) end
  end

  test "invalid recording ids cannot access another prefix", context do
    opts = Keyword.put(context.opts, :request, fn _ -> {:ok, %{body: "invalid"}} end)
    assert_raise ArgumentError, fn -> S3.fetch("../media", opts) end
  end

  test "chunks merge in sequence order and retries do not lose or repeat events", context do
    opts = Keyword.merge(context.opts, writer_node: "test-node", writer_pid: "12345")
    first = %Event{type: :mount, at: 0, data: %{assigns: %{count: 0}}}
    second = %Event{type: :event, at: 10, data: %{name: "increment", params: %{}}}
    third = %Event{type: :render, at: 11, data: %{assigns: %{count: 1}}}
    older = [{0, first}, {1, second}]
    newer = [{0, first}, {1, second}, {2, third}]

    assert :ok = S3.append(context.recording, older, opts)
    assert :ok = S3.append(context.recording, newer, opts)
    assert :ok = S3.append(context.recording, older, opts)
    assert {:ok, partial} = S3.fetch_partial("trial", opts)
    assert partial.events == [first, second, third]

    assert :ok = S3.save(partial, opts)
    assert {:ok, ^partial} = S3.fetch("trial", opts)

    assert Enum.all?(
             Agent.get(context.store, &Map.keys/1),
             &(not String.ends_with?(&1, ".chunk"))
           )
  end

  test "crashed writers recover once, while other nodes and live writers are left alone",
       context do
    opts = Keyword.merge(context.opts, writer_node: "test-node", writer_pid: "12345")
    event = %Event{type: :event, at: 10, data: %{name: "increment", params: %{}}}
    assert :ok = S3.append(context.recording, [{0, event}], opts)
    other = %{context.recording | id: "other"}

    assert :ok =
             S3.append(
               other,
               [{0, event}],
               Keyword.put(opts, :writer_node, "other-node")
             )

    reader = Keyword.merge(opts, writer_pid: "23456", writer_alive?: fn _pid -> true end)
    assert [] = S3.partials(reader)
    reader = Keyword.put(reader, :writer_alive?, fn _pid -> false end)
    assert ["trial"] = S3.partials(reader)
    config = %PhoenixReplay.Config{storage: {S3, reader}}
    assert ["trial"] = PhoenixReplay.Session.Recovery.run(config)
    assert [] = PhoenixReplay.Session.Recovery.run(config)
    assert {:ok, recording} = S3.fetch("trial", reader)
    assert [^event, %Event{type: :exit}] = recording.events

    assert {:ok, _partial} =
             S3.fetch_partial("other", Keyword.put(opts, :writer_node, "other-node"))
  end

  test "late chunks cannot replace a completed recording during recovery", context do
    opts = Keyword.merge(context.opts, writer_node: "test-node", writer_pid: "12345")
    event = %Event{type: :event, at: 10, data: %{name: "increment", params: %{}}}
    recording = %{context.recording | events: [event]}
    assert :ok = S3.save(recording, opts)
    assert :ok = S3.append(context.recording, [{0, event}], opts)
    reader = Keyword.merge(opts, writer_pid: "23456", writer_alive?: fn _pid -> false end)
    assert [] = S3.partials(reader)
    assert {:ok, ^recording} = S3.fetch("trial", reader)

    assert Enum.all?(
             Agent.get(context.store, &Map.keys/1),
             &(not String.ends_with?(&1, ".chunk"))
           )
  end

  test "a completed blob is preserved when summary publication failed", context do
    opts = Keyword.merge(context.opts, writer_node: "test-node", writer_pid: "12345")
    event = %Event{type: :event, at: 10, data: %{name: "increment", params: %{}}}
    later = %Event{type: :render, at: 20, data: %{assigns: %{count: 1}}}
    assert :ok = S3.append(context.recording, [{0, event}], opts)

    request = fn operation ->
      if operation.http_method == :put and String.ends_with?(operation.path, ".summary"),
        do: {:error, :timeout},
        else: opts[:request].(operation)
    end

    recording = %{context.recording | events: [event, later]}

    assert {:error, :timeout} =
             S3.save(recording, Keyword.put(opts, :request, request))

    assert {:ok, ^recording} = S3.fetch_partial("trial", opts)
    reader = Keyword.merge(opts, writer_pid: "23456", writer_alive?: fn _pid -> false end)
    config = %PhoenixReplay.Config{storage: {S3, reader}}
    assert [] = PhoenixReplay.Session.Recovery.run(config)
    assert {:ok, ^recording} = S3.fetch("trial", reader)
    assert [%Summary{id: "trial"}] = S3.list(reader)
  end

  test "deleting a completed recording prevents recovery after chunk cleanup failed", context do
    opts = Keyword.merge(context.opts, writer_node: "test-node", writer_pid: "12345")
    event = %Event{type: :event, at: 10, data: %{name: "increment", params: %{}}}
    assert :ok = S3.append(context.recording, [{0, event}], opts)

    request = fn operation ->
      if operation.http_method == :delete and String.ends_with?(operation.path, ".chunk"),
        do: {:error, :timeout},
        else: opts[:request].(operation)
    end

    assert {:error, :timeout} = S3.save(context.recording, Keyword.put(opts, :request, request))

    assert [%Summary{id: "trial"}] = S3.list(opts)
    assert :ok = S3.delete("trial", context.opts)
    reader = Keyword.merge(opts, writer_pid: "23456", writer_alive?: fn _pid -> false end)
    config = %PhoenixReplay.Config{storage: {S3, reader}}
    assert [] = PhoenixReplay.Session.Recovery.run(config)
    assert {:error, :not_found} = S3.fetch("trial", opts)
  end

  test "bad chunks and failed writes do not report success", context do
    assert {:error, :invalid_chunk} = S3.append(context.recording, [], context.opts)

    assert {:error, :invalid_chunk} =
             S3.append(context.recording, [{-1, :bad}], context.opts)

    opts = Keyword.put(context.opts, :request, fn _operation -> {:error, :timeout} end)
    event = %Event{type: :event, at: 1, data: %{name: "increment", params: %{}}}
    assert {:error, :timeout} = S3.append(context.recording, [{0, event}], opts)
    assert {:error, :timeout} = S3.fetch_partial("trial", opts)
  end

  test "partial storage requires a stable non-empty writer identity", context do
    event = %Event{type: :event, at: 1, data: %{name: "increment", params: %{}}}

    for writer_node <- [nil, "", "   ", 123] do
      opts = Keyword.put(context.opts, :writer_node, writer_node)

      assert_raise ArgumentError, ~r/non-empty :writer_node/, fn ->
        S3.append(context.recording, [{0, event}], opts)
      end
    end

    opts = Keyword.delete(context.opts, :writer_node)

    assert_raise ArgumentError, ~r/non-empty :writer_node/, fn ->
      S3.append(context.recording, [{0, event}], opts)
    end
  end
end
