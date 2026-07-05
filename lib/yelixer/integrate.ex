defmodule Yelixer.Integrate do
  @moduledoc """
  YATA insertion: places a single Item at its correct position in a
  parent sequence.

  One decision: given an incoming Item, where does it go in the
  parent's ordered ID list? The answer must be identical on every
  replica regardless of arrival order. YATA guarantees this via a
  deterministic insertion index computed from the Item's `origin`
  and `right_origin` anchors plus client-ID tiebreaks.

  `integrate/3` runs in three stages:

    1. **Anchor splitting.** If `origin` or `right_origin` names a
       clock inside a multi-clock block, split that block first so
       the anchor coincides with a block boundary.
       See "Why split before integrating" below.
    2. **Bracket computation.** Identify the `[start, end)` slice of
       the sequence that lies strictly between `origin` and
       `right_origin`. An empty bracket means unambiguous insertion.
    3. **Conflict resolution.** A non-empty bracket means concurrent
       insertions landed in the same gap; walk them to find the
       YATA-correct slot. See "The two-set conflict-resolution scan"
       below.

  ## What this module is NOT

  Integration is one step in a wider decode pipeline:

    - **Decoding bytes into Items**: `Yelixer.Encoding`. Items are
      fully structured before reaching this module.
    - **Pending-and-retry for missing dependencies**:
      `Yelixer.Encoding.apply_update/2`. When `find_id_index/3`
      returns `nil` because an anchor hasn't arrived yet, this
      module falls back to position 0 or end-of-sequence.
      `apply_update/2` detects that fallback as a dependency gap,
      defers the item, and retries after the batch completes. This
      module is the per-item primitive; the retry loop lives in the
      orchestrator.
    - **Delete-set application**: `apply_update/2`. It walks decoded
      delete-set ranges and calls `mark_deleted/2` here for each
      affected ID; the cumulative `DeleteSet.merge/2` into
      `doc.delete_set` also happens there.
    - **Block storage**: `Yelixer.BlockStore`. This module calls the
      store to split, look up, and insert — it never touches the
      bucket-and-tuple internals directly.

  ## Why split before integrating

  YATA anchors are `(client, clock)` pairs; the sequence is a list
  of block IDs. Before the algorithm can position a new item against
  an anchor, that anchor must coincide with an actual block boundary,
  not land in the interior of a run-length block.

    - **`origin` is the *last* clock of its block.** The new item
      sits *after* it, so origin must be a block's right edge.
      `maybe_split_at_origin/3` splits at `origin.clock + 1` when
      the block extends further.
    - **`right_origin` is the *first* clock of its block.** The new
      item sits *before* it, so right_origin must be a block's left
      edge. `maybe_split_at_right_origin/3` splits at that clock
      when the block starts earlier.

  Both helpers are no-ops when the anchor is `nil`, the block isn't
  found, or the clock already falls on a boundary. After this stage,
  boundaries exist exactly where the new item needs to anchor.

  ## The two-set conflict-resolution scan

  A non-empty bracket means concurrent items were inserted into the
  same gap. The scan walks them left-to-right, tracking where the
  new item's insertion point should be. It is a port of yrs's
  two-set algorithm, maintaining two `MapSet`s:

    - **`items_before_origin`** — every block encountered so far.
    - **`conflicting_items`** — blocks seen since the last
      "advance past" decision; the current pool of active rivals.

  For each `other` block in the bracket:

  **Case 1: `other.origin == item.origin`** — same left anchor,
    canonical YATA tiebreak. Resolved by client ID:

      - `other.id.client < item.id.client` — `other` wins; advance
        the insertion point past it, reset `conflicting_items`.
      - same `right_origin` — `item` wins this cluster; stop.
      - `other.id.client > item.id.client` — `item` will win, but
        later items in the bracket might shift the position; keep
        scanning without advancing.

  **Case 2: `other.origin != item.origin`** — different left anchor.
    Look up `other.origin` in the sequence via `find_origin_seq_id/3`
    and check set membership:

      - `other.origin` ∈ `items_before_origin` ∩ `conflicting_items`
        — active rival; keep scanning.
      - `other.origin` ∈ `items_before_origin` \\ `conflicting_items`
        — already settled; advance past `other`, reset
        `conflicting_items`.
      - `other.origin` ∉ `items_before_origin` — would jump a block
        whose origin hasn't been seen; stop.

  When the scan ends, `left_index` is the YATA-correct insertion
  position — identical on every replica regardless of arrival order.

  ## Other public functions

    - `find_index/3` — same computation as `integrate/3` without
      inserting. For when an item is already in the store and only
      its sequence position is needed (test/diagnostic surface).
    - `mark_deleted/2` — sets an Item's `deleted` flag and refreshes
      the BlockStore tuple cache. Called by `apply_update/2` per
      delete-set range and by local delete operations.
    - `sequence/2` — `BlockStore.get_sequence/2` flattened to
      renderable values: `:string` items yield `[the_string]`,
      `:any` items yield their value list, tombstones yield `[]`.
  """

  alias Yelixer.{ID, Item, BlockStore}

  @doc """
  Inserts `item` into `store` at the YATA-correct position in
  `type_name`'s sequence.

  Splits anchor blocks, computes the insertion index, then calls
  `BlockStore.insert_at/4` to push the item into its client bucket
  and splice its ID into the sequence.

  Returns `{:ok, store}`. Missing anchor lookups fall back to
  position 0 or end-of-sequence; `Yelixer.Encoding.apply_update/2`
  treats those fallbacks as dependency gaps and retries. See moduledoc.
  """
  def integrate(%BlockStore{} = store, %Item{} = item, type_name) do
    store = maybe_split_at_origin(store, item.origin, type_name)
    store = maybe_split_at_right_origin(store, item.right_origin, type_name)
    {store, index} = find_insertion_index(store, item, type_name)

    store = BlockStore.insert_at(store, type_name, index, item)
    {:ok, store}
  end

  @doc """
  Computes the insertion index without inserting. For items already
  in the block store when only their sequence position is needed.

  Any materialization `find_insertion_index/3` performs internally
  (the slow, conflict-resolution path) is local to this call and not
  returned to the caller — matches the pre-CX-w1fw behavior, where
  `maybe_split_at_origin/right_origin`'s splits were computed but
  never persisted either. This function is a test/diagnostic surface;
  it was never meant to mutate the store.
  """
  def find_index(%BlockStore{} = store, %Item{} = item, type_name) do
    store = maybe_split_at_origin(store, item.origin, type_name)
    store = maybe_split_at_right_origin(store, item.right_origin, type_name)
    {_store, index} = find_insertion_index(store, item, type_name)
    index
  end

  # If `origin` falls inside a block (not on its last clock), split
  # at `origin.clock + 1` so the "after origin" boundary exists.
  defp maybe_split_at_origin(store, nil, _type_name), do: store

  defp maybe_split_at_origin(store, %ID{} = origin_id, type_name) do
    case BlockStore.get(store, origin_id) do
      nil ->
        store

      item ->
        last_clock = item.id.clock + item.length - 1

        if origin_id.clock < last_clock do
          split_clock = origin_id.clock + 1
          {store, _} = BlockStore.split_block(store, ID.new(origin_id.client, split_clock), type_name)
          store
        else
          store
        end
    end
  end

  # If `right_origin` isn't a block's first clock, split at that
  # clock so the "before right_origin" boundary exists.
  defp maybe_split_at_right_origin(store, nil, _type_name), do: store

  defp maybe_split_at_right_origin(store, %ID{} = ro_id, type_name) do
    case BlockStore.get(store, ro_id) do
      nil ->
        store

      item ->
        if ro_id.clock > item.id.clock do
          {store, _} = BlockStore.split_block(store, ro_id, type_name)
          store
        else
          store
        end
    end
  end

  @doc """
  Returns live (non-tombstoned) content values of `type_name`'s
  sequence as a flat list.

  `:string` items yield `[the_string]` (whole run-length intact);
  `:any` items yield their value list; tombstones yield `[]` and
  drop out. Other variants yield `[content]`.
  """
  def sequence(%BlockStore{} = store, type_name) do
    store
    |> BlockStore.get_sequence(type_name)
    |> Enum.flat_map(&content_values/1)
  end

  @doc """
  Sets the `deleted` flag on the block at `id` and refreshes the
  tuple cache.

  Only flips the flag — does not rewrite `content`. Content is
  rewritten to `:deleted` (and later `:gc`) once the item is past
  the GC threshold; see `Yelixer.Item` "Tombstones and `:gc`".
  """
  def mark_deleted(%BlockStore{} = store, %ID{} = id) do
    store = BlockStore.materialize_client(store, id.client)
    blocks = Map.get(store.clients, id.client, [])

    case BlockStore.find_block_index(blocks, id.clock) do
      nil ->
        store

      {idx, item} ->
        deleted_item = %{item | deleted: true}

        clients =
          Map.update!(store.clients, id.client, fn blocks ->
            List.replace_at(blocks, idx, deleted_item)
          end)

        %{store | clients: clients}
        |> BlockStore.refresh_tuple_cache(id.client)
    end
  end

  # Computes the insertion index via YATA conflict resolution.
  # Brackets the search to [start, end) — strictly between origin and
  # right_origin — then either returns start (empty bracket) or runs
  # the two-set scan. Returns `{store, index}` — the fast path below
  # never mutates `store`, but the slow path materializes the sequence
  # before scanning it, so both branches must agree on a shape.
  defp find_insertion_index(store, item, type_name) do
    case fast_append_index(store, item, type_name) do
      {:ok, index} ->
        {store, index}

      :slow ->
        # CX-w1fw: this is the O(n) path (linear scan + conflict
        # resolution) — unchanged from before this rewrite, except
        # `seq_ids` is now a materialized view (pending ids folded in)
        # since sequence writes can be deferred. It only runs for a
        # non-empty origin/right_origin bracket: concurrent inserts
        # landing in the same gap, or an item whose origin isn't the
        # sequence's own last element (mid-history insert, replay of
        # merged history, etc). Append-heavy replay never reaches it.
        store = BlockStore.materialize_sequence(store, type_name)
        seq_ids = Map.get(store.sequences, type_name, [])
        seq_len = BlockStore.sequence_length(store, type_name)

        start_index =
          case item.origin do
            nil ->
              0

            origin_id ->
              case find_id_index(seq_ids, store, origin_id) do
                nil -> 0
                idx -> idx + 1
              end
          end

        end_index =
          case item.right_origin do
            nil ->
              seq_len

            ro_id ->
              case find_id_index(seq_ids, store, ro_id) do
                nil -> seq_len
                idx -> idx
              end
          end

        index =
          if start_index >= end_index do
            start_index
          else
            resolve_conflicts(store, item, seq_ids, start_index, end_index)
          end

        {store, index}
    end
  end

  # Fast path for the append-dominant case: `right_origin` is nil (the
  # new item has no upper anchor — it's being placed after `origin`
  # with nothing else constraining it) and `origin` is exactly the
  # sequence's current last block. Then the bracket is empty by
  # construction (`start_index == end_index == seq_len`) and the
  # correct insertion index is `seq_len`, with no scan needed. This is
  # the common case for sequential same-client edits (typing, or
  # replaying a commit chain one small update at a time), where each
  # new item's origin is literally the previous keystroke.
  #
  # Only reads `BlockStore.last_sequence_id/2` and `BlockStore.get/2`,
  # both O(1) in the pending-hit case — no scan, no materialize.
  defp fast_append_index(store, %Item{right_origin: nil, origin: nil}, type_name) do
    # No left anchor either — only unambiguous when the sequence is
    # (still) empty (the very first item). A non-empty sequence with
    # an anchorless item is the ambiguous case the general algorithm
    # (and its conflict-resolution scan) has to resolve.
    if BlockStore.sequence_length(store, type_name) == 0 do
      {:ok, 0}
    else
      :slow
    end
  end

  defp fast_append_index(store, %Item{right_origin: nil, origin: %ID{} = origin_id}, type_name) do
    case BlockStore.last_sequence_id(store, type_name) do
      nil ->
        :slow

      %ID{client: client} = last_id when client == origin_id.client ->
        case BlockStore.get(store, last_id) do
          %Item{id: %ID{clock: c}, length: len} ->
            if origin_id.clock >= c and origin_id.clock < c + len do
              {:ok, BlockStore.sequence_length(store, type_name)}
            else
              :slow
            end

          _ ->
            :slow
        end

      _ ->
        :slow
    end
  end

  defp fast_append_index(_store, _item, _type_name), do: :slow

  # YATA two-set scan — see moduledoc for the conceptual walkthrough.
  # Recursive state:
  #   - index: current scan position
  #   - left_index: candidate insertion point
  #   - items_before_origin: all blocks seen so far
  #   - conflicting_items: rivals since the last "advance past"
  defp resolve_conflicts(store, item, seq_ids, start_index, end_index) do
    do_resolve(store, item, seq_ids, start_index, end_index, start_index,
      MapSet.new(), MapSet.new())
  end

  defp do_resolve(_store, _item, _seq_ids, index, end_index, left_index, _ibo, _ci)
       when index >= end_index do
    left_index
  end

  defp do_resolve(store, item, seq_ids, index, end_index, left_index, items_before_origin, conflicting_items) do
    other_id = Enum.at(seq_ids, index)
    other = BlockStore.get(store, other_id)

    if other == nil do
      left_index
    else
      items_before_origin = MapSet.put(items_before_origin, other_id)
      conflicting_items = MapSet.put(conflicting_items, other_id)

      cond do
        # Case 1: same left anchor — client-ID tiebreak.
        other.origin == item.origin ->
          cond do
            # other has lower client id: it wins; advance past it,
            # reset the rival set.
            other.id.client < item.id.client ->
              do_resolve(store, item, seq_ids, index + 1, end_index, index + 1,
                items_before_origin, MapSet.new())

            # same right anchor: item wins this cluster; stop.
            item.right_origin == other.right_origin ->
              left_index

            # other has higher client id: item will win, but later
            # items may shift the position; keep scanning.
            true ->
              do_resolve(store, item, seq_ids, index + 1, end_index, left_index,
                items_before_origin, conflicting_items)
          end

        # Case 2: different left anchor. Position depends on where
        # `other.origin` falls relative to what we've scanned.
        true ->
          case other.origin do
            nil ->
              left_index

            other_origin ->
              other_origin_seq_id = find_origin_seq_id(seq_ids, store, other_origin)

              cond do
                other_origin_seq_id == nil ->
                  left_index

                MapSet.member?(items_before_origin, other_origin_seq_id) ->
                  if MapSet.member?(conflicting_items, other_origin_seq_id) do
                    # other.origin is an active rival; keep scanning.
                    do_resolve(store, item, seq_ids, index + 1, end_index, left_index,
                      items_before_origin, conflicting_items)
                  else
                    # other.origin already settled; advance past
                    # `other`, reset the rival set.
                    do_resolve(store, item, seq_ids, index + 1, end_index, index + 1,
                      items_before_origin, MapSet.new())
                  end

                true ->
                  # other.origin unseen; stop before jumping it.
                  left_index
              end
          end
      end
    end
  end

  # Returns the sequence ID whose block contains target_id's clock.
  # Used by the two-set scan to locate where an anchor lands.
  defp find_origin_seq_id(seq_ids, store, %ID{} = target_id) do
    Enum.find(seq_ids, fn seq_id ->
      item = BlockStore.get(store, seq_id)
      item != nil and
        item.id.client == target_id.client and
        target_id.clock >= item.id.clock and
        target_id.clock < item.id.clock + item.length
    end)
  end

  # Same containment check, returning the sequence index instead of
  # the ID.
  defp find_id_index(seq_ids, store, %ID{} = target_id) do
    Enum.find_index(seq_ids, fn seq_id ->
      item = BlockStore.get(store, seq_id)

      item != nil and
        item.id.client == target_id.client and
        target_id.clock >= item.id.clock and
        target_id.clock < item.id.clock + item.length
    end)
  end

  defp content_values(%Item{content: {:string, s}}), do: [s]
  defp content_values(%Item{content: {:any, list}}), do: list
  defp content_values(%Item{content: {:deleted, _}}), do: []
  defp content_values(%Item{content: content}), do: [content]
end
