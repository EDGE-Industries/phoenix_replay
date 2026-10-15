if Code.ensure_loaded?(Ecto.Query) do
  defmodule PhoenixReplay.Storage.EctoQuery do
    import Ecto.Query

    @doc "Adds the shared recording-list ordering and page bounds."
    def page(query, page_opts) do
      query
      |> order_by(desc: :connected_at, desc: :id)
      |> offset(^Keyword.get(page_opts, :offset, 0))
      |> limit(^Keyword.fetch!(page_opts, :limit))
    end

    @doc "Adds the shared SQL histogram grouping and projection."
    def histogram(query, size, page_opts) do
      utc_offset = Keyword.get(page_opts, :utc_offset, 0)

      query
      |> group_by(selected_as(:bucket))
      |> order_by(selected_as(:bucket))
      |> select([r], {
        selected_as(
          fragment(
            "(? + ?) - ((? + ?) % ?) - ?",
            r.connected_at,
            ^utc_offset,
            r.connected_at,
            ^utc_offset,
            ^size,
            ^utc_offset
          ),
          :bucket
        ),
        count(r.id),
        sum(fragment("CASE WHEN ? > 0 THEN 1 ELSE 0 END", r.error_count))
      })
    end

    @doc "Builds the shared exact-match criterion for a summary column."
    def equal(column, value), do: dynamic([r], field(r, ^column) == ^value)
  end
end
