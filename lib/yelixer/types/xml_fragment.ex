defmodule Yelixer.Types.XMLFragment do
  @moduledoc """
  Collaborative XML fragment type built on the YATA CRDT.

  A fragment is a container for multiple XML nodes without a tag of its own.
  It acts like a document fragment — useful for grouping nodes that don't
  need a wrapper element.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, Integrate, StateVector}

  @doc "Create a new XML fragment."
  def new_fragment(%Doc{} = doc, type_name) do
    {doc, _} = Doc.get_or_create_type(doc, type_name, :xml_fragment)
    doc
  end

  @doc """
  Insert a child node at the given index.

  Child spec can be:
  - `{:element, tag}` — inserts a new XMLElement child
  - `:text` — inserts a new XMLText child
  """
  def insert_child(%Doc{} = doc, type_name, index, child_spec) do
    children_key = children_key(type_name)
    {child_type_ref, doc, child_name} = register_child(doc, type_name, child_spec)

    {origin, right_origin} = find_child_origins(doc.store, children_key, index)
    clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, origin, right_origin, {:type, child_type_ref}, {:named, children_key}, nil)
    {:ok, store} = Integrate.integrate(doc.store, item, children_key)

    doc = %{doc | store: store}
    {doc, _} = Doc.get_or_create_type(doc, child_name, child_type_ref)
    doc
  end

  @doc "Get children as a list of typed tuples."
  def to_list(%Doc{} = doc, type_name) do
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

  @doc "Render the fragment's children as a string (no wrapper tag)."
  def to_string(%Doc{} = doc, type_name) do
    to_list(doc, type_name)
    |> Enum.map(fn
      {:element, _tag, child_name} ->
        Yelixer.Types.XMLElement.to_string(doc, child_name)

      {:text, child_name} ->
        Yelixer.Types.XMLText.to_string(doc, child_name)

      {:fragment, child_name} ->
        __MODULE__.to_string(doc, child_name)
    end)
    |> Enum.join()
  end

  # --- Private helpers ---

  defp children_key(type_name), do: "#{type_name}::children"

  defp child_name_from_id(parent_name, %ID{client: c, clock: k}) do
    "#{parent_name}::child::#{c}:#{k}"
  end

  defp register_child(doc, parent_name, {:element, tag}) do
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
end
