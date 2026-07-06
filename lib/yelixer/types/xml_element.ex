defmodule Yelixer.Types.XMLElement do
  @moduledoc """
  Collaborative XML element — tag-bearing node with attributes and children.

  `XMLElement` adds two things to `Yelixer.Types.XMLFragment`:

    - **A tag name** ("div", "p", "span", …) encoded as the element's
      *type ref* in `Yelixer.Doc`: `{:xml_element, tag}` instead of
      `:xml_fragment`. The tag lives on the type registration, not on
      any Item.
    - **Attributes** — unordered string→value pairs stored as Items
      keyed by `parent_sub` (the attribute name). They use the same
      `parent_sub` encoding as `Yelixer.Types.YMap`; see `YMap` for
      the full mechanics (rightmost-wins LWW, tombstone semantics on
      overwrite, sub-type values). Attribute Items are parented
      directly to the element's named sequence.

  Children use the same `"<type_name>::children"` derived sequence as
  `XMLFragment` — separate from attribute Items, so the two don't
  interleave in the YATA ordering.

  Public surface:

    - `new_element/3` — register an element under `type_name` with its tag.
    - `tag_name/2` — read the tag from the type registry.
    - `set_attribute/4`, `get_attribute/3`, `get_attributes/2`,
      `delete_attribute/3` — attribute CRUD.
    - `insert_child/4`, `delete_child/4`, `children/2`, `child_count/2`
      — child-sequence ops (same shape as `XMLFragment`).
    - `to_string/2` — recursive render: `<tag attrs>children</tag>`.

  ## Layering references

  This module doesn't restate concepts covered in:

    - `Yelixer.Types.XMLFragment` — children-sequence shape, synthetic
      child names (`"<parent>::child::<C>:<K>"`), XML-on-YATA layering.
    - `Yelixer.Types.YMap` — `parent_sub` key encoding that attributes
      share.
    - `Yelixer.Item`, `Yelixer.BlockStore`, `Yelixer.Integrate` —
      YATA mechanics and storage.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, Integrate}

  @doc "Register a new XML element under `type_name` with the given tag."
  def new_element(%Doc{} = doc, type_name, tag) when is_binary(tag) do
    {doc, _} = Doc.get_or_create_type(doc, type_name, {:xml_element, tag})
    doc
  end

  @doc "Read the element's tag from the type registry."
  def tag_name(%Doc{} = doc, type_name) do
    case doc.types[type_name] do
      {:xml_element, tag} -> tag
      _ -> nil
    end
  end

  @doc """
  Set an attribute, replacing any existing value for `key`.

  The replacement item carries `origin = <the overwritten item's id>`
  (the Yjs map-set convention): on replay, YATA places it RIGHT of the
  value it replaces regardless of client ids, so the rightmost-wins map
  conflict resolution keeps the causally-later write. With a nil origin
  a smaller-client overwrite integrates LEFT of the old item and is
  auto-deleted as a phantom concurrent loser (found via CX-saix —
  outline reparent flaked on random client-id order).
  """
  def set_attribute(%Doc{} = doc, type_name, key, value) do
    existing = find_current_attr(doc.store, type_name, key)
    doc = delete_existing_attr(doc, type_name, key)

    clock = Doc.mint_clock(doc)
    id = ID.new(doc.client_id, clock)
    origin = existing && existing.id
    item = Item.new(id, origin, nil, {:any, [value]}, {:named, type_name}, key)
    {:ok, store} = Integrate.integrate(doc.store, item, type_name)
    %{doc | store: store}
  end

  @doc "Get the current value of `key`, or `nil` if absent."
  def get_attribute(%Doc{} = doc, type_name, key) do
    case find_current_attr(doc.store, type_name, key) do
      nil -> nil
      %Item{content: {:any, [value]}} -> value
    end
  end

  @doc "Return all live attributes as a `%{key => value}` map."
  def get_attributes(%Doc{} = doc, type_name) do
    BlockStore.all_items(doc.store)
    |> Enum.filter(fn %Item{parent: parent, parent_sub: sub, deleted: deleted} ->
      parent == {:named, type_name} and sub != nil and not deleted
    end)
    |> Enum.reduce(%{}, fn %Item{parent_sub: key, content: {:any, [value]}}, acc ->
      Map.put(acc, key, value)
    end)
  end

  @doc "Tombstone the current Item for `key` (no-op if absent)."
  def delete_attribute(%Doc{} = doc, type_name, key) do
    delete_existing_attr(doc, type_name, key)
  end

  @doc """
  Splice a child node into the children sequence at `index`.

  `child_spec`:
  - `{:element, tag}` — new `XMLElement` with the given tag
  - `:text` — new `XMLText` node
  - `{:fragment}` — new `XMLFragment` node
  """
  def insert_child(%Doc{} = doc, type_name, index, child_spec) do
    children_key = children_key(type_name)
    {child_type_ref, doc, child_name} = register_child(doc, type_name, child_spec)

    {origin, right_origin} = find_child_origins(doc.store, children_key, index)
    clock = Doc.mint_clock(doc)
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, origin, right_origin, {:type, child_type_ref}, {:named, children_key}, nil)
    {:ok, store} = Integrate.integrate(doc.store, item, children_key)

    doc = %{doc | store: store}
    {doc, _} = Doc.get_or_create_type(doc, child_name, child_type_ref)
    doc
  end

  @doc """
  Delete `length` consecutive children starting at `index`.

  Children are tombstoned in the CRDT (never physically removed). The
  `children/2`, `child_count/2`, and `to_string/2` helpers skip tombstoned
  items, so the observable shape matches a plain array deletion.
  """
  def delete_child(%Doc{} = doc, type_name, index, length \\ 1) when length > 0 do
    children_key = children_key(type_name)
    items = find_child_items_in_range(doc.store, children_key, index, length)

    {store, delete_set} =
      Enum.reduce(items, {doc.store, doc.delete_set}, fn id, {store, ds} ->
        item = BlockStore.get(store, id)
        store = Integrate.mark_deleted(store, id)
        ds = DeleteSet.insert(ds, id.client, id.clock, item.length)
        {store, ds}
      end)

    %{doc | store: store, delete_set: delete_set}
  end

  @doc "Return live children as `{kind, tag_or_name, child_type_name}` tuples."
  def children(%Doc{} = doc, type_name) do
    children_key = children_key(type_name)

    doc.store
    |> BlockStore.get_sequence(children_key)
    |> Enum.map(fn %Item{content: {:type, type_ref}, id: id} ->
      child_name = child_name_from_id(type_name, id)

      case type_ref do
        {:xml_element, tag} -> {:element, tag, child_name}
        :xml_text -> {:text, child_name}
        :xml_fragment -> {:fragment, child_name}
      end
    end)
  end

  @doc "Live child count (tombstones excluded)."
  def child_count(%Doc{} = doc, type_name) do
    children_key = children_key(type_name)

    doc.store
    |> BlockStore.get_sequence(children_key)
    |> Enum.count()
  end

  @doc "Render the element as `<tag attrs>children</tag>`."
  def to_string(%Doc{} = doc, type_name) do
    tag = tag_name(doc, type_name)
    attrs = get_attributes(doc, type_name)

    attr_str =
      attrs
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> ~s( #{k}="#{v}") end)
      |> Enum.join()

    child_str =
      children(doc, type_name)
      |> Enum.map(fn
        {:element, _tag, child_name} ->
          __MODULE__.to_string(doc, child_name)

        {:text, child_name} ->
          Yelixer.Types.XMLText.to_string(doc, child_name)

        {:fragment, child_name} ->
          Yelixer.Types.XMLFragment.to_string(doc, child_name)
      end)
      |> Enum.join()

    "<#{tag}#{attr_str}>#{child_str}</#{tag}>"
  end

  # --- Private helpers ---

  defp children_key(type_name), do: "#{type_name}::children"

  defp child_name_from_id(parent_name, %ID{client: c, clock: k}) do
    "#{parent_name}::child::#{c}:#{k}"
  end

  defp register_child(doc, parent_name, {:element, tag}) do
    clock = Doc.mint_clock(doc)
    child_name = child_name_from_id(parent_name, ID.new(doc.client_id, clock))
    type_ref = {:xml_element, tag}
    {doc, _} = Doc.get_or_create_type(doc, child_name, type_ref)
    {type_ref, doc, child_name}
  end

  defp register_child(doc, parent_name, :text) do
    clock = Doc.mint_clock(doc)
    child_name = child_name_from_id(parent_name, ID.new(doc.client_id, clock))
    type_ref = :xml_text
    {doc, _} = Doc.get_or_create_type(doc, child_name, type_ref)
    {type_ref, doc, child_name}
  end

  defp register_child(doc, parent_name, {:fragment}) do
    clock = Doc.mint_clock(doc)
    child_name = child_name_from_id(parent_name, ID.new(doc.client_id, clock))
    type_ref = :xml_fragment
    {doc, _} = Doc.get_or_create_type(doc, child_name, type_ref)
    {type_ref, doc, child_name}
  end

  defp find_child_origins(store, children_key, index) do
    seq = BlockStore.get_sequence(store, children_key)

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

  defp find_current_attr(store, type_name, key) do
    BlockStore.all_items(store)
    |> Enum.filter(fn %Item{parent: parent, parent_sub: sub, deleted: deleted} ->
      parent == {:named, type_name} and sub == key and not deleted
    end)
    |> List.last()
  end

  defp find_child_items_in_range(store, children_key, index, len) do
    seq = BlockStore.get_sequence(store, children_key)
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

  defp delete_existing_attr(doc, type_name, key) do
    case find_current_attr(doc.store, type_name, key) do
      nil ->
        doc

      %Item{id: id} = item ->
        store = Integrate.mark_deleted(doc.store, id)
        delete_set = DeleteSet.insert(doc.delete_set, id.client, id.clock, item.length)
        %{doc | store: store, delete_set: delete_set}
    end
  end
end
