defmodule Yelixer.CrossClientOverwriteTest do
  @moduledoc """
  A causally-later map/attribute overwrite must win on replay REGARDLESS
  of the writers' client ids (CX-saix flushed this out: outline reparent
  flaked ~50% on random client-id order).

  Mechanism under test: the writer threads `origin = <overwritten
  item's id>` into the replacement item, so YATA places it RIGHT of the
  old value and `maybe_resolve_map_conflict`'s rightmost-wins keeps it.
  With a nil origin, a smaller-client writer integrates LEFT of the old
  item and gets auto-deleted as a phantom "concurrent loser" — then the
  delete set kills the old item too, and the key reads nil.
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Types.XMLElement, as: El
  alias Yelixer.Types.XMLFragment, as: Frag
  alias Yelixer.Types.YMap

  defp xml_base(client_id) do
    doc = Doc.new(client_id: client_id)
    doc = Frag.new_fragment(doc, "frag")
    doc = Frag.insert_child(doc, "frag", 0, {:element, "item"})
    {:element, "item", name} = Frag.to_list(doc, "frag") |> hd()
    doc = El.set_attribute(doc, name, "parent", "original")
    {doc, name}
  end

  defp replay(updates) do
    Enum.reduce(updates, Doc.new(client_id: 777_777), fn u, d ->
      {:ok, d2} = Yelixer.Encoding.apply_update(d, u)
      d2
    end)
  end

  for {label, base_client, writer_client} <- [
        {"writer client SMALLER than original", 900_000, 5},
        {"writer client LARGER than original", 5, 900_000}
      ] do
    test "xml attribute overwrite survives replay — #{label}" do
      {doc1, name} = xml_base(unquote(base_client))
      u1 = Yelixer.Encoding.encode_update(doc1)

      {:ok, doc2} = Yelixer.Encoding.apply_update(Doc.new(client_id: unquote(writer_client)), u1)
      doc2 = El.set_attribute(doc2, name, "parent", "REWRITTEN")
      u2 = Yelixer.Encoding.encode_update(doc2)

      merged = replay([u1, u2])
      assert El.get_attribute(merged, name, "parent") == "REWRITTEN"
    end

    test "ymap overwrite survives replay — #{label}" do
      doc1 = Doc.new(client_id: unquote(base_client))
      {doc1, _} = Doc.get_or_create_type(doc1, "m", :map)
      doc1 = YMap.set(doc1, "m", "k", "original")
      u1 = Yelixer.Encoding.encode_update(doc1)

      {:ok, doc2} = Yelixer.Encoding.apply_update(Doc.new(client_id: unquote(writer_client)), u1)
      doc2 = YMap.set(doc2, "m", "k", "REWRITTEN")
      u2 = Yelixer.Encoding.encode_update(doc2)

      merged = replay([u1, u2])
      assert YMap.get(merged, "m", "k") == "REWRITTEN"
    end
  end

  test "three-hop overwrite chain across three clients converges" do
    {doc1, name} = xml_base(500)
    u1 = Yelixer.Encoding.encode_update(doc1)

    {:ok, doc2} = Yelixer.Encoding.apply_update(Doc.new(client_id: 50), u1)
    doc2 = El.set_attribute(doc2, name, "parent", "second")
    u2 = Yelixer.Encoding.encode_update(doc2)

    doc3 =
      Enum.reduce([u1, u2], Doc.new(client_id: 7), fn u, d ->
        {:ok, d2} = Yelixer.Encoding.apply_update(d, u)
        d2
      end)

    doc3 = El.set_attribute(doc3, name, "parent", "third")
    u3 = Yelixer.Encoding.encode_update(doc3)

    merged = replay([u1, u2, u3])
    assert El.get_attribute(merged, name, "parent") == "third"
  end
end
