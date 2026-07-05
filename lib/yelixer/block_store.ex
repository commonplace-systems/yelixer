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

  Historical note (CX-w1fw): an earlier version of this moduledoc
  claimed `:erlang.append_element/2` was "the only O(1) Erlang tuple
  mutation" and used it in `push/2` to extend the cache on every
  write. That claim is false — `append_element/2` allocates a new
  tuple and copies all N existing elements, same as
  `Tuple.append/2` or rebuilding from a list. There is no O(1) tuple
  mutation in Erlang; tuples are fixed-size and immutable. Calling
  `append_element/2` once per push made every push O(n), which is
  exactly the O(n²) replay pattern this rewrite removes. `push/2` no
  longer touches the tuple cache at all — see "Deferred writes" below.

  Lists are the source of truth; tuples are a read-side optimization.

  ## Deferred writes (CX-w1fw)

  `clients[c]` and `sequences[name]` remain forward-order lists at
  rest — external readers (tests, the LWW-loss auditor, CLI inspect,
  snapshotters) still see plain `[Item.t()]` / `[ID.t()]` values with
  the same shape as before. But an Elixir list cannot support cheap
  tail-append without breaking that shape (appending copies the
  spine), so writes are buffered instead:

    - `push/2` puts the new item into `client_pending[c]`, a
      `:gb_trees` tree keyed by *negated* start clock. Insert is
      O(log k) in the pending count; keying by `-clock` makes
      "largest start clock ≤ target" (the floor query `get/2` needs)
      expressible as `:gb_trees.iterator_from/2`, and makes
      `:gb_trees.smallest/1` the newest block (the `state_vector/1`
      high-water mark).
    - The tail-append path of `insert_into_sequence/4` conses onto
      `sequence_pending[name]`, a reverse-order list, O(1). Sequences
      never need clock search — only append and whole-list reads.
    - `sequence_len` tracks the logical total sequence length
      (materialized + pending) in O(1) so append detection and
      `find_insertion_index`'s end-of-sequence case never call
      `length/1` on a list.

  Pending entries are folded into the canonical lists — "materialized"
  — lazily:

    - `client_blocks/2`, `all_items/1`, `get_sequence/2` compute a
      materialized *view* on demand without persisting it (cheap
      relative to their existing O(n) cost; they're not called per
      integrated item).
    - Any path that *mutates* `clients[c]` or `sequences[name]`
      directly (`split_block/3`, `mark_deleted/2`, delete-range
      splitting) calls `materialize_client/2` / `materialize_sequence/2`
      first, which folds pending in, rebuilds the tuple cache, and
      clears the pending buffer — so a later direct read of `clients`
      never races with a stale pending copy.
    - `get/2` does an O(log k) floor lookup in `client_pending[c]`
      before the tuple, so the hot path (an item's own most recent
      block, which is where YATA anchors it during append-heavy
      replay) never touches the tuple or the canonical list — and
      cold lookups deep inside an unmaterialized bucket stay
      sub-linear too.

  The upshot: appending N items to one client/sequence in a replay
  loop costs O(log N) each, not O(N) each — the tuple cache and
  canonical lists get rebuilt once, lazily, the first time something
  needs them (typically once, at the end of a whole replay), rather
  than once per item.

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
          client_tuples: %{non_neg_integer() => tuple()},
          client_pending: %{non_neg_integer() => :gb_trees.tree(integer(), Item.t())},
          sequence_pending: %{String.t() => [ID.t()]},
          sequence_len: %{String.t() => non_neg_integer()}
        }
  defstruct clients: %{},
            sequences: %{},
            client_tuples: %{},
            client_pending: %{},
            sequence_pending: %{},
            sequence_len: %{}

  @doc "An empty BlockStore — no clients, no sequences, no cached tuples."
  def new, do: %__MODULE__{}

  @doc """
  Appends `item` to its client's bucket, O(log k) in the client's
  pending count.

  Integration produces Items in clock order per client, so the new
  item's clock always exceeds every existing block in the bucket.
  Rather than copying `clients[client]` (and rebuilding the tuple
  cache) on every push, the item goes into `client_pending[client]` —
  a `:gb_trees` tree keyed by negated start clock — and is folded into
  the canonical list lazily. See the moduledoc's "Deferred writes"
  section.
  """
  def push(%__MODULE__{client_pending: pending} = store, %Item{} = item) do
    client = item.id.client
    tree = Map.get(pending, client) || :gb_trees.empty()
    tree = :gb_trees.enter(-item.id.clock, item, tree)
    %{store | client_pending: Map.put(pending, client, tree)}
  end

  @doc """
  Identity lookup: returns the Item covering `(client, clock)`, or
  `nil` if no block in the client's bucket spans that clock.

  The clock need not be a block boundary — it may fall inside a
  multi-clock run-length block, and the containing block is returned.
  Callers that need `id.clock == clock` exactly (e.g. to anchor at
  an interior boundary) should call `split_block/3` first.

  Does an O(log k) floor lookup in `client_pending[client]` (most
  recently pushed items, unmaterialized) before falling back to the
  tuple-cache binary search. During append-heavy replay the queried id
  is almost always the client's own last-pushed item, so the pending
  tree resolves it without ever touching the canonical list.
  """
  def get(%__MODULE__{} = store, %ID{client: client, clock: clock}) do
    case pending_floor(store.client_pending, client, clock) do
      %Item{} = item ->
        item

      nil ->
        case get_tuple(store, client) do
          nil -> nil
          tuple -> bsearch_item(tuple, clock)
        end
    end
  end

  # Floor query on the pending tree: the pending block with the
  # largest start clock <= `clock`, if it covers `clock`. Keys are
  # negated clocks, so `iterator_from(-clock)` positions at the first
  # key >= -clock — i.e. the first start clock <= clock. Blocks never
  # overlap, so if that block doesn't cover the clock, nothing in
  # pending does.
  defp pending_floor(pending, client, clock) do
    case Map.get(pending, client) do
      nil ->
        nil

      tree ->
        case :gb_trees.next(:gb_trees.iterator_from(-clock, tree)) do
          {_key, %Item{} = item, _iter} -> if covers?(item, clock), do: item, else: nil
          :none -> nil
        end
    end
  end

  defp covers?(%Item{id: %ID{clock: c}, length: len}, clock), do: clock >= c and clock < c + len

  # Pending items for a client in ascending clock order (tree values
  # come out ascending by key = descending clock; reverse them).
  defp pending_items(pending, client) do
    case Map.get(pending, client) do
      nil -> []
      tree -> tree |> :gb_trees.values() |> Enum.reverse()
    end
  end

  @doc """
  Returns the full list of blocks for a client (or `[]` if none) in
  clock order.

  A read-only *materialized view*: folds `client_pending[client]` onto
  `clients[client]` without persisting the fold. Callers that need to
  mutate the client's bucket (`split_block/3`, `mark_deleted/2`, delete
  splitting) must call `materialize_client/2` instead so the fold is
  persisted and the pending buffer is cleared before they write.
  """
  def client_blocks(%__MODULE__{clients: clients, client_pending: pending}, client) do
    Map.get(clients, client, []) ++ pending_items(pending, client)
  end

  @doc """
  Returns every client id with at least one block — materialized or
  still pending. `Map.keys(store.clients)` alone would miss clients
  whose only blocks haven't been folded in yet.
  """
  def client_ids(%__MODULE__{clients: clients, client_pending: pending}) do
    clients
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(MapSet.new(Map.keys(pending)))
    |> MapSet.to_list()
  end

  @doc """
  Returns every Item across every client, materialized-view (read-only).

  Order is by ascending client id, then clock within a client; callers
  that don't care about client order (attribute scans, LWW auditors)
  can treat this as an unordered bag, matching the unspecified
  Map-iteration order the pre-CX-w1fw code relied on.
  """
  def all_items(%__MODULE__{} = store) do
    store |> client_ids() |> Enum.sort() |> Enum.flat_map(&client_blocks(store, &1))
  end

  @doc """
  Folds `client_pending[client]` into `clients[client]` and rebuilds
  the tuple cache, clearing the pending buffer. No-op (returns `store`
  unchanged) if there's nothing pending.

  Required before any direct mutation of `clients[client]` (e.g.
  `List.replace_at/3`, `List.insert_at/3`) — those paths need the
  canonical list to already include every pushed item, and need the
  pending buffer cleared so a later `get/2` doesn't resurrect a
  pre-mutation copy from pending.
  """
  def materialize_client(%__MODULE__{} = store, client) do
    case pending_items(store.client_pending, client) do
      [] ->
        store

      new_items ->
        new_list = Map.get(store.clients, client, []) ++ new_items

        %{store |
          clients: Map.put(store.clients, client, new_list),
          client_pending: Map.delete(store.client_pending, client),
          client_tuples: Map.put(store.client_tuples, client, List.to_tuple(new_list))
        }
    end
  end

  @doc """
  Folds `sequence_pending[type_name]` into `sequences[type_name]`,
  clearing the pending buffer. No-op if nothing pending. Required
  before any direct read or mutation of `sequences[type_name]` that
  doesn't go through `insert_into_sequence/4` (e.g. `split_block/3`'s
  splice, `Encoding`'s delete-range splitting).
  """
  def materialize_sequence(%__MODULE__{} = store, type_name) do
    case Map.get(store.sequence_pending, type_name) do
      pending when pending in [nil, []] ->
        store

      pending ->
        new_ids = Enum.reverse(pending)
        new_seq = Map.get(store.sequences, type_name, []) ++ new_ids

        %{store |
          sequences: Map.put(store.sequences, type_name, new_seq),
          sequence_pending: Map.delete(store.sequence_pending, type_name)
        }
    end
  end

  @doc """
  Materializes every pending sequence (all type names). Used by
  operations that scan every sequence for an id's position (e.g.
  `Yelixer.Encoding`'s delete-range splitting, which doesn't know in
  advance which type an item belongs to).
  """
  def materialize_all_sequences(%__MODULE__{} = store) do
    Enum.reduce(Map.keys(store.sequence_pending), store, fn type_name, store ->
      materialize_sequence(store, type_name)
    end)
  end

  @doc """
  Materializes every pending client bucket and every pending sequence.
  Used by whole-store operations that already touch everything, e.g.
  `Yelixer.Doc.gc/1`.
  """
  def materialize_all(%__MODULE__{} = store) do
    store =
      Enum.reduce(Map.keys(store.client_pending), store, fn client, store ->
        materialize_client(store, client)
      end)

    materialize_all_sequences(store)
  end

  @doc """
  Logical length of `type_name`'s sequence — materialized plus
  pending — in O(1). Replaces `length(seq_ids)` on the hot path in
  `Yelixer.Integrate.find_insertion_index/3`.
  """
  def sequence_length(%__MODULE__{sequence_len: lens}, type_name) do
    Map.get(lens, type_name, 0)
  end

  @doc """
  Returns the ID of the logically-last element of `type_name`'s
  sequence (materialized or still pending), or `nil` if empty.
  """
  def last_sequence_id(%__MODULE__{} = store, type_name) do
    case Map.get(store.sequence_pending, type_name) do
      [id | _] ->
        id

      _ ->
        case Map.get(store.sequences, type_name) do
          nil -> nil
          [] -> nil
          list -> List.last(list)
        end
    end
  end

  @doc """
  Derives a `Yelixer.StateVector` from the current store contents.

  For each client, the high-water mark is `last_block.id.clock + length`
  — the next unused clock, per `StateVector`'s contract. Clients absent
  from `clients` (and from `client_pending`) produce no entry; the
  state vector defaults to 0 for unknown clients.

  Reads `client_pending` alongside `clients` so this stays correct
  without forcing a materialize: the pending tree's smallest key
  (most-negated clock) — when present — is always the highest-clock
  item for that client, same information `List.last(clients[client])`
  would give if it had been materialized. This function is called once
  per `Yelixer.Encoding.apply_update/2`, so keeping it O(#clients)
  instead of O(#clients + a materialize) matters for replay.
  """
  def state_vector(%__MODULE__{} = store) do
    Enum.reduce(client_ids(store), StateVector.new(), fn client, sv ->
      case last_client_item(store, client) do
        nil -> sv
        %Item{id: id, length: len} -> StateVector.set(sv, client, id.clock + len)
      end
    end)
  end

  defp last_client_item(store, client) do
    case Map.get(store.client_pending, client) do
      nil ->
        List.last(Map.get(store.clients, client, []))

      tree ->
        {_key, item} = :gb_trees.smallest(tree)
        item
    end
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

  When `index` is exactly the sequence's current logical length (the
  overwhelmingly common case for append-heavy replay — YATA anchors a
  new item after the client's own last block), this is O(1): the id is
  consed onto `sequence_pending[type_name]` rather than spliced into
  the materialized list with `List.insert_at/3` (O(index), i.e. O(n)
  for an append). Any other index materializes pending first, then
  inserts normally — mid-sequence inserts are the concurrent-edit case
  this rewrite doesn't need to special-case.
  """
  def insert_into_sequence(%__MODULE__{} = store, type_name, index, id) do
    len = sequence_length(store, type_name)

    store =
      if index == len do
        pending = [id | Map.get(store.sequence_pending, type_name, [])]
        %{store | sequence_pending: Map.put(store.sequence_pending, type_name, pending)}
      else
        store = materialize_sequence(store, type_name)
        seq = Map.get(store.sequences, type_name, [])
        seq = List.insert_at(seq, index, id)
        %{store | sequences: Map.put(store.sequences, type_name, seq)}
      end

    %{store | sequence_len: Map.put(store.sequence_len, type_name, len + 1)}
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
  def split_block(%__MODULE__{} = store, %ID{client: client, clock: clock} = id, type_name) do
    # get/2 checks client_pending first, so this doesn't force a
    # materialize for the common "already a boundary" no-op case (the
    # last item pushed for `client`, still pending, exactly on a
    # boundary — true for every single-char append). Only the actual
    # split branch below needs the canonical, mutable list.
    case get(store, id) do
      nil ->
        {store, nil}

      %Item{id: %ID{clock: item_clock}} = item when item_clock == clock ->
        # Already on a boundary; nothing to do.
        {store, item}

      _found ->
        store = materialize_client(store, client)
        store = materialize_sequence(store, type_name)

        tuple = get_tuple(store, client)
        {idx, item} = bsearch_index(tuple, clock)
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

        {sequences, sequence_len} =
          case Map.get(store.sequences, type_name) do
            nil ->
              {store.sequences, store.sequence_len}

            seq ->
              seq_idx = Enum.find_index(seq, &(&1 == item.id))

              if seq_idx != nil do
                new_seq = List.insert_at(seq, seq_idx + 1, right.id)
                new_len = Map.update(store.sequence_len, type_name, 1, &(&1 + 1))
                {Map.put(store.sequences, type_name, new_seq), new_len}
              else
                {store.sequences, store.sequence_len}
              end
          end

        {%{store | clients: clients, sequences: sequences, client_tuples: ct, sequence_len: sequence_len}, right}
    end
  end

  @doc """
  Returns all live (non-tombstoned) Items for `type_name` in document order.

  Resolves each ID in the sequence via the per-client index, then
  drops missing and tombstoned entries. Reads a materialized *view* of
  the sequence (pending ids folded in without persisting) so a caller
  mid-replay always sees every item integrated so far.
  """
  def get_sequence(%__MODULE__{} = store, type_name) do
    sequence_view(store, type_name)
    |> Enum.map(&get(store, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(& &1.deleted)
  end

  defp sequence_view(%__MODULE__{} = store, type_name) do
    base = Map.get(store.sequences, type_name, [])
    pending = Map.get(store.sequence_pending, type_name, [])
    base ++ Enum.reverse(pending)
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
