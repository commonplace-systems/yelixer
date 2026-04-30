defmodule Yelixer.Types.YMap do
  @moduledoc """
  Collaborative map type — keyed-dictionary facade over a YATA sequence.

  YMap is the user-facing facade for "treat this part of the document
  as a string-keyed map." Callers think in keys and values
  (`set(doc, name, "title", "Hello")`); under the hood, every key
  written becomes an `Yelixer.Item` whose `parent_sub` field carries
  the key string, sharing one underlying sequence with all other
  entries of this map.

  Public surface:

    - `set/4` — bind a key to a value (overwrites any prior binding).
    - `get/3` — read the current value for a key, or `nil`.
    - `delete/3` — remove a key.
    - `has_key?/3` — does the key currently have a live binding?
    - `to_map/2` — render the live entries as an Elixir map.
    - `to_json/2` — same, with nested CRDT sub-types resolved.

  ## How keys are encoded

  YMap doesn't use a separate per-key data structure. Every entry is
  an Item in the same YATA sequence as its sibling keys, identified
  by its `parent_sub` field. So a YMap with three keys "a", "b", "c"
  and one prior write to "a" has *four* Items in the sequence: three
  live ones (the latest write to each key) plus one tombstoned older
  "a" write.

  The advantage of this layout is uniformity: the same machinery
  that powers `Yelixer.Types.Text` and `Yelixer.Types.Array` —
  YATA anchors, run-length blocks, the BlockStore-and-sequence
  duality — works for keyed maps too. The cost is that read paths
  must filter by `parent_sub` to find the entries for a given key.

  ## Last-writer-wins, by sequence position

  Concurrent writes to the same key produce multiple Items in the
  sequence, all with the same `parent_sub`. The "current" value for
  a key is the **rightmost** non-tombstoned Item with that key in
  the YATA-canonical sequence order — `find_current_item/3` uses
  `List.last/1` after filtering.

  Because YATA gives every replica the same sequence order
  (`Yelixer.Integrate`'s two-set conflict scan), every replica
  picks the same winner. Ties on sequence position can't happen
  because two distinct Items always have distinct `(client, clock)`
  IDs.

  `set/4` actively tombstones the prior live binding before
  inserting the new one (`delete_existing/3` in the private
  helpers). This isn't strictly necessary for correctness — the new
  Item would naturally land to the right and become the rightmost
  by `find_current_item/3` — but it keeps the live-set small and
  prevents stale bindings from being resurrected if the new write
  happens to lose a YATA tiebreak somehow. Tombstoning the prior
  write also makes the deletion visible in `doc.delete_set`, which
  is what `Yelixer.Encoding.encode_update/1` ships to peers.

  ## Sub-types as values

  Values are stored as `{:any, [value]}` blocks for primitive types,
  matching `Yelixer.Types.Array`'s convention. Sub-types — a
  `YArray` or another `YMap` nested inside this one — appear in the
  sequence as `{:type, type_ref}` blocks; their internal items live
  elsewhere in the store and reference the parent block's id via
  `parent: {:id, this_block_id}`. `to_json/2` resolves these
  recursively via `Yelixer.Types.sub_type_to_json/2`.

  ## Tombstones and deletion

  `delete/3` is exactly `delete_existing/3` — find the live item
  for the key, set its `deleted: true` flag via
  `Yelixer.Integrate.mark_deleted/2`, and record the
  `(client, clock, length)` interval in `doc.delete_set` via
  `Yelixer.DeleteSet.insert/4`. After deletion, `get/3` returns
  `nil` and `has_key?/3` returns false because the rightmost
  *non-deleted* item for that key is gone.

  Items remain in the sequence after deletion (tombstoned, not
  removed). They get filtered out by `BlockStore.get_sequence/2`,
  which all read paths in this module use.

  ## What this module is NOT

  - Not the wire format: encoding lives in `Yelixer.Encoding`.
  - Not the YATA placement algorithm: that's `Yelixer.Integrate`.
    This module computes (or omits) anchors and hands the new Item
    off.
  - Not the storage: blocks live in `Yelixer.BlockStore`.
  - Not the document container: see `Yelixer.Doc`. This file is one
    of the type-side facades alongside `Yelixer.Types.Text` and
    `Yelixer.Types.Array`.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, StateVector, Integrate}

  @doc """
  Binds `key` to `value` in `type_name`'s map, overwriting any prior
  live binding.

  Three-step pipeline:

    1. Tombstone the existing live item for this key (if any) — see
       the LWW discussion in the moduledoc.
    2. Build a new Item with `content: {:any, [value]}` and
       `parent_sub: key`. Note `origin` and `right_origin` are both
       `nil` — keyed entries don't anchor to specific neighbours;
       they slot into the sequence by client-id tiebreak alone.
    3. Hand off to `Yelixer.Integrate.integrate/3` for placement.
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

  Reads the rightmost non-tombstoned Item in the YATA sequence whose
  `parent_sub == key`. Returns `nil` for missing keys, deleted keys,
  and the rare case where the resolved item carries a non-`:any`
  content variant (a sub-type, embed, etc.) — use `to_json/2` for a
  variant-aware read.
  """
  def get(%Doc{} = doc, type_name, key) do
    case find_current_item(doc.store, type_name, key) do
      nil -> nil
      %Item{content: {:any, [value]}} -> value
    end
  end

  @doc """
  Tombstones the current live binding for `key`. No-op if the key
  is already absent.
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
  Renders the live entries as an Elixir map.

  Walks the YATA sequence and folds via `Map.put/3`, so the
  rightmost (last-writer-wins) item for each key naturally
  overwrites earlier ones. Items without a `parent_sub` (which
  shouldn't appear in a well-formed YMap sequence but might if
  the type was repurposed) are skipped. Only `:any`-content
  values surface — for variant-aware output, use `to_json/2`.
  """
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

  @doc """
  Renders the live entries as a JSON-shaped map, resolving nested
  CRDT sub-types recursively.

  Per-content-variant behaviour mirrors `Yelixer.Types.Array.to_json/2`:
  `:any` values pass through `Yelixer.Types.resolve_content_value/2`;
  `:type` values are resolved via `sub_type_to_json/2`; `:string` and
  `:embed` pass through; other variants produce `nil`.

  Falls back to scanning the whole BlockStore by parent reference
  when the named-type sequence is empty — handles the
  `__sub:CLIENT:CLOCK` synthetic naming scheme used by nested YMaps
  inside sub-types (see `Yelixer.Doc`'s synthetic-name section).
  """
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

  # Collect every item that belongs to `type_key`. Two paths:
  #
  #   - Fast path: `BlockStore.get_sequence/2` returns the sequence
  #     for the named type if one exists. This is the case for any
  #     YMap that was built locally or apply_update-integrated under
  #     this name.
  #   - Slow path: when the sequence is empty (e.g. for a sub-type
  #     YMap reached via the `__sub:CLIENT:CLOCK` synthetic naming
  #     scheme — see `Yelixer.Doc`'s sub-type section), fall back to
  #     scanning every client bucket and filtering by parent ID match.
  #     Sorted by client to keep iteration order deterministic.
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
