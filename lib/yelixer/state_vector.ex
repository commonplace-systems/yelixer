defmodule Yelixer.StateVector do
  @moduledoc """
  Per-client high-water-mark of observed clocks — Yjs's vector clock.

  A state vector answers "how much of the document have I seen?" with
  one number per client: the maximum clock observed from that client.
  That single number fully describes a replica's knowledge of a
  client's contributions, because Yjs clocks are *dense* — a client
  numbers its items 0, 1, 2, … with no gaps allowed.

  ## Why one number is enough

  Each Yjs client maintains a monotonic counter starting at 0. Item N
  from client C carries clock N. The integration pipeline enforces
  causal order: item N+1 is refused until 0..N are already present.
  So "client C: 7" implies clocks 0–6 are all integrated. The
  high-water-mark is the whole story; no hole-tracking is needed.

  This density invariant means a per-client set of observed clocks
  always collapses to its supremum. The state vector is therefore a
  plain `%{client => max_clock}` map rather than a map of sets.

  Contrast `Yelixer.DeleteSet`, which *does* need hole-tracking:

    - **DeleteSet** tracks *which* items were deleted. Deletions are
      sparse — any subset can be tombstoned in any order — so the
      structure is a list of intervals per client.
    - **StateVector** tracks *how many* items have been seen.
      Insertions are dense, so the structure collapses to a single
      number per client.

  Together they form the two-part sync summary — see
  `Yelixer.SyncProtocol`.

  ## How sync uses it

  Each side sends its state vector to the other. On receiving a peer's
  vector, a replica calls `diff(peer_sv, my_sv)` to discover which
  clients the peer has advanced beyond its own knowledge, then asks
  the peer for everything past those clocks. Both sides run this same
  procedure with roles swapped, bringing both replicas to a common
  state.

  ## What this module is not

  - Not a clock generator — new clocks are minted by the document at
    integration time.
  - Not a tombstone index — see `Yelixer.DeleteSet`.
  - Not a CRDT itself. StateVector tracks knowledge *about* the
    document, not the document itself — it's metadata, not content.
  - Even so, `advance/3` is idempotent and commutative (like a CRDT
    merge), ensuring two replicas that gossip their state vectors
    converge to the same clock values even when messages arrive out
    of order.
  """

  # `clocks` stores per-client high-water-marks; clients not in the
  # map are implicitly at clock 0 (see `get/2`).
  @type t :: %__MODULE__{clocks: %{non_neg_integer() => non_neg_integer()}}
  defstruct clocks: %{}

  @doc """
  Returns an empty state vector — no clients observed yet.

  Every `get/2` on this value returns 0. Use it as the starting point
  for a fresh document or a new sync round.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Returns the high-water-mark clock for `client`, defaulting to 0 for
  any client not yet seen.

  Absence and zero mean the same thing in Yjs's model — "zero items
  integrated from this client" — so the default-to-0 lets every caller
  read clocks without first checking `Map.has_key?`.
  """
  @spec get(t(), non_neg_integer()) :: non_neg_integer()
  def get(%__MODULE__{clocks: clocks}, client) do
    Map.get(clocks, client, 0)
  end

  @doc """
  Unconditionally writes `clock` as `client`'s high-water-mark.

  Use only when the caller has already verified correctness — for
  example, a sync ingestion loop that has just integrated a contiguous
  run and knows the exact resulting clock. Whenever an earlier
  observation might already be stored, prefer `advance/3`, which is
  monotonic and safe to call out of order.
  """
  @spec set(t(), non_neg_integer(), non_neg_integer()) :: t()
  def set(%__MODULE__{clocks: clocks}, client, clock) do
    %__MODULE__{clocks: Map.put(clocks, client, clock)}
  end

  @doc """
  The safe general-purpose write: `advance(sv, c, k)` stores
  `max(get(sv, c), k)`. A stale clock — say, a 5 arriving after a
  7 — is silently dropped rather than treated as a correction.

  Two properties are load-bearing for sync correctness:

    - **Commutative**: `advance(advance(sv, c, a), c, b)` and
      `advance(advance(sv, c, b), c, a)` produce the same result.
      Reordered or duplicated messages converge to the same clock.
    - **Idempotent**: applying the same observation twice is a no-op.
      Duplicate delivery cannot corrupt state.

  Associativity holds too, but commutativity and idempotence are
  what make sync robust to network reality. Same convergence story
  as `DeleteSet.merge/2`.
  """
  @spec advance(t(), non_neg_integer(), non_neg_integer()) :: t()
  def advance(%__MODULE__{} = sv, client, clock) do
    # Strict `>` only — preserves the monotonic invariant under
    # reordered or duplicate observations.
    if clock > get(sv, client), do: set(sv, client, clock), else: sv
  end

  @doc """
  Returns the catch-up request that `local` needs to reach `remote`'s
  state.

  Call as `diff(remote, local)`. The result is a
  `%{client => local_clock}` map. Each entry means: "remote has more
  items from this client; local's knowledge ends at `local_clock`, so
  remote should stream everything from there."

  ## Walk-through

      remote: %{1 => 7, 2 => 3}
      local:  %{1 => 4, 2 => 3, 3 => 9}

  - Client 1: remote=7, local=4 → remote is ahead. Record `1 => 4`:
    "send clocks 4, 5, 6."
  - Client 2: remote=3, local=3 → equal. Nothing to ship; skip.
  - Client 3: remote doesn't know it; nothing to ship. The reverse
    direction — `diff(local, remote)` on the other side — handles
    whatever local has that remote lacks.

  Result: `%{1 => 4}`.

  ## Why iterate remote's clients, not local's

  Sync is symmetric: each side calls `diff(peer_sv, own_sv)` and ships
  what the peer is missing. Each call therefore only needs to answer
  one direction — "what should *this* side ship to the peer?" — and
  trust the other side to handle the reverse direction independently.

  From there the iteration choice falls out: only clients present in
  remote's map can possibly be shipped by remote. A client known only
  to local has no remote items to request; the peer's matching call
  on the other side picks it up.

  ## Why the value is local's clock, not remote's

  The result is a resume point: "start sending from here." Local's
  clock is that point — the first item local still needs. Remote's
  clock would only tell remote something it already knows.
  """
  @spec diff(t(), t()) :: %{non_neg_integer() => non_neg_integer()}
  def diff(%__MODULE__{clocks: remote}, %__MODULE__{clocks: local}) do
    Enum.reduce(remote, %{}, fn {client, remote_clock}, acc ->
      # Default to 0: local has never seen this client.
      local_clock = Map.get(local, client, 0)

      if remote_clock > local_clock do
        # Remote is ahead — record local's resume point.
        Map.put(acc, client, local_clock)
      else
        # Local is at or ahead of remote. Nothing to request here; the
        # other side's `diff(local, remote)` ships what remote is missing.
        acc
      end
    end)
  end
end
