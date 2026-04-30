defmodule Yelixer.ID do
  @moduledoc """
  Universal identifier for everything in a Yjs document: a `(client,
  clock)` pair.

  Every insertion gets exactly one ID — assigned once, kept forever.
  Items reference each other by ID; `Yelixer.DeleteSet` indexes
  tombstones by ID; `Yelixer.StateVector` summarizes "how much of each
  client's clock space we have observed." Sync messages, encoding,
  garbage collection, and integration all key off this struct.

  Why this shape:

    - `client` is a per-replica integer chosen at connect time. Two
      replicas pick distinct values (collision is acceptable; the
      protocol is robust to it but generation tries to avoid it).
    - `clock` is that client's monotonic counter, starting at 0 and
      incrementing once per item the client emits. Clocks are dense:
      an item at clock N implies its predecessors at clocks 0..N-1
      already exist.

  Together, `(client, clock)` is unique across the entire document
  forever, regardless of replica counts or merge order. That's the
  property the rest of the system relies on.
  """

  @type t :: %__MODULE__{client: non_neg_integer(), clock: non_neg_integer()}
  defstruct [:client, :clock]

  @doc "Constructs an ID from a client integer and a clock integer."
  def new(client, clock), do: %__MODULE__{client: client, clock: clock}

  @doc """
  Checks whether `clock` falls in the half-open range
  `[id.clock, id.clock + len)`. Used by callers that store an Item or
  range as an `(id, length)` pair and need to ask "does this specific
  clock land inside that run?"

  Note: this only checks the clock dimension. The caller is
  responsible for matching `client` separately.
  """
  def contains?(%__MODULE__{clock: start}, len, clock) do
    clock >= start and clock < start + len
  end
end
