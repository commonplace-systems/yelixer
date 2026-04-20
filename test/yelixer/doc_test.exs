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
