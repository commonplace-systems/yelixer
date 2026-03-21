defmodule Yelixer.Types.Text do
  @moduledoc """
  Collaborative text type built on the YATA CRDT.

  Inserts multi-character items. When inserting mid-item, the existing
  item is split first. This matches yrs behavior for efficiency.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, Integrate, StateVector}

  @doc "Insert text at a character position."
  def insert(%Doc{} = doc, type_name, index, text) when is_binary(text) and byte_size(text) > 0 do
    {store, origin, right_origin} = find_origins_with_split(doc.store, type_name, index)
    clock = StateVector.get(BlockStore.state_vector(store), doc.client_id)
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, origin, right_origin, {:string, text}, {:named, type_name}, nil)
    {:ok, store} = Integrate.integrate(store, item, type_name)
    %{doc | store: store}
  end

  @doc "Delete `len` characters starting at `index`."
  def delete(%Doc{} = doc, type_name, index, len) when len > 0 do
    {store, ids_to_delete} = find_items_in_range_with_split(doc.store, type_name, index, len)

    {store, delete_set} =
      Enum.reduce(ids_to_delete, {store, doc.delete_set}, fn id, {store, ds} ->
        item = BlockStore.get(store, id)
        store = Integrate.mark_deleted(store, id)
        ds = DeleteSet.insert(ds, id.client, id.clock, item.length)
        {store, ds}
      end)

    %{doc | store: store, delete_set: delete_set}
  end

  @doc "Get the text content as a string."
  def to_string(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.flat_map(fn
      %Item{content: {:string, s}} -> [s]
      _ -> []
    end)
    |> Enum.join()
  end

  @doc "Get the character length of the text."
  def length(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.reduce(0, fn %Item{length: len}, acc -> acc + len end)
  end

  # Find origins, splitting an existing item if inserting mid-item.
  defp find_origins_with_split(store, type_name, index) do
    seq = BlockStore.get_sequence(store, type_name)

    if index == 0 and seq == [] do
      {store, nil, nil}
    else
      {store, left_item, right_item} = find_neighbors_with_split(store, seq, type_name, index)

      origin =
        case left_item do
          nil -> nil
          %Item{id: id, length: len} -> ID.new(id.client, id.clock + len - 1)
        end

      right_origin =
        case right_item do
          nil -> nil
          %Item{id: id} -> id
        end

      {store, origin, right_origin}
    end
  end

  defp find_neighbors_with_split(store, items, type_name, index) do
    do_find_neighbors(store, items, type_name, index, 0, nil)
  end

  defp do_find_neighbors(store, [], _type_name, _index, _pos, left) do
    {store, left, nil}
  end

  defp do_find_neighbors(store, [item | rest], type_name, index, pos, left) do
    item_end = pos + item.length

    cond do
      index <= pos ->
        {store, left, item}

      index >= item_end ->
        do_find_neighbors(store, rest, type_name, index, item_end, item)

      true ->
        # Index falls within this item — split it
        offset = index - pos
        split_clock = item.id.clock + offset
        {store, right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)
        left_after_split = BlockStore.get(store, item.id)
        {store, left_after_split, right}
    end
  end

  # Find item IDs in a character range, splitting at boundaries as needed.
  defp find_items_in_range_with_split(store, type_name, index, len) do
    seq = BlockStore.get_sequence(store, type_name)
    do_collect_ids(store, seq, type_name, index, len, 0, [])
  end

  defp do_collect_ids(store, _, _, _, 0, _, acc), do: {store, Enum.reverse(acc)}
  defp do_collect_ids(store, [], _, _, _, _, acc), do: {store, Enum.reverse(acc)}

  defp do_collect_ids(store, [item | rest], type_name, index, remaining, pos, acc) do
    item_end = pos + item.length

    cond do
      item_end <= index ->
        # Before the range, skip
        do_collect_ids(store, rest, type_name, index, remaining, item_end, acc)

      pos >= index and item.length <= remaining ->
        # Entire item is within range
        do_collect_ids(store, rest, type_name, index, remaining - item.length, item_end, [
          item.id | acc
        ])

      pos >= index ->
        # Item extends beyond range — split at end of deletion range
        split_clock = item.id.clock + remaining
        {store, _right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)
        {store, Enum.reverse([item.id | acc])}

      true ->
        # Partial overlap at start — split at start of range
        split_clock = item.id.clock + (index - pos)
        {store, right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)

        if right.length <= remaining do
          # Take the whole right piece and continue
          new_seq = BlockStore.get_sequence(store, type_name)
          # Re-walk from the split point
          do_collect_ids(store, new_seq, type_name, index, remaining, 0, acc)
        else
          # Need to also split at the end
          split_end = right.id.clock + remaining
          {store, _} = BlockStore.split_block(store, ID.new(right.id.client, split_end), type_name)
          {store, [right.id]}
        end
    end
  end
end
