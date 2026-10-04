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

    # Every root, not just "a": after full replay, each root's sequence
    # holds only the content its authors put there. The generator writes
    # strings to text "t", unkeyed values to array "a", keyed values to map
    # "m" and to the attributes of XML element "x", and children (types) to
    # fragment "f". (A wider per-root Yjs comparison over these histories
    # is not usable as a gate: it also trips over unrelated, pre-existing
    # render differences.)
    @root_contents %{
      "t" => {:string, false},
      "a" => {:any, false},
      "m" => {:any, true},
      "x" => {:any, true},
      "f" => {:type, false}
    }

    test "seeds 0..299: full replay never puts a foreign item in any root" do
      bad =
        for s <- 0..299,
            h = H.generate(s),
            d = H.apply_all(H.registered(1), h.delivery ++ h.withheld),
            {root, {kind, keyed?}} <- @root_contents,
            Enum.any?(
              BlockStore.get_sequence(d.store, root),
              &(elem(&1.content, 0) != kind or &1.parent_sub != nil != keyed?)
            ),
            do: {s, root}

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
    # Yjs (gc on): "a" = [nested Y.Array [1, 2] | nested Y.Map %{"k" => 1},
    # "y"], then the nested type is deleted. Its children are GC'd under a
    # GC'd parent, so Yjs replaces them with a GC struct at 1:1; 1:0 (the
    # type item) becomes ContentDeleted and "y" is 1:(1 + gc_len).
    defp yjs_gc_struct_update(port, nested) do
      O.rpc(port, %{cmd: "reset", client_id: 1, gc: true})

      {cmd, gc_len} =
        case nested do
          :array -> {%{cmd: "array_push_nested_array", root: "a", values: [1, 2]}, 2}
          :map -> {%{cmd: "array_push_nested_map", root: "a", entries: %{"k" => 1}}, 1}
        end

      O.rpc(port, cmd)
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
                   content: {:gc, ^gc_len},
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
        yjs_bytes = yjs_gc_struct_update(port, :array)
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

    # A concurrent peer (client 2) wrote into the nested type before seeing
    # its delete. The receiver holds the anchor only inside GC struct 1:1.
    #   origin:       appended 3 after the nested array's last child 1:2
    #   right_origin: prepended 0 before the nested array's first child 1:1
    #   map key:      overwrote "k"; a map write's wire origin is the key's
    #                 previous value (1:1) and its parent_sub is not written
    for {label, nested, origin, right_origin, value} <- [
          {"origin", :array, {1, 2}, nil, 3},
          {"right_origin only", :array, nil, {1, 1}, 0},
          {"map key overwrite (parent_sub inherited)", :map, {1, 1}, nil, 2}
        ] do
      @nested nested
      @origin origin
      @right_origin right_origin
      @value value
      test "an item anchored on a wire GC struct by #{label} becomes GC, as in Yjs" do
        port = O.open()

        id = fn
          nil -> nil
          {c, k} -> ID.new(c, k)
        end

        origin = id.(@origin)
        right_origin = id.(@right_origin)

        try do
          yjs_bytes = yjs_gc_struct_update(port, @nested)

          late =
            Encoding.encode_items(
              [
                Item.new(
                  ID.new(2, 0),
                  origin,
                  right_origin,
                  {:any, [@value]},
                  {:infer, origin || right_origin},
                  nil
                )
              ],
              DeleteSet.new()
            )

          O.rpc(port, %{cmd: "reset", client_id: 3})
          O.apply(port, yjs_bytes)
          O.apply(port, late)
          expected = yjs_view(port, O.update(port))
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

    # The other GC kind: a block the RECEIVER collected with Doc.gc/1 keeps
    # its real parent (Yjs: ContentDeleted, Item.js gc/2), so a remote
    # insert anchored on it must integrate as a normal item, not as GC.
    test "an insert anchored on a block the receiver itself GC'd integrates normally (Yjs-equal)" do
      port = O.open()

      try do
        author = Doc.new(client_id: 100) |> Doc.put_type("t", :text) |> Text.insert("t", 0, "abc")
        ua = Encoding.encode_update(author)

        # Peer 300 (has "abc"): "X" between a and b (origin 100:0, right
        # origin 100:1), then "Y" at the front (right origin 100:0 only).
        {:ok, peer} = Encoding.apply_update(reg(300), ua)
        peer = peer |> Text.insert("t", 1, "X") |> Text.insert("t", 0, "Y")
        ub = Encoding.encode_diff(peer, Doc.state_vector(author))

        {:ok, {late, _, _}} = Encoding.decode_update(ub)

        assert Enum.map(late, &{&1.content, &1.origin, &1.right_origin}) == [
                 {{:string, "X"}, ID.new(100, 0), ID.new(100, 1)},
                 {{:string, "Y"}, nil, ID.new(100, 0)}
               ]

        # Receiver 200 deletes "ab" and collects it before ub arrives.
        {:ok, r} = Encoding.apply_update(reg(200), ua)
        r = r |> Text.delete("t", 0, 2) |> Doc.gc()
        assert %Item{content: {:gc, 2}} = BlockStore.get(r.store, ID.new(100, 0))
        {:ok, r} = Encoding.apply_update(r, ub)
        assert r.pending == []

        O.rpc(port, %{cmd: "reset", client_id: 200, gc: true})
        O.apply(port, ua)
        O.rpc(port, %{cmd: "delete_text", name: "t", pos: 0, len: 2})
        O.apply(port, ub)
        expected = yjs_view(port, O.update(port))
        assert expected.text == "YXc"

        assert Text.to_string(r, "t") == "YXc"
        assert yjs_view(port, Encoding.encode_update(r)) == expected
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
