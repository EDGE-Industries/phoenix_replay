defmodule PhoenixReplay.Web.Live.ReplayComponent do
  @moduledoc """
  Stands in for a recorded LiveComponent in the replay frame.

  `PhoenixReplay.Web.Rendering.rewrite/2` puts it in place of each component,
  so the frame renders the original module's template with the assigns the
  parent passes merged with the assigns recorded for that component. The
  frame refreshes it with `send_update/3` after every seek. Events from the
  recorded template are ignored.
  """

  use Phoenix.LiveComponent

  alias PhoenixReplay.Web.{Callbacks, Rendering}

  @replay_keys [:__replay_module__, :__replay_id__, :__replay_states__]

  @doc "Assigns that route a component through this replay component."
  @spec replay_assigns(module(), term(), Rendering.states()) :: map()
  def replay_assigns(module, id, states) do
    %{__replay_module__: module, __replay_id__: id, __replay_states__: states}
  end

  @impl true
  def update(assigns, socket) do
    replay = Map.merge(Map.take(socket.assigns, @replay_keys), Map.take(assigns, @replay_keys))
    %{__replay_module__: module, __replay_id__: id, __replay_states__: states} = replay

    passed =
      assigns
      |> Map.drop(@replay_keys)
      |> Map.reject(fn {key, value} -> key == :id and value == {module, id} end)

    previous = socket.private[:phoenix_replay_template_assigns] || %{}
    passed = if Map.has_key?(assigns, :__replay_module__), do: passed, else: previous
    recorded = Map.get(states, {module, id}, %{})
    restored = Callbacks.restore(Map.merge(passed, recorded), passed)

    removed =
      socket.assigns
      |> Map.drop([:__changed__ | @replay_keys])
      |> Rendering.assignable()
      |> Map.keys()
      |> Kernel.--(Map.keys(restored))

    {:ok,
     socket
     |> Phoenix.LiveView.put_private(:phoenix_replay_template_assigns, passed)
     |> assign(Map.new(removed, &{&1, nil}))
     |> assign(replay)
     |> assign(Rendering.assignable(restored))}
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(%{__replay_module__: module} = assigns) do
    case Rendering.render_error(module, assigns) do
      nil ->
        assigns |> module.render() |> Rendering.rewrite(assigns.__replay_states__)

      message ->
        assigns = assign(assigns, :message, message)

        ~H"""
        <div style="padding: 0.5rem; color: #737373; border: 1px dashed #d4d4d4;">
          Could not render {inspect(@__replay_module__)}: {@message}
        </div>
        """
    end
  end
end
