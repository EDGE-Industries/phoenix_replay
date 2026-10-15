defmodule PhoenixReplay.Web.CallbacksTest do
  use ExUnit.Case, async: true

  alias PhoenixReplay.Recording.Value.Callback
  alias PhoenixReplay.Sanitizer.Serializable
  alias PhoenixReplay.Web.Callbacks

  test "uses template callbacks without replacing recorded values or reviving disabled callbacks" do
    callback = fn row -> row.name end
    recorded = %{callback: Callback.from_function(callback), disabled: nil, label: nil, count: 4}
    template = %{callback: callback, disabled: callback, label: "current", count: 9}
    restored = Callbacks.restore(recorded, template)
    assert restored.callback.(%{name: "recorded"}) == "recorded"
    assert restored.disabled == nil
    assert restored.label == nil
    assert restored.count == 4
  end

  test "restores copied callbacks in arbitrary derived maps, structs, lists and tuples" do
    callback = fn _, row -> row.name end
    slot = %{__slot__: :cell, inner_block: callback}

    recorded =
      Serializable.sanitize_assigns(%{columns: [{:column, %{slot: slot, copied: callback}}]})

    restored = Callbacks.restore(recorded, %{cell: [slot]})
    [{:column, column}] = restored.columns
    assert column.slot.inner_block.(nil, %{name: "saved"}) == "saved"
    assert column.copied.(nil, %{name: "saved"}) == "saved"
  end

  test "does not guess between closures with the same origin and different environments" do
    factory = fn label -> fn _, _ -> label end end
    first = factory.("first")
    second = factory.("second")
    assert Callback.from_function(first) == Callback.from_function(second)
    recorded = %{columns: [%{callback: Callback.from_function(first)}]}
    assert Callbacks.restore(recorded, %{callbacks: [first, second]}) == recorded
  end

  test "uses map metadata to distinguish closures copied from a reordered template list" do
    factory = fn label -> fn _ -> label end end
    first = %{field: :a, callback: factory.("A")}
    second = %{field: :b, callback: factory.("B")}
    recorded = Serializable.sanitize_assigns(%{derived: [first, second]})
    restored = Callbacks.restore(recorded, %{definitions: [second, first]})
    assert Enum.map(restored.derived, &{&1.field, &1.callback.(nil)}) == [a: "A", b: "B"]
  end

  test "matches callback origin rather than list position or only arity" do
    first = fn _ -> :a end
    second = fn _ -> :b end

    recorded =
      Serializable.sanitize_assigns(%{
        items: [%{id: :a, callback: first}, %{id: :b, callback: second}]
      })

    template = %{items: [%{id: :b, callback: second}, %{id: :a, callback: first}]}
    restored = Callbacks.restore(recorded, template)
    assert Enum.map(restored.items, &{&1.id, &1.callback.(nil)}) == [a: :a, b: :b]
    marker = Callback.from_function(first)
    assert Callbacks.restore(%{callback: marker}, %{callback: second}) == %{callback: marker}
  end
end
