defmodule Yelixer.DeleteSet do
  @moduledoc """
  Tombstone tracking for a Yjs document.

  ## What problem this solves

  In a CRDT like Yjs, "delete" is not "remove from memory." Every
  insertion gets a stable ID — a `(client, clock)` pair — and that ID
  has to keep meaning forever, even after a delete. Why? Because some
  *other* replica may have inserted a neighbor anchored on the deleted
  item, while disconnected. When the two states finally merge, that
  neighbor's anchor still has to point somewhere; we can't pretend the
  item was never there. The fix is to mark the item as a *tombstone*
  rather than physically remove it. The structural ID-space stays
  intact; the semantics just say "treat this position as empty when
  rendering."

  This module is the index over those tombstones: given a `(client,
  clock)`, is it deleted?

  ## Why intervals (not a flat set of IDs)

  When a user types "abc", Yjs assigns three consecutive items at
  `(client=42, clock=0)`, `(42, 1)`, `(42, 2)` — clocks are per-client
  monotonic counters. When the user later selects and deletes those
  three characters, three contiguous IDs become tombstones at once.

  Real-world edits *cluster*: people delete words, lines, paragraphs;
  rarely do they delete every other character. So the natural storage
  shape is a list of run-length intervals per client, not a flat set
  of point IDs. One delete of three contiguous items costs us one
  `{0, 3}` interval, not three separate point entries.

  Intervals also let `merge/2` compose naturally: when two delete sets
  meet during sync, overlapping intervals collapse into a single
  longer one. The data structure rewards merges, which is exactly
  the CRDT property we want.

  ## Why per-client structure

  Two different clients each have their own clock counter starting at
  zero. So `(client=A, clock=5)` and `(client=B, clock=5)` are
  unrelated IDs that happen to share a number. Bucketing the
  intervals by client (`%{client_id => [ranges]}`) keeps unrelated
  tombstones from being scanned together, and it matches the
  shape of sync-protocol messages, which are themselves per-client.

  ## Interval semantics: half-open

  Throughout this module a range `{start, stop}` means the half-open
  interval `[start, stop)` — clock = start is included, clock = stop
  is not. So `insert(ds, c, 5, 3)` records deletions at clocks
  `5, 6, 7` (length 3, stop = 5 + 3 = 8, inclusive 5..7).

  Half-open is the convention here for a reason: adjacency composes
  cleanly. The intervals `[0, 3)` and `[3, 6)` *touch* at clock 3 with
  no gap and no overlap; merging them gives `[0, 6)` without an
  off-by-one fight. The overlap-or-touch test in `add_range/2` is
  written to permit this.
  """

  # A single range of consecutive deleted clocks for one client.
  # `{start, stop}` denotes the half-open interval [start, stop).
  @type range :: {non_neg_integer(), non_neg_integer()}

  # The whole delete set: each client maps to its own list of disjoint,
  # sorted ranges. Disjoint because `add_range/2` collapses any
  # overlap; sorted because `add_range/2` sorts before returning, and
  # we maintain that invariant on every write path.
  @type t :: %__MODULE__{clients: %{non_neg_integer() => [range()]}}

  defstruct clients: %{}

  @doc """
  An empty delete set: no client has any tombstones recorded.

  Used as the identity element for `merge/2` and as the starting
  point when constructing a delete set from scratch (e.g. when
  decoding a Yjs update or initialising a fresh document).
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Record that `len` consecutive items belonging to `client`, starting
  at `clock`, have been deleted.

  This is the typical write path. A user deletes a 12-character word
  → one `insert(ds, client, start_clock, 12)` call. The interval
  `{clock, clock + len}` then either lands in an empty bucket for
  that client (first deletion) or gets merged into the existing list
  via `add_range/2`, which guarantees the post-state stays disjoint
  and sorted.

  We bucket-and-merge rather than maintain a global sorted structure
  because clients' clock spaces are independent — there is no
  cross-client ordering to maintain.
  """
  @spec insert(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def insert(%__MODULE__{clients: clients}, client, clock, len) do
    # Pull the current list of ranges for this client (default to []
    # if this is the client's first deletion in this set).
    ranges = Map.get(clients, client, [])

    # Fold the new range into the list, preserving the disjoint+sorted
    # invariant. `add_range/2` is where the real interval bookkeeping
    # lives — see its body below.
    ranges = add_range(ranges, {clock, clock + len})

    %__MODULE__{clients: Map.put(clients, client, ranges)}
  end

  @doc """
  Predicate: is the `(client, clock)` pair currently tombstoned?

  This is the read path that the rest of Yjs hits when rendering
  document state. Walking content top-to-bottom, the renderer asks
  "is this item deleted?" once per visited item; if yes, skip
  rendering but keep the structural slot.

  v0 implementation: linear scan of the client's range list, with
  half-open membership test (`>= start and < stop`). Fine when the
  per-client range count is small (typical for human edits, where
  tombstones cluster). A binary search variant would be a one-line
  upgrade for atypical workloads with thousands of disjoint
  tombstone runs per client; not implemented because it has not
  been needed.
  """
  @spec deleted?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def deleted?(%__MODULE__{clients: clients}, client, clock) do
    clients
    |> Map.get(client, [])
    |> Enum.any?(fn {start, stop} -> clock >= start and clock < stop end)
  end

  @doc """
  Combine two delete sets into one whose tombstones are the union of
  both inputs.

  Why this is so short: the structure is a per-client map of
  per-client interval lists, and merging *those* is just two layers
  of natural composition.

  - Outer layer: `Map.merge/3` walks every client present in either
    side. If a client appears only on one side, that list survives
    untouched. If it appears on both, we merge the two lists at the
    inner layer.
  - Inner layer: each range in `ranges2` is folded into `ranges1`
    via `add_range/2`. We could do it the other way around — the
    fold is associative and commutative on the resulting set, since
    set-union is. The choice of direction doesn't change the final
    state; it only changes intermediate allocations during the
    fold.

  Algebraically: `merge` is associative, commutative, and idempotent
  with `new/0` as identity. That makes `(DeleteSet, merge, new)` a
  semilattice. Yjs's whole CRDT discipline rests on this kind of
  property — sync rounds in any order produce the same final state,
  so the protocol can be lossy, reordered, replayed, and still
  converge.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{clients: c1}, %__MODULE__{clients: c2}) do
    merged =
      Map.merge(c1, c2, fn _client, ranges1, ranges2 ->
        Enum.reduce(ranges2, ranges1, fn range, acc -> add_range(acc, range) end)
      end)

    %__MODULE__{clients: merged}
  end

  # ---- Private interval bookkeeping ----

  # `add_range/2` is the heart of this module. Every interval that
  # ever lands in a DeleteSet flows through here, and the disjoint+
  # sorted invariant on `t.clients[c]` is its responsibility alone.
  #
  # The transformation in plain English:
  #
  #   Given a sorted list of disjoint ranges and a new range:
  #     1. Partition the existing list into the ranges that
  #        overlap-or-touch the new range vs the ranges that do not.
  #     2. Replace the entire overlapping group + the new range with
  #        a single combined range whose start is the minimum start
  #        of the group and whose end is the maximum end.
  #     3. Re-attach the non-overlapping survivors and re-sort.
  #
  # Why this is correct: because the input list was already disjoint,
  # every overlapping range overlaps the *new* range — they don't
  # need to overlap each other. So their union (with the new range)
  # is contiguous, and a contiguous union is fully described by the
  # min of starts and the max of ends. No matter how many existing
  # ranges the new one spans, they collapse into one.
  defp add_range(ranges, {new_start, new_end}) do
    # Step 1: split existing ranges into "overlaps the new range"
    # and "doesn't." The predicate `s <= new_end and new_start <= e`
    # is the classic interval-overlap test, lifted into half-open
    # semantics: two intervals `[s, e)` and `[new_start, new_end)`
    # overlap or touch iff each one's start is at-or-before the
    # other's end. The "or touch" matters because half-open intervals
    # `[0, 3)` and `[3, 6)` are adjacent but not overlapping in the
    # strict sense, and we want them to merge into `[0, 6)` rather
    # than stay separate.
    {overlapping, rest} =
      Enum.split_with(ranges, fn {s, e} ->
        s <= new_end and new_start <= e
      end)

    # Step 2: collapse overlapping group + new range into one. The
    # initial accumulator is the new range's own start/end, so if
    # `overlapping` is empty (very common — first delete in a region)
    # we just use the new range as-is. If it's non-empty, fold-min
    # over starts and fold-max over ends gives the bounding interval
    # of the union.
    merged_start = Enum.reduce(overlapping, new_start, fn {s, _}, acc -> min(s, acc) end)
    merged_end = Enum.reduce(overlapping, new_end, fn {_, e}, acc -> max(e, acc) end)

    # Step 3: prepend the merged range to the survivors and re-sort.
    # Sorting is by tuple natural order, so `{start, _}` ascending,
    # which is what we want for the disjoint+sorted invariant. The
    # cost is O(n log n) per insertion; acceptable for typical edit
    # shapes, and a known scaling limit if a single client ever
    # accumulates thousands of disjoint tombstone runs (it's never
    # been hit in practice). Sorting the merged_start one back into
    # place rather than re-sorting the whole list would be the
    # natural optimisation if it ever matters.
    [{merged_start, merged_end} | rest]
    |> Enum.sort()
  end
end
