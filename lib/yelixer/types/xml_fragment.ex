defmodule Yelixer.Types.XMLFragment do
  @moduledoc """
  Collaborative XML fragment type — tagless container of XML nodes.

  An `XMLFragment` is the simplest member of Yelixer's XML family
  (`XMLFragment`, `Yelixer.Types.XMLElement`, `Yelixer.Types.XMLText`).
  It groups an ordered list of children — elements, texts, or nested
  fragments — without having a tag of its own. Use it as the
  document root when you don't want a wrapping element, or as a
  passive grouping container inside another XML node.

  Public surface:

    - `new_fragment/2` — register an empty fragment under `type_name`.
    - `insert_child/4` — splice a new child node at an index.
    - `delete_child/4` — tombstone a contiguous range of children.
    - `to_list/2` — render children as `{kind, ...}` tuples.
    - `child_count/2` — live child count.
    - `to_string/2` — recursively render the fragment as text (no
      wrapper tag).

  ## XML on top of YATA

  XML in Yelixer is not a separate CRDT — it's a layering on the
  same `Yelixer.BlockStore` machinery that powers the rest of the
  type system:

    - **Children** are an ordered sequence, exactly like
      `Yelixer.Types.Array`. The fragment owns one YATA sequence
      under a derived name (`"<type_name>::children"`); each child
      is one Item with `content: {:type, type_ref}` parented at
      that named sequence.
    - **Each child sub-type** (an `XMLElement`, `XMLText`, or nested
      `XMLFragment`) is itself a registered type in `Yelixer.Doc`.
      Its name is synthesized from the parent fragment's name plus
      the child item's id: `"<parent>::child::<client>:<clock>"`.
      This is one of two synthetic-naming schemes Doc handles —
      see `Yelixer.Doc`'s "Sub-types and the `__sub:CLIENT:CLOCK`
      naming" section for the other.
    - **Attributes** don't apply at the fragment level; only
      `XMLElement` carries them.

  The synthetic names are how a child sub-type's items reach back
  to their parent. When a peer applies an update that creates an
  XML child, both the parent's children-sequence Item and the
  child's own type registration land in the doc; the
  `parent::child::C:K` name binds them.

  ## Children are by-position, not by-key

  Anchor conventions follow `Yelixer.Types.Array`: `origin` is the
  last clock of the left neighbour, `right_origin` is the first
  clock of the right neighbour. Concurrent inserts at the same
  child index are ordered deterministically by
  `Yelixer.Integrate`'s two-set conflict scan plus client-ID
  tiebreak. No `parent_sub` is used — children are positional,
  not keyed.

  ## Tombstones and rendering

  `delete_child/4` follows the standard tombstone pattern: collect
  the IDs in `[index, index + length)`, mark each `deleted: true`
  via `Yelixer.Integrate.mark_deleted/2`, and record the interval
  in `doc.delete_set`. `BlockStore.get_sequence/2` filters
  tombstones from all read paths, so `to_list/2`, `child_count/2`,
  and `to_string/2` never see them.

  `to_string/2` recursively dispatches to the appropriate type
  module per child kind (`XMLElement.to_string`, `XMLText.to_string`,
  or back to itself). The result is the live serialized text — no
  outer tag because fragments don't have one.

  ## Naming conventions, summarized

  Two synthetic names are minted by this module:

    - `"<type_name>::children"` — the named sequence holding the
      children Items (parent reference of every child Item).
    - `"<parent>::child::<client>:<clock>"` — the registered name
      of each child sub-type. The trailing `<client>:<clock>` is
      the child Item's id; this is how `Yelixer.Doc.snapshot_update/1`
      and `Yelixer.Encoding.apply_update_in_namespace/3` recognize
      and skip child-type registrations during type iteration.

  ## What this module is NOT

  - Not the wire format: encoding lives in `Yelixer.Encoding`.
  - Not the YATA placement algorithm: that's `Yelixer.Integrate`.
  - Not the storage: blocks live in `Yelixer.BlockStore`.
  - Not the document container: see `Yelixer.Doc`.
  - Not for tag-bearing elements: see `Yelixer.Types.XMLElement`.
  - Not for character-stream text: see `Yelixer.Types.XMLText` (the
    XML-context analogue of `Yelixer.Types.Text`).
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, Integrate, StateVector}

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

  @doc """
  Delete `length` consecutive children starting at `index`.

  Children are tombstoned in the CRDT (never physically removed). The
  `to_list/2`, `child_count/2`, and `to_string/2` helpers skip tombstoned
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
end
