defmodule Yelixer.Types.XMLText do
  @moduledoc """
  Collaborative XML text type built on the YATA CRDT.

  Like YText but within an XML context. Uses the same insertion/deletion
  mechanics as Text, with content stored as {:string, text} items.
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

  # --- Private helpers (same mechanics as Text) ---

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
        offset = index - pos
        split_clock = item.id.clock + offset
        {store, right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)
        left_after_split = BlockStore.get(store, item.id)
        {store, left_after_split, right}
    end
  end

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
        do_collect_ids(store, rest, type_name, index, remaining, item_end, acc)

      pos >= index and item.length <= remaining ->
        do_collect_ids(store, rest, type_name, index, remaining - item.length, item_end, [
          item.id | acc
        ])

      pos >= index ->
        split_clock = item.id.clock + remaining
        {store, _right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)
        {store, Enum.reverse([item.id | acc])}

      true ->
        split_clock = item.id.clock + (index - pos)
        {store, right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)

        if right.length <= remaining do
          new_seq = BlockStore.get_sequence(store, type_name)
          do_collect_ids(store, new_seq, type_name, index, remaining, 0, acc)
        else
          split_end = right.id.clock + remaining
          {store, _} = BlockStore.split_block(store, ID.new(right.id.client, split_end), type_name)
          {store, [right.id]}
        end
    end
  end
end
