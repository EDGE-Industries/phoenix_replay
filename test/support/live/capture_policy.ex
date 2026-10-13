defmodule PhoenixReplay.Test.Live.CapturePolicy do
  use Phoenix.LiveView, layout: false

  on_mount {PhoenixReplay.Recorder, exclude_assigns: [:session_only]}
  on_mount PhoenixReplay.Recorder

  def replay_excluded_assigns, do: [:view_only]

  def replay_capture_assigns(assigns) do
    if assigns[:fail_capture] and assigns[:count] > 0, do: raise("capture failure")

    assigns
    |> Map.take([:count, :visible_nil, :global_only, :session_only, :view_only, :show_optional])
    |> then(fn captured ->
      if captured[:show_optional], do: Map.put(captured, :optional, "included"), else: captured
    end)
  end

  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       count: 0,
       fail_capture: session["fail_capture"] == true,
       show_optional: true,
       visible_nil: nil,
       global_only: "global source",
       session_only: "session source",
       view_only: "view source",
       internal_only: "runtime source"
     )}
  end

  def handle_event("change", _, socket),
    do: {:noreply, assign(socket, count: socket.assigns.count + 1, show_optional: false)}

  def handle_event("finish", _, socket),
    do: {:noreply, redirect(socket, to: "/counter")}

  def render(assigns) do
    ~H"""
    <p id="count">{@count}</p>
    <p id="runtime">{@internal_only} / {@view_only} / {@session_only} / {@global_only}</p>
    <button id="change" phx-click="change">Change</button>
    <button id="finish" phx-click="finish">Finish</button>
    """
  end
end

defmodule PhoenixReplay.Test.Live.CaptureDisabled do
  use Phoenix.LiveView, layout: false

  on_mount {PhoenixReplay.Recorder, sample_rate: 0.0}
  on_mount PhoenixReplay.Recorder

  def mount(_, _, socket), do: {:ok, assign(socket, count: 0)}

  def handle_event("change", _, socket),
    do: {:noreply, assign(socket, count: socket.assigns.count + 1)}

  def handle_event("finish", _, socket), do: {:noreply, redirect(socket, to: "/counter")}

  def render(assigns) do
    ~H"""
    <p id="count">{@count}</p>
    <button id="change" phx-click="change">Change</button>
    <button id="finish" phx-click="finish">Finish</button>
    """
  end
end
