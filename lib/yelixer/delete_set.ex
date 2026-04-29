defmodule Yelixer.DeleteSet do
  @moduledoc """
  Tombstone tracking for a Yjs document.

  ## Why deleted items are kept in memory

  Every insertion in a Yjs document gets a stable, permanent ID — a
  `(client, clock)` pair. That ID must remain meaningful even after the
  item is deleted, because another replica may have positioned content
  relative to it while offline.

  Concrete example: Alice types "X" (ID `(A, 5)`). Bob, disconnected,
  types "Y" immediately after X, recording Y's position as "after `(A, 5)`."
  Alice deletes X. When the replicas sync, Bob's anchor still needs
  something to point at. If X had been erased entirely, Y would have
  nowhere to land.

  The solution is to mark deleted items as *tombstones* — they stay in
  the ID space but are invisible to the renderer. This module is the index
  over those tombstones: given a `(client, clock)` pair, is it deleted?

  ## Why intervals rather than a flat set of IDs

  Yjs clocks are per-client monotonic counters. Typing "abc" produces IDs
  `(client=42, clock=0)`, `(42, 1)`, `(42, 2)`. A consecutive delete
  produces three consecutive tombstones.

  Real edits cluster — words, lines, paragraphs — so runs of consecutive
  tombstones are the common case. Storing run-length intervals instead of
  individual IDs compresses these naturally: deleting "abc" costs one
  `{0, 3}` entry rather than three point entries.

  Intervals also make `merge/2` cheap: when two delete sets sync,
  overlapping intervals collapse into one. The representation gets more
  compact as replicas converge — exactly the behavior a CRDT needs.

  ## Why tombstones are bucketed by client

  Clock counters are independent per client: `(client=A, clock=5)` and
  `(client=B, clock=5)` are unrelated IDs that happen to share a number.
  The structure is `%{client_id => [ranges]}` — each client owns its own
  sorted interval list. This also matches the wire shape of Yjs sync
  messages, so encoding and decoding are straightforward.

  ## Interval convention: half-open `[start, stop)`

  A tuple `{start, stop}` represents the half-open interval `[start, stop)`:
  `start` is included, `stop` is not. So `insert(ds, c, 5, 3)` covers
  clocks 5, 6, 7 — `stop = 5 + 3 = 8`.

  Half-open intervals compose cleanly at boundaries: `[0, 3)` and `[3, 6)`
  meet at clock 3 with no gap and no overlap, merging to `[0, 6)` with no
  off-by-one adjustment needed. The overlap-or-touch predicate in
  `add_range/2` is designed around this property.
  """

  # A single half-open interval `[start, stop)` of consecutive deleted
  # clocks for one client. See "Interval convention" in the moduledoc.
  @type range :: {non_neg_integer(), non_neg_integer()}

  # The delete set: a map from client ID to that client's sorted,
  # disjoint list of ranges. `add_range/2` enforces the sorted-disjoint
  # invariant on every write.
  @type t :: %__MODULE__{clients: %{non_neg_integer() => [range()]}}

  defstruct clients: %{}

  @doc """
  Returns an empty delete set with no tombstones.

  This is the identity element for `merge/2`. Use it as the starting
  point when decoding a Yjs update or initializing a fresh document.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Records that `len` consecutive items from `client`, starting at `clock`,
  have been deleted.

  This is the primary write path. A single call covers an entire run —
  deleting a 12-character word is one `insert(ds, client, start_clock, 12)`.
  The interval `{clock, clock + len}` is folded into the client's existing
  range list via `add_range/2`, which maintains the sorted-disjoint
  invariant.

  Each client's ranges are maintained independently because clock spaces
  do not overlap across clients.
  """
  @spec insert(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def insert(%__MODULE__{clients: clients}, client, clock, len) do
    # Fetch the current range list; default to [] for a new client.
    ranges = Map.get(clients, client, [])

    # Fold the new interval in, restoring sorted-disjoint. See `add_range/2`.
    ranges = add_range(ranges, {clock, clock + len})

    %__MODULE__{clients: Map.put(clients, client, ranges)}
  end

  @doc """
  Returns `true` if the item at `(client, clock)` is tombstoned.

  Called by the renderer for each item: items returning `true` are skipped
  in the visible output but their IDs remain intact in the document
  structure.

  Implemented as a linear scan using the half-open membership test
  (`clock >= start and clock < stop`). For typical human edits — where
  tombstones cluster into a small number of disjoint runs — this is fast
  enough. A binary search over the sorted range list is the natural
  upgrade if profiling ever identifies this as a bottleneck on documents
  with many scattered deletions.
  """
  @spec deleted?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def deleted?(%__MODULE__{clients: clients}, client, clock) do
    clients
    |> Map.get(client, [])
    |> Enum.any?(fn {start, stop} -> clock >= start and clock < stop end)
  end

  @doc """
  Returns a delete set whose tombstones are the union of both inputs.

  The merge is two layers of composition:

  - **Outer layer** — `Map.merge/3` visits every client present in either
    input. Clients that appear in only one side carry over unchanged.
    Clients present in both are resolved by the inner layer.

  - **Inner layer** — each range from `ranges2` is folded into `ranges1`
    via `add_range/2`, collapsing overlaps as it goes. The direction (2
    into 1) is arbitrary not because of an abstract appeal to set-union
    commutativity, but because of a concrete mechanism: `add_range/2`
    ends by sorting the list. Whichever fold direction you pick,
    intermediate states differ but the final list passes through that
    same sort step at every insertion, and so both directions land in
    the same canonical sorted-disjoint shape.

  `merge` is associative, commutative, idempotent, and has `new/0` as its
  identity. These four properties mean delete sets can be exchanged in any
  order, replayed, or duplicated without diverging — the convergence
  guarantee Yjs requires.

  Idempotence is the easiest one to see in action: `merge(A, A) = A`.
  Why? Every range in A is already in A's sorted-disjoint list. When
  `merge` folds A's ranges into A again, each range hits `add_range/2`
  and gets compared against ranges already there. The overlap test
  finds itself (a range fully contains itself, so `s <= new_end` and
  `new_start <= e` both hold trivially), the fold-min and fold-max
  take min/max with self → unchanged, and the result is the same
  range in the same place. No growth, no duplicates, no change.
  Associativity and commutativity follow from the same canonical-form
  argument as the inner layer above; identity is the empty-map
  property of `Map.merge/3`.

  (Formally, `(DeleteSet, merge, new)` is a *join-semilattice*; the
  four properties are what that label means in practice.)
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{clients: c1}, %__MODULE__{clients: c2}) do
    merged =
      Map.merge(c1, c2, fn _client, ranges1, ranges2 ->
        # Fold ranges2 into ranges1, one interval at a time. Direction
        # is arbitrary because `add_range/2` ends with a sort — both
        # fold directions therefore produce the same canonical
        # sorted-disjoint list.
        Enum.reduce(ranges2, ranges1, fn range, acc -> add_range(acc, range) end)
      end)

    %__MODULE__{clients: merged}
  end

  # ---- Private interval bookkeeping ----

  # `add_range/2` is the single write primitive. Every interval — whether
  # from `insert/4` or `merge/2` — passes through here. It is solely
  # responsible for keeping the range list sorted and disjoint.
  #
  # Three steps:
  #
  #   1. Partition the existing ranges into those that overlap-or-touch
  #      the new range and those that do not.
  #   2. Collapse the overlapping group and the new range into one
  #      bounding interval: min of all starts, max of all ends.
  #   3. Prepend the merged interval to the non-overlapping survivors
  #      and sort.
  #
  # Why step 2 produces a single contiguous span: the existing list is
  # already disjoint, so every range in the overlapping group touches
  # the *new* range specifically — not necessarily each other. The new
  # range is the connector: it shares clocks with each member of the
  # group, transitively linking them all. Because each member overlaps
  # the connector, there is no internal gap among them. A gap-free span
  # is fully described by its minimum start and maximum end, which is
  # what the two folds compute.
  #
  # Worked example.
  #
  # Two existing ranges in the list, disjoint from each other:
  #
  #   existing A:           [1, 3)
  #   existing B:                   [5, 7)
  #
  # A new range arrives and spans the gap:
  #
  #   new:                    [2,    6)
  #
  # ASCII view of the clock axis (each cell is one clock):
  #
  #     clock:  0  1  2  3  4  5  6  7
  #     A:         AA AA
  #     B:                        BB BB
  #     new:          NN NN NN NN
  #
  # The new range shares clocks with A (clock 2 falls in both A's
  # `[1, 3)` and new's `[2, 6)`) and shares clocks with B (clock 5
  # falls in both B's `[5, 7)` and new's `[2, 6)`). Both A and B go
  # into the overlapping group with the new range. Their bounds:
  #
  #   starts of group: A.start = 1, new.start = 2, B.start = 5
  #   ends of group:   A.end   = 3, new.end   = 6, B.end   = 7
  #
  # Step 2 takes `min(1, 2, 5) = 1` and `max(3, 6, 7) = 7`, producing
  # the merged interval `[1, 7)`. The non-overlapping survivors (none,
  # in this example) get prepended in step 3 and the list is re-sorted.
  defp add_range(ranges, {new_start, new_end}) do
    # Step 1: separate ranges that overlap-or-touch the new interval
    # from those that don't.
    #
    # Two half-open intervals `[s, e)` and `[new_start, new_end)` overlap
    # or touch when `s <= new_end AND new_start <= e`. Both conjuncts are
    # load-bearing — each one rules out a different way the existing
    # range could sit clear of the new range. Walk the four cases for
    # an existing `[s, e)` against new `[2, 6)`:
    #
    #   case A — existing entirely to the left, e.g. `[0, 1)`:
    #     `s = 0 <= 6` ✓  but  `new_start = 2 <= e = 1` ✗  → disjoint.
    #     The second conjunct is what catches this; the first alone
    #     would have classified it as overlapping.
    #
    #   case B — existing entirely to the right, e.g. `[7, 9)`:
    #     `s = 7 <= 6` ✗  → disjoint.
    #     The first conjunct catches this; the second alone would have
    #     said yes (`2 <= 9`).
    #
    #   case C — genuine overlap, e.g. `[3, 5)`:
    #     `s = 3 <= 6` ✓  and  `new_start = 2 <= e = 5` ✓ → overlap.
    #     Both conjuncts hold, as expected.
    #
    #   case D — adjacent, e.g. `[6, 8)`:
    #     `s = 6 <= 6` ✓  and  `new_start = 2 <= e = 8` ✓ → touch.
    #     Using `<=` (not `<`) is what makes case D pass: equality at
    #     the boundary is allowed. Without it, adjacent half-open
    #     intervals like `[0, 3)` and `[3, 6)` would stay separate
    #     instead of merging into `[0, 6)`.
    #
    # In short: each `<=` rules out one direction of "clearly outside,"
    # and equality at the boundary is the touch case we actively want.
    {overlapping, rest} =
      Enum.split_with(ranges, fn {s, e} ->
        s <= new_end and new_start <= e
      end)

    # Step 2: compute the bounding interval of the overlapping group plus
    # the new range. The accumulator seeds at the new range's own bounds,
    # so an empty overlapping group returns the new range unchanged.
    merged_start = Enum.reduce(overlapping, new_start, fn {s, _}, acc -> min(s, acc) end)
    merged_end = Enum.reduce(overlapping, new_end, fn {_, e}, acc -> max(e, acc) end)

    # Step 3: insert the merged interval and re-sort.
    #
    # Tuple natural order sorts `{start, _}` ascending, restoring the
    # sorted invariant. O(n log n) per insertion — fine for typical edit
    # patterns. Inserting at the correct position rather than re-sorting
    # would be the upgrade if a client ever accumulates many disjoint runs.
    [{merged_start, merged_end} | rest]
    |> Enum.sort()
  end
end
