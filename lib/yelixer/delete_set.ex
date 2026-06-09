defmodule Yelixer.DeleteSet do
  @moduledoc """
  Tombstone tracking for a Yjs document.

  ## Why deleted items are kept in memory

  Every insertion in a Yjs document gets a stable, permanent ID — a
  `(client, clock)` pair. That ID must stay meaningful even after the item
  is deleted, because another replica may have positioned content relative
  to it while offline.

  Concrete example: Alice types "X" (ID `(A, 5)`). Bob, offline, types "Y"
  immediately after X, recording Y's position as "after `(A, 5)`." Alice
  deletes X. When the replicas sync, Bob's anchor still needs something to
  point at. Erasing X entirely would leave Y with no landing spot.

  The solution is to mark deleted items as *tombstones* — they stay in the
  ID space but are hidden from the renderer. This module is the index over
  those tombstones: given a `(client, clock)` pair, is it deleted?

  ## Why intervals rather than a flat set of IDs

  Yjs clocks are per-client monotonic counters. Typing "abc" produces IDs
  `(client=42, clock=0)`, `(42, 1)`, `(42, 2)`, so deleting those three
  characters produces three consecutive tombstones.

  Real edits cluster — words, lines, paragraphs — making runs of consecutive
  tombstones the common case. Storing run-length intervals compresses these
  naturally: deleting "abc" costs one `{0, 3}` entry rather than three point
  entries.

  Intervals also make `merge/2` cheap: when two delete sets sync, overlapping
  intervals collapse into one. The representation grows more compact as
  replicas converge — exactly the behavior a CRDT needs.

  ## Why tombstones are bucketed by client

  Clock counters are independent per client: `(client=A, clock=5)` and
  `(client=B, clock=5)` are unrelated IDs that happen to share a number.
  The structure is `%{client_id => [ranges]}` — each client owns its own
  sorted interval list. This shape also matches the Yjs sync-message wire
  format, so encoding and decoding are straightforward.

  ## Interval convention: half-open `[start, stop)`

  A tuple `{start, stop}` represents the half-open interval `[start, stop)`:
  `start` is included, `stop` is not. So `insert(ds, c, 5, 3)` covers
  clocks 5, 6, 7 — `stop = 5 + 3 = 8`.

  Half-open intervals compose cleanly at boundaries: `[0, 3)` and `[3, 6)`
  share clock 3 as the boundary with no gap and no overlap, merging to
  `[0, 6)` with no off-by-one adjustment. The overlap-or-touch predicate
  in `add_range/2` is designed around this property.
  """

  # One half-open interval `[start, stop)` of consecutive deleted clocks
  # for a single client. See "Interval convention" in the moduledoc.
  @type range :: {non_neg_integer(), non_neg_integer()}

  # The delete set: a map from client ID to that client's sorted, disjoint
  # list of ranges. `add_range/2` enforces the sorted-disjoint invariant on
  # every write.
  @type t :: %__MODULE__{clients: %{non_neg_integer() => [range()]}}

  defstruct clients: %{}

  @doc """
  Returns an empty delete set — no tombstones, no clients.

  This is the identity element for `merge/2`. Use it as the starting point
  when decoding a Yjs update or initializing a fresh document.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Records that `len` consecutive items from `client`, starting at `clock`,
  have been deleted.

  This is the primary write path. One call covers an entire run — deleting
  a 12-character word is one `insert(ds, client, start_clock, 12)`. The
  interval `{clock, clock + len}` is folded into the client's existing range
  list via `add_range/2`, which maintains the sorted-disjoint invariant.
  """
  @spec insert(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def insert(%__MODULE__{clients: clients}, client, clock, len) do
    # Fetch the existing range list; new clients start from [].
    ranges = Map.get(clients, client, [])

    # Fold the new interval in, restoring the sorted-disjoint invariant.
    ranges = add_range(ranges, {clock, clock + len})

    %__MODULE__{clients: Map.put(clients, client, ranges)}
  end

  @doc """
  Returns `true` if the item at `(client, clock)` is tombstoned.

  Called by the renderer for each item: items returning `true` are skipped
  in the visible output, but their IDs remain intact in the document
  structure.

  Implemented as a linear scan with the half-open membership test
  (`clock >= start and clock < stop`). For typical human edits — tombstones
  clustered into a small number of disjoint runs — this is fast enough.
  Binary search over the sorted range list is the natural upgrade if
  profiling ever shows this as a bottleneck on documents with many scattered
  deletions.
  """
  @spec deleted?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def deleted?(%__MODULE__{clients: clients}, client, clock) do
    clients
    |> Map.get(client, [])
    |> Enum.any?(fn {start, stop} -> clock >= start and clock < stop end)
  end

  @doc """
  Returns a delete set whose tombstones are the union of both inputs.

  The merge operates in two layers:

  - **Outer layer** — `Map.merge/3` visits every client present in either
    input. Clients appearing in only one input carry over unchanged. Clients
    present in both are resolved by the inner layer.

  - **Inner layer** — each range from `ranges2` is folded into `ranges1`
    via `add_range/2`, collapsing overlaps as it goes. The fold direction
    (2 into 1) is arbitrary: `add_range/2` sorts after every insertion, so
    both directions pass through the same sort step and land in the same
    canonical sorted-disjoint shape.

  `merge` is associative, commutative, idempotent, and has `new/0` as its
  identity. These four properties together mean delete sets can be exchanged
  in any order, replayed, or duplicated without diverging — the convergence
  guarantee Yjs requires.

  Idempotence is the most concrete to verify: `merge(A, A) = A`. Every range
  in A is already in A's sorted-disjoint list. When `merge` folds A's ranges
  into A again, each range reaches `add_range/2` and is compared against its
  own copy already in the list. The overlap test finds it (a range trivially
  contains itself, so `s <= new_end` and `new_start <= e` both hold), and
  `min`/`max` with self leaves the bounds unchanged. No growth, no
  duplicates. Associativity and commutativity follow from the same
  canonical-form argument as the inner layer; identity is the empty-map
  property of `Map.merge/3`.

  (Formally, `(DeleteSet, merge, new)` is a *join-semilattice*. The four
  properties are what that label means in practice.)
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{clients: c1}, %__MODULE__{clients: c2}) do
    merged =
      Map.merge(c1, c2, fn _client, ranges1, ranges2 ->
        # Direction irrelevant: add_range/2 sorts at each step.
        Enum.reduce(ranges2, ranges1, fn range, acc -> add_range(acc, range) end)
      end)

    %__MODULE__{clients: merged}
  end

  # ---- Private interval bookkeeping ----

  # `add_range/2` is the single write primitive. Every interval — from
  # `insert/4` or `merge/2` — passes through here. It is solely responsible
  # for keeping the range list sorted and disjoint.
  #
  # Three steps:
  #
  #   1. Partition existing ranges into those that overlap-or-touch the new
  #      range and those that do not.
  #   2. Collapse the overlapping group plus the new range into one bounding
  #      interval: min of all starts, max of all ends.
  #   3. Prepend the merged interval to the non-overlapping survivors and sort.
  #
  # Why step 2 produces a single contiguous span: the existing list is already
  # disjoint, so every range in the overlapping group touches the *new* range
  # specifically — not necessarily each other. The new range is the connector:
  # it overlaps each member, which means no gap can exist between any two
  # members. A gap-free span is fully described by its minimum start and
  # maximum end, which is what the two folds compute.
  #
  # Worked example — two existing ranges, a new one that bridges them:
  #
  #   existing A:  [1, 3)
  #   existing B:          [5, 7)
  #   new:           [2,    6)
  #
  # ASCII view of the clock axis (each cell = one clock):
  #
  #     clock:  0  1  2  3  4  5  6  7
  #     A:         AA AA
  #     B:                        BB BB
  #     new:          NN NN NN NN
  #
  #   A   = `[1, 3)` covers clocks 1, 2
  #   B   = `[5, 7)` covers clocks 5, 6
  #   new = `[2, 6)` covers clocks 2, 3, 4, 5
  #
  # New overlaps A at clock 2 (`[1,3)` ∩ `[2,6)` ≠ ∅) and B at clock 5
  # (`[5,7)` ∩ `[2,6)` ≠ ∅). Both go into the overlapping group. Their
  # collective bounds:
  #
  #   starts: A.start=1, new.start=2, B.start=5  → min = 1
  #   ends:   A.end=3,   new.end=6,   B.end=7    → max = 7
  #
  # Step 2 produces `[1, 7)`. Step 3 prepends it to the empty survivor
  # list and sorts, leaving `[{1, 7}]`.
  defp add_range(ranges, {new_start, new_end}) do
    # Step 1: separate ranges that overlap-or-touch the new interval from
    # those that do not.
    #
    # Two half-open intervals `[s, e)` and `[new_start, new_end)` overlap or
    # touch when `s <= new_end AND new_start <= e`. Both conjuncts are
    # load-bearing — each rules out a different direction of "clearly outside."
    # Four cases against new `[2, 6)`:
    #
    #   case A — existing entirely to the left, e.g. `[0, 1)`:
    #     `s=0 <= 6` ✓  but  `new_start=2 <= e=1` ✗  → disjoint.
    #     Only the second conjunct catches this.
    #
    #   case B — existing entirely to the right, e.g. `[7, 9)`:
    #     `s=7 <= 6` ✗  → disjoint.
    #     Only the first conjunct catches this (`2 <= 9` would pass alone).
    #
    #   case C — genuine overlap, e.g. `[3, 5)`:
    #     `s=3 <= 6` ✓  and  `new_start=2 <= e=5` ✓  → overlap.
    #
    #   case D — adjacent (touching boundary), e.g. `[6, 8)`:
    #     `s=6 <= 6` ✓  and  `new_start=2 <= e=8` ✓  → touch.
    #     The `<=` (not `<`) makes this pass. Without it, `[0, 3)` and
    #     `[3, 6)` would stay separate instead of merging to `[0, 6)`.
    {overlapping, rest} =
      Enum.split_with(ranges, fn {s, e} ->
        s <= new_end and new_start <= e
      end)

    # Step 2: compute the bounding interval of the overlapping group plus
    # the new range. Seeded at the new range's own bounds, so an empty
    # overlapping group leaves the new range unchanged.
    merged_start = Enum.reduce(overlapping, new_start, fn {s, _}, acc -> min(s, acc) end)
    merged_end = Enum.reduce(overlapping, new_end, fn {_, e}, acc -> max(e, acc) end)

    # Step 3: prepend the merged interval to the survivors and sort.
    #
    # Elixir sorts tuples lexicographically — element-by-element, left
    # to right — so a list of `{start, stop}` tuples ends up ordered
    # ascending by `start` (with `stop` as the tiebreaker, though
    # within a sorted-disjoint list ties on start can't happen). That's
    # exactly the sorted invariant we need to maintain.
    #
    # Cost is O(n log n) per insertion — fine for typical edit patterns.
    # Inserting at the correct position rather than re-sorting is the
    # natural upgrade if a client ever accumulates many disjoint runs.
    [{merged_start, merged_end} | rest]
    |> Enum.sort()
  end
end
