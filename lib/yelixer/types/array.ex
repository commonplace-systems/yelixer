defmodule Yelixer.Types.Array do
  @moduledoc """
  Collaborative array type built on the YATA CRDT.
  Each element is stored as a separate Item with {:any, [value]} content.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, Integrate, StateVector}

  @doc "Insert elements at an index."
  def insert(%Doc{} = doc, type_name, index, values) when is_list(values) do
    Enum.with_index(values)
    |> Enum.reduce(doc, fn {value, i}, doc ->
      {origin, right_origin} = find_origins(doc.store, type_name, index + i)
      clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
      id = ID.new(doc.client_id, clock)
      item = Item.new(id, origin, right_origin, {:any, [value]}, {:named, type_name}, nil)
      {:ok, store} = Integrate.integrate(doc.store, item, type_name)
      %{doc | store: store}
    end)
  end

  @doc "Push elements to the end of the array."
  def push(%Doc{} = doc, type_name, values) do
    current_len = length(doc, type_name)
    insert(doc, type_name, current_len, values)
  end

  @doc "Delete `len` elements starting at `index`."
  def delete(%Doc{} = doc, type_name, index, len) when len > 0 do
    items = find_items_in_range(doc.store, type_name, index, len)

    {store, delete_set} =
      Enum.reduce(items, {doc.store, doc.delete_set}, fn id, {store, ds} ->
        item = BlockStore.get(store, id)
        store = Integrate.mark_deleted(store, id)
        ds = DeleteSet.insert(ds, id.client, id.clock, item.length)
        {store, ds}
      end)

    %{doc | store: store, delete_set: delete_set}
  end

  @doc "Get all elements as a list."
  def to_list(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.flat_map(fn %Item{content: {:any, values}} -> values end)
  end

  @doc "Convert array to JSON-compatible list, resolving nested types."
  def to_json(%Doc{} = doc, type_key) do
    doc.store
    |> BlockStore.get_sequence(type_key)
    |> Enum.flat_map(&item_to_json_values(doc, &1))
  end

  defp item_to_json_values(doc, %Item{content: {:any, values}}) do
    Enum.map(values, &Yelixer.Types.resolve_content_value(doc, &1))
  end

  defp item_to_json_values(doc, %Item{content: {:type, _ref}, id: id}) do
    [Yelixer.Types.sub_type_to_json(doc, id)]
  end

  defp item_to_json_values(doc, %Item{content: {:string, s}}) do
    [Yelixer.Types.resolve_content_value(doc, s)]
  end

  defp item_to_json_values(_doc, %Item{content: {:embed, v}}), do: [v]
  defp item_to_json_values(_doc, %Item{content: {:json, values}}), do: values
  defp item_to_json_values(_doc, _item), do: []

  @doc "Get the number of elements."
  def length(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.reduce(0, fn %Item{length: len}, acc -> acc + len end)
  end

  defp find_origins(store, type_name, index) do
    seq = BlockStore.get_sequence(store, type_name)

    if index == 0 and seq == [] do
      {nil, nil}
    else
      {left_item, right_item} = find_neighbors(seq, index, 0, nil)

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

      {origin, right_origin}
    end
  end

  defp find_neighbors([], _index, _pos, left), do: {left, nil}

  defp find_neighbors([item | rest], index, pos, left) do
    item_end = pos + item.length

    if index <= pos do
      {left, item}
    else
      if index >= item_end do
        find_neighbors(rest, index, item_end, item)
      else
        {item, List.first(rest)}
      end
    end
  end

  defp find_items_in_range(store, type_name, index, len) do
    seq = BlockStore.get_sequence(store, type_name)
    collect_ids(seq, index, len, 0, [])
  end

  defp collect_ids(_, _, 0, _, acc), do: Enum.reverse(acc)
  defp collect_ids([], _, _, _, acc), do: Enum.reverse(acc)

  defp collect_ids([item | rest], index, remaining, pos, acc) do
    item_end = pos + item.length

    cond do
      item_end <= index ->
        collect_ids(rest, index, remaining, item_end, acc)

      pos >= index ->
        to_take = min(item.length, remaining)
        collect_ids(rest, index, remaining - to_take, item_end, [item.id | acc])

      true ->
        to_take = min(item_end - index, remaining)
        collect_ids(rest, index, remaining - to_take, item_end, [item.id | acc])
    end
  end
end
