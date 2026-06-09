defmodule Yelixer.Types.XMLFragment do
  @moduledoc """
  Collaborative XML fragment — tagless container of XML nodes.

  `XMLFragment` is the base of Yelixer's XML family
  (`XMLFragment`, `Yelixer.Types.XMLElement`, `Yelixer.Types.XMLText`):
  an ordered list of children — elements, texts, or nested fragments —
  with no tag of its own. Use it as a document root (which can't bear
  a tag in standard XML) or as a grouping container inside another
  XML node.

  Public surface:

    - `new_fragment/2` — register an empty fragment under `type_name`.
    - `insert_child/4` — splice a new child node at an index.
    - `delete_child/4` — tombstone a contiguous range of children.
    - `to_list/2` — return children as `{kind, ...}` tuples.
    - `child_count/2` — live child count.
    - `to_string/2` — recursively render children as text (no wrapper tag).

  ## XML on top of YATA

  XML in Yelixer is not a separate CRDT — it layers on the same
  `Yelixer.BlockStore` machinery as every other type:

    - **Children** are a positional sequence, like `Yelixer.Types.Array`.
      The fragment owns one YATA sequence under the derived name
      `"<type_name>::children"`; each child is one Item with
      `content: {:type, type_ref}` parented to that sequence. (In
      YATA, type references always live as Items — `{:type, _}` content
      is not specific to XML. `YMap` values that hold sub-types use the
      same shape; the children sequence is one application of the
      pattern.)
    - **Each child sub-type** (`XMLElement`, `XMLText`, or a nested
      `XMLFragment`) is registered in `Yelixer.Doc` under a name
      synthesized from the parent's name and the child Item's id:
      `"<parent>::child::<client>:<clock>"`. This *synthetic name* is
      how the child's Items reach back to their parent: when a peer
      applies an update that creates a child, both the children-sequence
      Item and the child's type registration land in the doc, bound
      together by the `parent::child::C:K` key. (Doc handles one other
      synthetic-naming scheme — see `Yelixer.Doc`'s
      "Sub-types and the `__sub:CLIENT:CLOCK` naming" section.)
    - **Attributes** don't exist at the fragment level; only
      `Yelixer.Types.XMLElement` carries them.

  ## Children are positional, not keyed

  Anchor conventions follow `Yelixer.Types.Array`: `origin` is the
  last clock of the left neighbour, `right_origin` is the first clock
  of the right neighbour. Concurrent inserts at the same index are
  ordered deterministically by `Yelixer.Integrate`'s two-set conflict
  scan with client-ID tiebreak. No `parent_sub` is used.

  ## Tombstones and rendering

  `delete_child/4` collects the IDs in `[index, index + length)`,
  marks each `deleted: true` via `Yelixer.Integrate.mark_deleted/2`,
  and records the interval in `doc.delete_set`.
  `BlockStore.get_sequence/2` filters tombstones on all read paths, so
  `to_list/2`, `child_count/2`, and `to_string/2` never see them.

  `to_string/2` dispatches to the child's own module per kind
  (`XMLElement.to_string`, `XMLText.to_string`, or recursively back to
  itself). No outer tag is emitted.

  ## Synthetic names minted here

    - `"<type_name>::children"` — the named sequence that parents every
      child Item.
    - `"<parent>::child::<client>:<clock>"` — the registered name of
      each child sub-type (trailing `<client>:<clock>` is the child
      Item's id). `Yelixer.Doc.snapshot_update/1` and
      `Yelixer.Encoding.apply_update_in_namespace/3` use this pattern
      to recognise and skip child-type registrations during type
      iteration.

  ## Out of scope

  - Wire format: `Yelixer.Encoding`.
  - YATA placement: `Yelixer.Integrate`.
  - Block storage: `Yelixer.BlockStore`.
  - Document container: `Yelixer.Doc`.
  - Tag-bearing elements: `Yelixer.Types.XMLElement`.
  - Character-stream text nodes: `Yelixer.Types.XMLText`.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, Integrate, StateVector}

  @doc "Register a new, empty XML fragment under `type_name`."
  def new_fragment(%Doc{} = doc, type_name) do
    {doc, _} = Doc.get_or_create_type(doc, type_name, :xml_fragment)
    doc
  end

  @doc """
  Splice a child node into the children sequence at `index`.

  `child_spec`:
  - `{:element, tag}` — new `XMLElement` with the given tag
  - `:text` — new `XMLText` node
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

  @doc "Return live children as `{kind, ...}` tuples (tombstones excluded)."
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

  @doc "Live child count (tombstones excluded)."
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
