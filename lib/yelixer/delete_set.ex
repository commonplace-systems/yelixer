defmodule Yelixer.DeleteSet do
  @moduledoc """
  Tombstone tracking for a Yjs document.

  ## What problem this solves

  In a CRDT like Yjs, deleting an item does not remove it from memory.
  Every insertion gets a stable ID — a `(client, clock)` pair — and
  that ID must remain meaningful forever, even after the item is
  deleted. The reason: another replica may have inserted a neighbor
  *anchored on* (positioned relative to) the deleted item while
  offline. Concretely: Alice types "X", Bob — disconnected — types "Y"
  immediately after X, recording Y's position as "after the item with
  this ID." Alice deletes X. When the two replicas sync, Bob's "after
  X" anchor still needs something to point at; if X had been wiped
  from memory, Y would have nowhere to land. We solve this by marking
  deleted items as *tombstones* rather than removing them. The ID
  space stays intact; rendering simply skips tombstoned items.

  This module is the index over those tombstones: given a `(client,
  clock)` pair, is it deleted?

  ## Why intervals instead of a flat set of IDs

  Yjs assigns clocks as per-client monotonic counters. When a user
  types "abc", the three characters get IDs `(client=42, clock=0)`,
  `(42, 1)`, `(42, 2)`. Deleting them produces three *consecutive*
  tombstones.

  Real edits cluster: people delete words, lines, paragraphs — rarely
  every other character. So instead of storing individual point IDs,
  we store run-length intervals per client. Deleting three consecutive
  characters costs one `{0, 3}` interval entry, not three separate
  entries.

  Intervals also make `merge/2` efficient: when two delete sets sync,
  overlapping intervals collapse into a single longer one. The
  structure naturally rewards merges, which is the key CRDT property
  we want.

  ## Why per-client structure

  Clock counters are independent per client. `(client=A, clock=5)` and
  `(client=B, clock=5)` are unrelated IDs that share a number.
  Bucketing intervals by client (`%{client_id => [ranges]}`) keeps
  each client's tombstones separate, which also matches the shape of
  Yjs sync messages.

  ## Interval convention: half-open

  A range `{start, stop}` means the half-open interval `[start, stop)`
  — `start` is included, `stop` is not. So `insert(ds, c, 5, 3)`
  records deletions at clocks 5, 6, 7 (stop = 5 + 3 = 8).

  Half-open intervals compose cleanly at boundaries: `[0, 3)` and
  `[3, 6)` touch at clock 3 with no gap and no overlap. Merging them
  gives `[0, 6)` with no off-by-one arithmetic. The
  overlap-or-touch test in `add_range/2` is written to capture this.
  """

  # A single range of consecutive deleted clocks for one client.
  # `{start, stop}` is the half-open interval [start, stop).
  @type range :: {non_neg_integer(), non_neg_integer()}

  # The whole delete set: each client maps to its own sorted,
  # disjoint list of ranges. `add_range/2` enforces this invariant
  # on every write.
  @type t :: %__MODULE__{clients: %{non_neg_integer() => [range()]}}

  defstruct clients: %{}

  @doc """
  Returns an empty delete set with no tombstones recorded.

  This is the identity element for `merge/2` and the starting point
  when constructing a delete set from scratch — for example when
  decoding a Yjs update or initializing a fresh document.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Records that `len` consecutive items belonging to `client`,
  starting at `clock`, have been deleted.

  This is the primary write path. A user deletes a 12-character word
  → one `insert(ds, client, start_clock, 12)` call. The interval
  `{clock, clock + len}` is folded into the client's existing range
  list via `add_range/2`, which keeps the list sorted and disjoint.

  Clients are bucketed separately because their clock spaces are
  independent — there is no cross-client ordering to maintain.
  """
  @spec insert(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def insert(%__MODULE__{clients: clients}, client, clock, len) do
    # Pull the current list of ranges for this client (defaults to []
    # if this client has no tombstones yet).
    ranges = Map.get(clients, client, [])

    # Fold the new range into the list, preserving disjoint+sorted.
    # See `add_range/2` for the interval bookkeeping.
    ranges = add_range(ranges, {clock, clock + len})

    %__MODULE__{clients: Map.put(clients, client, ranges)}
  end

  @doc """
  Returns `true` if the item at `(client, clock)` is tombstoned.

  This is the read path called during document rendering. The renderer
  walks content in order, calls `deleted?` for each item, and skips
  rendering any item that returns `true` (while keeping its structural
  slot in the ID space).

  Implemented as a linear scan of the client's range list using the
  half-open membership test (`clock >= start and clock < stop`). This
  is fast enough for typical human edits, where tombstones cluster
  into a small number of disjoint runs per client. If profiling ever
  surfaces this as a hot path under workloads with many disjoint
  runs per client (large pasted regions deleted in scattered chunks,
  long-lived documents with adversarial edit shapes), a binary
  search over the sorted ranges would be a straightforward upgrade.
  """
  @spec deleted?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def deleted?(%__MODULE__{clients: clients}, client, clock) do
    clients
    |> Map.get(client, [])
    |> Enum.any?(fn {start, stop} -> clock >= start and clock < stop end)
  end

  @doc """
  Combines two delete sets into one whose tombstones are the union of
  both inputs.

  The implementation is two layers of natural composition:

  - **Outer layer** — `Map.merge/3` walks every client present in
    either input. If a client appears in only one input, its range
    list carries over unchanged. If it appears in both, the two lists
    are merged at the inner layer.

  - **Inner layer** — each range from `ranges2` is folded into
    `ranges1` via `add_range/2`, collapsing overlaps as it goes. The
    fold direction (2 into 1) is arbitrary: not just because set union
    is commutative as a *concept*, but because `add_range/2` always
    returns a sorted-disjoint list. So whichever side you start from,
    the per-client representation converges to the same canonical
    list — same intervals, same order. Folding in the opposite
    direction would only reshuffle intermediate allocations during
    the fold, not the result.

  Algebraically, `merge` is associative, commutative, and idempotent,
  with `new/0` as identity. This makes `(DeleteSet, merge, new)` a
  *join-semilattice* — the structure underlying Yjs's convergence
  guarantee. Sync rounds can arrive in any order, be replayed, or be
  duplicated; the result always converges to the same state.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{clients: c1}, %__MODULE__{clients: c2}) do
    merged =
      Map.merge(c1, c2, fn _client, ranges1, ranges2 ->
        # Fold each of `ranges2`'s entries into `ranges1`. Direction
        # is arbitrary — both sides land in the same canonical sorted-
        # disjoint shape via `add_range/2`.
        Enum.reduce(ranges2, ranges1, fn range, acc -> add_range(acc, range) end)
      end)

    %__MODULE__{clients: merged}
  end

  # ---- Private interval bookkeeping ----

  # `add_range/2` is the core of this module. Every interval written
  # to a DeleteSet passes through here, and it is solely responsible
  # for keeping each client's range list sorted and disjoint.
  #
  # Three steps:
  #
  #   1. Partition the existing ranges into those that overlap-or-touch
  #      the new range and those that do not.
  #   2. Collapse the overlapping group and the new range into a single
  #      bounding interval (min of starts, max of ends).
  #   3. Prepend the merged interval to the non-overlapping survivors
  #      and sort.
  #
  # Why step 2 is safe: because the input list was already disjoint,
  # every existing range in the overlapping group overlaps the *new*
  # range — not necessarily each other. But that's enough. Picture
  # the new range as a connector: each existing range that overlaps
  # it shares some clocks with it, and through those shared clocks
  # they're transitively connected to every other range in the group.
  # The union of "new range + everything overlapping new range" is
  # therefore one contiguous span, with no gap inside. A contiguous
  # span is fully described by its minimum start and maximum end —
  # which is what fold-min and fold-max recover.
  defp add_range(ranges, {new_start, new_end}) do
    # Step 1: split into overlapping and non-overlapping ranges.
    #
    # The predicate `s <= new_end and new_start <= e` is the standard
    # interval-overlap test, extended to half-open intervals. Read it
    # as: "neither range ends before the other begins." If either
    # range ended strictly before the other started, there'd be a gap
    # between them and they'd be disjoint; otherwise they overlap or
    # at least touch. Adjacent half-open intervals like `[0, 3)` and
    # `[3, 6)` satisfy this with equality (`3 <= 3`), which is exactly
    # the touch case we want to merge into `[0, 6)`.
    {overlapping, rest} =
      Enum.split_with(ranges, fn {s, e} ->
        s <= new_end and new_start <= e
      end)

    # Step 2: fold the overlapping group into the new range.
    #
    # The accumulator starts at the new range's own bounds. If
    # `overlapping` is empty (first deletion in this region), the
    # result is just the new range. Otherwise, fold-min over starts
    # and fold-max over ends gives the bounding interval of the union.
    merged_start = Enum.reduce(overlapping, new_start, fn {s, _}, acc -> min(s, acc) end)
    merged_end = Enum.reduce(overlapping, new_end, fn {_, e}, acc -> max(e, acc) end)

    # Step 3: prepend the merged interval and sort.
    #
    # Tuple natural order sorts by `{start, _}` ascending, which
    # restores the sorted invariant. Cost is O(n log n) per insertion —
    # acceptable for typical edit patterns. If a single client ever
    # accumulates a very large number of disjoint runs, inserting
    # the merged range at the correct position (instead of re-sorting
    # the whole list) would be the natural optimization.
    [{merged_start, merged_end} | rest]
    |> Enum.sort()
  end
end
