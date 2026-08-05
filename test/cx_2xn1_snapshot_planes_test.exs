defmodule Yelixer.CX2xn1SnapshotPlanesTest do
  @moduledoc """
  CX-2xn1: a named type has two storage planes — the MAP plane
  (parent_sub != nil items, the Y.Map key-space) and the SEQUENCE
  plane (parent_sub == nil items, the Text/Array ordered sequence).
  Both can be populated under the same name.

  `Doc.snapshot_update/1`'s `replay_top_level_type/4` used to dispatch
  on a single inferred/declared kind per name, silently destroying
  whichever plane it didn't pick. This file proves both planes survive
  a snapshot round-trip, in both the explicit-ref and decoded/:unknown
  ref directions, and that the single-plane cases are unperturbed.
  """
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Text, YMap, Array}

  describe "dual-plane snapshot replay" do
    test "explicit-ref direction: both map and text planes survive snapshot_update" do
      doc = Doc.new(client_id: 1)
      {doc, _} = Doc.get_or_create_type(doc, "content", :map)
      doc = YMap.set(doc, "content", "description", "LEGACY KEY VALUE")
      source = Text.insert(doc, "content", 0, "PLAIN TEXT BLOB")

      {bytes, _dm} = Doc.snapshot_update(source, force: true)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), bytes)

      assert Text.to_string(rebuilt, "content") == "PLAIN TEXT BLOB"
      assert YMap.to_map(rebuilt, "content") == %{"description" => "LEGACY KEY VALUE"}
    end

    test "decoded-ref direction: both planes survive when the source's own type ref is :unknown" do
      doc = Doc.new(client_id: 2)
      {doc, _} = Doc.get_or_create_type(doc, "content", :map)
      doc = YMap.set(doc, "content", "description", "LEGACY KEY VALUE")
      source = Text.insert(doc, "content", 0, "PLAIN TEXT BLOB")

      # Round-trip through apply_update so the receiver's type ref for
      # "content" is :unknown, forcing infer_type_from_sequence/2 to
      # decide the dispatch — this is the second half of the bug.
      {:ok, decoded} = Encoding.apply_update(Doc.new(), Encoding.encode_update(source))
      assert Doc.get_or_create_type(decoded, "content", :unknown) |> elem(1) == :unknown

      {bytes, _dm} = Doc.snapshot_update(decoded, force: true)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), bytes)

      assert Text.to_string(rebuilt, "content") == "PLAIN TEXT BLOB"
      assert YMap.to_map(rebuilt, "content") == %{"description" => "LEGACY KEY VALUE"}
    end
  end

  describe "single-plane regression guards" do
    test "pure-text doc snapshots to the same text" do
      doc = Doc.new(client_id: 3)
      {doc, _} = Doc.get_or_create_type(doc, "t", :text)
      source = Text.insert(doc, "t", 0, "just text, no map plane")

      {bytes, _dm} = Doc.snapshot_update(source, force: true)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), bytes)

      assert Text.to_string(rebuilt, "t") == "just text, no map plane"
      assert YMap.to_map(rebuilt, "t") == %{}
    end

    test "pure-map doc snapshots to the same keys" do
      doc = Doc.new(client_id: 4)
      {doc, _} = Doc.get_or_create_type(doc, "m", :map)
      doc = YMap.set(doc, "m", "a", 1)
      source = YMap.set(doc, "m", "b", "two")

      {bytes, _dm} = Doc.snapshot_update(source, force: true)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), bytes)

      assert YMap.to_map(rebuilt, "m") == %{"a" => 1, "b" => "two"}
      assert Text.to_string(rebuilt, "m") == ""
    end

    test "pure-array doc snapshots to the same list" do
      doc = Doc.new(client_id: 5)
      {doc, _} = Doc.get_or_create_type(doc, "arr", :array)
      source = Array.insert(doc, "arr", 0, [1, 2, 3])

      {bytes, _dm} = Doc.snapshot_update(source, force: true)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), bytes)

      assert Array.to_list(rebuilt, "arr") == [1, 2, 3]
      assert YMap.to_map(rebuilt, "arr") == %{}
    end
  end
end
