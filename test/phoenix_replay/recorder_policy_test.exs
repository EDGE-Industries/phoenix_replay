defmodule PhoenixReplay.RecorderPolicyTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixReplay.{Config, Storage}
  alias PhoenixReplay.Recording.{Event, Timeline}
  alias PhoenixReplay.Test.Live.{CapturePolicy, CaptureDisabled}

  @endpoint PhoenixReplay.Test.Endpoint

  setup do
    storage =
      {PhoenixReplay.Storage.File,
       path: Path.join(System.tmp_dir!(), "capture-policy-#{System.unique_integer([:positive])}")}

    overrides = [
      storage: storage,
      sample_rate: 1.0,
      keep: [rate: 1.0],
      flush: false,
      sanitizer: PhoenixReplay.Sanitizer.Serializable,
      exclude_assigns: [:global_only]
    ]

    previous =
      Enum.map(overrides, fn {key, _} -> {key, Application.fetch_env(:phoenix_replay, key)} end)

    Enum.each(overrides, fn {key, value} -> Application.put_env(:phoenix_replay, key, value) end)
    handler = "capture-policy-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phoenix_replay, :recording, :persisted],
        fn _, _, metadata, _ -> send(parent, {:saved, metadata.id}) end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      Storage.clear(storage)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:phoenix_replay, key, value)
        {key, :error} -> Application.delete_env(:phoenix_replay, key)
      end)
    end)

    %{storage: storage}
  end

  test "full transforms preserve runtime assigns and replay derived key removals", %{
    storage: storage
  } do
    {:ok, view, _} = live_isolated(build_conn(), CapturePolicy)

    assert has_element?(
             view,
             "#runtime",
             "runtime source / view source / session source / global source"
           )

    view |> element("#change") |> render_click()
    assert has_element?(view, "#count", "1")
    assert {:error, {:redirect, %{to: "/counter"}}} = view |> element("#finish") |> render_click()
    assert_receive {:saved, id}, 5_000
    assert {:ok, recording} = Storage.fetch(storage, id)
    assert length(Storage.list(storage)) == 1
    assert Enum.count(recording.events, &(&1.type == :mount)) == 1
    assert recording.capture_policy.excluded_assigns == [:global_only, :session_only, :view_only]
    {recording, _} = Timeline.for_playback(recording)
    first = Timeline.first_render_index(recording)
    initial = Timeline.at(recording, first)
    assert initial.assigns.optional == "included"
    final = Timeline.seek(initial, length(recording.events) - 1)
    assert final.assigns.count == 1
    assert Map.fetch(final.assigns, :visible_nil) == {:ok, nil}
    refute Map.has_key?(final.assigns, :optional)
    assert Timeline.seek(final, first).assigns == initial.assigns

    for event <- recording.events, event.type in [:mount, :render] do
      assert Map.take(event.data.assigns, [
               :global_only,
               :session_only,
               :view_only,
               :internal_only
             ]) == %{}
    end
  end

  test "capture failure leaves the page working and emits one recording error", %{
    storage: storage
  } do
    {:ok, view, _} =
      live_isolated(build_conn(), CapturePolicy, session: %{"fail_capture" => true})

    view |> element("#change") |> render_click()
    view |> element("#change") |> render_click()
    assert has_element?(view, "#count", "2")
    assert {:error, {:redirect, %{to: "/counter"}}} = view |> element("#finish") |> render_click()
    assert_receive {:saved, id}, 5_000
    assert {:ok, recording} = Storage.fetch(storage, id)
    assert Enum.count(recording.events, &Event.error?/1) == 1
    timeline = Timeline.at(recording, length(recording.events) - 1)
    assert timeline.assigns.count == 0
    refute Map.has_key?(timeline.assigns, :internal_only)
  end

  test "a second recorder hook does not undo disabled sampling", %{storage: storage} do
    {:ok, view, _} = live_isolated(build_conn(), CaptureDisabled)
    view |> element("#change") |> render_click()
    assert has_element?(view, "#count", "1")
    assert PhoenixReplay.Catalog.list(Config.load()) == []
    assert {:error, {:redirect, %{to: "/counter"}}} = view |> element("#finish") |> render_click()
    assert Storage.list(storage) == []
  end
end
