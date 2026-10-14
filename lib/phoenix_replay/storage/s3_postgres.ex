if Code.ensure_loaded?(Ecto.Query) and Code.ensure_loaded?(ExAws.S3) do
  defmodule PhoenixReplay.Storage.S3Postgres do
    @moduledoc """
    Stores recording objects in S3 and searchable summaries in PostgreSQL.

    PostgreSQL handles every dashboard filter, facet, count, histogram and
    page. Playback fetches the recording object only after a recording is
    opened. Running-session chunks use the same S3 layout as
    `PhoenixReplay.Storage.S3`.

    ## Options

      * `:repo` — a PostgreSQL Ecto repo (required)
      * `:repo_opts` — options passed when the adapter starts the repo
      * `:bucket` — the S3 bucket (required)
      * `:prefix` — the application prefix (required)
      * `:writer_node` — stable non-empty node identity for chunk recovery
      * `:request` — an ExAws request function, useful for an S3-compatible endpoint or tests

    Run `PhoenixReplay.Storage.S3Postgres.Migration` in the replay metadata
    database before enabling this backend. The database can share a PostgreSQL
    server with the application while using a separate database and the
    `public` schema. Metadata rows are scoped by the S3 bucket and trimmed
    prefix, so multiple storage namespaces can share the table without
    affecting one another.
    """

    @behaviour PhoenixReplay.Storage

    import Ecto.Query

    alias PhoenixReplay.Recording
    alias PhoenixReplay.Recording.{Client, Filter, Summary}
    alias PhoenixReplay.Storage.EctoQuery
    alias PhoenixReplay.Storage.S3

    @table "phoenix_replay_s3_recordings"
    @summary_fields [
      :id,
      :view,
      :url,
      :connected_at,
      :event_count,
      :error_count,
      :duration_ms,
      :event_names,
      :marks,
      :tab,
      :viewport,
      :device,
      :device_type,
      :browser,
      :release,
      :source,
      :medium,
      :campaign,
      :saved_at
    ]
    @replaced_fields [:object_key | @summary_fields]
    @columns [:view, :source, :medium, :campaign, :device_type, :browser, :release]

    @impl true
    def save(%Recording{} = recording, opts) do
      S3.writer_node(opts)
      summary = Summary.new(recording, saved_at: System.system_time(:millisecond))

      with :ok <- S3.put_recording(recording, opts),
           {:ok, _count} <- upsert(summary, opts) do
        delete_chunks(recording.id, opts)
      end
    end

    @impl true
    def fetch(id, opts) do
      case metadata_object_key(id, opts) do
        nil -> {:error, :not_found}
        object_key -> S3.fetch_recording_key(object_key, opts)
      end
    end

    @impl true
    def list(opts) do
      from(r in @table,
        where: r.namespace == ^S3.namespace(opts),
        order_by: [desc: r.connected_at, desc: r.id],
        select: map(r, ^@summary_fields)
      )
      |> repo(opts).all()
      |> Enum.map(&to_summary/1)
    end

    @impl true
    def query(%Filter{} = filter, page_opts, opts) do
      matching = matching(filter, page_opts, opts)
      repo = repo(opts)
      total = repo.aggregate(matching, :count, :id)

      page =
        matching
        |> EctoQuery.page(page_opts)
        |> select([r], map(r, ^@summary_fields))
        |> repo.all()
        |> Enum.map(&to_summary/1)

      {page, total}
    end

    @impl true
    def values(field, %Filter{} = filter, page_opts, opts) when field in @columns do
      filter = Map.put(filter, field, nil)

      filter
      |> matching(page_opts, opts)
      |> where([r], not is_nil(field(r, ^field)))
      |> group_by([r], field(r, ^field))
      |> order_by([r], desc: count(r.id), asc: field(r, ^field))
      |> limit(^Keyword.fetch!(page_opts, :limit))
      |> select([r], {field(r, ^field), count(r.id)})
      |> repo(opts).all()
    end

    @impl true
    def values(:event, %Filter{} = filter, page_opts, opts) do
      filter = %{filter | event: nil}

      filter
      |> matching(page_opts, opts)
      |> join(:inner, [r], event in fragment("LATERAL unnest(?)", r.event_names), on: true)
      |> group_by([_r, event], fragment("?", event))
      |> order_by([r, event], desc: count(r.id), asc: fragment("?", event))
      |> limit(^Keyword.fetch!(page_opts, :limit))
      |> select([r, event], {fragment("?", event), count(r.id)})
      |> repo(opts).all()
    end

    @impl true
    def values(:mark, %Filter{} = filter, page_opts, opts) do
      filter = %{filter | mark: nil}

      filter
      |> matching(page_opts, opts)
      |> join(
        :inner,
        [r],
        mark in fragment("LATERAL jsonb_object_keys(?)", r.marks),
        on: true
      )
      |> group_by([_r, mark], fragment("?", mark))
      |> order_by([r, mark], desc: count(r.id), asc: fragment("?", mark))
      |> limit(^Keyword.fetch!(page_opts, :limit))
      |> select([r, mark], {fragment("?", mark), count(r.id)})
      |> repo(opts).all()
    end

    @impl true
    def histogram(%Filter{} = filter, size, page_opts, opts) do
      filter
      |> matching(page_opts, opts)
      |> EctoQuery.histogram(size, page_opts)
      |> repo(opts).all()
      |> Enum.map(fn {start, sessions, errors} -> {start, sessions, errors || 0} end)
    end

    @impl true
    def delete(id, opts) do
      object_key = metadata_object_key(id, opts) || S3.recording_key(id, opts)

      with :ok <- delete_chunks(id, opts),
           :ok <- delete_recording_object(object_key, opts),
           {:ok, _count} <- delete_metadata(id, opts) do
        :ok
      end
    end

    @impl true
    def clear(opts) do
      with {:ok, keys} <- all_object_keys(opts),
           :ok <- S3.delete_objects(keys, opts),
           {:ok, _count} <- delete_all_metadata(opts) do
        :ok
      end
    end

    @impl true
    def append(%Recording{} = recording, chunk, opts),
      do: S3.append(recording, chunk, opts)

    @impl true
    def fetch_partial(id, opts), do: S3.fetch_partial(id, opts)

    @impl true
    def partials(opts) do
      S3.partial_ids(opts)
      |> Enum.filter(fn id ->
        if metadata_exists?(id, opts) do
          case delete_chunks(id, opts) do
            :ok -> false
            {:error, reason} -> raise "Replay chunk cleanup failed: #{inspect(reason)}"
          end
        else
          case S3.fetch_recording(id, opts) do
            {:ok, recording} ->
              case save(recording, opts) do
                :ok -> false
                {:error, reason} -> raise "Replay metadata recovery failed: #{inspect(reason)}"
              end

            {:error, :not_found} ->
              true

            {:error, reason} ->
              raise "Replay recording read failed: #{inspect(reason)}"
          end
        end
      end)
    end

    @impl true
    def child_spec(opts) do
      repo = Keyword.fetch!(opts, :repo)

      %{
        id: {__MODULE__, repo},
        start:
          {PhoenixReplay.Storage.S3Postgres.RepoStarter, :start_link,
           [repo, Keyword.get(opts, :repo_opts, [])]},
        type: :supervisor
      }
    end

    defp upsert(%Summary{} = summary, opts) do
      row =
        summary
        |> Map.take(@summary_fields)
        |> Map.update!(:viewport, &Client.encode_viewport/1)
        |> Map.merge(%{
          namespace: S3.namespace(opts),
          object_key: S3.recording_key(summary.id, opts)
        })

      {count, _returned} =
        repo(opts).insert_all(@table, [row],
          on_conflict: {:replace, @replaced_fields},
          conflict_target: [:namespace, :id]
        )

      {:ok, count}
    rescue
      error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
    end

    defp matching(%Filter{} = filter, page_opts, opts) do
      criteria =
        Enum.concat(
          Enum.map(@columns, &{&1, Map.fetch!(filter, &1)}),
          query: filter.query,
          event: filter.event,
          mark: filter.mark,
          started_after: Filter.started_after(filter, Keyword.fetch!(page_opts, :now)),
          from: filter.from,
          to: filter.to,
          longer_than: filter.longer_than,
          min_events: filter.min_events,
          errors: filter.errors,
          tab: filter.tab,
          until: page_opts[:until],
          since: page_opts[:since]
        )

      criteria
      |> Enum.reject(fn {_criterion, value} -> value in [nil, false] end)
      |> Enum.reduce(
        from(r in @table, as: :recording, where: r.namespace == ^S3.namespace(opts)),
        fn {criterion, value}, query ->
          where(query, ^criterion(criterion, value))
        end
      )
    end

    defp criterion(column, value) when column in @columns,
      do: EctoQuery.equal(column, value)

    defp criterion(:query, value) do
      needle = String.downcase(value)

      dynamic(
        [r],
        fragment(
          "(position(? in lower(coalesce(?, ''))) > 0 OR position(? in lower(coalesce(?, ''))) > 0 OR position(? in lower(coalesce(?, ''))) > 0 OR position(? in lower(coalesce(?, ''))) > 0 OR EXISTS (SELECT 1 FROM unnest(?) AS event_name WHERE position(? in lower(event_name)) > 0) OR EXISTS (SELECT 1 FROM jsonb_object_keys(?) AS mark_name WHERE position(? in lower(mark_name)) > 0))",
          ^needle,
          r.id,
          ^needle,
          r.url,
          ^needle,
          r.source,
          ^needle,
          r.campaign,
          r.event_names,
          ^needle,
          r.marks,
          ^needle
        )
      )
    end

    defp criterion(:event, value),
      do: dynamic([r], fragment("? @> ARRAY[?]::varchar[]", r.event_names, ^value))

    defp criterion(:mark, value),
      do: dynamic([r], fragment("? \\? CAST(? AS text)", r.marks, ^value))

    defp criterion(:started_after, ms), do: dynamic([r], r.connected_at >= ^ms)
    defp criterion(:from, ms), do: dynamic([r], r.connected_at >= ^ms)
    defp criterion(:to, ms), do: dynamic([r], r.connected_at <= ^ms)
    defp criterion(:longer_than, seconds), do: dynamic([r], r.duration_ms >= ^(seconds * 1_000))
    defp criterion(:min_events, count), do: dynamic([r], r.event_count >= ^count)
    defp criterion(:errors, true), do: dynamic([r], r.error_count > 0)
    defp criterion(:tab, tab), do: dynamic([r], r.tab == ^tab)
    defp criterion(:until, ms), do: dynamic([r], coalesce(r.saved_at, r.connected_at) <= ^ms)
    defp criterion(:since, ms), do: dynamic([r], coalesce(r.saved_at, r.connected_at) > ^ms)

    defp to_summary(row) do
      row
      |> Map.update!(:viewport, &Client.decode_viewport/1)
      |> then(&struct!(Summary, &1))
      |> Summary.upgrade()
    end

    defp metadata_exists?(id, opts),
      do: not is_nil(metadata_object_key(id, opts))

    defp metadata_object_key(id, opts) do
      repo(opts).one(
        from(r in @table,
          where: r.namespace == ^S3.namespace(opts) and r.id == ^id,
          select: r.object_key
        )
      )
    end

    defp delete_metadata(id, opts) do
      {count, _returned} =
        repo(opts).delete_all(
          from(r in @table, where: r.namespace == ^S3.namespace(opts) and r.id == ^id)
        )

      {:ok, count}
    end

    defp delete_all_metadata(opts) do
      {count, _returned} =
        repo(opts).delete_all(from(r in @table, where: r.namespace == ^S3.namespace(opts)))

      {:ok, count}
    end

    defp delete_recording_object(object_key, opts) do
      S3.delete_object(object_key, opts)
    end

    defp delete_chunks(id, opts) do
      S3.delete_partial_chunks(id, opts)
    end

    defp all_object_keys(opts) do
      S3.list_objects(opts, S3.prefix(opts) <> "/")
    end

    defp repo(opts), do: Keyword.fetch!(opts, :repo)

    defmodule RepoStarter do
      @moduledoc false

      def start_link(repo, opts) do
        if Process.whereis(repo) do
          :ignore
        else
          case repo.start_link(opts) do
            {:error, {:already_started, _pid}} -> :ignore
            result -> result
          end
        end
      end
    end
  end
end
