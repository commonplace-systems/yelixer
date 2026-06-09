defmodule Yelixer.BlockStore do
  @moduledoc """
  Physical storage for Items, with dual indexes keyed by identity and position.

  Two indexes over the same Items:

    - `clients :: %{client_id => [Item.t()]}` — all Items grouped by
      client. Within a bucket, blocks are sorted by clock and, because
      clocks are dense per `Yelixer.ID`'s contract, form one
      contiguous run with no gaps or overlap. This is the identity
      index: "give me the Item with ID `(A, 5)`."
    - `sequences :: %{type_name => [ID.t()]}` — for each top-level
      named CRDT type (a `YArray` named "list", a `YText` named
      "body", etc.), the document-order list of IDs. This is the
      position index: "what is the third element of `list`?"

  Items physically live in `clients`; document order lives in
  `sequences`. Walking a sequence — resolving IDs through `get/2` —
  yields the rendered list.

  ## Why per-client buckets

  Dense clocks (see `Yelixer.ID` and `Yelixer.StateVector`) mean a
  client's blocks form one sorted run by construction. Identity lookup
  reduces to a binary search within that run. Cross-client lookup adds
  only a map indirection (client → bucket → block).

  ## The tuple cache

  Binary search needs O(1) random access; Erlang lists are O(n).
  `client_tuples` mirrors each client's block list as a tuple
  (`:erlang.elem` is O(1)). The cache is built lazily (`get_tuple/2`).
  `push/2` extends it cheaply with `:erlang.append_element/2` — the
  only O(1) Erlang tuple mutation. `split_block/3`, which inserts into
  the middle of a list, drops the cached tuple and lets the next read
  rebuild it.

  Lists are the source of truth; tuples are a read-side optimization.

  ## Block ranges and clock membership

  A block at `id = (client, clock)` with `length = n` covers clocks
  `[clock, clock + n)` — half-open, matching `Yelixer.DeleteSet`.
  The binary search uses inclusive bounds (`block_end = clock + length - 1`,
  `clock <= block_end`) — same membership, one fewer arithmetic op
  than the half-open form.

  ## Invariants

  Maintained on every write path:

    1. Each `clients[c]` list is sorted by `id.clock`.
    2. The list is contiguous — no clock gaps within a client.
    3. Blocks never overlap; `split_block/3` partitions via `Item.split/2`.
    4. `client_tuples[c]`, when present, mirrors `clients[c]` element-for-element.
    5. Every ID in `sequences[type_name]` resolves to a block in some
       `clients[c]`. Sequences may include tombstoned IDs; `get_sequence/2`
       filters them on read.

  ## What this module is not

  - Not the integrator — `Yelixer.Integrate` decides YATA insertion
    order; this module stores the result.
  - Not the renderer — `get_sequence/2` is a low-level walk; rich-text
    and DOM rendering live further up the stack.
  - Not the encoder — `Yelixer.Encoding` serializes a BlockStore to
    the Yjs binary update format.
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
  Appends `item` to its client's bucket and extends the tuple cache in place.

  Integration produces Items in clock order per client, so the new
  item's clock always exceeds every existing block in the bucket. That
  monotonicity lets the tuple cache grow with `:erlang.append_element/2`
  (O(1) on the right) rather than a full rebuild.
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
  Identity lookup: returns the Item covering `(client, clock)`, or
  `nil` if no block in the client's bucket spans that clock.

  The clock need not be a block boundary — it may fall inside a
  multi-clock run-length block, and the containing block is returned.
  Callers that need `id.clock == clock` exactly (e.g. to anchor at
  an interior boundary) should call `split_block/3` first.
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

  For each client, the high-water mark is `last_block.id.clock + length`
  — the next unused clock, per `StateVector`'s contract. Clients absent
  from `clients` produce no entry; the state vector defaults to 0 for
  unknown clients.
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
  Stores `item` and inserts its ID at `index` in `type_name`'s
  sequence — the compound write integration uses when placing a new
  item at a known position within a named type.
  """
  def insert_at(%__MODULE__{} = store, type_name, index, %Item{} = item) do
    store = push(store, item)
    insert_into_sequence(store, type_name, index, item.id)
  end

  @doc """
  Inserts an existing block's ID into a sequence at `index`. Used when
  a split introduces a new right-half block, or when reordering moves
  an existing item's slot.
  """
  def insert_into_sequence(%__MODULE__{} = store, type_name, index, id) do
    seq = Map.get(store.sequences, type_name, [])
    seq = List.insert_at(seq, index, id)
    %{store | sequences: Map.put(store.sequences, type_name, seq)}
  end

  @doc """
  Ensures `clock` is a block boundary within `client`'s bucket, then
  returns `{store, right_block_or_nil}`.

  Three outcomes:

    1. Client has no blocks → `{store, nil}`.
    2. `clock` is already a boundary (`item.id.clock == clock`) →
       `{store, item}`, no mutation.
    3. `clock` falls inside a block → `Item.split/2` partitions it into
       `[left, right]` in place; the tuple cache for that client is
       dropped (middle-of-list insert; no O(1) update path); and
       `right.id` is spliced into the sequence after `item.id` if the
       item appears there.

  `origin` / `right_origin` in `Yelixer.Item` reference whole-block
  boundaries, so a split is the prerequisite for anchoring a new YATA
  insertion at an interior clock.
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

            # Cache no longer mirrors the list; drop it for lazy rebuild.
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
  Returns all live (non-tombstoned) Items for `type_name` in document order.

  Resolves each ID in the sequence via the per-client index, then
  drops missing and tombstoned entries.
  """
  def get_sequence(%__MODULE__{} = store, type_name) do
    store.sequences
    |> Map.get(type_name, [])
    |> Enum.map(&get(store, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(& &1.deleted)
  end

  # Public binary-search hook for callers that hold a `[Item.t()]` list
  # directly (e.g. during integration, before results land in a store).
  # Materializes a one-shot tuple and delegates to the standard search.
  @doc false
  def find_block_index(blocks, clock) when is_list(blocks) do
    tuple = List.to_tuple(blocks)
    bsearch_index(tuple, clock)
  end

  # --- Internal helpers ---

  # Returns the cached tuple for `client`, building it lazily if absent.
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

  # Rebuilds the tuple cache for `client` from `clients[client]`.
  # External mutators that reshape a bucket directly (bypassing
  # `push/2` / `split_block/3`) must call this afterward.
  @doc false
  def refresh_tuple_cache(%__MODULE__{clients: clients, client_tuples: ct} = store, client) do
    case Map.get(clients, client) do
      nil ->
        %{store | client_tuples: Map.delete(ct, client)}

      blocks ->
        %{store | client_tuples: Map.put(ct, client, List.to_tuple(blocks))}
    end
  end

  # Drops the tuple cache for `client`. Cheaper than
  # `refresh_tuple_cache/2` when the next read will trigger a lazy
  # rebuild via `get_tuple/2` anyway.
  @doc false
  def invalidate_tuple_cache(%__MODULE__{client_tuples: ct} = store, client) do
    %{store | client_tuples: Map.delete(ct, client)}
  end

  # Binary-search the clock-sorted tuple for the block covering `clock`.
  # Uses inclusive bounds (`block_end = id.clock + length - 1`) —
  # same membership as the half-open range, one fewer subtraction.

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
