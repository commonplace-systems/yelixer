defmodule Yelixer.StateVector do
  @moduledoc """
  Per-client high-water-mark of observed clocks — Yjs's vector clock.

  A state vector is a compact summary of "everything I have seen from
  every client." For each client, it stores the maximum clock value we
  have observed an item at; nothing else. Despite that compactness, it
  fully describes our knowledge of the document — because Yjs clocks
  are dense.

  ## Why a single clock per client is enough

  Each Yjs client maintains its own monotonic counter starting at 0.
  Item N from client C has clock N; item N+1 has clock N+1; gaps are
  not allowed. The integration pipeline refuses to apply item N+1 from
  client C unless items 0..N from that client are already integrated
  (causal ordering). So if our state vector says "client C: 7," we
  have necessarily integrated client C's items at clocks 0, 1, 2, 3,
  4, 5, 6 — the whole prefix up to (but not including) 7. There is no
  hole-tracking to do; the high-water-mark is the whole story.

  This is why a state vector lives in a single `%{client => max_clock}`
  map rather than, say, a per-client *set* of observed clocks. The
  density invariant collapses the set to its supremum.

  Compare this with `Yelixer.DeleteSet`, which *does* need
  hole-tracking: deletions don't have to be contiguous, so the per-
  client structure there is a list of intervals rather than a single
  number. State vectors and delete sets pair up as the two halves of
  the sync-protocol summary — see `Yelixer.SyncProtocol`.

  ## How sync uses it

  Sync between two replicas runs in two halves. Each side sends *its
  own* state vector to the other, meaning "this is everything I have."
  The other side computes `diff(my_sv, their_sv)` to learn which of
  *its* clients carry items the requester is missing, and at what
  clock the requester's knowledge ends. The reply ships the relevant
  items past those clocks.

  Because the protocol is symmetric — both sides do the same thing
  with the roles flipped — the two halves together drive both replicas
  to a common state.

  ## What this module is NOT

  - Not a clock generator. New clocks are minted by the document at
    integration time, not here.
  - Not a tombstone index. See `Yelixer.DeleteSet`.
  - Not a CRDT itself, though `advance/3` is a join operation on the
    natural max-lattice. State vectors are *summaries* of CRDT state;
    the CRDT itself is the document.
  """

  # The state vector struct. `clocks` maps client_id (a non-neg
  # integer) to that client's high-water-mark clock (also a non-neg
  # integer). A client absent from the map is implicitly at clock 0
  # — see `get/2`.
  @type t :: %__MODULE__{clocks: %{non_neg_integer() => non_neg_integer()}}
  defstruct clocks: %{}

  @doc """
  An empty state vector — no clients observed.

  Every `get/2` lookup against this returns 0, which is correct: we
  have observed nothing from anyone. Used as the starting point when
  initializing a fresh document or beginning a sync round.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Returns the high-water-mark clock observed from `client`. Defaults
  to 0 for any client not yet seen.

  The default-to-0 is a deliberate equivalence: "client C is at
  clock 0" and "we have not heard of client C" are the same statement
  in Yjs's model — both mean "we have integrated zero items from C."
  Treating absence as 0 lets the rest of the module avoid case
  analysis on `Map.has_key?` everywhere a clock is read.
  """
  @spec get(t(), non_neg_integer()) :: non_neg_integer()
  def get(%__MODULE__{clocks: clocks}, client) do
    Map.get(clocks, client, 0)
  end

  @doc """
  Unconditionally writes `clock` as `client`'s high-water-mark.

  Used by code paths that have already established the new value is
  correct — for example, a sync ingestion loop that has just
  integrated a contiguous run of items from a client and knows its new
  end clock. For ordinary write paths where you might race against an
  earlier observation, prefer `advance/3`, which is monotonic.
  """
  @spec set(t(), non_neg_integer(), non_neg_integer()) :: t()
  def set(%__MODULE__{clocks: clocks}, client, clock) do
    %__MODULE__{clocks: Map.put(clocks, client, clock)}
  end

  @doc """
  Bumps `client`'s clock to `max(existing, clock)`. Idempotent and
  monotonic — the stored value never decreases.

  This is the safe write primitive: you can call it with any clock
  you've observed for `client` and the state vector will end up at
  least as far ahead as it was before. Out-of-order observations
  (e.g. seeing clock 7 then re-seeing clock 5 from a duplicate
  message) are no-ops rather than corrections.

  Algebraically, `advance` is the join operation on the lattice of
  state vectors — applied per-client. Repeated calls converge,
  ordering doesn't matter, and the operation is associative. Same
  shape as `DeleteSet.merge/2`'s convergence story; same reason.
  """
  @spec advance(t(), non_neg_integer(), non_neg_integer()) :: t()
  def advance(%__MODULE__{} = sv, client, clock) do
    if clock > get(sv, client), do: set(sv, client, clock), else: sv
  end

  @doc """
  Computes the catch-up request a *local* replica would send to a
  *remote* replica, given that local has just learned what remote has.

  Argument order is `diff(remote, local)`, read as "from remote's
  perspective vs local's." The result is a `%{client => local_clock}`
  map saying: "for each client where remote is further ahead than I
  am, remote should send me everything starting from this clock."

  ## Walk-through

  Suppose remote's state vector is `%{1 => 7, 2 => 3}` and local's is
  `%{1 => 4, 2 => 3, 3 => 9}`.

  - Client 1: remote has 7, local has 4 → remote is ahead by 3 items.
    The diff records `1 => 4`, meaning "I have client 1 up to clock
    4 (exclusive); send me items at clocks 4, 5, 6."
  - Client 2: remote has 3, local has 3 → equal. No catch-up needed.
    Skipped.
  - Client 3: remote doesn't know about it. Skipped — remote can't
    send what it doesn't have. (If local has items remote is
    missing, remote will discover that on its own side by computing
    `diff(local, remote)`. The two halves run symmetrically.)

  ## Why iterate `remote`, not `local`

  We iterate the remote map because the question is "what should
  remote ship to local?" Clients that exist only in local are
  uninteresting from this side of the conversation — local already
  has them; remote couldn't supply them even if asked. The symmetric
  half of sync runs `diff(local, remote)` on the other side and picks
  those up there.

  ## Why the value is the *local* clock, not the remote one

  The result is a request, not a status report. Local says "send me
  items starting from clock X." That clock is local's current
  high-water-mark for the client — the position past which local
  needs new items. Putting remote's clock in the value would tell
  remote what it already knows about itself; useless. Putting
  local's clock tells remote what to skip past, which is what the
  reply machinery needs.
  """
  @spec diff(t(), t()) :: %{non_neg_integer() => non_neg_integer()}
  def diff(%__MODULE__{clocks: remote}, %__MODULE__{clocks: local}) do
    Enum.reduce(remote, %{}, fn {client, remote_clock}, acc ->
      # Local's clock for this client; default 0 if local hasn't
      # heard of the client at all (in which case local needs
      # everything from clock 0 onward).
      local_clock = Map.get(local, client, 0)

      if remote_clock > local_clock do
        # Local is behind. Record local's current position so remote
        # knows where to start the catch-up stream from.
        Map.put(acc, client, local_clock)
      else
        # Local is at or ahead of remote for this client; nothing for
        # remote to ship. The symmetric half of sync (run on the
        # other side as `diff(local, remote)`) will pick up the
        # opposite case if local is genuinely ahead.
        acc
      end
    end)
  end
end
