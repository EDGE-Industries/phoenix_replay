defmodule PhoenixReplay.Web.Callbacks do
  @moduledoc false

  alias PhoenixReplay.Recording.Value.Callback
  alias PhoenixReplay.Sanitizer.Serializable

  def restore(recorded, template),
    do: restore(recorded, template, callbacks(template, %{origins: %{}, contexts: %{}}))

  defp restore(%Callback{} = recorded, template, callbacks) when is_function(template) do
    if Callback.from_function(template) == recorded,
      do: template,
      else: restore(recorded, nil, callbacks)
  end

  defp restore(%Callback{} = recorded, _template, callbacks) do
    case Map.get(callbacks.origins, recorded) do
      {:unique, function} -> function
      _ -> recorded
    end
  end

  defp restore(recorded, template, callbacks) when is_map(recorded) do
    template = if is_map(template), do: template, else: %{}

    Map.new(Map.to_list(recorded), fn {key, value} ->
      candidate =
        if match?(%Callback{}, value) do
          case Map.get(callbacks.contexts, {recorded, key}) do
            {:unique, function} -> function
            _ -> Map.get(template, key)
          end
        else
          Map.get(template, key)
        end

      {key, restore(value, candidate, callbacks)}
    end)
  end

  defp restore(recorded, _template, callbacks) when is_list(recorded),
    do: Enum.map(recorded, &restore(&1, nil, callbacks))

  defp restore(recorded, _template, callbacks) when is_tuple(recorded),
    do: recorded |> Tuple.to_list() |> restore(nil, callbacks) |> List.to_tuple()

  defp restore(recorded, _template, _callbacks), do: recorded

  defp callbacks(function, callbacks) when is_function(function) do
    %{
      callbacks
      | origins: candidate(callbacks.origins, Callback.from_function(function), function)
    }
  end

  defp callbacks(map, callbacks) when is_map(map) do
    functions = Enum.filter(Map.to_list(map), fn {_key, value} -> is_function(value) end)

    contexts =
      if functions == [] do
        callbacks.contexts
      else
        context = Serializable.sanitize_assigns(%{context: map}).context

        Enum.reduce(functions, callbacks.contexts, fn {key, function}, contexts ->
          candidate(contexts, {context, key}, function)
        end)
      end

    Enum.reduce(Map.values(map), %{callbacks | contexts: contexts}, &callbacks/2)
  end

  defp callbacks(list, callbacks) when is_list(list),
    do: Enum.reduce(list, callbacks, &callbacks/2)

  defp callbacks(tuple, callbacks) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> callbacks(callbacks)

  defp callbacks(_value, callbacks), do: callbacks

  defp candidate(candidates, key, function) do
    Map.update(candidates, key, {:unique, function}, fn
      {:unique, ^function} -> {:unique, function}
      _ -> :ambiguous
    end)
  end
end
