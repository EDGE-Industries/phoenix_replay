defmodule PhoenixReplay.Capture.PolicyTest do
  use ExUnit.Case, async: true

  alias PhoenixReplay.Capture.{Assigns, Policy}
  alias PhoenixReplay.Config
  alias PhoenixReplay.Recording.{Event, Timeline}

  defmodule View do
    def replay_excluded_assigns, do: [:view]
    def replay_capture_assigns(assigns), do: Map.take(assigns, [:count, :global, :session, :view])
  end

  defmodule InvalidSanitizer do
    def sanitize_assigns(_), do: :invalid
  end

  defmodule InvalidView do
    def replay_excluded_assigns, do: [:valid, "invalid"]
  end

  test "configuration unions exclusions and view transforms take precedence" do
    config =
      Config.new(
        exclude_assigns: [:global],
        exclude_assigns: [:session, :global],
        capture_assigns: fn _ -> raise "must not run" end
      )

    policy = Policy.resolve(View, config)
    assert policy.excluded == [:global, :session, :view]

    assert {:ok, %{count: 1}} =
             Policy.capture(
               policy,
               %{count: 1, global: 2, session: 3, view: 4, internal: 5},
               PhoenixReplay.Sanitizer.Serializable
             )

    refute Policy.metadata(policy) |> Map.values() |> Enum.any?(&is_function/1)
  end

  test "session transform replaces global transform" do
    config =
      Config.new(
        capture_assigns: fn _ -> %{global: true} end,
        capture_assigns: fn assigns -> Map.take(assigns, [:count]) end
      )

    assert {:ok, %{count: 2}} =
             Policy.capture(
               Policy.resolve(__MODULE__, config),
               %{count: 2, secret_token: "secret"},
               PhoenixReplay.Sanitizer.Serializable
             )
  end

  test "invalid options are rejected" do
    assert_raise ArgumentError, fn -> Config.new(exclude_assigns: ["key"]) end
    assert_raise ArgumentError, fn -> Config.new(capture_assigns: :bad) end
    assert_raise ArgumentError, fn -> Config.new(capture_assigns: fn _, _ -> %{} end) end
  end

  test "exclusions run before sanitizer and bookkeeping never reaches it" do
    source = %{
      keep: "value",
      skip: "large",
      secret_token: "secret",
      __changed__: %{},
      streams: %{}
    }

    policy = Policy.resolve(__MODULE__, Config.new(exclude_assigns: [:skip]))

    assert {:ok, %{keep: "value", secret_token: "[FILTERED]"}} =
             Policy.capture(policy, source, PhoenixReplay.Sanitizer.Serializable)

    assert source.skip == "large"
  end

  test "policy and transform failures never return raw assigns" do
    assert {:error, :capture_policy_failed} =
             Policy.capture(
               Policy.resolve(__MODULE__, Config.new([])),
               %{raw: "data"},
               InvalidSanitizer
             )

    policy = Policy.resolve(InvalidView, Config.new([]))
    assert Policy.metadata(policy).status == :failed

    assert {:error, :capture_policy_failed} =
             Policy.capture(policy, %{raw: "data"}, PhoenixReplay.Sanitizer.Serializable)

    for transform <- [
          fn _ -> raise "failure" end,
          fn _ -> throw(:failure) end,
          fn _ -> [:invalid] end,
          fn _ -> %{"invalid" => true} end,
          {__MODULE__, :missing}
        ] do
      policy = Policy.resolve(__MODULE__, Config.new(capture_assigns: transform))

      assert {:error, :capture_policy_failed} =
               Policy.capture(policy, %{raw: "data"}, PhoenixReplay.Sanitizer.Serializable)
    end
  end

  test "component capture does not apply its parent's policy" do
    assert Assigns.component(
             %{view: "component value", myself: :cid},
             PhoenixReplay.Sanitizer.Serializable
           ) ==
             %{view: "component value"}
  end

  test "deletion differs from nil and works forward and backward through the player timeline" do
    data = Policy.diff(%{keep: 1, removed: nil, nullable: 4}, %{keep: 1, nullable: nil})
    assert data == %{assigns: %{nullable: nil}, removed: [:removed]}

    render_event = %Event{at: 1, type: :render, data: data}

    recording = %PhoenixReplay.Recording{
      id: "test",
      view: View,
      connected_at: 1,
      events: [
        %Event{at: 0, type: :mount, data: %{assigns: %{keep: 1, removed: nil, nullable: 4}}},
        render_event
      ]
    }

    before = Timeline.at(recording, 0)
    after_change = Timeline.seek(before, 1)
    refute Map.has_key?(after_change.assigns, :removed)
    assert Map.fetch(after_change.assigns, :nullable) == {:ok, nil}
    assert Timeline.seek(after_change, 0).assigns == before.assigns
    assert Enum.sort(Event.changed_keys(render_event)) == [:nullable, :removed]
    assert Policy.diff(%{a: 1}, %{a: 1}) == %{assigns: %{}, removed: []}
  end
end
