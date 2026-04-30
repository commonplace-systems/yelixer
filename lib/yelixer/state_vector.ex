defmodule Yelixer.StateVector do
  @moduledoc """
  Per-client high-water-mark of observed clocks — Yjs's vector clock.

  A state vector answers "how much of the document have I seen?" with
  a single number per client. For each client it records the maximum
  clock observed from that client — nothing else. That single number
  is enough to describe a replica's complete knowledge of that client's
  contributions, because Yjs clocks are *dense*: a client numbers its
  items 0, 1, 2, 3, … with no gaps allowed.

  ## Why a single number per client is enough

  Each Yjs client maintains its own monotonic counter (a counter that
  never decreases) starting at 0. Item N from client C carries clock
  N; item N+1 carries clock N+1. The integration pipeline enforces
  causal ordering: it refuses to apply item N+1 from client C until
  items 0..N from that client are already integrated. So if the state
  vector records "client C: 7," items at clocks 0, 1, 2, 3, 4, 5, 6
  are necessarily present. The high-water-mark — the maximum clock
  seen — is the whole story; no hole-tracking is needed.

  This density invariant means that a per-client *set* of observed
  clocks always collapses to a single value: its supremum (maximum).
  That is why the state vector is a plain `%{client => max_clock}` map
  rather than a map of sets.

  Compare this with `Yelixer.DeleteSet`, which *does* need
  hole-tracking: deletions don't have to arrive in order or cover a
  contiguous range, so that structure uses a list of intervals rather
  than a single number. The two modules carry complementary roles in
  sync:

    - **DeleteSet** tracks *which* items were deleted. Deletions are
      sparse (any subset of items can be tombstoned in any pattern),
      so the structure is a list of intervals per client.
    - **StateVector** tracks *how many* items we have seen. Insertions
      are dense (clocks 0..N-1 always present before clock N), so the
      structure collapses to a single number per client.

  State vectors and delete sets are the two halves of the
  sync-protocol summary — see `Yelixer.SyncProtocol`.

  ## How sync uses it

  Sync between two replicas runs in two halves. Each side sends its
  own state vector to the other. On receiving a peer's state vector,
  a replica calls `diff(peer_sv, my_sv)` to find which clients the
  peer has more items from, and where its own knowledge runs out. It
  then asks the peer for everything past those clocks.

  Both sides run this same procedure with the roles swapped. The two
  halves together bring both replicas to a common state.

  ## What this module is NOT

  - Not a clock generator. New clocks are minted by the document at
    integration time, not here.
  - Not a tombstone index. See `Yelixer.DeleteSet`.
  - Not a CRDT itself, though `advance/3` plays the same role here
    that `merge` plays in a CRDT: it combines two observations into
    one that respects both. Concretely, `advance(sv, c, k)` sets
    `c`'s clock to `max(existing, k)` — the larger of the two
    is always correct, since clocks only ever go forward. State
    vectors are *summaries* of CRDT state; the document is the CRDT.
  """

  # The state vector struct. `clocks` maps each client ID (a non-neg
  # integer) to that client's current high-water-mark clock (also a
  # non-neg integer). A client absent from the map is implicitly at
  # clock 0 — see `get/2`.
  @type t :: %__MODULE__{clocks: %{non_neg_integer() => non_neg_integer()}}
  defstruct clocks: %{}

  @doc """
  Returns an empty state vector — no clients observed.

  Every `get/2` on this value returns 0: nothing has been seen from
  anyone. Use it as the starting point when initializing a fresh
  document or beginning a sync round.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Returns the high-water-mark clock for `client`. Defaults to 0 for
  any client not yet seen.

  Absence and zero are intentionally equivalent: "client C is at
  clock 0" means "we have integrated zero items from C," which is
  exactly the state of a client we have never heard of. Defaulting
  to 0 means the rest of the module never needs to distinguish between
  the two cases with `Map.has_key?`.
  """
  @spec get(t(), non_neg_integer()) :: non_neg_integer()
  def get(%__MODULE__{clocks: clocks}, client) do
    Map.get(clocks, client, 0)
  end

  @doc """
  Unconditionally writes `clock` as `client`'s high-water-mark.

  Use this only when the caller has already established that `clock`
  is correct — for example, a sync ingestion loop that has just
  integrated a contiguous run of items and knows the resulting end
  clock exactly. For any path where an earlier observation might
  already be stored, prefer `advance/3`, which is monotonic and safe
  to call out of order.
  """
  @spec set(t(), non_neg_integer(), non_neg_integer()) :: t()
  def set(%__MODULE__{clocks: clocks}, client, clock) do
    %__MODULE__{clocks: Map.put(clocks, client, clock)}
  end

  @doc """
  Raises `client`'s clock to `max(existing, clock)`. Idempotent and
  monotonic — the stored value never decreases.

  This is the safe general-purpose write. Any observed clock can be
  passed in; the result is always at least as far ahead as before.
  Out-of-order observations — such as receiving clock 7 and then
  re-receiving clock 5 from a duplicate network message — are
  silently ignored rather than treated as corrections.

  Concretely, `advance(sv, c, k)` is just `max(get(sv, c), k)` written
  out: take whichever of the two clocks is larger, and that's the
  new high-water-mark. The "join" name in CRDT papers is shorthand
  for exactly this operation — the *least upper bound* of two
  observations.

  Two properties are load-bearing for sync correctness:

    - **Commutative**: `advance(advance(sv, c, a), c, b)` and
      `advance(advance(sv, c, b), c, a)` produce the same result.
      Order of arrival doesn't matter — duplicate or reordered
      network messages converge to the same clock.
    - **Idempotent**: `advance(advance(sv, c, k), c, k) ==
      advance(sv, c, k)`. Re-applying the same observation is a
      no-op. Duplicate delivery cannot corrupt state.

  Associativity holds too, but it does less work in practice — the
  two properties above are what make the sync protocol robust to
  network reality. Same shape as `DeleteSet.merge/2`'s convergence
  story; same reason.
  """
  @spec advance(t(), non_neg_integer(), non_neg_integer()) :: t()
  def advance(%__MODULE__{} = sv, client, clock) do
    # Only write when the new clock is strictly larger. Equal or
    # smaller clocks (duplicates, late arrivals) leave the state
    # vector untouched — that's what makes this monotonic.
    if clock > get(sv, client), do: set(sv, client, clock), else: sv
  end

  @doc """
  Produces the catch-up request local needs in order to reach remote's
  state.

  Call as `diff(remote, local)`. The result is a
  `%{client => local_clock}` map. Each entry means: "remote has more
  items from this client than local does; local's knowledge ends at
  `local_clock`, so remote should send everything from there onward."

  ## Walk-through

  Remote's state vector: `%{1 => 7, 2 => 3}`.
  Local's state vector:  `%{1 => 4, 2 => 3, 3 => 9}`.

  - Client 1: remote=7, local=4 → remote is ahead. Record `1 => 4`:
    "send me client 1's items at clocks 4, 5, 6."
  - Client 2: remote=3, local=3 → equal. No catch-up needed; skip.
  - Client 3: only local knows about it; remote has nothing to ship.
    Skip. The symmetric half of sync — `diff(local, remote)` run
    on the other side — handles the reverse case.

  Result: `%{1 => 4}`.

  ## Why iterate remote's clients, not local's

  The question is "what can remote supply that local is missing?" Only
  clients that appear in remote's map can be shipped by remote. Clients
  known only to local are irrelevant here; the other side of the sync
  exchange picks them up.

  Sync is symmetric. Each side computes diff with its peer's state
  vector as the first argument and its own as the second, then ships
  back the items the peer is missing. This side sends what remote
  lacks; the other side sends what local lacks. Together the two
  half-runs leave both replicas at the same state.

  ## Why the value is local's clock, not remote's

  The result is a streaming request: "start sending from this clock."
  Local's clock is the resume point — the first item local still needs.
  Remote's clock would merely tell remote something it already knows
  about itself.
  """
  @spec diff(t(), t()) :: %{non_neg_integer() => non_neg_integer()}
  def diff(%__MODULE__{clocks: remote}, %__MODULE__{clocks: local}) do
    Enum.reduce(remote, %{}, fn {client, remote_clock}, acc ->
      # Local's clock for this client. Defaults to 0 when local has
      # never heard of this client — meaning local needs all of its
      # items, starting from clock 0.
      local_clock = Map.get(local, client, 0)

      if remote_clock > local_clock do
        # Local is behind. Record where local's knowledge ends so
        # remote knows where to start the catch-up stream.
        Map.put(acc, client, local_clock)
      else
        # Local is at or ahead of remote for this client. Remote has
        # nothing to ship. If local is genuinely ahead, the other
        # side's `diff(local, remote)` call will catch that.
        acc
      end
    end)
  end
end
