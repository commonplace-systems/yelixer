defmodule Yelixer.ID do
  @moduledoc """
  Universal identifier for everything in a Yjs document: a `(client,
  clock)` pair.

  Every insertion gets exactly one ID — assigned once, kept forever.
  Items reference each other by ID; `Yelixer.DeleteSet` indexes
  tombstones by ID; `Yelixer.StateVector` tracks "how much of each
  client's clock space we have observed." Sync, encoding, GC, and
  integration all key off this struct.

  - `client` — per-replica integer chosen at connect time. Collisions
    are tolerated but generation tries to avoid them.
  - `clock` — that client's monotonic counter, starting at 0.
    Clocks are dense: an item at clock N implies 0..N-1 exist.

  Together, `(client, clock)` is globally unique across the document
  regardless of replica count or merge order — the invariant everything
  else depends on.
  """

  @type t :: %__MODULE__{client: non_neg_integer(), clock: non_neg_integer()}
  defstruct [:client, :clock]

  @doc "Build an ID from a client integer and a clock integer."
  def new(client, clock), do: %__MODULE__{client: client, clock: clock}

  @doc """
  Returns true if `clock` falls in `[id.clock, id.clock + len)`.

  Used when an Item or range is stored as an `(id, length)` pair to
  ask "does this clock land inside that run?"

  Only checks the clock dimension — the caller must match `client`.
  """
  def contains?(%__MODULE__{clock: start}, len, clock) do
    clock >= start and clock < start + len
  end
end
