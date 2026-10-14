if Code.ensure_loaded?(Ecto.Migration) do
  defmodule PhoenixReplay.Storage.S3Postgres.Migration do
    @moduledoc """
    Creates the PostgreSQL metadata table for `PhoenixReplay.Storage.S3Postgres`.

    The table stores summaries and the S3 object key. Recording data stays in
    S3. Run this migration in the database and schema dedicated to replay
    metadata:

        defmodule MyApp.Repo.Migrations.AddReplayMetadata do
          use Ecto.Migration

          def up, do: PhoenixReplay.Storage.S3Postgres.Migration.up()
          def down, do: PhoenixReplay.Storage.S3Postgres.Migration.down()
        end

    The migration is PostgreSQL-specific because it uses array and JSONB
    columns for SQL filtering of event names and marks.
    """

    use Ecto.Migration

    @table :phoenix_replay_s3_recordings

    @doc "Creates the replay metadata table and its query indexes."
    @spec up() :: :ok
    def up do
      create table(@table, primary_key: false) do
        add :namespace, :string, primary_key: true
        add :id, :string, primary_key: true
        add :object_key, :text, null: false
        add :view, :string, null: false
        add :url, :text
        add :connected_at, :bigint, null: false
        add :event_count, :integer, null: false
        add :error_count, :integer, null: false
        add :duration_ms, :integer, null: false
        add :event_names, {:array, :string}, null: false, default: []
        add :marks, :map, null: false, default: %{}
        add :tab, :string
        add :viewport, :string
        add :device, :string
        add :device_type, :string
        add :browser, :string
        add :release, :string
        add :source, :string
        add :medium, :string
        add :campaign, :string
        add :saved_at, :bigint
      end

      create index(@table, [:connected_at])
      create index(@table, [:namespace, :connected_at, :id])
      create index(@table, [:id])
      create index(@table, [:view])
      create index(@table, [:source])
      create index(@table, [:medium])
      create index(@table, [:campaign])
      create index(@table, [:device_type])
      create index(@table, [:browser])
      create index(@table, [:release])
      create index(@table, [:tab])
      create index(@table, [:saved_at])
      create index(@table, [:event_names], using: :gin)
      create index(@table, [:marks], using: :gin)
      :ok
    end

    @doc "Drops the replay metadata table."
    @spec down() :: :ok
    def down do
      drop table(@table)
      :ok
    end
  end
end
