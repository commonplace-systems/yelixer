defmodule Yelixer.Types.YMap do
  @moduledoc """
  Collaborative map type built on the YATA CRDT.

  Map entries use parent_sub to store the key. Each key has at most one
  non-deleted item — setting a key creates a new item and marks the old
  one as deleted (last-write-wins).
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, StateVector, Integrate}

  @doc "Set a key to a value."
  def set(%Doc{} = doc, type_name, key, value) do
    # Mark any existing item for this key as deleted
    doc = delete_existing(doc, type_name, key)

    clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, nil, nil, {:any, [value]}, {:named, type_name}, key)
    # Integrate via YATA so the item is added to both clients and the sequence
    {:ok, store} = Integrate.integrate(doc.store, item, type_name)
    %{doc | store: store}
  end

  @doc "Get the value for a key, or nil if not found."
  def get(%Doc{} = doc, type_name, key) do
    case find_current_item(doc.store, type_name, key) do
      nil -> nil
      %Item{content: {:any, [value]}} -> value
    end
  end

  @doc "Delete a key."
  def delete(%Doc{} = doc, type_name, key) do
    delete_existing(doc, type_name, key)
  end

  @doc "Check if a key exists."
  def has_key?(%Doc{} = doc, type_name, key) do
    find_current_item(doc.store, type_name, key) != nil
  end

  @doc "Get all entries as a map."
  def to_map(%Doc{} = doc, type_name) do
    # Use the YATA sequence for deterministic iteration order.
    # Rightmost non-deleted item per key wins (consistent with yrs).
    BlockStore.get_sequence(doc.store, type_name)
    |> Enum.filter(fn %Item{parent_sub: sub} -> sub != nil end)
    |> Enum.reduce(%{}, fn %Item{parent_sub: key, content: {:any, [value]}}, acc ->
      # Sequence is in YATA order; later items overwrite earlier ones,
      # so the rightmost item for each key wins.
      Map.put(acc, key, value)
    end)
  end

  @doc "Convert map to JSON-compatible map, resolving nested types."
  def to_json(%Doc{} = doc, type_key) do
    # Use the YATA sequence for deterministic iteration order.
    # Rightmost non-deleted item per key wins (consistent with yrs).
    find_all_items_for_type(doc.store, type_key)
    |> Enum.filter(fn %Item{parent_sub: sub} -> sub != nil end)
    |> Enum.reduce(%{}, fn %Item{parent_sub: key} = item, acc ->
      # Sequence order: later items overwrite earlier ones (rightmost wins)
      Map.put(acc, key, item_value_to_json(doc, item))
    end)
  end

  defp item_value_to_json(doc, %Item{content: {:any, values}}) do
    case values do
      [single] -> Yelixer.Types.resolve_content_value(doc, single)
      list -> Enum.map(list, &Yelixer.Types.resolve_content_value(doc, &1))
    end
  end

  defp item_value_to_json(doc, %Item{content: {:type, _ref}, id: id}) do
    Yelixer.Types.sub_type_to_json(doc, id)
  end

  defp item_value_to_json(_doc, %Item{content: {:string, s}}), do: s
  defp item_value_to_json(_doc, %Item{content: {:embed, v}}), do: v
  defp item_value_to_json(_doc, _item), do: nil

  defp find_all_items_for_type(store, type_key) do
    # Check sequence first (for items integrated into the type)
    seq_items = BlockStore.get_sequence(store, type_key)

    if seq_items != [] do
      seq_items
    else
      # Fallback: scan all items for matching parent.
      # Sort by {client, clock} for deterministic order when no sequence exists.
      parent_match = match_parent(type_key)

      store.clients
      |> Enum.sort_by(fn {client, _items} -> client end)
      |> Enum.flat_map(fn {_client, items} -> items end)
      |> Enum.filter(fn item -> parent_match.(item.parent) and not item.deleted end)
    end
  end

  defp match_parent("__sub:" <> _ = key) do
    fn parent ->
      case parent do
        {:id, %Yelixer.ID{client: c, clock: k}} -> "__sub:#{c}:#{k}" == key
        _ -> false
      end
    end
  end

  defp match_parent(name) do
    fn parent -> parent == {:named, name} end
  end

  defp find_current_item(store, type_name, key) do
    # Use the YATA sequence for deterministic order.
    # Rightmost non-deleted item for the given key wins.
    BlockStore.get_sequence(store, type_name)
    |> Enum.filter(fn %Item{parent_sub: sub} -> sub == key end)
    |> List.last()
  end

  defp delete_existing(doc, type_name, key) do
    case find_current_item(doc.store, type_name, key) do
      nil ->
        doc

      %Item{id: id} = item ->
        store = Integrate.mark_deleted(doc.store, id)
        delete_set = DeleteSet.insert(doc.delete_set, id.client, id.clock, item.length)
        %{doc | store: store, delete_set: delete_set}
    end
  end
end
