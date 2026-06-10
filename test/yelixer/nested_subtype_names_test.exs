defmodule Yelixer.NestedSubtypeNamesTest do
  @moduledoc """
  CX-tdkq.5 (architecture-review R5): `Doc.nested_subtype_names/1` is the
  detector behind the snapshot guard. `snapshot_update/1` drops the CRDT
  state of sub-types nested inside maps/arrays (it short-circuits on the
  `"__sub:"` prefix), so a doc carrying such a type cannot be snapshotted
  without silent data loss. This function surfaces exactly those types so
  callers can refuse the lossy snapshot.
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc

  test "empty for a fresh doc" do
    assert Doc.nested_subtype_names(Doc.new()) == []
  end

  test "empty for a doc with only top-level types (the JSON-blob convention)" do
    doc = Doc.new(client_id: 7)
    {doc, _} = Doc.get_or_create_type(doc, "_messages", :array)
    {doc, _} = Doc.get_or_create_type(doc, "_reactions", :map)
    {doc, _} = Doc.get_or_create_type(doc, "content", :text)

    assert Doc.nested_subtype_names(doc) == []
  end

  test "surfaces __sub: nested map/array sub-types (the lossy ones)" do
    base = Doc.new(client_id: 7)
    # `__sub:CLIENT:CLOCK` is the synthetic key snapshot_update/1 drops.
    # No public facade mints these from commonplace today (they arrive via
    # decode/interop), so construct the registry shape directly — the
    # detector inspects `doc.types` keys, which is exactly what
    # snapshot_update/1 iterates.
    doc = %Doc{base | types: Map.merge(base.types, %{"__sub:5:3" => :map, "__sub:5:9" => :array})}

    assert Enum.sort(Doc.nested_subtype_names(doc)) == ["__sub:5:3", "__sub:5:9"]
  end

  test "ignores XML child sub-types (they are replayed structurally)" do
    base = Doc.new(client_id: 7)

    doc = %Doc{
      base
      | types:
          Map.merge(base.types, %{
            "root" => :xml_fragment,
            "root::child::5:7" => {:xml_element, "div"}
          })
    }

    assert Doc.nested_subtype_names(doc) == []
  end
end
