Code.require_file("../support/compat_oracle.exs", __DIR__)
Code.require_file("../support/root_mix_history.exs", __DIR__)

defmodule Yelixer.GcOriginTest do
  @moduledoc """
  Issue #8 (YELIXER-ROOT-MIX-1), fixes A and C.

  A. After `Doc.gc/1`, the encoder used to rewrite an origin that pointed
     into a GC'd block to the same client's nearest earlier live block BY
     CLOCK (`remap_gc_origin/2`), which can sit in a different root. Yjs
     never does that: a GC'd item keeps its slot on the wire as a
     ContentDeleted item with its real origin/parent (Item.js `gc/2`), and
     every neighbour keeps its real origin.

  C. A wire GC struct (info byte 0, no parent) decodes with a
     `{:gc_placeholder, nil}` parent. (1) Re-encoding one used to raise
     CaseClauseError. (2) An item anchored on one used to get a parent
     guessed from its author's first block; Yjs instead drops the parent
     and integrates the item as a GC struct (Item.js getMissing/integrate).
  """
  use ExUnit.Case, async: false

  alias Yelixer.{BlockStore, DeleteSet, Doc, Encoding, ID, Item}
  alias Yelixer.Types.{Array, Text}
  alias Yelixer.Test.CompatOracle, as: O
  alias Yelixer.Test.RootMixHistory, as: H

  defp reg(cid),
    do: Doc.new(client_id: cid) |> Doc.put_type("t", :text) |> Doc.put_type("a", :array)

  # The diag/minimal.exs history: A:0 = "x" in array "a"; A:1..4 = "gcme"
  # in text "t"; A:1..3 deleted then GC'd; "e" = A:4 keeps origin A:3.
  defp minimal_author do
    reg(100)
    |> Array.insert("a", 0, ["x"])
    |> Text.insert("t", 0, "gcme")
    |> Text.delete("t", 0, 3)
    |> Doc.gc()
  end

  describe "fix A: no sender-side origin rewrite after Doc.gc" do
    test "the wire origin of a GC'd block's neighbour is its real origin" do
      author = minimal_author()
      assert %Item{content: {:gc, 3}} = BlockStore.get(author.store, ID.new(100, 1))
      assert BlockStore.get(author.store, ID.new(100, 4)).origin == ID.new(100, 3)

      u = Encoding.encode_update(author)
      {:ok, {items, _ds, _}} = Encoding.decode_update(u)
      wire_e = Enum.find(items, &(&1.id == ID.new(100, 4)))
      assert wire_e.origin == ID.new(100, 3)

      {:ok, r} = Encoding.apply_update(reg(200), u)
      assert Text.to_string(r, "t") == "e"
      assert Array.to_list(r, "a") == ["x"]
    end

    test "seeds 0..299: full replay never puts a foreign item in array root \"a\"" do
      bad =
        Enum.filter(0..299, fn s ->
          h = H.generate(s)
          d = H.apply_all(H.registered(1), h.delivery ++ h.withheld)

          Enum.any?(
            BlockStore.get_sequence(d.store, "a"),
            &(not match?({:any, _}, &1.content))
          )
        end)

      assert bad == []
    end

    test "Yjs reads Yelixer's bytes for the repro as it reads its own" do
      port = O.open()

      try do
        # Yjs authors the same history natively (gc on).
        O.rpc(port, %{cmd: "reset", client_id: 100, gc: true})
        O.rpc(port, %{cmd: "push_array", root: "a", items: ["x"]})
        O.rpc(port, %{cmd: "insert_text", name: "t", pos: 0, text: "gcme"})
        O.rpc(port, %{cmd: "delete_text", name: "t", pos: 0, len: 3})
        yjs_bytes = O.update(port)

        expected = yjs_view(port, yjs_bytes)
        assert expected == %{array: ["x"], text: "e", reencoded: expected.reencoded}

        assert yjs_view(port, Encoding.encode_update(minimal_author())) == expected
      after
        Port.close(port)
      end
    end
  end

  describe "fix C: wire GC structs" do
    # Yjs (gc on): "a" = [nested Y.Array [1, 2], "y"], then the nested
    # array is deleted. Its children are GC'd under a GC'd parent, so Yjs
    # replaces them with a GC struct 1:1 (len 2); 1:0 becomes ContentDeleted.
    defp yjs_gc_struct_update(port) do
      O.rpc(port, %{cmd: "reset", client_id: 1, gc: true})
      O.rpc(port, %{cmd: "array_push_nested_array", root: "a", values: [1, 2]})
      O.rpc(port, %{cmd: "push_array", root: "a", items: ["y"]})
      O.rpc(port, %{cmd: "delete_array", root: "a", pos: 0, len: 1})
      bytes = O.update(port)

      # Positive control: the bytes really carry a wire GC struct.
      {:ok, {items, _ds, _}} = Encoding.decode_update(bytes)

      assert Enum.any?(
               items,
               &match?(
                 %Item{
                   id: %ID{client: 1, clock: 1},
                   content: {:gc, 2},
                   parent: {:gc_placeholder, _}
                 },
                 &1
               )
             )

      bytes
    end

    test "decoding then re-encoding a wire GC struct round-trips (Yjs-equal)" do
      port = O.open()

      try do
        yjs_bytes = yjs_gc_struct_update(port)
        expected = yjs_view(port, yjs_bytes)
        assert expected.array == ["y"]

        doc = O.load(yjs_bytes, 900)
        assert Array.to_list(doc, "a") == ["y"]
        reencoded = Encoding.encode_update(doc)

        {:ok, {items, _ds, _}} = Encoding.decode_update(reencoded)

        assert Enum.any?(
                 items,
                 &match?(%Item{id: %ID{client: 1, clock: 1}, content: {:gc, 2}}, &1)
               )

        assert yjs_view(port, reencoded) == expected
        assert Array.to_list(O.load(reencoded, 901), "a") == ["y"]
      after
        Port.close(port)
      end
    end

    test "an item anchored on a wire GC struct becomes GC, as in Yjs" do
      port = O.open()

      try do
        yjs_bytes = yjs_gc_struct_update(port)

        # A concurrent peer (client 2) had appended 3 to the nested array
        # before seeing the delete: origin = 1:2, the nested array's last
        # child, which the receiver only holds inside GC struct 1:1..2.
        late =
          Encoding.encode_items(
            [Item.new(ID.new(2, 0), ID.new(1, 2), nil, {:any, [3]}, {:infer, ID.new(1, 2)}, nil)],
            DeleteSet.new()
          )

        O.rpc(port, %{cmd: "reset", client_id: 3})
        O.apply(port, yjs_bytes)
        O.apply(port, late)
        yjs_bytes2 = O.update(port)
        expected = yjs_view(port, yjs_bytes2)
        assert expected.array == ["y"]

        {:ok, doc} = Encoding.apply_update(O.load(yjs_bytes, 900), late)
        assert doc.pending == []
        assert Array.to_list(doc, "a") == ["y"]
        assert %Item{content: {:gc, 1}} = BlockStore.get(doc.store, ID.new(2, 0))

        assert yjs_view(port, Encoding.encode_update(doc)) == expected
      after
        Port.close(port)
      end
    end
  end

  # What a fresh Yjs replica shows after applying `bytes`: the array and
  # text roots plus Yjs's own re-encoding of its whole state (a full-state
  # round-trip, not a shape comparison).
  defp yjs_view(port, bytes) do
    O.rpc(port, %{cmd: "reset", client_id: 77})
    O.apply(port, bytes)

    %{
      array: O.rpc(port, %{cmd: "array_content", name: "a"})["array"],
      text: O.text(port, "t"),
      reencoded: O.update(port)
    }
  end
end
