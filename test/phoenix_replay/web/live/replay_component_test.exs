defmodule PhoenixReplay.Web.Live.ReplayComponentTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixReplay.Recording.Event
  alias PhoenixReplay.Storage
  alias PhoenixReplay.Test.{Fixtures, Sessions}
  alias PhoenixReplay.Web.Player.Channel

  @endpoint PhoenixReplay.Test.Endpoint

  defmodule Column do
    defstruct [:field, :slot]
  end

  defmodule Table do
    use Phoenix.LiveComponent

    def render(assigns) do
      ~H"""
      <table
        id="recorded-table"
        data-optional={if is_function(assigns[:optional]), do: "enabled", else: "disabled"}
      >
        <tr :for={row <- @data || []}>
          <td :for={column <- @columns || []}>{render_slot(column.slot, row)}</td>
        </tr>
      </table>
      """
    end
  end

  defmodule Page do
    use Phoenix.LiveView

    def render(assigns) do
      ~H"""
      <.live_component
        module={Table}
        id="table"
        {if @enabled, do: %{optional: &Function.identity/1}, else: %{}}
      >
        <:cell :let={row} field="name">{@prefix}: {row.name}</:cell>
      </.live_component>
      """
    end
  end

  setup context do
    on_exit(fn -> Storage.clear(Fixtures.storage()) end)
    Sessions.setup_sessions(context)
  end

  test "rebuilds derived slots from the template while keeping recorded rows across seeks" do
    [%Phoenix.LiveView.Component{assigns: %{cell: [slot]}}] =
      Page.render(%{__changed__: nil, prefix: "Before", enabled: true}).dynamic.(false)

    slot = PhoenixReplay.Sanitizer.Serializable.sanitize_assigns(slot)

    recording = %PhoenixReplay.Recording{
      id: "derived-slot",
      view: Page,
      connected_at: 0,
      events: [
        %Event{at: 0, type: :mount, data: %{assigns: %{prefix: "Before", enabled: true}}},
        %Event{
          at: 1,
          type: :component,
          data: %{
            module: Table,
            id: "table",
            assigns: %{
              data: [%{name: "saved row"}],
              columns: [%Column{field: "name", slot: slot}],
              cell: [slot]
            }
          }
        },
        %Event{at: 2, type: :render, data: %{assigns: %{prefix: "Before", enabled: true}}},
        %Event{at: 3, type: :render, data: %{assigns: %{prefix: "After", enabled: false}}},
        %Event{
          at: 4,
          type: :component,
          data: %{module: Table, id: "table", assigns: %{data: [%{name: "updated saved row"}]}}
        }
      ]
    }

    :ok = Storage.save(Fixtures.storage(), recording)
    {:ok, view, html} = live(build_conn(), "/replay/derived-slot/frame?channel=derived-slot")
    assert html =~ "Before: saved row"
    refute html =~ "Could not render"
    assert has_element?(view, "#recorded-table[data-optional=enabled]")

    Channel.seek("derived-slot", 3)
    assert render(view) =~ "After: saved row"
    assert has_element?(view, "#recorded-table[data-optional=disabled]")

    Channel.seek("derived-slot", 4)
    assert_rendered(view, "After: updated saved row")

    Channel.seek("derived-slot", 2)
    assert render(view) =~ "Before: saved row"
    assert has_element?(view, "#recorded-table[data-optional=enabled]")

    Channel.seek("derived-slot", 0)
    assert_rendered(view, "saved row", false)

    Channel.seek("derived-slot", 2)
    assert_rendered(view, "Before: saved row")
  end

  defp assert_rendered(view, text, present? \\ true) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    html =
      Stream.repeatedly(fn -> render(view) end)
      |> Enum.find(fn html ->
        html =~ text == present? or System.monotonic_time(:millisecond) >= deadline
      end)

    assert html =~ text == present?
  end
end
