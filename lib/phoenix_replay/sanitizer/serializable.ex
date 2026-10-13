defmodule PhoenixReplay.Sanitizer.Serializable do
  @moduledoc """
  Default sanitization plus removal of values that cannot be serialized safely.

  This opt-in sanitizer delegates key filtering and runtime compaction to
  `PhoenixReplay.Sanitizer.Default`, then replaces functions, pids, ports and
  references with `nil` at every nested position. It keeps map and struct
  shapes, list and tuple types, and typed standard-library values such as
  `DateTime`.

      config :phoenix_replay,
        sanitizer: PhoenixReplay.Sanitizer.Serializable
  """

  @behaviour PhoenixReplay.Sanitizer

  @impl true
  def sanitize_assigns(assigns) do
    assigns |> PhoenixReplay.Sanitizer.Default.sanitize_assigns() |> drop_runtime_values()
  end

  @impl true
  def sanitize_params(params) do
    params |> PhoenixReplay.Sanitizer.Default.sanitize_params() |> drop_runtime_values()
  end

  defp drop_runtime_values(value)
       when is_function(value) or is_pid(value) or is_port(value) or is_reference(value),
       do: nil

  defp drop_runtime_values(map) when is_map(map),
    do:
      Map.new(Map.to_list(map), fn {key, value} ->
        {drop_runtime_values(key), drop_runtime_values(value)}
      end)

  defp drop_runtime_values(list) when is_list(list), do: Enum.map(list, &drop_runtime_values/1)

  defp drop_runtime_values(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&drop_runtime_values/1) |> List.to_tuple()

  defp drop_runtime_values(value), do: value
end
