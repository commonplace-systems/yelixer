defmodule Yelixer.EncoderDeterminismTest do
  @moduledoc """
  CX-w62 (Build 6 gate): `Yelixer.Encoding.encode_update/1` must be
  byte-deterministic given equal op sets. Mirrors the
  `Doc.snapshot_update/1` determinism gate landed in CX-umz (Build 5).

  The late-edit translator (CX-yvhs, Build 6.3) depends on this property:
  two independent peers reconstructing the same source state must
  re-encode it to byte-identical bytes so content-address hashes agree.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Text, YMap, Array, XMLFragment}

  defp round_trip(update_bytes, target_client_id) do
    {:ok, doc} = Encoding.apply_update(Doc.new(client_id: target_client_id), update_bytes)
    doc
  end

  describe "encode_update/1 is byte-deterministic across calls on the same doc" do
    test "re-encoding the same doc twice produces identical bytes" do
      doc = Doc.new(client_id: 42)
      {doc, _} = Doc.get_or_create_type(doc, "t", :text)
      doc = Text.insert(doc, "t", 0, "hello")

      assert Encoding.encode_update(doc) == Encoding.encode_update(doc)
    end

    test "empty doc encodes deterministically" do
      doc_a = Doc.new(client_id: 1)
      doc_b = Doc.new(client_id: 1)
      assert Encoding.encode_update(doc_a) == Encoding.encode_update(doc_b)
    end
  end

  describe "encode_update/1 is byte-deterministic across independent instances" do
    test "two independent Text docs with same state encode to identical bytes" do
      doc_a = Doc.new(client_id: 42)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
      doc_a = Text.insert(doc_a, "t", 0, "hello world")

      update = Encoding.encode_update(doc_a)
      doc_b = round_trip(update, 42)

      assert Encoding.encode_update(doc_a) == Encoding.encode_update(doc_b)
    end

    test "two independent YMap docs with same state encode to identical bytes" do
      doc_a = Doc.new(client_id: 7)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "m", :map)
      doc_a = YMap.set(doc_a, "m", "alpha", "one")
      doc_a = YMap.set(doc_a, "m", "beta", "two")
      doc_a = YMap.set(doc_a, "m", "gamma", "three")

      update = Encoding.encode_update(doc_a)
      doc_b = round_trip(update, 7)

      assert Encoding.encode_update(doc_a) == Encoding.encode_update(doc_b)
    end

    test "two independent Array docs with same state encode to identical bytes" do
      doc_a = Doc.new(client_id: 3)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "a", :array)
      doc_a = Array.insert(doc_a, "a", 0, [1, 2, 3, "four", "five"])

      update = Encoding.encode_update(doc_a)
      doc_b = round_trip(update, 3)

      assert Encoding.encode_update(doc_a) == Encoding.encode_update(doc_b)
    end

    test "two independent XMLFragment docs with same state encode to identical bytes" do
      doc_a = Doc.new(client_id: 9)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "x", :xml_fragment)
      doc_a = XMLFragment.insert_child(doc_a, "x", 0, {:element, "div"})

      update = Encoding.encode_update(doc_a)
      doc_b = round_trip(update, 9)

      assert Encoding.encode_update(doc_a) == Encoding.encode_update(doc_b)
    end

    test "multi-type doc encodes deterministically across independent instances" do
      doc_a = Doc.new(client_id: 5)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "m", :map)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "a", :array)
      doc_a = Text.insert(doc_a, "t", 0, "txt")
      doc_a = YMap.set(doc_a, "m", "k", "v")
      doc_a = Array.insert(doc_a, "a", 0, [1, 2, 3])

      update = Encoding.encode_update(doc_a)
      doc_b = round_trip(update, 5)

      assert Encoding.encode_update(doc_a) == Encoding.encode_update(doc_b)
    end
  end

  describe "encode_update/1 byte-determinism across all reference types" do
    test "adjacent inserts (left-origin references) encode deterministically" do
      # Multiple insertions at the same text position exercise left-origin refs.
      doc_a = Doc.new(client_id: 11)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
      doc_a = Text.insert(doc_a, "t", 0, "a")
      doc_a = Text.insert(doc_a, "t", 1, "b")
      doc_a = Text.insert(doc_a, "t", 2, "c")

      update = Encoding.encode_update(doc_a)
      doc_b = round_trip(update, 11)

      assert Encoding.encode_update(doc_a) == Encoding.encode_update(doc_b)
    end

    test "inserts at head (right-origin references) encode deterministically" do
      # Inserting at position 0 repeatedly exercises right-origin refs.
      doc_a = Doc.new(client_id: 13)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
      doc_a = Text.insert(doc_a, "t", 0, "c")
      doc_a = Text.insert(doc_a, "t", 0, "b")
      doc_a = Text.insert(doc_a, "t", 0, "a")

      update = Encoding.encode_update(doc_a)
      doc_b = round_trip(update, 13)

      assert Encoding.encode_update(doc_a) == Encoding.encode_update(doc_b)
    end

    test "nested map items (parent references) encode deterministically" do
      # YMap keys use parent-sub references.
      doc_a = Doc.new(client_id: 17)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "m", :map)
      doc_a = YMap.set(doc_a, "m", "zeta", "z")
      doc_a = YMap.set(doc_a, "m", "alpha", "a")
      doc_a = YMap.set(doc_a, "m", "mu", "m")

      update = Encoding.encode_update(doc_a)
      doc_b = round_trip(update, 17)

      assert Encoding.encode_update(doc_a) == Encoding.encode_update(doc_b)
    end
  end

  describe "encode_update/1 byte-determinism with mixed clientIDs" do
    test "doc holding ops from multiple clients encodes deterministically" do
      # Build a doc containing ops from three different clients by merging
      # updates. Then re-encode on two independent instances.
      doc_1 = Doc.new(client_id: 100)
      {doc_1, _} = Doc.get_or_create_type(doc_1, "t", :text)
      doc_1 = Text.insert(doc_1, "t", 0, "aaa")

      doc_2 = Doc.new(client_id: 200)
      {:ok, doc_2} = Encoding.apply_update(doc_2, Encoding.encode_update(doc_1))
      {doc_2, _} = Doc.get_or_create_type(doc_2, "t", :text)
      doc_2 = Text.insert(doc_2, "t", 3, "bbb")

      doc_3 = Doc.new(client_id: 300)
      {:ok, doc_3} = Encoding.apply_update(doc_3, Encoding.encode_update(doc_2))
      {doc_3, _} = Doc.get_or_create_type(doc_3, "t", :text)
      doc_3 = Text.insert(doc_3, "t", 6, "ccc")

      # doc_3 now contains ops from 100, 200, 300.
      update = Encoding.encode_update(doc_3)

      # Two independent peers reconstruct the same logical state.
      {:ok, peer_a} = Encoding.apply_update(Doc.new(client_id: 999), update)
      {:ok, peer_b} = Encoding.apply_update(Doc.new(client_id: 999), update)

      assert Encoding.encode_update(peer_a) == Encoding.encode_update(peer_b)
    end
  end

  describe "encode_update/1 byte-determinism property" do
    property "≥100 random Text docs encode deterministically across instances" do
      check all content <- string(:printable, min_length: 0, max_length: 40),
                client_id <- integer(1..1_000_000),
                max_runs: 100 do
        doc_a = Doc.new(client_id: client_id)
        {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
        doc_a = if content == "", do: doc_a, else: Text.insert(doc_a, "t", 0, content)

        update = Encoding.encode_update(doc_a)
        doc_b = round_trip(update, client_id)

        assert Encoding.encode_update(doc_a) == Encoding.encode_update(doc_b)
      end
    end

    property "≥100 random YMap docs encode deterministically across instances" do
      check all entries <-
                  list_of(
                    tuple({string(:alphanumeric, min_length: 1, max_length: 6),
                           string(:alphanumeric, min_length: 0, max_length: 10)}),
                    min_length: 0,
                    max_length: 6
                  ),
                client_id <- integer(1..1_000_000),
                max_runs: 100 do
        doc_a = Doc.new(client_id: client_id)
        {doc_a, _} = Doc.get_or_create_type(doc_a, "m", :map)

        doc_a =
          Enum.reduce(entries, doc_a, fn {k, v}, d -> YMap.set(d, "m", k, v) end)

        update = Encoding.encode_update(doc_a)
        doc_b = round_trip(update, client_id)

        assert Encoding.encode_update(doc_a) == Encoding.encode_update(doc_b)
      end
    end
  end
end
