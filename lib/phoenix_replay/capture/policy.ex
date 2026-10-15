defmodule PhoenixReplay.Capture.Policy do
  @moduledoc """
  Resolves a view's capture policy once and filters recorded assigns.

  `replay_excluded_assigns/0` adds top-level exclusions. `replay_capture_assigns/1`
  receives the full current assigns and overrides configured transforms.
  Components retain their separate sanitizer path.
  """

  @callback replay_excluded_assigns() :: [atom()]
  @callback replay_capture_assigns(map()) :: map()
  @optional_callbacks replay_excluded_assigns: 0, replay_capture_assigns: 1

  alias PhoenixReplay.Capture.Assigns

  def resolve(view, config) do
    excluded =
      if function_exported?(view, :replay_excluded_assigns, 0),
        do: view.replay_excluded_assigns(),
        else: []

    if not is_list(excluded) or not Enum.all?(excluded, &is_atom/1),
      do: raise(ArgumentError, "replay_excluded_assigns/0 must return atom keys")

    transform =
      if function_exported?(view, :replay_capture_assigns, 1),
        do: {view, :replay_capture_assigns},
        else: config.capture_assigns

    %{excluded: Enum.sort(Enum.uniq(config.exclude_assigns ++ excluded)), transform: transform}
  catch
    _, _ -> %{failed: true, excluded: config.exclude_assigns, transform: nil}
  end

  def metadata(policy) do
    transform =
      case policy.transform do
        nil -> nil
        {module, fun} -> {module, fun}
        _fun -> :function
      end

    contract = %{
      excluded_assigns: policy.excluded,
      transform: transform,
      status: if(Map.get(policy, :failed, false), do: :failed, else: :active)
    }

    id = :crypto.hash(:sha256, :erlang.term_to_binary(contract)) |> Base.encode16(case: :lower)
    Map.put(contract, :id, id)
  end

  def capture(%{failed: true}, _assigns, _sanitizer), do: {:error, :capture_policy_failed}

  def capture(policy, assigns, sanitizer) do
    captured = transform(policy.transform, assigns)

    if not is_map(captured) or not Enum.all?(Map.keys(captured), &is_atom/1),
      do: raise(ArgumentError, "capture transform must return a map with atom keys")

    captured = captured |> Map.drop(policy.excluded) |> Assigns.view(sanitizer)
    if not is_map(captured), do: raise(ArgumentError, "assign sanitizer must return a map")
    {:ok, captured}
  catch
    _, _ -> {:error, :capture_policy_failed}
  end

  def diff(previous, current) do
    changed = Map.reject(current, fn {key, value} -> Map.fetch(previous, key) == {:ok, value} end)
    %{assigns: changed, removed: Map.keys(previous) -- Map.keys(current)}
  end

  defp transform(nil, assigns), do: assigns
  defp transform({module, fun}, assigns), do: apply(module, fun, [assigns])
  defp transform(fun, assigns), do: fun.(assigns)
end
