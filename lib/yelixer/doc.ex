defmodule Yelixer.Doc do
  alias Yelixer.{BlockStore, DeleteSet, Item}
  alias Yelixer.Types.{YMap, Text, Array}

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
    rebuilt = Enum.reduce(source.types, fresh, &replay_named_type(&1, &2, source))
    Yelixer.Encoding.encode_update(rebuilt)
  end

  # Sub-types nested inside maps/arrays (keyed `__sub:CLIENT:CLOCK`) are
  # not yet replayed structurally; current callers (presence, schema)
  # store only primitive values at top-level types.
  defp replay_named_type({"__sub:" <> _ = _name, _ref}, doc, _source), do: doc

  defp replay_named_type({name, ref}, doc, source) do
    # Updates decoded by `apply_update` do not carry the symbolic type
    # tag — top-level named types come back as `:unknown`. Infer the
    # actual shape from the source's block_store sequence so we can
    # call the right type API to read and replay content.
    effective_ref = if ref == :unknown, do: infer_type_from_sequence(source, name), else: ref

    case effective_ref do
      :text -> replay_text(doc, source, name)
      :map -> replay_map(doc, source, name)
      :array -> replay_array(doc, source, name)
      _ ->
        # XML and any other ref types: register the name so the resulting
        # doc carries the type registration, but skip content replay.
        # XML support is currently a stub in commonplace; revisit when
        # it lands. Filed under generalizing compaction to non-
        # presence/schema docs.
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

  # Infer the YType (text/map/array) for a top-level named type by
  # inspecting the items in its YATA sequence. This is needed because
  # `apply_update` cannot recover the symbolic ref from the wire format
  # for top-level named types — it stores them as `:unknown`.
  #
  # - String content → text
  # - Items with `parent_sub` → map (entries keyed by parent_sub)
  # - Otherwise (any content with no parent_sub) → array
  defp infer_type_from_sequence(%__MODULE__{store: store}, name) do
    items = Yelixer.BlockStore.get_sequence(store, name)

    cond do
      Enum.any?(items, &match?(%Item{content: {:string, _}}, &1)) -> :text
      Enum.any?(items, &(&1.parent_sub != nil)) -> :map
      items == [] -> :map
      true -> :array
    end
  end
end
