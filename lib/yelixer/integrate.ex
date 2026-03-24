defmodule Yelixer.Integrate do
  @moduledoc """
  YATA integration algorithm — resolves where new items go in the sequence.

  The algorithm uses origin (left neighbor at creation time) and right_origin
  (right neighbor at creation time) to find the correct insertion position.
  When conflicts exist (multiple items with the same origin), client IDs
  break ties deterministically.
  """

  alias Yelixer.{ID, Item, BlockStore}

  @doc """
  Integrate an item into the block store at the correct position
  determined by the YATA algorithm.
  """
  def integrate(%BlockStore{} = store, %Item{} = item, type_name) do
    # Split items at origin/right_origin boundaries if they point mid-item
    store = maybe_split_at_origin(store, item.origin, type_name)
    store = maybe_split_at_right_origin(store, item.right_origin, type_name)
    index = find_insertion_index(store, item, type_name)

    store = BlockStore.insert_at(store, type_name, index, item)
    {:ok, store}
  end

  @doc """
  Find the insertion index for an item without actually inserting it.
  Used when the item is already in the store but needs to be placed in a sequence.
  """
  def find_index(%BlockStore{} = store, %Item{} = item, type_name) do
    store = maybe_split_at_origin(store, item.origin, type_name)
    store = maybe_split_at_right_origin(store, item.right_origin, type_name)
    find_insertion_index(store, item, type_name)
  end

  # Split an item if origin points into its middle (not at its last clock)
  defp maybe_split_at_origin(store, nil, _type_name), do: store

  defp maybe_split_at_origin(store, %ID{} = origin_id, type_name) do
    case BlockStore.get(store, origin_id) do
      nil ->
        store

      item ->
        last_clock = item.id.clock + item.length - 1

        if origin_id.clock < last_clock do
          # Origin is not at the last char — split after origin
          split_clock = origin_id.clock + 1
          {store, _} = BlockStore.split_block(store, ID.new(origin_id.client, split_clock), type_name)
          store
        else
          store
        end
    end
  end

  # Split an item if right_origin points into its middle (not at its first clock)
  defp maybe_split_at_right_origin(store, nil, _type_name), do: store

  defp maybe_split_at_right_origin(store, %ID{} = ro_id, type_name) do
    case BlockStore.get(store, ro_id) do
      nil ->
        store

      item ->
        if ro_id.clock > item.id.clock do
          # Right_origin is not at the first char — split at right_origin
          {store, _} = BlockStore.split_block(store, ro_id, type_name)
          store
        else
          store
        end
    end
  end

  @doc """
  Get the content values of the sequence for a type, excluding deleted items.
  """
  def sequence(%BlockStore{} = store, type_name) do
    store
    |> BlockStore.get_sequence(type_name)
    |> Enum.flat_map(&content_values/1)
  end

  @doc """
  Mark an item as deleted in the block store.
  """
  def mark_deleted(%BlockStore{} = store, %ID{} = id) do
    blocks = Map.get(store.clients, id.client, [])

    case BlockStore.find_block_index(blocks, id.clock) do
      nil ->
        store

      {idx, item} ->
        deleted_item = %{item | deleted: true}

        clients =
          Map.update!(store.clients, id.client, fn blocks ->
            List.replace_at(blocks, idx, deleted_item)
          end)

        %{store | clients: clients}
        |> BlockStore.refresh_tuple_cache(id.client)
    end
  end

  # Find where to insert an item in the sequence using YATA conflict resolution.
  defp find_insertion_index(store, item, type_name) do
    seq_ids = Map.get(store.sequences, type_name, [])

    # Find position after origin
    start_index =
      case item.origin do
        nil ->
          0

        origin_id ->
          case find_id_index(seq_ids, store, origin_id) do
            nil -> 0
            idx -> idx + 1
          end
      end

    # Find position before right_origin
    end_index =
      case item.right_origin do
        nil ->
          length(seq_ids)

        ro_id ->
          case find_id_index(seq_ids, store, ro_id) do
            nil -> length(seq_ids)
            idx -> idx
          end
      end

    if start_index >= end_index do
      start_index
    else
      resolve_conflicts(store, item, seq_ids, start_index, end_index)
    end
  end

  # YATA conflict resolution using the two-set algorithm from yrs.
  # Scans items between start_index and end_index to find the correct position.
  # Tracks items_before_origin (all scanned items) and conflicting_items
  # (items since last "winner" decision).
  defp resolve_conflicts(store, item, seq_ids, start_index, end_index) do
    do_resolve(store, item, seq_ids, start_index, end_index, start_index,
      MapSet.new(), MapSet.new())
  end

  defp do_resolve(_store, _item, _seq_ids, index, end_index, left_index, _ibo, _ci)
       when index >= end_index do
    left_index
  end

  defp do_resolve(store, item, seq_ids, index, end_index, left_index, items_before_origin, conflicting_items) do
    other_id = Enum.at(seq_ids, index)
    other = BlockStore.get(store, other_id)

    if other == nil do
      left_index
    else
      # Add this item to both sets
      items_before_origin = MapSet.put(items_before_origin, other_id)
      conflicting_items = MapSet.put(conflicting_items, other_id)

      cond do
        # Case 1: Same origin — compare client IDs
        other.origin == item.origin ->
          cond do
            # Other has lower client ID — self goes AFTER other
            other.id.client < item.id.client ->
              # Move left past other, clear conflicting_items
              do_resolve(store, item, seq_ids, index + 1, end_index, index + 1,
                items_before_origin, MapSet.new())

            # Same right_origin — self is to the left of other, break
            item.right_origin == other.right_origin ->
              left_index

            # Other has higher client ID — continue scanning
            true ->
              do_resolve(store, item, seq_ids, index + 1, end_index, left_index,
                items_before_origin, conflicting_items)
          end

        # Case 2: Different origin
        true ->
          case other.origin do
            nil ->
              # Can't find other's origin — break
              left_index

            other_origin ->
              # Find the actual item other.origin points to
              other_origin_seq_id = find_origin_seq_id(seq_ids, store, other_origin)

              cond do
                other_origin_seq_id == nil ->
                  # Can't find other's origin in sequence — break
                  left_index

                MapSet.member?(items_before_origin, other_origin_seq_id) ->
                  if MapSet.member?(conflicting_items, other_origin_seq_id) do
                    # Origin is in conflicting_items — continue scanning
                    do_resolve(store, item, seq_ids, index + 1, end_index, left_index,
                      items_before_origin, conflicting_items)
                  else
                    # Origin is in items_before_origin but NOT in conflicting_items
                    # Move left past other, clear conflicting_items
                    do_resolve(store, item, seq_ids, index + 1, end_index, index + 1,
                      items_before_origin, MapSet.new())
                  end

                true ->
                  # Origin is NOT in items_before_origin — break
                  left_index
              end
          end
      end
    end
  end

  # Find the sequence ID for an origin reference (handles multi-char items)
  defp find_origin_seq_id(seq_ids, store, %ID{} = target_id) do
    Enum.find(seq_ids, fn seq_id ->
      item = BlockStore.get(store, seq_id)
      item != nil and
        item.id.client == target_id.client and
        target_id.clock >= item.id.clock and
        target_id.clock < item.id.clock + item.length
    end)
  end

  # Find the index in the sequence where an ID lives.
  # Handles multi-character items by checking clock ranges.
  defp find_id_index(seq_ids, store, %ID{} = target_id) do
    Enum.find_index(seq_ids, fn seq_id ->
      item = BlockStore.get(store, seq_id)

      item != nil and
        item.id.client == target_id.client and
        target_id.clock >= item.id.clock and
        target_id.clock < item.id.clock + item.length
    end)
  end

  defp content_values(%Item{content: {:string, s}}), do: [s]
  defp content_values(%Item{content: {:any, list}}), do: list
  defp content_values(%Item{content: {:deleted, _}}), do: []
  defp content_values(%Item{content: content}), do: [content]
end
