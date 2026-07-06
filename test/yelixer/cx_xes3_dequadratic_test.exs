defmodule Yelixer.CXXes3DequadraticTest do
  @moduledoc """
  CX-xes3 (E3/E4) regression coverage: the map-key conflict resolution
  and delete-application quadratic paths this issue de-quadratic-ed,
  plus a correctness pin for the conflict-resolution fast path added
  along the way (`Yelixer.BlockStore.map_live_ids/3` +
  `Yelixer.Integrate`'s map-aware `fast_append_index/3` clause).

  Every scaling assertion here replays *wire-encoded updates* — a list
  of small `apply_update/2` blobs, exactly the shape a real commit
  chain replay walks — rather than timing in-memory `YMap.set/4` calls
  directly, since that's what actually stalled (see CX-xes3 issue: a
  49MB production store copy replay sat on one doc for hours).
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Types.{YMap, Array}
  alias Yelixer.{Encoding, BlockStore, ID, Integrate, DeleteSet}

  # Builds a list of small per-write update blobs by tracking the
  # state vector after each `build_step` call and diffing against it —
  # the same shape `Yelixer.Encoding.encode_diff/2` produces for a real
  # incremental sync, and what a commit chain replay actually walks
  # (one small update per commit, not one giant snapshot).
  defp incremental_updates(doc, steps) do
    {updates, _final_doc, _final_sv} =
      Enum.reduce(steps, {[], doc, BlockStore.state_vector(doc.store)}, fn step, {acc, d, sv} ->
        d2 = step.(d)
        u = Encoding.encode_diff(d2, sv)
        {[u | acc], d2, BlockStore.state_vector(d2.store)}
      end)

    Enum.reverse(updates)
  end

  defp replay(updates, client_id \\ 999_999) do
    Enum.reduce(updates, Doc.new(client_id: client_id), fn u, d ->
      {:ok, d2} = Encoding.apply_update(d, u)
      d2
    end)
  end

  defp time_replay(updates) do
    {us, _doc} = :timer.tc(fn -> replay(updates) end)
    us
  end

  # N sequential `YMap.set/4` writes, round-robined across M keys — the
  # map-heavy shape (schemas, presence, per-entity status docs) that
  # made `maybe_resolve_map_conflict/3` (and, less obviously,
  # `Yelixer.Integrate`'s YATA insertion) O(n) per write.
  defp map_heavy_updates(n, m) do
    keys = for i <- 0..(m - 1), do: "key#{i}"
    doc = Doc.new(client_id: 1)
    {doc, _} = Doc.get_or_create_type(doc, "root", :map)

    steps =
      for i <- 1..n do
        key = Enum.at(keys, rem(i, m))
        fn d -> YMap.set(d, "root", key, "value-#{i}") end
      end

    incremental_updates(doc, steps)
  end

  describe "(a) map-heavy replay scaling" do
    @tag timeout: 120_000
    test "N sequential YMap.set updates on one key + M keys: 10k replay < 3x the 5k replay" do
      m = 8

      small_updates = map_heavy_updates(5_000, m)
      large_updates = map_heavy_updates(10_000, m)

      small_us = time_replay(small_updates)
      large_us = time_replay(large_updates)

      ratio = large_us / max(small_us, 1)

      assert ratio < 3,
        "map-heavy replay scaling ratio #{Float.round(ratio, 2)}x (5k=#{small_us}us, " <>
          "10k=#{large_us}us) suggests quadratic behavior reintroduced"
    end
  end

  describe "(b) conflict-resolution correctness unchanged under concurrency" do
    test "concurrent same-key writes from two clients converge to the same winner regardless of integration order" do
      # Shared ancestor: one client establishes the key, both replicas
      # sync to that point before diverging.
      base = Doc.new(client_id: 42)
      {base, _} = Doc.get_or_create_type(base, "m", :map)
      base = YMap.set(base, "m", "k", "original")
      common = Encoding.encode_update(base)

      {:ok, replica_a} = Encoding.apply_update(Doc.new(client_id: 111), common)
      {:ok, replica_b} = Encoding.apply_update(Doc.new(client_id: 222), common)

      sv_after_common = BlockStore.state_vector(replica_a.store)

      replica_a = YMap.set(replica_a, "m", "k", "from-A")
      update_a = Encoding.encode_diff(replica_a, sv_after_common)

      replica_b = YMap.set(replica_b, "m", "k", "from-B")
      update_b = Encoding.encode_diff(replica_b, sv_after_common)

      doc_ab = replay([common, update_a, update_b], 1)
      doc_ba = replay([common, update_b, update_a], 2)

      assert YMap.get(doc_ab, "m", "k") == YMap.get(doc_ba, "m", "k"),
        "same-key concurrent writes picked different winners depending on integration order"

      # Byte-identical encodes pin that the map_index fast path didn't
      # change which item wins, not just that the visible value matches
      # (a coincidental value match could hide a different underlying
      # winner item / tombstone set).
      assert Encoding.encode_update(doc_ab) == Encoding.encode_update(doc_ba)
    end

    test "three-way concurrent same-key writes converge regardless of integration order" do
      base = Doc.new(client_id: 42)
      {base, _} = Doc.get_or_create_type(base, "m", :map)
      base = YMap.set(base, "m", "k", "original")
      common = Encoding.encode_update(base)
      sv = fn d -> BlockStore.state_vector(d.store) end

      make_update = fn client_id, value ->
        {:ok, replica} = Encoding.apply_update(Doc.new(client_id: client_id), common)
        sv0 = sv.(replica)
        replica = YMap.set(replica, "m", "k", value)
        Encoding.encode_diff(replica, sv0)
      end

      u_a = make_update.(111, "from-A")
      u_b = make_update.(222, "from-B")
      u_c = make_update.(333, "from-C")

      orders = [
        [common, u_a, u_b, u_c],
        [common, u_c, u_b, u_a],
        [common, u_b, u_a, u_c]
      ]

      results =
        orders
        |> Enum.with_index()
        |> Enum.map(fn {updates, i} ->
          doc = replay(updates, 1000 + i)
          {YMap.get(doc, "m", "k"), Encoding.encode_update(doc)}
        end)

      assert results |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 1
      assert results |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
    end
  end

  describe "(c) delete-heavy replay scaling" do
    # N sequential single-element deletes from the tail of a growing
    # array — exercises `Yelixer.Integrate.mark_deleted/2` and
    # `Yelixer.Encoding.apply_delete_range/4`'s block-splitting
    # (`split_in_clients/4`) once per delete.
    #
    # Builds each delete step from the id directly (`Array.push/3`
    # assigns ids sequentially — clocks `0..n-1` on one client_id) —
    # bypassing `Array.delete/4`'s own `find_items_in_range/4`, which
    # walks `BlockStore.get_sequence/2` (O(current length)) on *every*
    # call regardless of which index is targeted. That's a real,
    # separate quadratic path in `Yelixer.Types.Array`'s read-model,
    # but outside E3/E4's scope (BlockStore/Integrate/Encoding/
    # DeleteSet) — going around it here keeps this test's SETUP phase
    # linear, so what's actually timed below is the E3 delete-
    # application path (`Integrate.mark_deleted/2` +
    # `Encoding.apply_delete_range/4`'s block-splitting), not test
    # scaffolding.
    defp delete_heavy_updates(n) do
      doc = Doc.new(client_id: 1)
      {doc, _} = Doc.get_or_create_type(doc, "arr", :array)
      doc = Array.push(doc, "arr", Enum.to_list(1..n))

      steps =
        for i <- (n - 1)..0//-1 do
          id = ID.new(doc.client_id, i)

          fn d ->
            store = Integrate.mark_deleted(d.store, id)
            delete_set = DeleteSet.insert(d.delete_set, id.client, id.clock, 1)
            %{d | store: store, delete_set: delete_set}
          end
        end

      incremental_updates(doc, steps)
    end

    @tag timeout: 120_000
    test "N sequential single-element deletes: 10k replay < 3x the 5k replay" do
      small_updates = delete_heavy_updates(5_000)
      large_updates = delete_heavy_updates(10_000)

      small_us = time_replay(small_updates)
      large_us = time_replay(large_updates)

      ratio = large_us / max(small_us, 1)

      assert ratio < 3,
        "delete-heavy replay scaling ratio #{Float.round(ratio, 2)}x (5k=#{small_us}us, " <>
          "10k=#{large_us}us) suggests quadratic behavior reintroduced"
    end

    test "deletes are actually applied (sanity check alongside the scaling assertion)" do
      updates = delete_heavy_updates(50)
      doc = replay(updates)
      assert Array.length(doc, "arr") == 0
    end
  end
end
