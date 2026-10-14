defmodule PhoenixReplay.Storage.S3PostgresTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias PhoenixReplay.Recording.{Event, Filter, Summary}
  alias PhoenixReplay.Storage.S3Postgres
  alias PhoenixReplay.Test.{Fixtures, PostgresRepo, ReplayObjectStore}

  defmodule MetadataFailureRepo do
    def insert_all(_table, _rows, _opts),
      do: raise(DBConnection.ConnectionError, "metadata database unavailable")
  end

  defmodule Migration do
    use Ecto.Migration

    def up, do: PhoenixReplay.Storage.S3Postgres.Migration.up()
    def down, do: PhoenixReplay.Storage.S3Postgres.Migration.down()
  end

  @migration_version 1_000_001

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(PostgresRepo, :auto)
    PostgresRepo.query!("DROP TABLE IF EXISTS phoenix_replay_s3_recordings CASCADE")
    PostgresRepo.query!("DELETE FROM schema_migrations WHERE version = #{@migration_version}")

    Ecto.Migrator.run(PostgresRepo, [{@migration_version, Migration}], :up,
      all: true,
      log: false
    )

    Ecto.Adapters.SQL.Sandbox.mode(PostgresRepo, :manual)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(PostgresRepo)
    PostgresRepo.delete_all("phoenix_replay_s3_recordings")
    {:ok, store} = ReplayObjectStore.start_link()

    %{opts: [repo: PostgresRepo] ++ ReplayObjectStore.options(store, "s3-postgres"), store: store}
  end

  test "stores searchable metadata in SQL and the recording only in S3", context do
    recording = Fixtures.counter_recording(id: "one")

    assert :ok = S3Postgres.save(recording, context.opts)
    assert {:ok, ^recording} = S3Postgres.fetch("one", context.opts)
    assert [%Summary{id: "one", event_names: ["inc"]}] = S3Postgres.list(context.opts)

    objects = Agent.get(context.store, & &1)
    assert Map.keys(objects) == ["s3-postgres/recordings/one.recording"]
    assert %{num_rows: 1} = PostgresRepo.query!("SELECT 1 FROM phoenix_replay_s3_recordings")
  end

  test "child spec does not start a repo that the host already owns" do
    child = S3Postgres.child_spec(repo: PostgresRepo, repo_opts: [])

    assert child.type == :supervisor
    assert :ignore = S3Postgres.RepoStarter.start_link(PostgresRepo, [])
  end

  test "fetch and delete use the object key stored with metadata", context do
    recording = Fixtures.counter_recording(id: "stored-key")
    assert :ok = S3Postgres.save(recording, context.opts)

    original = "s3-postgres/recordings/stored-key.recording"
    relocated = "s3-postgres/relocated/stored-key.recording"
    body = Agent.get(context.store, &Map.fetch!(&1, original))

    Agent.update(context.store, fn objects ->
      objects |> Map.delete(original) |> Map.put(relocated, body)
    end)

    PostgresRepo.query!(
      "UPDATE phoenix_replay_s3_recordings SET object_key = $1 WHERE namespace = $2 AND id = $3",
      [relocated, "s3-postgres|trial-bucket", "stored-key"]
    )

    assert {:ok, ^recording} = S3Postgres.fetch("stored-key", context.opts)
    assert :ok = S3Postgres.delete("stored-key", context.opts)
    assert Agent.get(context.store, &Map.has_key?(&1, relocated)) == false
  end

  test "can retry metadata publication after the S3 object was written", context do
    recording = Fixtures.counter_recording(id: "retry")
    failing = Keyword.put(context.opts, :repo, MetadataFailureRepo)

    assert {:error, %DBConnection.ConnectionError{message: "metadata database unavailable"}} =
             S3Postgres.save(recording, failing)

    assert Map.has_key?(Agent.get(context.store, & &1), "s3-postgres/recordings/retry.recording")
    assert [] = S3Postgres.list(context.opts)

    assert :ok = S3Postgres.save(recording, context.opts)
    assert [%Summary{id: "retry"}] = S3Postgres.list(context.opts)
  end

  test "applies every filter and page in PostgreSQL without reading S3", context do
    error = %Event{at: 9, type: :log, data: %{level: :error, message: "x", metadata: %{}}}

    mark = %Event{
      at: 9,
      type: :telemetry,
      data: %{event: [:shop, :paid], measurements: %{}, metadata: %{}, mark: "Paid"}
    }

    google = %PhoenixReplay.Recording.Client.Landing{
      path: "/",
      at: 0,
      params: %{"utm_source" => "google", "utm_medium" => "cpc"}
    }

    recordings = [
      Fixtures.counter_recording(id: "a", connected_at: 1),
      %{
        Fixtures.counter_recording(id: "b", connected_at: 2)
        | url: "http://x/sale/100%_off!",
          client: %{Fixtures.counter_recording().client | tab: "t1", landing: google},
          events: Enum.concat(Fixtures.counter_recording(id: "b").events, [mark])
      },
      %{
        Fixtures.counter_recording(id: "c", connected_at: 3)
        | view: Other,
          events: Enum.concat(Fixtures.counter_recording(id: "c").events, [error]),
          client: %{
            Fixtures.counter_recording().client
            | viewport: %{width: 390, height: 844, dpr: 3}
          }
      },
      %{
        Fixtures.counter_recording(id: "d", connected_at: 4)
        | client: %{Fixtures.counter_recording().client | tab: "t1", landing: google},
          events: Enum.concat(Fixtures.counter_recording(id: "d").events, [mark])
      }
    ]

    Enum.each(recordings, &assert(:ok = S3Postgres.save(&1, context.opts)))
    Agent.update(context.store, &Map.drop(&1, Map.keys(&1)))

    ids = fn params ->
      filter = Filter.from_params(params)
      {summaries, total} = S3Postgres.query(filter, [now: 10, limit: 10], context.opts)
      {Enum.map(summaries, & &1.id), total}
    end

    assert ids.(%{"q" => "100%_OFF"}) == {~w(b), 1}
    assert ids.(%{"q" => "INC"}) == {~w(d c b a), 4}
    assert ids.(%{"q" => "a http://localhost/counter"}) == {[], 0}
    assert ids.(%{"event" => "inc", "tab" => "t1"}) == {~w(d b), 2}
    assert ids.(%{"mark" => "Paid", "q" => "sale"}) == {~w(b), 1}
    assert ids.(%{"source" => "google", "medium" => "cpc"}) == {~w(d b), 2}
    assert ids.(%{"errors" => "1"}) == {~w(c), 1}
    assert ids.(%{"device_type" => "phone"}) == {~w(c), 1}
    assert ids.(%{}) == {~w(d c b a), 4}

    assert {[], 4} = S3Postgres.query(%Filter{}, [now: 10, offset: 4, limit: 0], context.opts)
    assert Agent.get(context.store, & &1) == %{}
  end

  test "matches Filter page, facets and histogram for all criteria", context do
    client = %PhoenixReplay.Recording.Client{
      tab: "tab-1",
      viewport: %{width: 390, height: 844, dpr: 3},
      user_agent:
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " <>
          "Version/17.0 Mobile/15E148 Safari/604.1",
      landing: %PhoenixReplay.Recording.Client.Landing{
        path: "/",
        at: 0,
        params: %{
          "utm_source" => "google",
          "utm_medium" => "cpc",
          "utm_campaign" => "spring"
        }
      }
    }

    error = %Event{
      at: 2_000,
      type: :log,
      data: %{level: :error, message: "failed", metadata: %{}}
    }

    mark = %Event{
      at: 2_001,
      type: :telemetry,
      data: %{event: [:checkout, :paid], measurements: %{}, metadata: %{}, mark: "Paid"}
    }

    rich = %{
      Fixtures.counter_recording(id: "rich", connected_at: 2)
      | client: client,
        code: %{release: "v2", modules: %{}, migration: nil, deps: %{}},
        events: Enum.concat(Fixtures.counter_recording(id: "rich").events, [error, mark])
    }

    recordings = [
      Fixtures.counter_recording(id: "plain", connected_at: 1),
      rich,
      %{
        Fixtures.counter_recording(id: "other", connected_at: 3)
        | url: "http://example.test/other"
      }
    ]

    Enum.each(recordings, &assert(:ok = S3Postgres.save(&1, context.opts)))
    summaries = S3Postgres.list(context.opts)
    page_opts = [now: 10, limit: 10, offset: 0, utc_offset: -500]

    filters = [
      %Filter{},
      %Filter{view: inspect(PhoenixReplay.Test.Live.Counter)},
      %Filter{source: "google", medium: "cpc", campaign: "spring"},
      %Filter{device_type: "phone", browser: "Mobile Safari", release: "v2", tab: "tab-1"},
      %Filter{event: "inc", mark: "Paid", errors: true, min_events: 1, longer_than: 1},
      %Filter{from: 2, to: 2},
      %Filter{query: "http://example.test"}
    ]

    for filter <- filters do
      assert S3Postgres.query(filter, page_opts, context.opts) ==
               Filter.page(summaries, filter, page_opts)

      for field <- Filter.fields() do
        assert S3Postgres.values(field, filter, page_opts, context.opts) ==
                 Filter.count_values(summaries, field, filter, page_opts[:now], page_opts[:limit])
      end

      assert S3Postgres.histogram(filter, 1_000, page_opts, context.opts) ==
               Filter.histogram(summaries, filter, 1_000, page_opts)
    end
  end

  test "counts SQL facets and histogram", context do
    mark = %Event{
      at: 9,
      type: :telemetry,
      data: %{event: [:shop, :paid], measurements: %{}, metadata: %{}, mark: "Paid"}
    }

    marked = %{
      Fixtures.counter_recording(id: "c", connected_at: 3)
      | events: Enum.concat(Fixtures.counter_recording(id: "c").events, [mark])
    }

    Enum.each(
      [
        Fixtures.counter_recording(id: "a", connected_at: 1),
        Fixtures.counter_recording(id: "b", connected_at: 2),
        marked
      ],
      &S3Postgres.save(&1, context.opts)
    )

    assert S3Postgres.values(:event, %Filter{}, [now: 10, limit: 10], context.opts) == [
             {"inc", 3}
           ]

    assert S3Postgres.values(:mark, %Filter{}, [now: 10, limit: 10], context.opts) == [
             {"Paid", 1}
           ]

    assert S3Postgres.histogram(%Filter{}, 2, [now: 10, utc_offset: 0], context.opts) == [
             {0, 1, 0},
             {2, 2, 0}
           ]
  end

  test "scopes metadata by prefix and matches negative time buckets", context do
    recording = Fixtures.counter_recording(id: "negative", connected_at: -1)
    other = Keyword.put(context.opts, :prefix, "other-prefix")

    assert :ok = S3Postgres.save(recording, context.opts)
    assert :ok = S3Postgres.save(%{recording | id: "other"}, other)
    assert [%Summary{id: "negative"}] = S3Postgres.list(context.opts)
    assert [%Summary{id: "other"}] = S3Postgres.list(other)

    expected = [{Filter.bucket(-1, 2, 0), 1, 0}]
    assert S3Postgres.histogram(%Filter{}, 2, [now: 10, utc_offset: 0], context.opts) == expected
  end

  test "does not publish metadata when the S3 write fails", context do
    opts = Keyword.put(context.opts, :request, fn _operation -> {:error, :timeout} end)

    assert {:error, :timeout} = S3Postgres.save(Fixtures.counter_recording(id: "failed"), opts)
    assert [] = S3Postgres.list(context.opts)
  end

  test "deletes metadata only after S3 deletion succeeds", context do
    assert :ok = S3Postgres.save(Fixtures.counter_recording(id: "kept"), context.opts)

    opts =
      Keyword.put(context.opts, :request, fn operation ->
        if operation.http_method == :delete,
          do: {:error, :timeout},
          else: context.opts[:request].(operation)
      end)

    assert {:error, :timeout} = S3Postgres.delete("kept", opts)
    assert [%Summary{id: "kept"}] = S3Postgres.list(context.opts)
  end

  test "recovers a chunked recording and preserves all events", context do
    opts = Keyword.merge(context.opts, writer_pid: "12345")
    first = %Event{at: 10, type: :event, data: %{name: "first", params: %{}}}
    second = %Event{at: 20, type: :render, data: %{assigns: %{count: 2}}}
    recording = %{Fixtures.counter_recording(id: "recover") | events: [first, second]}

    assert :ok = S3Postgres.append(recording, [{0, first}], opts)
    assert :ok = S3Postgres.append(recording, [{0, first}, {1, second}], opts)

    reader = Keyword.merge(opts, writer_pid: "23456", writer_alive?: fn _pid -> false end)
    assert ["recover"] = S3Postgres.partials(reader)

    config = %PhoenixReplay.Config{storage: {S3Postgres, reader}}
    assert ["recover"] = PhoenixReplay.Session.Recovery.run(config)
    assert [] = PhoenixReplay.Session.Recovery.run(config)
    assert {:ok, recovered} = S3Postgres.fetch("recover", reader)
    assert [^first, ^second, %Event{type: :exit}] = recovered.events
  end

  test "publishes a completed orphan and removes its chunks", context do
    opts = Keyword.merge(context.opts, writer_pid: "12345")
    event = %Event{at: 10, type: :event, data: %{name: "first", params: %{}}}
    later = %Event{at: 20, type: :render, data: %{assigns: %{count: 2}}}
    recording = %{Fixtures.counter_recording(id: "orphan") | events: [event, later]}

    assert :ok = S3Postgres.append(recording, [{0, event}], opts)
    assert :ok = PhoenixReplay.Storage.S3.put_recording(recording, opts)

    reader = Keyword.merge(opts, writer_pid: "23456", writer_alive?: fn _pid -> false end)
    assert [] = S3Postgres.partials(reader)
    assert [%Summary{id: "orphan"}] = S3Postgres.list(reader)
    assert {:ok, ^recording} = S3Postgres.fetch("orphan", reader)
    assert [] = S3Postgres.partials(reader)
  end

  test "a failed chunk cleanup leaves metadata for recovery", context do
    opts = Keyword.merge(context.opts, writer_pid: "12345")
    recording = Fixtures.counter_recording(id: "cleanup")
    event = %Event{at: 10, type: :event, data: %{name: "late", params: %{}}}

    assert :ok = S3Postgres.append(recording, [{0, event}], opts)

    failing =
      Keyword.put(opts, :request, fn operation ->
        if operation.http_method == :delete and String.ends_with?(operation.path, ".chunk"),
          do: {:error, :timeout},
          else: opts[:request].(operation)
      end)

    assert {:error, :timeout} = S3Postgres.save(recording, failing)
    assert [%Summary{id: "cleanup"}] = S3Postgres.list(opts)

    reader = Keyword.merge(opts, writer_pid: "23456", writer_alive?: fn _pid -> false end)
    assert [] = S3Postgres.partials(reader)

    assert {:ok, %PhoenixReplay.Recording{id: "cleanup"}} =
             S3Postgres.fetch_partial("cleanup", reader)
  end

  test "delete and clear keep other storage namespaces", context do
    other = Keyword.put(context.opts, :prefix, "other-prefix")
    assert :ok = S3Postgres.save(Fixtures.counter_recording(id: "one"), context.opts)
    assert :ok = S3Postgres.save(Fixtures.counter_recording(id: "two"), context.opts)
    assert :ok = S3Postgres.save(Fixtures.counter_recording(id: "other"), other)

    assert :ok =
             PhoenixReplay.Storage.S3.save(Fixtures.counter_recording(id: "legacy"), context.opts)

    assert :ok = S3Postgres.delete("one", context.opts)
    assert [%Summary{id: "two"}] = S3Postgres.list(context.opts)
    assert [%Summary{id: "other"}] = S3Postgres.list(other)

    assert :ok = S3Postgres.clear(context.opts)
    assert [] = S3Postgres.list(context.opts)
    assert [%Summary{id: "other"}] = S3Postgres.list(other)

    objects = Agent.get(context.store, &Map.keys/1)
    assert objects == ["other-prefix/recordings/other.recording"]
  end

  test "repeated and concurrent saves publish independent ids", context do
    assert :ok =
             S3Postgres.save(
               Fixtures.counter_recording(id: "repeat", connected_at: 1),
               context.opts
             )

    assert :ok =
             S3Postgres.save(
               Fixtures.counter_recording(id: "repeat", clicks: 3, connected_at: 1),
               context.opts
             )

    parent = self()

    tasks =
      for id <- ~w(one two three four) do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(PostgresRepo, parent, self())
          S3Postgres.save(Fixtures.counter_recording(id: id, connected_at: 1), context.opts)
        end)
      end

    assert Enum.map(tasks, &Task.await(&1, 5_000)) == List.duplicate(:ok, 4)

    assert Enum.map(S3Postgres.list(context.opts), & &1.id) ==
             Enum.sort(~w(four three two one repeat), :desc)

    assert [%Summary{event_count: 8}] =
             Enum.filter(S3Postgres.list(context.opts), &(&1.id == "repeat"))
  end
end
