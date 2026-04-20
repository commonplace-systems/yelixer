defmodule Yelixer.Doc do
  alias Yelixer.{BlockStore, DeleteSet, Item}
  alias Yelixer.Types.{YMap, Text, Array, XMLFragment, XMLElement, XMLText}

  @type t :: %__MODULE__{
          client_id: non_neg_integer(),
          store: BlockStore.t(),
          delete_set: DeleteSet.t(),
          types: %{String.t() => atom()}
        }

  defstruct [:client_id, :store, :delete_set, :types]

  def new(opts \\ []) do
    client_id = Keyword.get(opts, :client_id, :rand.uniform(1_000_000_000))

    %__MODULE__{
      client_id: client_id,
      store: BlockStore.new(),
      delete_set: DeleteSet.new(),
      types: %{}
    }
  end

  def has_type?(%__MODULE__{types: types}, name), do: Map.has_key?(types, name)

  def get_or_create_type(%__MODULE__{types: types} = doc, name, type_ref) do
    if Map.has_key?(types, name) do
      {doc, Map.get(types, name)}
    else
      doc = %{doc | types: Map.put(types, name, type_ref)}
      {doc, type_ref}
    end
  end

  @doc """
  Garbage collect deleted items, replacing them with lightweight GC blocks.
  Remaps origin/right_origin references through GC blocks to nearest
  non-GC neighbors so ordering is preserved when re-encoding.
  """
  def gc(%__MODULE__{store: store} = doc) do
    clients =
      Map.new(store.clients, fn {client, blocks} ->
        {client, Enum.map(blocks, &gc_item/1)}
      end)

    %{doc | store: %{store | clients: clients, client_tuples: %{}}}
  end

  defp gc_item(%Item{deleted: true, content: {:gc, _}} = item), do: item
  defp gc_item(%Item{deleted: true} = item), do: %{item | content: {:gc, item.length}}
  defp gc_item(item), do: item

  @doc """
  Build a fresh self-contained Yjs binary update encoding the source doc's
  current materialized observable state, with a single client_id in the
  state vector.

  Used by the compaction primitive (CX-u7p): when a long-lived doc has
  accumulated thousands of distinct client_ids in its state vector (e.g.
  presence docs minted a fresh client_id each heartbeat), the resulting
  update payload becomes O(clients) in both size and apply time. This
  helper rebuilds the doc from observable state under one stable
  client_id, so applying the returned update to a fresh `Doc.new()`
  produces equivalent observable content with a state vector of size 1.

  Internally: walks the source doc's registered named top-level types
  and replays the materialized content into a new doc using the public
  type APIs (YMap/Text/Array). The returned binary is a Yjs V1 update;
  applying it on top of a receiver that already has the source doc is
  idempotent in Yjs — so storing it as a chained commit and replicating
  to peers is safe even if some readers have not yet learned to
  short-circuit on snapshot commits.

  Sub-types nested inside maps/arrays (keyed `__sub:CLIENT:CLOCK`) are
  not yet replayed structurally; current callers (presence, schema)
  store only primitive values.
  """
  def snapshot_update(%__MODULE__{} = source) do
    fresh = new(client_id: source.client_id)

    # CX-hzdc: replay in source-clock order, not `source.types` map
    # iteration order. The downstream derivation map pairs source and
    # new items by position, so source ordering must be preserved in
    # the rebuilt doc. Without this, envelope-structure docs (root YMap
    # + named "content") get a DM that pairs `_type` with "content" and
    # causes spurious `:case_b` in late-edit translation.
    types_in_source_order = sort_types_by_earliest_item(source)
    rebuilt = Enum.reduce(types_in_source_order, fresh, &replay_named_type(&1, &2, source))
    bytes = Yelixer.Encoding.encode_update(rebuilt)

    # CX-umz: the derivation map is computed atomically with the
    # snapshot bytes so both commit to the same (source, client_id,
    # iteration order) pair. See also `Commonplace.Store.Snapshotter`
    # which determinizes source.client_id before calling this.
    {bytes, build_derivation_map(source, rebuilt)}
  end

  # Pair each new item id with the source item at the same position in
  # deterministic iteration order (clients desc by id, items asc by
  # clock — matches `Yelixer.Encoding.encode_update/1`). If the rebuilt
  # doc has more items than the source (rare — snapshots consolidate,
  # not split), tail ids reuse the last source id.
  defp build_derivation_map(source, rebuilt) do
    source_ids = collect_item_ids(source)
    new_ids = collect_item_ids(rebuilt)
    pair_ids(new_ids, source_ids)
  end

  defp collect_item_ids(%__MODULE__{store: %BlockStore{clients: clients}}) do
    clients
    |> Enum.sort_by(fn {client, _} -> client end, :desc)
    |> Enum.flat_map(fn {_client, items} ->
      items
      |> Enum.sort_by(fn item -> item.id.clock end)
      |> Enum.map(fn item -> {item.id.client, item.id.clock} end)
    end)
  end

  defp pair_ids([], _source_ids), do: %{}
  defp pair_ids(_new_ids, []), do: %{}

  defp pair_ids(new_ids, source_ids) do
    last = List.last(source_ids)
    source_tuple = List.to_tuple(source_ids)
    source_len = tuple_size(source_tuple)

    new_ids
    |> Enum.with_index()
    |> Map.new(fn {new_id, idx} ->
      src = if idx < source_len, do: elem(source_tuple, idx), else: last
      {new_id, src}
    end)
  end

  # Order top-level named types by the `{client, clock}` of their
  # earliest item in `source`. Types with no direct items (possible
  # when content lives only under sub-types that snapshot_update
  # doesn't structurally replay yet) sort last under a sentinel so
  # they don't perturb clocks for types that do carry items.
  defp sort_types_by_earliest_item(%__MODULE__{types: types} = source) do
    Enum.sort_by(types, fn {name, _ref} -> earliest_id_for_type(source, name) end)
  end

  defp earliest_id_for_type(%__MODULE__{store: %BlockStore{clients: clients}}, name) do
    clients
    |> Enum.flat_map(fn {_client, items} -> items end)
    |> Enum.filter(fn
      %Item{parent: {:named, ^name}} -> true
      _ -> false
    end)
    |> Enum.map(fn %Item{id: id} -> {id.client, id.clock} end)
    |> case do
      [] -> {:no_items, name}
      ids -> Enum.min(ids)
    end
  end

  # Sub-types nested inside maps/arrays (keyed `__sub:CLIENT:CLOCK`) are
  # not yet replayed structurally; current callers (presence, schema)
  # store only primitive values at top-level types.
  defp replay_named_type({"__sub:" <> _ = _name, _ref}, doc, _source), do: doc

  # XML child types are registered under synthetic names
  # (`parent::child::CLIENT:CLOCK`) by their parent's insert_child and
  # replayed recursively when we process the top-level parent — skip
  # them here to avoid double-replay.
  defp replay_named_type({name, ref}, doc, source) do
    cond do
      String.contains?(name, "::child::") -> doc
      # The `::children` sub-sequence belongs to an XML element/fragment;
      # it isn't a named top-level type (Doc.get_or_create_type is never
      # called for it), but guard defensively for decoded updates.
      String.ends_with?(name, "::children") -> doc
      true -> replay_top_level_type(name, ref, source, doc)
    end
  end

  defp replay_top_level_type(name, ref, source, doc) do
    # Updates decoded by `apply_update` do not carry the symbolic type
    # tag — top-level named types come back as `:unknown`. Infer the
    # actual shape from the source's block_store sequence so we can
    # call the right type API to read and replay content.
    effective_ref = if ref == :unknown, do: infer_type_from_sequence(source, name), else: ref

    case effective_ref do
      :text -> replay_text(doc, source, name)
      :map -> replay_map(doc, source, name)
      :array -> replay_array(doc, source, name)
      :xml_fragment -> replay_xml_fragment(doc, source, name, name)
      {:xml_element, tag} -> replay_xml_element(doc, source, name, name, tag)
      :xml_text -> replay_xml_text(doc, source, name, name)
      _ ->
        # Unknown/stub ref types: register the name so the resulting doc
        # carries the type registration, but skip content replay.
        {doc, _} = get_or_create_type(doc, name, effective_ref)
        doc
    end
  end

  defp replay_text(doc, source, name) do
    {doc, _} = get_or_create_type(doc, name, :text)
    text = Text.to_string(source, name)
    if text == "", do: doc, else: Text.insert(doc, name, 0, text)
  end

  defp replay_map(doc, source, name) do
    {doc, _} = get_or_create_type(doc, name, :map)

    YMap.to_map(source, name)
    |> Enum.reduce(doc, fn {key, value}, d -> YMap.set(d, name, key, value) end)
  end

  defp replay_array(doc, source, name) do
    {doc, _} = get_or_create_type(doc, name, :array)
    values = Array.to_list(source, name)
    if values == [], do: doc, else: Array.insert(doc, name, 0, values)
  end

  # XML replay: walk the source's observable structure (tombstones are
  # already dropped by to_list/children) and rebuild it in `doc` under
  # `target_name`. Children in the source carry source-minted child type
  # names (`parent::child::CLIENT:CLOCK`) that won't match after re-
  # insertion in `doc`, so we map each source child to its newly-minted
  # name in the fresh doc before recursing.
  defp replay_xml_fragment(doc, source, source_name, target_name) do
    {doc, _} = get_or_create_type(doc, target_name, :xml_fragment)
    source_children = XMLFragment.to_list(source, source_name)
    replay_xml_children_into_fragment(doc, source, target_name, source_children)
  end

  defp replay_xml_element(doc, source, source_name, target_name, tag) do
    {doc, _} = get_or_create_type(doc, target_name, {:xml_element, tag})
    doc = replay_xml_attributes(doc, source, source_name, target_name)
    source_children = XMLElement.children(source, source_name)
    replay_xml_children_into_element(doc, source, target_name, source_children)
  end

  defp replay_xml_text(doc, source, source_name, target_name) do
    {doc, _} = get_or_create_type(doc, target_name, :xml_text)
    text = XMLText.to_string(source, source_name)
    if text == "", do: doc, else: XMLText.insert(doc, target_name, 0, text)
  end

  defp replay_xml_attributes(doc, source, source_name, target_name) do
    XMLElement.get_attributes(source, source_name)
    |> Enum.reduce(doc, fn {key, value}, d ->
      XMLElement.set_attribute(d, target_name, key, value)
    end)
  end

  defp replay_xml_children_into_fragment(doc, source, target_parent, source_children) do
    source_children
    |> Enum.with_index()
    |> Enum.reduce(doc, fn {source_child, idx}, d ->
      {spec, source_child_name, replay_fn} = xml_child_replay_plan(source_child)
      d = XMLFragment.insert_child(d, target_parent, idx, spec)
      target_children = XMLFragment.to_list(d, target_parent)
      target_child_name = target_child_name_at(target_children, idx)
      replay_fn.(d, source, source_child_name, target_child_name)
    end)
  end

  defp replay_xml_children_into_element(doc, source, target_parent, source_children) do
    source_children
    |> Enum.with_index()
    |> Enum.reduce(doc, fn {source_child, idx}, d ->
      {spec, source_child_name, replay_fn} = xml_child_replay_plan(source_child)
      d = XMLElement.insert_child(d, target_parent, idx, spec)
      target_children = XMLElement.children(d, target_parent)
      target_child_name = target_child_name_at(target_children, idx)
      replay_fn.(d, source, source_child_name, target_child_name)
    end)
  end

  defp xml_child_replay_plan({:element, tag, source_name}) do
    replay_fn = fn d, src, s_name, t_name ->
      replay_xml_element(d, src, s_name, t_name, tag)
    end

    {{:element, tag}, source_name, replay_fn}
  end

  defp xml_child_replay_plan({:text, source_name}) do
    replay_fn = fn d, src, s_name, t_name ->
      replay_xml_text(d, src, s_name, t_name)
    end

    {:text, source_name, replay_fn}
  end

  defp xml_child_replay_plan({:fragment, source_name}) do
    replay_fn = fn d, src, s_name, t_name ->
      replay_xml_fragment(d, src, s_name, t_name)
    end

    {{:fragment}, source_name, replay_fn}
  end

  defp target_child_name_at(target_children, idx) do
    case Enum.at(target_children, idx) do
      {:element, _tag, name} -> name
      {:text, name} -> name
      {:fragment, name} -> name
    end
  end

  # Infer the YType for a top-level named type by inspecting the items
  # in its YATA sequence. Needed because `apply_update` cannot recover
  # the symbolic ref from the wire format for top-level named types —
  # it stores them as `:unknown`.
  #
  # - String content → :text
  # - Items with `parent_sub` → :map (entries keyed by parent_sub)
  # - Items whose content is a nested XML type → :xml_fragment
  # - Otherwise (any content with no parent_sub) → :array
  #
  # Top-level XMLElement / XMLText inference isn't possible from items
  # alone (the tag isn't carried on the wire for top-level elements; a
  # top-level xml_text's items look identical to :text). Callers that
  # need those must pre-register the top-level type on the receiver —
  # same contract as Y.js `ydoc.get(name, Y.XmlElement)`.
  defp infer_type_from_sequence(%__MODULE__{store: store}, name) do
    items = Yelixer.BlockStore.get_sequence(store, name)

    cond do
      Enum.any?(items, &match?(%Item{content: {:string, _}}, &1)) -> :text
      Enum.any?(items, &(&1.parent_sub != nil)) -> :map
      xml_fragment_like?(items) -> :xml_fragment
      items == [] -> :map
      true -> :array
    end
  end

  defp xml_fragment_like?(items) do
    Enum.any?(items, fn
      %Item{content: {:type, {:xml_element, _}}} -> true
      %Item{content: {:type, :xml_text}} -> true
      %Item{content: {:type, :xml_fragment}} -> true
      _ -> false
    end)
  end
end
