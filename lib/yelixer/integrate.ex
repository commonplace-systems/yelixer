defmodule Yelixer.Integrate do
  @moduledoc """
  YATA insertion: places a single Item at the correct position in a
  parent sequence.

  This module owns one decision: given an Item that has just arrived
  (from `Yelixer.Encoding.apply_update/2`, or from a local mutation),
  where does it go in the parent's ordered list of IDs? "Where" has
  to be the same answer on every replica that ever sees the same
  Item, even if items arrive in different orders. That's what the
  YATA algorithm produces: a deterministic insertion index from the
  Item's `origin` and `right_origin` anchors plus client-ID tiebreaks.

  The algorithm runs in three stages, all visible in `integrate/3`:

    1. **Anchor splitting.** If `origin` or `right_origin` points at
       a clock in the middle of a multi-clock block, split that
       block first so the anchor lines up with a real block boundary.
       See "Why split before integrating" below.
    2. **Bracket the search range.** Compute `[start, end)` in the
       parent's sequence — the slice of the sequence that lies
       strictly between `origin` and `right_origin`. If empty,
       insertion is unambiguous.
    3. **Conflict resolution.** When the bracket isn't empty,
       multiple items have already been inserted in the same gap;
       walk them and pick the YATA-correct slot. See "The two-set
       conflict-resolution scan" below.

  ## What this module is NOT

  Integration is one node in a wider decode pipeline. These pieces
  live elsewhere:

    - **Decoding bytes into Items**: `Yelixer.Encoding`. By the time
      anything in this module sees an Item, the bytes are already
      structured.
    - **Pending-and-retry of items missing dependencies**:
      `Yelixer.Encoding.apply_update/2`. If `find_id_index/3` here
      returns `nil` because the anchor item hasn't been integrated
      yet, this module's behaviour is to *fall back to position 0
      or the end of the sequence*. The orchestrator in
      `apply_update/2` notices the dependency gap, defers the item
      to a pending list, and retries after the rest of the batch
      lands. Two-phase integration is not implemented here; this
      module is the per-item primitive that batch logic builds on.
    - **Delete-set application**: also in `apply_update/2`.
      Tombstones from a decoded delete set are applied by walking
      the delete-set ranges and calling `mark_deleted/2` here for
      each affected ID. The cumulative `DeleteSet.merge/2` into
      `doc.delete_set` happens in the orchestrator, not here.
    - **Block storage**: `Yelixer.BlockStore`. This module asks the
      store to split, look up, and insert — it never reaches into
      the bucket-and-tuple machinery directly.

  ## Why split before integrating

  YATA anchors are referred to by a `(client, clock)` pair, and the
  sequence is a list of block IDs. Anchors must therefore land on
  actual block boundaries, not in the interior of a run-length
  block, before the algorithm can position the new item against them.

    - **`origin` points at the *last* clock of its block.** The new
      item sits *after* origin, so origin needs to be the rightmost
      end of some block. If the existing block extends past that
      clock, split *after* it (`maybe_split_at_origin/3` splits at
      `origin.clock + 1`).
    - **`right_origin` points at the *first* clock of its block.**
      The new item sits *before* right_origin, so right_origin needs
      to be the leftmost start of some block. If the existing block
      starts before that clock, split *at* that clock
      (`maybe_split_at_right_origin/3`).

  Both helpers are no-ops when the anchor is `nil`, when the target
  block isn't found, or when the clock already lines up with a
  boundary. After this stage, the parent's sequence has block
  boundaries exactly where the new item needs to anchor.

  ## The two-set conflict-resolution scan

  When the search bracket `[start, end)` contains more than zero
  items, there are concurrent insertions in the same gap. The
  algorithm walks them, deciding for each whether the new item
  belongs *before* or *after* it. The walk is a port of yrs's two-set
  algorithm; it tracks two `MapSet`s:

    - **`items_before_origin`** — every block scanned so far.
    - **`conflicting_items`** — blocks scanned since the most recent
      "the new item goes after this one" decision (i.e. the
      candidates the new item is *currently* tied with).

  For each `other` block in the bracket, two top-level cases:

  **Case 1: `other.origin == item.origin`.**
    Same left anchor; the canonical YATA tie-break case. Compared
    by client id:

      - `other.id.client < item.id.client` — `other` wins; advance
        the insertion point past it and reset `conflicting_items`.
      - same `right_origin` — `item` wins this slot; stop.
      - `other.id.client > item.id.client` — `item` will win this
        slot, but other items between origins might still nudge the
        position; continue scanning without advancing the
        insertion point.

  **Case 2: `other.origin != item.origin`.**
    Different left anchor. Whether `item` belongs before or after
    `other` depends on where `other.origin` sits relative to what
    we've already scanned. Look up `other.origin`'s sequence position
    via `find_origin_seq_id/3` and check membership in the two sets:

      - `other.origin` ∈ `items_before_origin` ∩ `conflicting_items`
        — origin is one of our active rivals; keep scanning, no
        position change.
      - `other.origin` ∈ `items_before_origin` \\ `conflicting_items`
        — origin was already settled; advance past `other` and
        reset `conflicting_items`.
      - `other.origin` ∉ `items_before_origin` — we'd be jumping a
        block whose origin we haven't seen; stop here.

  When the scan finishes (or breaks early), `left_index` holds the
  YATA-correct insertion position. The same input always yields the
  same `left_index` regardless of arrival order — that's the
  convergence property the rest of the system depends on.

  ## Other public functions

    - `find_index/3` — runs the same lookup as `integrate/3` but
      doesn't actually insert. Used when an item is already in the
      block store but needs its sequence slot computed (rare; mostly
      a test/diagnostic surface).
    - `mark_deleted/2` — flips an Item's `deleted` flag in place and
      refreshes the BlockStore's tuple cache. Called by
      `apply_update/2` once per delete-set range, and by local
      delete operations.
    - `sequence/2` — convenience: `BlockStore.get_sequence/2` plus
      flattening each Item's content into the renderable values.
      Multi-character `:string` items expand to a single-string
      list; `:any` items expand to their value list; tombstones
      expand to `[]`.
  """

  alias Yelixer.{ID, Item, BlockStore}

  @doc """
  Integrates `item` into `store` at the YATA-correct position in
  `type_name`'s sequence.

  Three stages: split blocks at anchor boundaries, compute the
  insertion index, hand off to `BlockStore.insert_at/4` (which both
  pushes the item into its client bucket and inserts the ID into the
  sequence at the chosen position).

  Returns `{:ok, store}`. The function does not currently surface
  failure modes — anchor lookups that miss simply fall back to a
  conservative default (position 0 / end of sequence). The
  orchestrator in `Yelixer.Encoding.apply_update/2` interprets those
  fallbacks as "dependency missing, retry later"; see the moduledoc.
  """
  def integrate(%BlockStore{} = store, %Item{} = item, type_name) do
    store = maybe_split_at_origin(store, item.origin, type_name)
    store = maybe_split_at_right_origin(store, item.right_origin, type_name)
    index = find_insertion_index(store, item, type_name)

    store = BlockStore.insert_at(store, type_name, index, item)
    {:ok, store}
  end

  @doc """
  Computes the insertion index without inserting. Used when an item
  is already in the block store and only its sequence position is
  needed.
  """
  def find_index(%BlockStore{} = store, %Item{} = item, type_name) do
    store = maybe_split_at_origin(store, item.origin, type_name)
    store = maybe_split_at_right_origin(store, item.right_origin, type_name)
    find_insertion_index(store, item, type_name)
  end

  # If `origin` points at a clock strictly inside an existing block
  # (i.e. not the block's last clock), split that block at
  # `origin.clock + 1` so the boundary "after origin" exists. The
  # new item will be inserted at that boundary in the sequence.
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

  # If `right_origin` points at a clock that isn't the first clock of
  # an existing block, split that block *at* the right_origin clock
  # so the boundary "before right_origin" exists.
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
  Returns the live (non-tombstoned) content values of `type_name`'s
  sequence as a flat list.

  String items expand to `[the_string]` (the whole run-length, kept
  intact); `:any` items expand to their member list; tombstones
  produce `[]` and so drop out entirely. Other variants expand to
  `[content]` so callers can pattern-match on the tag.
  """
  def sequence(%BlockStore{} = store, type_name) do
    store
    |> BlockStore.get_sequence(type_name)
    |> Enum.flat_map(&content_values/1)
  end

  @doc """
  Marks the block at `id` as deleted by setting its `deleted` flag
  and refreshing the tuple cache.

  Note this only flips the flag — it does not rewrite `content`.
  Once the item is past the GC threshold, its content variant is
  rewritten to `:deleted` (or eventually `:gc`) elsewhere; see the
  "Tombstones and `:gc`" section in `Yelixer.Item`.
  """
  def mark_deleted(%BlockStore{} = store, %ID{} = id) do
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

  # Find where to insert an item in the sequence using YATA conflict
  # resolution. Brackets the search to [start, end) — strictly between
  # the item's origin and right_origin in sequence-position terms —
  # then either inserts at `start` (no rivals) or runs the two-set
  # scan over the bracket.
  defp find_insertion_index(store, item, type_name) do
    seq_ids = Map.get(store.sequences, type_name, [])

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
          length(seq_ids)

        ro_id ->
          case find_id_index(seq_ids, store, ro_id) do
            nil -> length(seq_ids)
            idx -> idx
          end
      end

    if start_index >= end_index do
      start_index
    else
      resolve_conflicts(store, item, seq_ids, start_index, end_index)
    end
  end

  # YATA two-set algorithm — see "The two-set conflict-resolution
  # scan" in the moduledoc for the conceptual walkthrough. The state
  # carried through the recursion is:
  #
  #   - index: where we are in the sequence scan
  #   - left_index: the candidate insertion point so far
  #   - items_before_origin: everything we've scanned past
  #   - conflicting_items: rivals since the most recent "advance past"
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
            # Other has lower client id; new item belongs after it.
            # Advance the insertion point past `other` and reset the
            # rival set — anything seen so far is now decided.
            other.id.client < item.id.client ->
              do_resolve(store, item, seq_ids, index + 1, end_index, index + 1,
                items_before_origin, MapSet.new())

            # Same right anchor too: new item is the leftmost of the
            # current rival cluster; stop and use the current
            # left_index.
            item.right_origin == other.right_origin ->
              left_index

            # Other has higher client id; new item belongs before it
            # but later items in the bracket might still nudge the
            # position. Keep scanning without advancing.
            true ->
              do_resolve(store, item, seq_ids, index + 1, end_index, left_index,
                items_before_origin, conflicting_items)
          end

        # Case 2: different left anchor. Position depends on where
        # `other.origin` sits relative to what we've scanned.
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
                    # other.origin was already settled; advance past
                    # `other` and reset the rival set.
                    do_resolve(store, item, seq_ids, index + 1, end_index, index + 1,
                      items_before_origin, MapSet.new())
                  end

                true ->
                  # We'd be jumping a block whose origin we haven't
                  # seen; stop here.
                  left_index
              end
          end
      end
    end
  end

  # Returns the sequence ID whose block contains target_id's clock,
  # accounting for run-length blocks. Used by the two-set scan when
  # it needs to know "where in the sequence does this anchor land?"
  defp find_origin_seq_id(seq_ids, store, %ID{} = target_id) do
    Enum.find(seq_ids, fn seq_id ->
      item = BlockStore.get(store, seq_id)
      item != nil and
        item.id.client == target_id.client and
        target_id.clock >= item.id.clock and
        target_id.clock < item.id.clock + item.length
    end)
  end

  # Same containment check, returning the index in the sequence
  # rather than the ID itself.
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
