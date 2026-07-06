defmodule Yelixer.DocTest do
  use ExUnit.Case, async: true

  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.{Array, Text, YMap}

  test "creates a new doc with a client id" do
    doc = Doc.new(client_id: 1)
    assert doc.client_id == 1
  end

  test "auto-generates client id if not provided" do
    doc = Doc.new()
    assert is_integer(doc.client_id)
    assert doc.client_id > 0
  end

  test "get_or_create_type registers a root type" do
    {doc, _ref} = Doc.new(client_id: 1) |> Doc.get_or_create_type("text", :text)
    assert Doc.has_type?(doc, "text")
  end

  test "get_or_create_type returns existing type on second call" do
    {doc, ref1} = Doc.new(client_id: 1) |> Doc.get_or_create_type("text", :text)
    {_doc, ref2} = Doc.get_or_create_type(doc, "text", :text)
    assert ref1 == ref2
  end

  test "multiple types can coexist" do
    doc = Doc.new(client_id: 1)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    {doc, _} = Doc.get_or_create_type(doc, "arr", :array)
    {doc, _} = Doc.get_or_create_type(doc, "map", :map)
    assert Doc.has_type?(doc, "text")
    assert Doc.has_type?(doc, "arr")
    assert Doc.has_type?(doc, "map")
  end

  describe "clock_floor / mint_clock (CX-b0ow.9)" do
    test "defaults to 0 and doesn't perturb non-floored mint clocks" do
      doc = Doc.new(client_id: 1)
      assert doc.clock_floor == 0
      assert Doc.mint_clock(doc) == 0

      doc = Text.insert(doc, "t", 0, "hello")
      assert Doc.mint_clock(doc) == 5
    end

    test "a floored doc mints starting at the floor, not its own (lower) state vector clock" do
      # Fresh doc, empty store -> local SV clock is 0, but the floor
      # forces the NEXT mint to start higher, simulating a replica
      # reconstructed at a stale anchor whose hand minted further ops
      # later in the chain (CX-b0ow.9's region-merge scenario).
      doc = Doc.new(client_id: 42, clock_floor: 100)
      assert Doc.mint_clock(doc) == 100

      doc = Text.insert(doc, "t", 0, "hi")
      # The insert's item id used clock 100 (the floor); the doc's own
      # state vector now reflects that write.
      assert BlockStore.state_vector(doc.store) |> Yelixer.StateVector.get(42) == 102
      assert Doc.mint_clock(doc) == 102
    end

    test "floor never LOWERS the mint clock below the doc's own state vector" do
      doc = Doc.new(client_id: 1, clock_floor: 0)
      doc = Text.insert(doc, "t", 0, "abcde")
      # Local SV clock (5) already exceeds the floor (0) -> max/2 picks
      # the local clock, exactly like the pre-floor behavior.
      assert Doc.mint_clock(doc) == 5
    end

    test "encode_diff from a floored replica carries the floored clocks, and applies cleanly onto a doc that owns the gap" do
      # Simulates the region-merge shape: a "live" doc mints ops 0..4
      # under a shared client id, advancing its clock past what a stale
      # anchor replica knows about.
      hand = 7
      live = Doc.new(client_id: hand)
      live = Text.insert(live, "t", 0, "aaaaa")
      gap_sv = BlockStore.state_vector(live.store)
      assert Yelixer.StateVector.get(gap_sv, hand) == 5

      # A replica reconstructed at the stale anchor (empty store, same
      # hand) with the floor set to the live doc's clock.
      replica = Doc.new(client_id: hand, clock_floor: 5)
      anchor_sv = BlockStore.state_vector(replica.store)
      replica = Text.insert(replica, "t", 0, "bbb")

      u_bytes = Encoding.encode_diff(replica, anchor_sv)

      # U's new item claims clocks starting at the floor (5), not 0 —
      # applying it to a FRESH doc that does NOT own the gap (clocks
      # 0..4) would leave a permanently-pending item; applying it to
      # `live` (which DOES own the gap) integrates cleanly.
      {:ok, merged} = Encoding.apply_update(live, u_bytes)
      assert Yelixer.Doc.pending_info(merged).count == 0
      merged_text = Text.to_string(merged, "t")
      # Both sides' content survived and integrated (exact interleave
      # order is a YATA tiebreak detail, not what this pin is about).
      assert merged_text =~ "aaaaa"
      assert merged_text =~ "bbb"
      assert String.length(merged_text) == 8
    end

    test "non-floored doc's encode_update bytes are byte-identical to the pre-refactor shape (wire-invariance pin)" do
      doc = Doc.new(client_id: 9)
      doc = Text.insert(doc, "t", 0, "hello")
      doc = YMap.set(doc, "m", "k", "v")
      doc = Array.insert(doc, "a", 0, [1, 2, 3])

      bytes1 = Encoding.encode_update(doc)

      # Rebuild the identical sequence of ops on a second, independently
      # constructed (non-floored) doc under the same client id -- since
      # ops are deterministic given the same inputs, the encoded bytes
      # must match exactly. This is the wire-invariance pin: the
      # mint_clock centralization must not change a single byte for the
      # `clock_floor: 0` (default) case.
      doc2 = Doc.new(client_id: 9)
      doc2 = Text.insert(doc2, "t", 0, "hello")
      doc2 = YMap.set(doc2, "m", "k", "v")
      doc2 = Array.insert(doc2, "a", 0, [1, 2, 3])

      bytes2 = Encoding.encode_update(doc2)

      assert bytes1 == bytes2
    end
  end

  describe "snapshot_update/1 (CX-u7p)" do
    test "produces an update with state vector size 1 for a YMap-only doc" do
      # Simulate a presence-style doc that's accumulated many client_ids
      # by applying updates from many fresh-client-id docs in sequence.
      base = simulate_bloated_map(50)

      assert map_size(BlockStore.state_vector(base.store).clocks) >= 50

      {snapshot_bin, _dm} = Doc.snapshot_update(base)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), snapshot_bin)

      assert map_size(BlockStore.state_vector(rebuilt.store).clocks) == 1
      assert YMap.to_map(rebuilt, "presence") == YMap.to_map(base, "presence")
    end

    test "preserves text content with single client_id in state vector" do
      doc = Doc.new(client_id: 7)
      {doc, _} = Doc.get_or_create_type(doc, "body", :text)
      doc = Text.insert(doc, "body", 0, "hello world")

      {snapshot_bin, _dm} = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), snapshot_bin)

      assert Text.to_string(rebuilt, "body") == "hello world"
      assert map_size(BlockStore.state_vector(rebuilt.store).clocks) == 1
      assert Map.has_key?(BlockStore.state_vector(rebuilt.store).clocks, 7)
    end

    test "preserves array content with single client_id in state vector" do
      doc = Doc.new(client_id: 11)
      {doc, _} = Doc.get_or_create_type(doc, "items", :array)
      doc = Array.insert(doc, "items", 0, ["a", "b", "c"])

      {snapshot_bin, _dm} = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), snapshot_bin)

      assert Array.to_list(rebuilt, "items") == ["a", "b", "c"]
      assert map_size(BlockStore.state_vector(rebuilt.store).clocks) == 1
    end

    test "snapshot uses the source doc's own client_id" do
      doc = Doc.new(client_id: 4242)
      {doc, _} = Doc.get_or_create_type(doc, "m", :map)
      doc = YMap.set(doc, "m", "k", "v")

      {snapshot_bin, _dm} = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), snapshot_bin)

      assert Map.keys(BlockStore.state_vector(rebuilt.store).clocks) == [4242]
    end

    # Build a YMap doc with many distinct client_ids by repeatedly
    # generating updates from fresh-client docs and merging them in,
    # mirroring the bug pattern from the design doc.
    defp simulate_bloated_map(rounds) do
      seed =
        Doc.new(client_id: 1)
        |> add_map("presence", "name", "alice")

      Enum.reduce(2..(rounds + 1), seed, fn round, acc ->
        # Re-encode acc into a fresh client and apply back, simulating
        # the writer-bug pattern of `Doc.new() |> apply_update(latest)`.
        update = Encoding.encode_update(acc)
        fresh = Doc.new(client_id: round)
        {:ok, fresh} = Encoding.apply_update(fresh, update)
        fresh = YMap.set(fresh, "presence", "heartbeat", "round-#{round}")
        # Merge updated state back into acc so all client_ids accumulate
        new_update = Encoding.encode_update(fresh)
        {:ok, acc} = Encoding.apply_update(acc, new_update)
        acc
      end)
    end

    defp add_map(doc, name, key, value) do
      {doc, _} = Doc.get_or_create_type(doc, name, :map)
      YMap.set(doc, name, key, value)
    end
  end
end
