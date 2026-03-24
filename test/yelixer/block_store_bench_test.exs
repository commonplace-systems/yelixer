defmodule Yelixer.BlockStoreBenchTest do
  use ExUnit.Case, async: true

  alias Yelixer.{ID, Item, BlockStore}

  @moduledoc """
  Performance tests for BlockStore binary search optimization.
  Verifies that get/2 and split_block/3 use O(log n) binary search
  instead of O(n) linear scan.
  """

  defp make_item(client, clock, content \\ {:string, "a"}) do
    Item.new(ID.new(client, clock), nil, nil, content, {:named, "text"}, nil)
  end

  defp build_store(n) do
    Enum.reduce(0..(n - 1), BlockStore.new(), fn i, store ->
      BlockStore.push(store, make_item(1, i))
    end)
  end

  describe "binary search correctness" do
    test "find_block_index returns nil for empty list" do
      assert BlockStore.find_block_index([], 0) == nil
    end

    test "find_block_index finds single block" do
      item = make_item(1, 0, {:string, "hello"})
      {idx, found} = BlockStore.find_block_index([item], 0)
      assert idx == 0
      assert found.id == ID.new(1, 0)
    end

    test "find_block_index finds block by clock within range" do
      item = make_item(1, 0, {:string, "hello"})
      {idx, found} = BlockStore.find_block_index([item], 3)
      assert idx == 0
      assert found.id == ID.new(1, 0)
      assert found.length == 5
    end

    test "find_block_index returns nil for clock beyond range" do
      item = make_item(1, 0, {:string, "hello"})
      assert BlockStore.find_block_index([item], 5) == nil
      assert BlockStore.find_block_index([item], 100) == nil
    end

    test "find_block_index searches multiple blocks correctly" do
      items = [
        make_item(1, 0, {:string, "ab"}),
        make_item(1, 2, {:string, "cd"}),
        make_item(1, 4, {:string, "ef"})
      ]

      # First block
      {idx, found} = BlockStore.find_block_index(items, 0)
      assert idx == 0
      assert found.id.clock == 0

      {idx, found} = BlockStore.find_block_index(items, 1)
      assert idx == 0
      assert found.id.clock == 0

      # Second block
      {idx, found} = BlockStore.find_block_index(items, 2)
      assert idx == 1
      assert found.id.clock == 2

      {idx, found} = BlockStore.find_block_index(items, 3)
      assert idx == 1
      assert found.id.clock == 2

      # Third block
      {idx, found} = BlockStore.find_block_index(items, 4)
      assert idx == 2
      assert found.id.clock == 4

      {idx, found} = BlockStore.find_block_index(items, 5)
      assert idx == 2
      assert found.id.clock == 4

      # Beyond range
      assert BlockStore.find_block_index(items, 6) == nil
    end

    test "find_block_index handles gaps between blocks" do
      # Blocks: [0..1], [5..6], [10..11]
      items = [
        make_item(1, 0, {:string, "ab"}),
        make_item(1, 5, {:string, "ab"}),
        make_item(1, 10, {:string, "ab"})
      ]

      assert BlockStore.find_block_index(items, 3) == nil
      assert BlockStore.find_block_index(items, 7) == nil

      {idx, _} = BlockStore.find_block_index(items, 5)
      assert idx == 1
    end

    test "get/2 works correctly with binary search for large stores" do
      store = build_store(1000)

      # Check various positions
      assert BlockStore.get(store, ID.new(1, 0)).id.clock == 0
      assert BlockStore.get(store, ID.new(1, 500)).id.clock == 500
      assert BlockStore.get(store, ID.new(1, 999)).id.clock == 999
      assert BlockStore.get(store, ID.new(1, 1000)) == nil
      assert BlockStore.get(store, ID.new(2, 0)) == nil
    end

    test "split_block/3 works correctly with binary search index" do
      item = make_item(1, 0, {:string, "hello"})
      store = BlockStore.insert_at(BlockStore.new(), "text", 0, item)

      {store, right} = BlockStore.split_block(store, ID.new(1, 2), "text")

      left = BlockStore.get(store, ID.new(1, 0))
      assert left.content == {:string, "he"}
      assert left.length == 2

      assert right.id == ID.new(1, 2)
      assert right.content == {:string, "llo"}
      assert right.length == 3
    end
  end

  describe "performance" do
    @tag timeout: 30_000
    test "get/2 scales sub-linearly (binary search vs linear scan)" do
      # Build stores of increasing size
      small_n = 100
      large_n = 10_000

      small_store = build_store(small_n)
      large_store = build_store(large_n)

      # Time lookups in the middle of each store
      small_time = time_lookups(small_store, div(small_n, 2), 10_000)
      large_time = time_lookups(large_store, div(large_n, 2), 10_000)

      # With binary search: large_time / small_time should be roughly
      # log(large_n) / log(small_n) ~= 2x
      # With linear scan: it would be large_n / small_n = 100x
      # Accept anything under 10x as evidence of sub-linear scaling
      ratio = large_time / max(small_time, 1)

      assert ratio < 10,
        "Lookup scaling ratio #{Float.round(ratio, 1)}x suggests linear scan. " <>
          "Expected sub-linear (binary search). " <>
          "small=#{small_time}us, large=#{large_time}us"
    end
  end

  defp time_lookups(store, target_clock, iterations) do
    id = ID.new(1, target_clock)

    {time_us, _} =
      :timer.tc(fn ->
        Enum.each(1..iterations, fn _ ->
          BlockStore.get(store, id)
        end)
      end)

    time_us
  end
end
