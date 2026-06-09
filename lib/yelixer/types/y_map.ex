defmodule Yelixer.Types.YMap do
  @moduledoc """
  Collaborative map type — string-keyed dictionary facade over a YATA sequence.

  Callers think in keys and values (`set(doc, name, "title", "Hello")`).
  Internally, each write becomes an `Yelixer.Item` whose `parent_sub` field
  carries the key string. All entries of the map share one YATA sequence,
  differentiated only by that `parent_sub` label.

  Public surface:

    - `set/4` — bind a key to a value, overwriting any prior binding.
    - `get/3` — read the current value for a key, or `nil`.
    - `delete/3` — remove a key.
    - `has_key?/3` — does the key have a live binding?
    - `to_map/2` — render live entries as an Elixir map.
    - `to_json/2` — same, with nested CRDT sub-types resolved recursively.

  ## Key encoding via `parent_sub`

  YMap uses no separate per-key data structure. Every entry is an Item in
  a single shared YATA sequence; `parent_sub` is the string key that
  distinguishes one entry from another. A YMap with keys "a", "b", "c"
  and one superseded write to "a" holds *four* Items: three live (one per
  key) and one tombstoned (the old "a").

  This mirrors `Yelixer.Types.Text` and `Yelixer.Types.Array` exactly —
  the same YATA anchors, run-length blocks, and BlockStore machinery apply.
  The trade-off: read paths must filter by `parent_sub` to isolate a key,
  rather than scanning a dedicated structure.

  ## Last-writer-wins by sequence position

  Concurrent writes to the same key produce multiple Items with identical
  `parent_sub`. The winner is the **rightmost** non-tombstoned Item in
  YATA-canonical order — `find_current_item/3` takes `List.last/1` after
  filtering. Because `Yelixer.Integrate`'s two-set conflict scan gives every
  replica the same ordering, all replicas pick the same winner.

  `set/4` eagerly tombstones the prior live binding (`delete_existing/3`)
  before inserting the new Item. Correctness doesn't require this — the new
  Item would land rightmost anyway — but it shrinks the live set and ensures
  the superseded write appears in `doc.delete_set`, so
  `Yelixer.Encoding.encode_update/1` propagates the deletion to peers.

  ## Sub-types as values

  Primitive values are stored as `{:any, [value]}` content, matching
  `Yelixer.Types.Array`'s convention. A nested CRDT (a `YArray` or another
  `YMap` embedded as a value) is stored as `{:type, type_ref}`; its own
  Items live elsewhere in the store and point back to the parent block's ID
  via `parent: {:id, this_block_id}`. `to_json/2` resolves these recursively
  via `Yelixer.Types.sub_type_to_json/2`.

  ## Tombstones and deletion

  `delete/3` calls `delete_existing/3`: mark the live Item's `deleted: true`
  via `Yelixer.Integrate.mark_deleted/2`, then record the
  `(client, clock, length)` interval in `doc.delete_set` via
  `Yelixer.DeleteSet.insert/4`. After deletion, `get/3` returns `nil` and
  `has_key?/3` returns `false` because no non-deleted Item remains for
  that key.

  Tombstoned Items stay in the sequence; `BlockStore.get_sequence/2` filters
  them out before returning results to callers.

  ## Boundaries

  - Wire format: `Yelixer.Encoding`.
  - YATA placement: `Yelixer.Integrate` (this module sets `origin`/`right_origin`
    to `nil` — keyed entries position themselves by client-ID tiebreak alone).
  - Storage: `Yelixer.BlockStore`.
  - Document container: `Yelixer.Doc`.
  - Sibling facades: `Yelixer.Types.Text`, `Yelixer.Types.Array`.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, StateVector, Integrate}

  @doc """
  Binds `key` to `value` in `type_name`'s map, overwriting any prior binding.

  Three steps:

    1. Tombstone the existing live Item for this key (if any) — see LWW
       semantics in the moduledoc.
    2. Build a new Item: `content: {:any, [value]}`, `parent_sub: key`,
       `origin` and `right_origin` both `nil` (keyed entries anchor by
       client-ID tiebreak, not to specific neighbours).
    3. Pass to `Yelixer.Integrate.integrate/3` for YATA placement.
  """
  def set(%Doc{} = doc, type_name, key, value) do
    doc = delete_existing(doc, type_name, key)

    clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, nil, nil, {:any, [value]}, {:named, type_name}, key)
    {:ok, store} = Integrate.integrate(doc.store, item, type_name)
    %{doc | store: store}
  end

  @doc """
  Returns the live value for `key`, or `nil` if absent.

  Finds the rightmost non-tombstoned Item in the YATA sequence with
  `parent_sub == key`. Returns `nil` for missing or deleted keys, and also
  for Items whose content variant is not `:any` (sub-types, embeds, etc.) —
  use `to_json/2` for a variant-aware read.
  """
  def get(%Doc{} = doc, type_name, key) do
    case find_current_item(doc.store, type_name, key) do
      nil -> nil
      %Item{content: {:any, [value]}} -> value
    end
  end

  @doc """
  Tombstones the live binding for `key`. No-op if the key is already absent.
  """
  def delete(%Doc{} = doc, type_name, key) do
    delete_existing(doc, type_name, key)
  end

  @doc """
  Returns `true` if `key` has a live (non-tombstoned) binding.
  """
  def has_key?(%Doc{} = doc, type_name, key) do
    find_current_item(doc.store, type_name, key) != nil
  end

  @doc """
  Renders live entries as an Elixir map.

  Folds the YATA sequence with `Map.put/3`; later Items overwrite earlier
  ones, so the rightmost entry per key (LWW winner) is the final value.
  Items with no `parent_sub` are skipped (unexpected in a well-formed YMap,
  but harmless). Only `:any`-content values surface; use `to_json/2` for
  variant-aware output that resolves sub-types.
  """
  def to_map(%Doc{} = doc, type_name) do
    # YATA sequence order is deterministic across replicas.
    # Later (rightmost) Items overwrite earlier ones, giving LWW per key.
    BlockStore.get_sequence(doc.store, type_name)
    |> Enum.filter(fn %Item{parent_sub: sub} -> sub != nil end)
    |> Enum.reduce(%{}, fn %Item{parent_sub: key, content: {:any, [value]}}, acc ->
      Map.put(acc, key, value)
    end)
  end

  @doc """
  Renders live entries as a JSON-shaped map, resolving nested CRDT sub-types
  recursively.

  Content-variant handling mirrors `Yelixer.Types.Array.to_json/2`:
  `:any` → `Yelixer.Types.resolve_content_value/2`;
  `:type` (a nested sub-type) → `sub_type_to_json/2`;
  `:string` and `:embed` pass through;
  all other variants produce `nil`.

  When the named-type sequence is empty, falls back to a full BlockStore scan
  filtered by parent reference. This handles `__sub:CLIENT:CLOCK` synthetic
  names — the naming scheme `Yelixer.Doc` assigns to YMaps nested inside
  sub-types (see `Yelixer.Doc`'s synthetic-name section).
  """
  def to_json(%Doc{} = doc, type_key) do
    # YATA sequence order is deterministic; rightmost Item per key wins (LWW).
    find_all_items_for_type(doc.store, type_key)
    |> Enum.filter(fn %Item{parent_sub: sub} -> sub != nil end)
    |> Enum.reduce(%{}, fn %Item{parent_sub: key} = item, acc ->
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

  # Collect all Items belonging to `type_key`. Two paths:
  #
  #   - Fast path: `BlockStore.get_sequence/2` returns the pre-indexed
  #     sequence for any YMap built locally or integrated via apply_update.
  #   - Slow path: when the sequence is empty — e.g. a sub-type YMap
  #     addressed by its `__sub:CLIENT:CLOCK` synthetic name (see
  #     `Yelixer.Doc`'s sub-type section) — scan every client bucket and
  #     filter by parent-ID match. Client buckets are sorted for determinism.
  defp find_all_items_for_type(store, type_key) do
    seq_items = BlockStore.get_sequence(store, type_key)

    if seq_items != [] do
      seq_items
    else
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
    # YATA sequence order is deterministic; rightmost non-deleted Item wins.
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
