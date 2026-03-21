defmodule Yelixer.Types.XMLElement do
  @moduledoc """
  Collaborative XML element type built on the YATA CRDT.

  An XML element has:
  - A tag name (e.g., "div", "p", "span")
  - Attributes (key-value pairs, stored as YMap-like entries with parent_sub)
  - Children (ordered sequence of XMLElement, XMLText, or XMLFragment nodes)

  The element's tag name is stored in the doc's types registry.
  Attributes use parent_sub keying (same pattern as YMap).
  Children use the YATA-ordered sequence (same pattern as Array).
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, Integrate, StateVector}

  @doc """
  Create a new XML element with the given tag name.
  Registers the element type in the doc.
  """
  def new_element(%Doc{} = doc, type_name, tag) when is_binary(tag) do
    {doc, _} = Doc.get_or_create_type(doc, type_name, {:xml_element, tag})
    doc
  end

  @doc "Get the tag name of an XML element."
  def tag_name(%Doc{} = doc, type_name) do
    case doc.types[type_name] do
      {:xml_element, tag} -> tag
      _ -> nil
    end
  end

  @doc "Set an attribute on the element."
  def set_attribute(%Doc{} = doc, type_name, key, value) do
    # Mark any existing item for this attribute key as deleted
    doc = delete_existing_attr(doc, type_name, key)

    clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, nil, nil, {:any, [value]}, {:named, type_name}, key)
    store = BlockStore.push(doc.store, item)
    %{doc | store: store}
  end

  @doc "Get the value of an attribute, or nil if not set."
  def get_attribute(%Doc{} = doc, type_name, key) do
    case find_current_attr(doc.store, type_name, key) do
      nil -> nil
      %Item{content: {:any, [value]}} -> value
    end
  end

  @doc "Get all attributes as a map."
  def get_attributes(%Doc{} = doc, type_name) do
    doc.store.clients
    |> Enum.flat_map(fn {_client, items} -> items end)
    |> Enum.filter(fn %Item{parent: parent, parent_sub: sub, deleted: deleted} ->
      parent == {:named, type_name} and sub != nil and not deleted
    end)
    |> Enum.reduce(%{}, fn %Item{parent_sub: key, content: {:any, [value]}}, acc ->
      Map.put(acc, key, value)
    end)
  end

  @doc "Delete an attribute."
  def delete_attribute(%Doc{} = doc, type_name, key) do
    delete_existing_attr(doc, type_name, key)
  end

  @doc """
  Insert a child node at the given index.

  Child spec can be:
  - `{:element, tag}` — inserts a new XMLElement child
  - `:text` — inserts a new XMLText child
  - `{:fragment}` — inserts a new XMLFragment child
  """
  def insert_child(%Doc{} = doc, type_name, index, child_spec) do
    # The children sequence uses a separate key to avoid mixing with attributes
    children_key = children_key(type_name)
    {child_type_ref, doc, child_name} = register_child(doc, type_name, child_spec)

    {origin, right_origin} = find_child_origins(doc.store, children_key, index)
    clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, origin, right_origin, {:type, child_type_ref}, {:named, children_key}, nil)
    {:ok, store} = Integrate.integrate(doc.store, item, children_key)

    # Register the child type with its name keyed to the item's id
    doc = %{doc | store: store}
    {doc, _} = Doc.get_or_create_type(doc, child_name, child_type_ref)
    doc
  end

  @doc "Get children as a list of {type, tag_or_name, child_type_name} tuples."
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

  @doc "Get the number of children."
  def child_count(%Doc{} = doc, type_name) do
    children_key = children_key(type_name)

    doc.store
    |> BlockStore.get_sequence(children_key)
    |> Enum.count()
  end

  @doc "Render the element as an XML/HTML string."
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
    # Pre-allocate the child name based on the next clock
    clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
    child_name = child_name_from_id(parent_name, ID.new(doc.client_id, clock))
    type_ref = {:xml_element, tag}
    {doc, _} = Doc.get_or_create_type(doc, child_name, type_ref)
    {type_ref, doc, child_name}
  end

  defp register_child(doc, parent_name, :text) do
    clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
    child_name = child_name_from_id(parent_name, ID.new(doc.client_id, clock))
    type_ref = :xml_text
    {doc, _} = Doc.get_or_create_type(doc, child_name, type_ref)
    {type_ref, doc, child_name}
  end

  defp register_child(doc, parent_name, {:fragment}) do
    clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
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
    store.clients
    |> Enum.flat_map(fn {_client, items} -> items end)
    |> Enum.filter(fn %Item{parent: parent, parent_sub: sub, deleted: deleted} ->
      parent == {:named, type_name} and sub == key and not deleted
    end)
    |> List.last()
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
