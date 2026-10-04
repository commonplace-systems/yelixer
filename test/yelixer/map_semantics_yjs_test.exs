Code.require_file("../support/compat_oracle.exs", __DIR__)
Code.require_file("../support/clock_gap_history.exs", __DIR__)

defmodule Yelixer.MapSemanticsYjsTest do
  @moduledoc """
  yelixer#11: YMap read and write semantics against Yjs 13.6.32 itself.

    - **M2 (winner).** A key's value is its RIGHTMOST write in YATA order
      whether or not that write is deleted; a deleted rightmost write
      makes the key absent (Yjs `typeMapGet`). A write that integrates
      with a same-key write to its right is deleted on arrival
      (Item.js:507-528).
    - **M1 (origin).** `YMap.set` after a delete uses the deleted write as
      its origin (Yjs `typeMapSet`, AbstractType.js:847).

  Every expected value comes from the stable Yjs oracle, never from a
  hand-written literal alone. The oracle is REQUIRED: `CompatOracle.open/0`
  raises when Node or the oracle import is missing, so a missing oracle is
  a failure here, never a skip (the YELIXER_REQUIRE_YJS_ORACLE=1 semantics,
  unconditionally).

  Known byte-level difference from Yjs, not asserted here: Yelixer does
  not put the losers it tombstones on integration into its outgoing
  delete set (Yjs does); every receiver re-derives them, so reads agree.

  Every step also checks the `map_index` winner cache against a cold scan
  of the type's sequence, using only the store's raw fields so the check
  does not share code with the cache it is checking.
  """
  use ExUnit.Case, async: false

  alias Yelixer.{BlockStore, ClockGapHistory, DeleteSet, Doc, Encoding, ID, Item, StateCodec}
  alias Yelixer.Types.{XMLElement, YMap}
  alias Yelixer.Test.CompatOracle, as: O

  @key "map-semantics"

  setup do
    Process.put(:index_violations, [])
    p = O.open()
    on_exit(fn -> if Port.info(p), do: Port.close(p) end)
    %{port: p}
  end

  # ── oracle helpers ────────────────────────────────────────────────

  # One Yjs author per client: runs `ops` on a fresh Yjs doc and returns
  # one update per op (a diff from the state vector before that op).
  defp yjs_author(p, client, ops) do
    O.reset(p, client)

    Enum.map(ops, fn op ->
      sv = O.sv(p)

      case op do
        {:set, k, v} -> O.rpc(p, %{cmd: "set_map", root: "m", key: k, value: v})
        {:del, k} -> O.rpc(p, %{cmd: "delete_map", root: "m", key: k})
      end

      O.update(p, sv)
    end)
  end

  # What a fresh Yjs replica reads after applying `updates` in order.
  defp yjs_read(p, updates) do
    O.reset(p, 900)
    Enum.each(updates, &O.apply(p, &1))
    O.rpc(p, %{cmd: "map_content", name: "m"})["map"]
  end

  # The generator writes 2^70, which Yjs reads as a float; compare numbers
  # as floats (the known integer-vs-float artefact, not a map divergence).
  defp norm(n) when is_integer(n), do: n * 1.0
  defp norm(l) when is_list(l), do: Enum.map(l, &norm/1)
  defp norm(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), norm(v)} end)
  defp norm(v), do: v

  # ── yelixer helpers ───────────────────────────────────────────────

  defp replica(client \\ 999), do: Doc.new(client_id: client) |> Doc.put_type("m", :map)

  # Applies `updates` one at a time, checking the winner cache after each.
  defp yel_read(updates, label, doc \\ replica()) do
    Enum.reduce(updates, doc, fn u, d ->
      {:ok, d} = Encoding.apply_update(d, u)
      assert_index_consistent!(d, label)
      d
    end)
  end

  defp step(doc, f) do
    sv = Doc.state_vector(doc)
    doc = f.(doc)
    {doc, Encoding.encode_diff(doc, sv)}
  end

  # Cold scan from the raw store: every item of `type_key`'s sequence in
  # document order (tombstones included), the last one per key wins.
  defp cold_winners(doc, type_key) do
    store = BlockStore.materialize_sequence(doc.store, type_key)

    store.sequences
    |> Map.get(type_key, [])
    |> Enum.map(&BlockStore.get(store, &1))
    |> Enum.reduce(%{}, fn
      %{parent_sub: sub} = item, acc when is_binary(sub) -> Map.put(acc, sub, item)
      _, acc -> acc
    end)
  end

  # (1) every cached [id] is the key's rightmost write; (2) the cached read
  # path (has_key?) agrees with the cold winner for every key; (3) the
  # scanning read path (to_json) agrees with the cold winners.
  #
  # Violations are RECORDED here and asserted by `assert_index_clean!/0` at
  # the end of each test, after the Yjs value assertions — so a red run
  # names the value divergence first rather than hiding it behind the cache.
  defp assert_index_consistent!(doc, label) do
    cache =
      for {tk, subs} <- doc.store.map_index,
          {sub, ids} <- subs,
          ids != [],
          cold = cold_winners(doc, tk)[sub],
          cold == nil or ids != [cold.id] do
        "#{label}: map_index #{tk}/#{sub} = #{inspect(ids)}, cold rightmost write = " <>
          inspect(cold && {cold.id, cold.deleted})
      end

    winners = cold_winners(doc, "m")

    reads =
      for {k, item} <- winners, YMap.has_key?(doc, "m", k) != not item.deleted do
        "#{label}: has_key?(#{k}) disagrees with the cold winner #{inspect({item.id, item.deleted})}"
      end

    live = for {k, item} <- winners, not item.deleted, do: k

    json =
      if Map.keys(YMap.to_json(doc, "m")) |> Enum.sort() == Enum.sort(live),
        do: [],
        else: ["#{label}: to_json keys disagree with the cold winners"]

    Process.put(:index_violations, Process.get(:index_violations, []) ++ cache ++ reads ++ json)
    :ok
  end

  defp assert_index_clean! do
    violations = Process.get(:index_violations, [])

    assert violations == [],
           "map_index / read-path vs cold scan:\n" <> Enum.join(violations, "\n")
  end

  defp permutations([]), do: [[]]
  defp permutations(l), do: for(x <- l, rest <- permutations(l -- [x]), do: [x | rest])

  # ── M2: the #11 shape, every delivery order ───────────────────────

  describe "M2: [b, del b, a] — a deleted rightmost write hides an earlier live one" do
    test "Yjs-authored updates: every delivery order reads as Yjs reads it", %{port: p} do
      [ua] = yjs_author(p, 1, [{:set, "k", "a"}])
      [ub, udel] = yjs_author(p, 2, [{:set, "k", "b"}, {:del, "k"}])
      named = %{ua => "a", ub => "b", udel => "del b"}

      for order <- permutations([ub, udel, ua]) do
        label = "order " <> Enum.map_join(order, ", ", &named[&1])
        want = yjs_read(p, order)
        assert want == %{}, "#{label}: oracle positive control (Yjs reads the key as absent)"
        doc = yel_read(order, label)
        assert norm(YMap.to_json(doc, "m")) == norm(want), label
        assert YMap.get(doc, "m", "k") == nil, label
        refute YMap.has_key?(doc, "m", "k"), label
        # Yjs reads Yelixer's own re-encode the same way.
        assert yjs_read(p, [Encoding.encode_update(doc)]) == want, label
      end

      assert_index_clean!()
    end

    test "Yelixer-authored updates: every delivery order reads as Yjs reads it", %{port: p} do
      {_, ua} = step(replica(1), &YMap.set(&1, "m", "k", "a"))
      {d2, ub} = step(replica(2), &YMap.set(&1, "m", "k", "b"))
      {_, udel} = step(d2, &YMap.delete(&1, "m", "k"))
      named = %{ua => "a", ub => "b", udel => "del b"}

      for order <- permutations([ub, udel, ua]) do
        label = "order " <> Enum.map_join(order, ", ", &named[&1])
        want = yjs_read(p, order)
        assert want == %{}, "#{label}: oracle positive control"
        doc = yel_read(order, label)
        assert norm(YMap.to_json(doc, "m")) == norm(want), label
        assert YMap.get(doc, "m", "k") == nil, label
      end

      assert_index_clean!()
    end

    test "control: the rightmost write LIVE wins in every order", %{port: p} do
      [ua] = yjs_author(p, 2, [{:set, "k", "a"}])
      [ub, udel] = yjs_author(p, 1, [{:set, "k", "b"}, {:del, "k"}])

      for order <- permutations([ub, udel, ua]) do
        want = yjs_read(p, order)
        assert want == %{"k" => "a"}, "oracle positive control"
        doc = yel_read(order, "live-winner control")
        assert YMap.to_json(doc, "m") == want
        assert YMap.get(doc, "m", "k") == "a"
      end

      assert_index_clean!()
    end

    test "a set after reading the absent key lands right of the tombstone everywhere", %{
      port: p
    } do
      [ua] = yjs_author(p, 1, [{:set, "k", "a"}])
      [ub, udel] = yjs_author(p, 2, [{:set, "k", "b"}, {:del, "k"}])
      doc = yel_read([ub, udel, ua], "pre-set", replica(3))
      {doc, uc} = step(doc, &YMap.set(&1, "m", "k", "c"))
      assert_index_consistent!(doc, "post-set")
      assert YMap.to_json(doc, "m") == %{"k" => "c"}

      for order <- permutations([ub, udel, ua, uc]) do
        assert yjs_read(p, order) == %{"k" => "c"}
        assert YMap.to_json(yel_read(order, "with c"), "m") == %{"k" => "c"}
      end

      assert_index_clean!()
    end
  end

  # ── M1: single client set, delete, set ────────────────────────────

  describe "M1: one client sets k=1, deletes k, sets k=2" do
    test "Yelixer-authored bytes read the same in Yjs as in Yelixer", %{port: p} do
      {d, u1} = step(replica(5), &YMap.set(&1, "m", "k", 1))
      {d, u2} = step(d, &YMap.delete(&1, "m", "k"))
      {author, u3} = step(d, &YMap.set(&1, "m", "k", 2))
      assert_index_consistent!(author, "author")

      # The third write's origin is the tombstoned first write (typeMapSet).
      {:ok, {[item], _, _}} = Encoding.decode_update(u3)
      assert item.origin == ID.new(5, 0)

      want = yjs_read(p, [u1, u2, u3])
      assert want == %{"k" => 2}
      assert YMap.to_json(author, "m") == want
      assert YMap.to_json(yel_read([u1, u2, u3], "replica"), "m") == want
      assert yjs_read(p, [Encoding.encode_update(author)]) == want
      assert_index_clean!()
    end

    test "Yjs-authored bytes read the same in Yelixer as in Yjs", %{port: p} do
      ups = yjs_author(p, 5, [{:set, "k", 1}, {:del, "k"}, {:set, "k", 2}])
      want = yjs_read(p, ups)
      assert want == %{"k" => 2}
      doc = yel_read(ups, "yjs-authored")
      assert YMap.to_json(doc, "m") == want
      # And back: Yjs reads Yelixer's re-encode of the Yjs history the same.
      assert yjs_read(p, [Encoding.encode_update(doc)]) == want
      assert_index_clean!()
    end

    test "Yelixer and Yjs alternate on one key and agree at every step", %{port: p} do
      ops = [{:set, "k", 1}, {:del, "k"}, {:set, "k", 2}, {:del, "k"}, {:set, "k", 3}]

      {_doc, ups} =
        Enum.reduce(ops, {replica(7), []}, fn op, {d, ups} ->
          {d, u} =
            case op do
              {:set, k, v} -> step(d, &YMap.set(&1, "m", k, v))
              {:del, k} -> step(d, &YMap.delete(&1, "m", k))
            end

          ups = ups ++ [u]
          assert_index_consistent!(d, "step #{length(ups)}")
          assert yjs_read(p, ups) == YMap.to_json(d, "m"), "step #{length(ups)}"
          {d, ups}
        end)

      assert yjs_read(p, ups) == %{"k" => 3}
      assert_index_clean!()
    end
  end

  # ── generated histories (S3 generator), forward and reverse ───────

  # Seeds that diverged before yelixer#11 (diagnosis on the S3 pin,
  # seeds 0-299 plus the first five real seeds of 300-2999).
  @seeds [43, 107, 113, 138, 164, 192, 236, 238, 248, 261, 277, 291, 309, 331, 342, 363, 389]

  describe "generated multi-author histories" do
    test "map root matches Yjs forward and reversed, cache checked every step", %{port: p} do
      bad =
        Enum.flat_map(@seeds, fn seed ->
          h = ClockGapHistory.generate(seed)
          fwd = h.delivery ++ h.withheld

          Enum.flat_map([{"fwd", fwd}, {"rev", Enum.reverse(fwd)}], fn {dir, ups} ->
            doc =
              Enum.reduce(ups, ClockGapHistory.registered(999_001), fn u, d ->
                {:ok, d} = Encoding.apply_update(d, u)
                assert_index_consistent!(d, "seed #{seed} #{dir}")
                d
              end)

            yel = norm(YMap.to_json(doc, "m"))
            yjs = norm(yjs_read(p, ups))
            if yel == yjs, do: [], else: [{seed, dir, yel, yjs}]
          end)
        end)

      assert bad == []
      assert_index_clean!()
    end
  end

  # ── B1/I1: merged multi-clock winners (origin = lastId; split moves the cache) ──

  describe "a Yjs key history merged into one multi-clock block" do
    for {gc, client} <- [{false, 10}, {true, 10}, {false, 2}, {true, 2}] do
      @gc gc
      @client client
      test "Yjs set,set,del (gc=#{gc}) then a Yelixer set from client #{if client > 5, do: "LOWER", else: "HIGHER"} id",
           %{port: p} do
        O.rpc(p, %{cmd: "reset", client_id: @client, gc: @gc})
        O.rpc(p, %{cmd: "set_map", root: "m", key: "k", value: 1})
        O.rpc(p, %{cmd: "set_map", root: "m", key: "k", value: 2})
        O.rpc(p, %{cmd: "delete_map", root: "m", key: "k"})
        full = O.update(p)

        replica = yel_read([full], "merged history", replica(5))
        # Positive control on the shape: the key's two writes arrive as ONE
        # deleted 2-clock block, the key's winner.
        merged = BlockStore.get(replica.store, ID.new(@client, 0))
        assert merged.length == 2 and merged.deleted and merged.parent_sub == "k"
        assert YMap.to_json(replica, "m") == %{}

        {author, u} = step(replica, &YMap.set(&1, "m", "k", 3))
        assert_index_consistent!(author, "author after set")
        {:ok, {[item], _, _}} = Encoding.decode_update(u)
        # Yjs typeMapSet: origin = left.lastId, the block's LAST clock.
        assert item.origin == ID.new(@client, 1)

        assert yjs_read(p, [full, u]) == %{"k" => 3}
        assert YMap.to_json(author, "m") == %{"k" => 3}
        # A fresh replica integrates `u` anchored at the merged block's LAST
        # clock, so no split happens here (the split path is pinned by
        # "splitting a cached multi-clock winner" below); its cache must end
        # on the new write.
        fresh = yel_read([full, u], "fresh replica")
        assert YMap.to_json(fresh, "m") == %{"k" => 3}
        assert fresh.store.map_index["m"]["k"] == [item.id]
        assert {:ok, _} = StateCodec.encode(fresh, @key)
        assert {:ok, _} = StateCodec.encode(author, @key)
        assert yjs_read(p, [Encoding.encode_update(author)]) == %{"k" => 3}
        assert_index_clean!()
      end
    end
  end

  describe "splitting a cached multi-clock winner" do
    # Through integration this is masked: a split of a map block is always
    # for a same-key write anchored inside it, and settling that write
    # re-caches the winner. This pins the split itself (BlockStore's split
    # path, used by Integrate's origin/right-origin splits): the cache must
    # follow the rightmost piece, as Yjs splitItem moves `_map`.
    test "the cache moves to the right piece", %{port: p} do
      O.rpc(p, %{cmd: "reset", client_id: 10, gc: false})
      O.rpc(p, %{cmd: "set_map", root: "m", key: "k", value: 1})
      O.rpc(p, %{cmd: "set_map", root: "m", key: "k", value: 2})
      O.rpc(p, %{cmd: "delete_map", root: "m", key: "k"})
      doc = yel_read([O.update(p)], "merged")
      assert doc.store.map_index["m"]["k"] == [ID.new(10, 0)]
      assert BlockStore.get(doc.store, ID.new(10, 0)).length == 2

      {store, right} = BlockStore.split_block_at_clock(doc.store, ID.new(10, 1), "m")
      assert right.id == ID.new(10, 1)
      doc = %{doc | store: store}
      assert doc.store.map_index["m"]["k"] == [ID.new(10, 1)]
      assert_index_consistent!(doc, "after split")
      assert {:ok, _} = StateCodec.encode(doc, @key)
      assert_index_clean!()
    end
  end

  # ── Doc.gc, then set ──────────────────────────────────────────────

  describe "Doc.gc then set" do
    test "set, delete, gc, set is visible to Yjs", %{port: p} do
      {d, u1} = step(replica(5), &YMap.set(&1, "m", "k", 1))
      {d, u2} = step(d, &YMap.delete(&1, "m", "k"))
      {d, u3} = step(Doc.gc(d), &YMap.set(&1, "m", "k", 2))
      assert_index_consistent!(d, "after gc + set")
      assert YMap.to_json(d, "m") == %{"k" => 2}
      assert yjs_read(p, [u1, u2, u3]) == %{"k" => 2}
      assert yjs_read(p, [Encoding.encode_update(d)]) == %{"k" => 2}
      assert YMap.to_json(yel_read([Encoding.encode_update(d)], "reload"), "m") == %{"k" => 2}
      assert_index_clean!()
    end

    test "set, set, gc, set is visible to Yjs", %{port: p} do
      {d, u1} = step(replica(5), &YMap.set(&1, "m", "k", 1))
      {d, u2} = step(d, &YMap.set(&1, "m", "k", 2))
      {d, u3} = step(Doc.gc(d), &YMap.set(&1, "m", "k", 3))
      assert_index_consistent!(d, "after gc + set")
      assert yjs_read(p, [u1, u2, u3]) == %{"k" => 3}
      assert YMap.to_json(d, "m") == %{"k" => 3}
      assert_index_clean!()
    end
  end

  # ── nested maps and XmlFragment attributes (map plane under a parent id) ──

  # Hand-built wire updates: a parent value `{:type, ref}` at m["sub"]
  # (client 3), two concurrent writes of key "k" under it (clients 1 and
  # 2), and a delete of client 2's write.
  defp nested_updates(ref, deleted?) do
    parent = ID.new(3, 0)

    up =
      Encoding.encode_items(
        [Item.new(parent, nil, nil, {:type, ref}, {:named, "m"}, "sub")],
        DeleteSet.new()
      )

    ua =
      Encoding.encode_items(
        [Item.new(ID.new(1, 0), nil, nil, {:any, ["a"]}, {:id, parent}, "k")],
        DeleteSet.new()
      )

    ub =
      Encoding.encode_items(
        [Item.new(ID.new(2, 0), nil, nil, {:any, ["b"]}, {:id, parent}, "k")],
        DeleteSet.new()
      )

    udel = Encoding.encode_items([], DeleteSet.insert(DeleteSet.new(), 2, 0, 1))
    {up, if(deleted?, do: [ua, ub, udel], else: [ua, ub])}
  end

  # The parent always arrives first. A child delivered BEFORE its parent
  # value is integrated under `__sub:3:0` with an `:unknown` type that is
  # never upgraded, so the nested value then reads as nil — a pre-existing
  # sub-type registration defect independent of yelixer#11 (it does not
  # involve the winner rule), tracked separately.
  defp nested_orders(ref, deleted?) do
    {up, rest} = nested_updates(ref, deleted?)
    for order <- permutations(rest), do: [up | order]
  end

  describe "the map rule under a parent id" do
    test "nested map: a deleted rightmost write hides the earlier one, every order", %{port: p} do
      for order <- nested_orders(:map, true) do
        want = yjs_read(p, order)
        assert want == %{"sub" => %{}}, "oracle positive control"
        assert YMap.to_json(yel_read(order, "nested"), "m") == want
      end

      for order <- nested_orders(:map, false) do
        want = yjs_read(p, order)
        assert want == %{"sub" => %{"k" => "b"}}, "oracle positive control"
        assert YMap.to_json(yel_read(order, "nested control"), "m") == want
      end

      assert_index_clean!()
    end

    # yelixer#15 shape: children delivered BEFORE their parent value. Read
    # through the synthetic name directly, the nested map plane follows the
    # winner rule in every child-first order; only the parent's `:unknown`
    # type registration (read via m["sub"]) is wrong, which is #15.
    test "child-first: the nested map read by its __sub name matches Yjs", %{port: p} do
      for deleted? <- [true, false] do
        {up, rest} = nested_updates(:map, deleted?)

        for order <- permutations(rest) do
          ups = order ++ [up]
          want = yjs_read(p, ups)["sub"]
          assert want == if(deleted?, do: %{}, else: %{"k" => "b"}), "oracle positive control"
          doc = yel_read(ups, "child-first")
          assert YMap.to_json(doc, "__sub:3:0") == want
        end
      end

      assert_index_clean!()
    end

    # Yjs's XmlFragment.toJSON renders children only, so there is no oracle
    # value for attributes; this pins Yelixer's xml_fragment_to_json attrs
    # (types.ex) to the same winner rule the map oracle verifies above.
    test "XmlFragment attrs follow the winner rule, every order" do
      for order <- nested_orders(:xml_fragment, true) do
        assert YMap.to_json(yel_read(order, "frag"), "m") == %{"sub" => %{}}
      end

      for order <- nested_orders(:xml_fragment, false) do
        assert YMap.to_json(yel_read(order, "frag control"), "m") ==
                 %{"sub" => %{"attrs" => %{"k" => "b"}}}
      end

      assert_index_clean!()
    end
  end

  # ── I2: XmlElement attribute writes keep the winner cache honest ──

  describe "XmlElement.set_attribute after a remote attribute write" do
    test "the cache stays consistent and the doc still checkpoints" do
      reg = fn cid -> Doc.new(client_id: cid) |> Doc.put_type("x", {:xml_element, "div"}) end
      remote = XMLElement.set_attribute(reg.(5), "x", "class", "r")
      {:ok, local} = Encoding.apply_update(reg.(9), Encoding.encode_update(remote))
      assert local.store.map_index["x"]["class"] == [ID.new(5, 0)]
      local = XMLElement.set_attribute(local, "x", "class", "l")
      assert XMLElement.get_attribute(local, "x", "class") == "l"
      assert_index_consistent!(local, "after local set_attribute")
      assert {:ok, _} = StateCodec.encode(local, @key)
      assert_index_clean!()
    end
  end

  # ── checkpoints written before #11 ────────────────────────────────

  defp forge(term) do
    {:ok, payload} = StateCodec.encode_term(term)

    header =
      <<"YXSC", StateCodec.format_version()::16, byte_size(@key)::32, @key::binary,
        byte_size(payload)::64>>

    header <> :crypto.hash(:sha256, [header, payload]) <> payload
  end

  describe "StateCodec and the pre-#11 live-id cache" do
    test "a cache naming a live write left of a deleted rightmost write is refused", %{port: p} do
      [ua] = yjs_author(p, 1, [{:set, "k", "a"}])
      [ub, udel] = yjs_author(p, 2, [{:set, "k", "b"}, {:del, "k"}])
      doc = yel_read([ub, udel, ua], "checkpoint source")
      {:ok, good} = StateCodec.canonical_state(doc)

      # The pre-#11 shape of this state: `a` (1:0) left live and cached as
      # the key's live id, while `b` (2:0, deleted) is rightmost.
      clients = elem(good, 7)

      live_a =
        Enum.map(clients[1], fn t -> if elem(t, 0) == 0, do: put_elem(t, 5, false), else: t end)

      legacy = good |> put_elem(7, Map.put(clients, 1, live_a))

      assert {:error, {:malformed, :map_index}} =
               StateCodec.decode(forge(put_elem(legacy, 10, %{"m" => %{"k" => [{1, 0}]}})), @key)

      # The same stored items with the rightmost write cached, or with the
      # pre-#11 `[]` ("unknown"), are accepted and read as Yjs reads them.
      for index <- [%{"m" => %{"k" => [{2, 0}]}}, %{"m" => %{"k" => []}}, %{}] do
        assert {:ok, restored} = StateCodec.decode(forge(put_elem(legacy, 10, index)), @key)
        assert YMap.to_json(restored, "m") == %{}
        assert YMap.get(restored, "m", "k") == nil
      end

      assert_index_clean!()
    end
  end
end
