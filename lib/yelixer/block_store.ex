defmodule Yelixer.BlockStore do
  @moduledoc """
  The data structure that physically holds Items and answers lookups.

  A `BlockStore` is the union of two indexes over the same underlying
  Items, one keyed by **identity**, one keyed by **position**:

    - `clients :: %{client_id => [Item.t()]}` — every Item the store
      knows about, grouped by its client. Within a bucket, blocks are
      sorted by clock and (because clocks are dense per
      `Yelixer.ID`'s contract) they form a single contiguous run with
      no gaps and no overlap. This is the index that answers "give me
      Item with ID `(A, 5)`."
    - `sequences :: %{type_name => [ID.t()]}` — for each top-level
      named CRDT type (a `YArray` named "list", a `YText` named
      "body", etc.), the rendered order of items as a list of IDs.
      This is the index that answers "what's the third element of
      `list`?"

  The duality is the whole point. Items physically live in `clients`;
  the document's visible *order* lives in `sequences`. Walking a
  sequence — IDs through `get/2` — gives you the rendered list.

  ## Why per-client buckets

  Clocks are dense per client (see `Yelixer.ID` and
  `Yelixer.StateVector`). A client's blocks form one sorted run by
  construction, so identity lookup reduces to "find the block
  covering this clock," which is a binary search on a sorted list.

  Cross-client lookup is just two map indirections (client →
  bucket → block).

  ## The tuple cache

  Binary search needs O(1) random access; Erlang lists give you O(n).
  The store keeps a parallel `client_tuples` cache where each client's
  list is mirrored as a tuple (`{}` element access via `:erlang.elem`
  is O(1)). The cache is built lazily (`get_tuple/2`) and invalidated
  whenever a mutation reshapes a client's list mid-stream — `push/2`
  can extend it cheaply with `:erlang.append_element/2`, but
  `split_block/3` (which mutates the middle) drops the cached tuple
  and lets the next read rebuild it.

  Lists stay the source of truth; tuples are a read-side optimization.

  ## Block ranges and clock membership

  A block at `id = (client, clock)` with `length = n` covers clocks
  `[clock, clock + n)` — half-open, matching the convention in
  `Yelixer.DeleteSet`. The binary search expresses this as inclusive
  bounds (`block_end = clock + length - 1`, `clock <= block_end`)
  because comparing a clock against an inclusive endpoint with `<=`
  is one fewer arithmetic op than against a half-open endpoint with
  `<`. Same membership; alternate spelling.

  ## Invariants

  Maintained on every write path:

    1. Each `clients[c]` list is sorted by `id.clock`.
    2. The list is contiguous — no clock gaps within a client.
    3. Blocks within a client never overlap. `split_block/3`
       partitions cleanly using `Item.split/2`.
    4. The `client_tuples` cache, when present for a client, mirrors
       that client's list element-for-element.
    5. Each `sequences[type_name]` is a list of IDs, every one of
       which appears in some `clients[c]`. Sequences may contain IDs
       of tombstoned blocks; rendering filters them in `get_sequence/2`.

  ## What this module is not

  - Not the integrator. `Yelixer.Integrate` decides *where* a new
    Item belongs in YATA order; this module just stores the result.
  - Not the renderer. `get_sequence/2` is a low-level walk; the
    rich-text / DOM-level rendering lives further up the stack.
  - Not the encoder. `Yelixer.Encoding` serializes a BlockStore's
    contents to the Yjs binary update format.
  """

  alias Yelixer.{ID, Item, StateVector}

  @type t :: %__MODULE__{
          clients: %{non_neg_integer() => [Item.t()]},
          sequences: %{String.t() => [ID.t()]},
          client_tuples: %{non_neg_integer() => tuple()}
        }
  defstruct clients: %{}, sequences: %{}, client_tuples: %{}

  @doc "An empty BlockStore — no clients, no sequences, no cached tuples."
  def new, do: %__MODULE__{}

  @doc """
  Appends `item` to its client's bucket and extends the tuple cache
  in place.

  Append-only is the typical write path: integration produces items
  in clock order for any one client, so the new item's clock is
  always strictly greater than every existing block in the bucket.
  Because of that monotonicity, the tuple cache can be extended with
  `:erlang.append_element/2` (O(1) on the right end) rather than
  rebuilt — the only cheap mutation an Erlang tuple supports.
  """
  def push(%__MODULE__{clients: clients, client_tuples: ct} = store, %Item{} = item) do
    client = item.id.client
    client_blocks = Map.get(clients, client, [])
    new_blocks = client_blocks ++ [item]

    new_tuple =
      case Map.get(ct, client) do
        nil -> List.to_tuple(new_blocks)
        existing -> :erlang.append_element(existing, item)
      end

    %{store |
      clients: Map.put(clients, client, new_blocks),
      client_tuples: Map.put(ct, client, new_tuple)
    }
  end

  @doc """
  Identity lookup: returns the Item whose ID is `(client, clock)`,
  or `nil` if no block in that client's bucket covers that clock.

  The clock may not be a block's `id.clock` exactly — it may fall
  inside a multi-clock run-length block. The binary search returns
  the *containing* block in either case. If the caller specifically
  needs `id.clock == clock` (e.g. so they can split off the boundary
  before anchoring), they should call `split_block/3` first.
  """
  def get(%__MODULE__{} = store, %ID{client: client, clock: clock}) do
    case get_tuple(store, client) do
      nil -> nil
      tuple -> bsearch_item(tuple, clock)
    end
  end

  @doc "Returns the full list of blocks for a client (or `[]` if none)."
  def client_blocks(%__MODULE__{clients: clients}, client) do
    Map.get(clients, client, [])
  end

  @doc """
  Derives a `Yelixer.StateVector` from the current store contents.

  For each client, take the last block, compute `id.clock + length` —
  that's the next-unused clock for the client, which by
  `StateVector`'s contract is the high-water-mark recorded for that
  client. Clients absent from `clients` produce no entry; `get/2` on
  the resulting state vector still defaults to 0.
  """
  def state_vector(%__MODULE__{clients: clients}) do
    Enum.reduce(clients, StateVector.new(), fn {client, blocks}, sv ->
      case List.last(blocks) do
        nil -> sv
        %Item{id: id, length: len} -> StateVector.set(sv, client, id.clock + len)
      end
    end)
  end

  @doc """
  Stores `item` and inserts its ID into `type_name`'s sequence at
  `index`. The compound write that integration uses for "this new
  item belongs at position N of this named type."
  """
  def insert_at(%__MODULE__{} = store, type_name, index, %Item{} = item) do
    store = push(store, item)
    insert_into_sequence(store, type_name, index, item.id)
  end

  @doc """
  Inserts an existing block's ID into a sequence — used when a split
  introduces a new block whose left half was already in the sequence,
  or when reordering moves an existing item's slot.
  """
  def insert_into_sequence(%__MODULE__{} = store, type_name, index, id) do
    seq = Map.get(store.sequences, type_name, [])
    seq = List.insert_at(seq, index, id)
    %{store | sequences: Map.put(store.sequences, type_name, seq)}
  end

  @doc """
  Splits the block containing `clock` (within `client`'s bucket) so
  that the boundary clock starts a fresh block. Returns
  `{store, right_half_or_nil}`.

  Three outcomes:

    1. The client has no blocks → return the store unchanged with
       `nil` as the right half.
    2. The clock already lies on a block boundary
       (`item.id.clock == clock`) → no split needed, return the
       existing block as the "right half."
    3. The clock falls in the interior of a block → call
       `Item.split/2`, splice `[left, right]` in place of the
       original in the client's list, invalidate the tuple cache (the
       middle of the list changed; an O(1) tuple update isn't
       available), and update the sequence to insert `right.id` after
       `item.id` if that sequence carries the item.

  Splits are the prerequisite for anchoring a new YATA edit at an
  interior clock — the `origin` / `right_origin` references in
  `Yelixer.Item` only address whole blocks, so the boundary has to
  exist as a block boundary before it can be referenced.
  """
  def split_block(%__MODULE__{} = store, %ID{client: client, clock: clock}, type_name) do
    case get_tuple(store, client) do
      nil ->
        {store, nil}

      tuple ->
        case bsearch_index(tuple, clock) do
          nil ->
            {store, nil}

          {_idx, item} when item.id.clock == clock ->
            # Already on a boundary; nothing to do.
            {store, item}

          {idx, item} ->
            offset = clock - item.id.clock
            {left, right} = Item.split(item, offset)

            clients =
              Map.update!(store.clients, client, fn blocks ->
                blocks
                |> List.replace_at(idx, left)
                |> List.insert_at(idx + 1, right)
              end)

            # Tuple cache no longer mirrors the list — drop it; the
            # next read rebuilds via `get_tuple/2`.
            ct = Map.delete(store.client_tuples, client)

            sequences =
              case Map.get(store.sequences, type_name) do
                nil ->
                  store.sequences

                seq ->
                  seq_idx = Enum.find_index(seq, &(&1 == item.id))

                  if seq_idx != nil do
                    Map.put(store.sequences, type_name, List.insert_at(seq, seq_idx + 1, right.id))
                  else
                    store.sequences
                  end
              end

            {%{store | clients: clients, sequences: sequences, client_tuples: ct}, right}
        end
    end
  end

  @doc """
  Renders a sequence as a list of live (non-tombstoned) Items in
  document order.

  Walks the type's stored ID list, looks each ID up in the per-client
  index, drops anything that's missing or tombstoned. The output is
  the user-visible content of the named type.
  """
  def get_sequence(%__MODULE__{} = store, type_name) do
    store.sequences
    |> Map.get(type_name, [])
    |> Enum.map(&get(store, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(& &1.deleted)
  end

  # Public binary-search hook for callers that hold a `[Item.t()]`
  # directly (e.g. during integration, before the result lands in a
  # store). Materializes a one-shot tuple and runs the standard search.
  @doc false
  def find_block_index(blocks, clock) when is_list(blocks) do
    tuple = List.to_tuple(blocks)
    bsearch_index(tuple, clock)
  end

  # --- Internal helpers ---

  # Get-or-lazily-build the tuple cache for a client.
  defp get_tuple(%__MODULE__{client_tuples: ct, clients: clients}, client) do
    case Map.get(ct, client) do
      nil ->
        case Map.get(clients, client) do
          nil -> nil
          [] -> nil
          blocks -> List.to_tuple(blocks)
        end

      tuple ->
        tuple
    end
  end

  # Rebuilds the tuple cache entry for `client` from its current
  # `clients[client]` list. Called by external mutators that bypass
  # `push/2` / `split_block/3` and reshape the bucket directly — they
  # are responsible for asking the cache to refresh afterward.
  @doc false
  def refresh_tuple_cache(%__MODULE__{clients: clients, client_tuples: ct} = store, client) do
    case Map.get(clients, client) do
      nil ->
        %{store | client_tuples: Map.delete(ct, client)}

      blocks ->
        %{store | client_tuples: Map.put(ct, client, List.to_tuple(blocks))}
    end
  end

  # Drops the tuple cache entry for `client`. Cheaper than
  # `refresh_tuple_cache/2` when an external mutator knows the next
  # reader will trigger a lazy rebuild via `get_tuple/2` anyway.
  @doc false
  def invalidate_tuple_cache(%__MODULE__{client_tuples: ct} = store, client) do
    %{store | client_tuples: Map.delete(ct, client)}
  end

  # Binary-search the clock-sorted tuple of blocks for the one whose
  # range covers `clock`. Each block at id.clock with length n covers
  # clocks `[id.clock, id.clock + n)`; the comparison uses inclusive
  # bounds (`block_end = id.clock + length - 1`) — same membership,
  # one less subtraction in the hot path.

  defp bsearch_item(tuple, clock) do
    size = tuple_size(tuple)

    if size == 0 do
      nil
    else
      case bsearch(tuple, clock, 0, size - 1) do
        nil -> nil
        {_idx, item} -> item
      end
    end
  end

  defp bsearch_index(tuple, clock) do
    size = tuple_size(tuple)

    if size == 0 do
      nil
    else
      bsearch(tuple, clock, 0, size - 1)
    end
  end

  defp bsearch(_tuple, _clock, low, high) when low > high, do: nil

  defp bsearch(tuple, clock, low, high) do
    mid = div(low + high, 2)
    item = elem(tuple, mid)
    block_start = item.id.clock
    block_end = block_start + item.length - 1

    cond do
      clock < block_start -> bsearch(tuple, clock, low, mid - 1)
      clock > block_end -> bsearch(tuple, clock, mid + 1, high)
      true -> {mid, item}
    end
  end
end
