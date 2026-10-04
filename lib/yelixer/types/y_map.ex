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
  `parent_sub`. The winner is the **rightmost** Item for the key in
  YATA-canonical order, **whether or not it is tombstoned** — Yjs's
  `type._map.get(key)` (yelixer#11, M2). If the winner is tombstoned the
  key is ABSENT: an earlier undeleted write never resurfaces, and a write
  that integrates with a same-key write to its right is deleted on
  arrival, exactly as Yjs `Item.integrate` does. Because
  `Yelixer.Integrate`'s two-set conflict scan gives every replica the same
  ordering, all replicas pick the same winner.

  `set/4` uses the winner as the new write's `origin` even when the winner
  is tombstoned (Yjs `typeMapSet`, AbstractType.js:847; yelixer#11, M1),
  so the new write lands right of it on every replica. It eagerly
  tombstones a still-live winner (`delete_existing/3`), so the superseded
  write appears in `doc.delete_set` and
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
  `has_key?/3` returns `false` because the key's winner is tombstoned.

  Tombstoned Items stay in the sequence; the read paths use
  `BlockStore.map_winners/2` (tombstones included, then a deleted winner
  dropped) rather than `BlockStore.get_sequence/2`, which filters
  tombstones out before the winner is chosen.

  ## Boundaries

  - Wire format: `Yelixer.Encoding`.
  - YATA placement: `Yelixer.Integrate` (this module sets `origin`/`right_origin`
    to `nil` — keyed entries position themselves by client-ID tiebreak alone).
  - Storage: `Yelixer.BlockStore`.
  - Document container: `Yelixer.Doc`.
  - Sibling facades: `Yelixer.Types.Text`, `Yelixer.Types.Array`.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, Integrate}

  @doc """
  Binds `key` to `value` in `type_name`'s map, overwriting any prior binding.

  Three steps:

    1. Tombstone the key's winner if it is live — see LWW semantics in
       the moduledoc.
    2. Build a new Item: `content: {:any, [value]}`, `parent_sub: key`,
       `origin = <the key's winner id, tombstoned or not>` (nil for a
       first write) — the Yjs map-set convention (`typeMapSet`), so a
       causally-later overwrite from a SMALLER client id still
       integrates RIGHT of the value it replaces and wins the
       rightmost-wins conflict resolution on replay (found via CX-saix:
       outline reparent flaked on random client-id order). yelixer#11
       (M1): the origin is the winner EVEN AFTER a delete; a nil origin
       there let the new write land LEFT of the tombstone on every
       replica, so Yjs read the key as absent forever.
    3. Pass to `Yelixer.Integrate.integrate/3` for YATA placement.
  """
  def set(%Doc{} = doc, type_name, key, value) do
    winner = find_winner(doc.store, type_name, key)
    doc = delete_existing(doc, type_name, key)

    clock = Doc.mint_clock(doc)
    id = ID.new(doc.client_id, clock)
    origin = winner && winner.id
    item = Item.new(id, origin, nil, {:any, [value]}, {:named, type_name}, key)
    {:ok, store} = Integrate.integrate(doc.store, item, type_name)

    # CX-xes3 (E4): `set/4` resolves conflicts itself (delete-then-insert)
    # rather than going through `Yelixer.Encoding`'s post-hoc
    # `maybe_resolve_map_conflict/3` — the only other place
    # `BlockStore.map_index` gets written. Without this, a document
    # built by calling `set/4` directly (the live-editing path, as
    # opposed to replaying an already-encoded update) never populates
    # the index, so `find_current_item/3`'s fast path above always
    # misses and every `set/3`/`get/3`/`delete/3` call pays the full
    # sequence scan — quadratic across N sequential edits to the same
    # key. `item.id` is unambiguously the key's new rightmost write
    # immediately after integration here (its origin was the previous
    # rightmost, and nothing of ours lies beyond it).
    store = BlockStore.put_map_winner_ids(store, type_name, key, [id])
    %{doc | store: store}
  end

  @doc """
  Returns the live value for `key`, or `nil` if absent.

  Finds the rightmost Item in the YATA sequence with `parent_sub == key`
  (tombstoned or not). Returns `nil` for missing keys and for keys whose
  rightmost write is tombstoned, and also
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
  Returns `true` if `key`'s rightmost write is live (not tombstoned).
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
    # YATA sequence order is deterministic across replicas. The
    # rightmost write per key wins even when tombstoned (yelixer#11);
    # a tombstoned winner is an absent key.
    doc.store
    |> BlockStore.map_winners(type_name)
    |> Enum.reduce(%{}, fn
      {_key, %Item{deleted: true}}, acc -> acc
      {key, %Item{content: {:any, [value]}}}, acc -> Map.put(acc, key, value)
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
    # YATA sequence order is deterministic; the rightmost Item per key
    # wins even when tombstoned (yelixer#11), and a tombstoned winner is
    # an absent key.
    find_live_winners(doc.store, type_key)
    |> Map.new(fn %Item{parent_sub: key} = item -> {key, item_value_to_json(doc, item)} end)
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

  # The live winners of `type_key`, one Item per present key. Two paths:
  #
  #   - Fast path: `BlockStore.map_winners/2` over the pre-indexed
  #     sequence for any YMap built locally or integrated via
  #     apply_update — tombstones included, so a tombstoned rightmost
  #     write hides every earlier write to its key (yelixer#11).
  #   - Slow path: when the sequence is empty — e.g. a sub-type YMap
  #     addressed by its `__sub:CLIENT:CLOCK` synthetic name (see
  #     `Yelixer.Doc`'s sub-type section) — scan every client bucket and
  #     filter by parent-ID match. There is no YATA order to consult
  #     here, so this keeps the pre-#11 behaviour: live items only,
  #     client buckets in ascending id order, the last one per key wins.
  defp find_live_winners(store, type_key) do
    winners = BlockStore.map_winners(store, type_key)

    if map_size(winners) > 0 do
      winners |> Map.values() |> Enum.reject(& &1.deleted)
    else
      parent_match = match_parent(type_key)

      # BlockStore.all_items/1 is already sorted by ascending client id.
      store
      |> BlockStore.all_items()
      |> Enum.filter(fn item ->
        parent_match.(item.parent) and not item.deleted and is_binary(item.parent_sub)
      end)
      |> Map.new(&{&1.parent_sub, &1})
      |> Map.values()
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

  # The key's live winner, or nil when the key is absent (never written,
  # or its rightmost write is tombstoned — yelixer#11).
  defp find_current_item(store, type_name, key) do
    case find_winner(store, type_name, key) do
      %Item{deleted: false} = item -> item
      _ -> nil
    end
  end

  # CX-xes3 (E4): a full sequence scan is O(n) in the *whole type's*
  # sequence length — every key sharing this map pays for every other
  # key's history on every `set/3`/`get/3`/`delete/3` call.
  # `BlockStore.map_winner_ids/3` (maintained by `Yelixer.Encoding`'s
  # conflict resolution and by `set/4`) names this exact key's
  # rightmost write in O(log n); use it when known, falling back to the
  # full scan only when the index has no entry (or a pre-#11 `[]`).
  # yelixer#11 (M2): the winner is returned tombstoned or not.
  defp find_winner(store, type_name, key) do
    case BlockStore.map_winner_ids(store, type_name, key) do
      [%ID{} = id] ->
        case BlockStore.get(store, id) do
          %Item{parent_sub: ^key} = item -> item
          _ -> BlockStore.map_winner_scan(store, type_name, key)
        end

      _ ->
        BlockStore.map_winner_scan(store, type_name, key)
    end
  end

  defp delete_existing(doc, type_name, key) do
    case find_current_item(doc.store, type_name, key) do
      nil ->
        doc

      %Item{id: id} = item ->
        store = Integrate.mark_deleted(doc.store, id)
        # The tombstoned item stays the key's winner (yelixer#11): cache
        # it, so `delete/3` followed by `has_key?/3`/`get/3`/`set/4` on
        # the same key stays O(log n) instead of falling back to the
        # full scan.
        store = BlockStore.put_map_winner_ids(store, type_name, key, [id])
        delete_set = DeleteSet.insert(doc.delete_set, id.client, id.clock, item.length)
        %{doc | store: store, delete_set: delete_set}
    end
  end
end
