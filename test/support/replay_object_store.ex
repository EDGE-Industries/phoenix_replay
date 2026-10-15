defmodule PhoenixReplay.Test.ReplayObjectStore do
  @moduledoc false

  def start_link, do: Agent.start_link(fn -> %{} end)

  def options(store, prefix) do
    [
      bucket: "trial-bucket",
      prefix: prefix,
      writer_node: "test-node",
      request: &request(store, &1)
    ]
  end

  def request(store, %{bucket: "trial-bucket"} = operation) do
    case operation do
      %{http_method: :put, path: path, body: body} when is_binary(body) ->
        Agent.update(store, &Map.put(&1, path, body))
        {:ok, %{status_code: 200}}

      %{http_method: :get, path: "/", params: params} ->
        prefix = Map.fetch!(params, "prefix")

        contents =
          Agent.get(store, fn objects ->
            objects
            |> Map.keys()
            |> Enum.filter(&String.starts_with?(&1, prefix))
            |> Enum.map(&%{key: String.trim_leading(&1, "/")})
          end)

        {:ok, %{body: %{contents: contents, is_truncated: "false"}}}

      %{http_method: :get, path: path} ->
        case Agent.get(store, &Map.fetch(&1, path)) do
          {:ok, body} -> {:ok, %{body: body}}
          :error -> {:error, {:http_error, 404, "NoSuchKey"}}
        end

      %{http_method: :head, path: path} ->
        if Agent.get(store, &Map.has_key?(&1, path)),
          do: {:ok, %{status_code: 200}},
          else: {:error, {:http_error, 404, "NoSuchKey"}}

      %{http_method: :delete, path: path} ->
        Agent.update(store, &Map.delete(&1, path))
        {:ok, %{status_code: 204}}
    end
  end

  def request(_store, _operation), do: {:error, :unexpected_bucket}
end
