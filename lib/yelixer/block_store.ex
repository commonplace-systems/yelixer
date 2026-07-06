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
          sequence_len: %{String.t() => non_neg_integer()},
          map_index: %{String.t() => %{term() => [ID.t()]}},
          sequence_index: %{String.t() => %{ID.t() => non_neg_integer()}},
          sequence_positions: %{String.t() => %{non_neg_integer() => ID.t()}},
          deleted_overlay: %{non_neg_integer() => MapSet.t(non_neg_integer())}
        }
  defstruct clients: %{},
            sequences: %{},
            client_tuples: %{},
            client_pending: %{},
            sequence_pending: %{},
            sequence_len: %{},
            map_index: %{},
            sequence_index: %{},
            sequence_positions: %{},
            deleted_overlay: %{}

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
        apply_overlay(store, client, item)

      nil ->
        case get_tuple(store, client) do
          nil -> nil
          tuple -> tuple |> bsearch_item(clock) |> then(&(&1 && apply_overlay(store, client, &1)))
        end
    end
  end

  # CX-xes3 (E3): a block whose start clock is in `deleted_overlay`
  # reads as tombstoned even though the canonical list/tuple still
  # carries `deleted: false` — see `tombstone/3`'s moduledoc for why
  # tombstoning is deferred like this instead of mutating the list.
  defp apply_overlay(%__MODULE__{deleted_overlay: overlay}, client, %Item{deleted: false} = item) do
    case Map.get(overlay, client) do
      nil -> item
      clocks -> if MapSet.member?(clocks, item.id.clock), do: %{item | deleted: true}, else: item
    end
  end

  defp apply_overlay(_store, _client, item), do: item

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
  def client_blocks(%__MODULE__{clients: clients, client_pending: pending} = store, client) do
    case Map.get(store.deleted_overlay, client) do
      nil ->
        Map.get(clients, client, []) ++ pending_items(pending, client)

      overlay_clocks ->
        (Map.get(clients, client, []) ++ pending_items(pending, client))
        |> Enum.map(fn
          %Item{deleted: false} = item ->
            if MapSet.member?(overlay_clocks, item.id.clock), do: %{item | deleted: true}, else: item

          item ->
            item
        end)
    end
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
    pending = pending_items(store.client_pending, client)
    overlay = Map.get(store.deleted_overlay, client)

    if pending == [] and overlay == nil do
      store
    else
      base = Map.get(store.clients, client, []) ++ pending

      # CX-xes3 (E3): fold any deferred tombstones (`tombstone/3`) into
      # the canonical list now, since we're rebuilding it anyway — the
      # whole point of the overlay is to avoid this O(n) rewrite on
      # every single delete, not to avoid it forever.
      new_list =
        if overlay do
          Enum.map(base, fn
            %Item{deleted: false} = item ->
              if MapSet.member?(overlay, item.id.clock), do: %{item | deleted: true}, else: item

            item ->
              item
          end)
        else
          base
        end

      %{store |
        clients: Map.put(store.clients, client, new_list),
        client_pending: Map.delete(store.client_pending, client),
        client_tuples: Map.put(store.client_tuples, client, List.to_tuple(new_list)),
        deleted_overlay: Map.delete(store.deleted_overlay, client)
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
    # CX-xes3 (E3): a client can have deferred tombstones
    # (`deleted_overlay`) with no pending appends — `client_pending`
    # alone would miss it, leaving `store.clients` stale for any caller
    # (e.g. `Yelixer.Doc.gc/1`) that reads the canonical list directly
    # instead of going through `get/2` / `client_blocks/2`.
    clients_needing_materialize =
      MapSet.new(Map.keys(store.client_pending))
      |> MapSet.union(MapSet.new(Map.keys(store.deleted_overlay)))

    store =
      Enum.reduce(clients_needing_materialize, store, fn client, store ->
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
        |> extend_sequence_index(type_name, id, len)
      else
        store = materialize_sequence(store, type_name)
        seq = Map.get(store.sequences, type_name, [])
        seq = List.insert_at(seq, index, id)

        %{store | sequences: Map.put(store.sequences, type_name, seq)}
        |> invalidate_sequence_index(type_name)
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

        store = %{store | clients: clients, sequences: sequences, client_tuples: ct, sequence_len: sequence_len}
        # Splicing `right.id` in after `item.id` shifts every later
        # index — the cached reverse index (if any) is now stale.
        store = invalidate_sequence_index(store, type_name)
        {store, right}
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

  @doc """
  Returns `{next_clock, store}` where `next_clock` is the start clock
  of the first block for `client` at or after `at_least`, or `{nil,
  store}` if no such block exists.

  CX-wmtz (H2): `Yelixer.Encoding.apply_delete_range/4` calls this when
  it finds no block at the clock it's currently walking. Without it,
  a crafted delete-set range declaring a huge length over clocks that
  don't exist (e.g. a client that only ever wrote 3 items, with a
  delete range of length 10^12 starting at clock 1000) makes
  `apply_delete_range/4` recurse once per absent clock — unbounded CPU
  on any node that replays the update. This lets the caller jump
  straight to the next real block (or bail immediately if there is
  none), turning that walk into a single binary search.

  Materializes `client`'s bucket first (folding `client_pending` in),
  since the search needs the canonical sorted list; `apply_delete_range/4`
  already materializes before mutating; the returned `store` carries
  that fold forward so it isn't repeated.
  """
  @spec next_block_at_or_after(t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer() | nil, t()}
  def next_block_at_or_after(%__MODULE__{} = store, client, at_least) do
    store = materialize_client(store, client)
    blocks = Map.get(store.clients, client, [])

    case blocks do
      [] ->
        {nil, store}

      _ ->
        tuple = List.to_tuple(blocks)
        idx = first_index_at_or_after(tuple, at_least, 0, tuple_size(tuple) - 1, nil)

        case idx do
          nil -> {nil, store}
          idx -> {elem(tuple, idx).id.clock, store}
        end
    end
  end

  # Binary search for the leftmost index whose block start clock is
  # >= at_least (blocks are sorted ascending by start clock, per the
  # module's clients-bucket invariant).
  defp first_index_at_or_after(_tuple, _at_least, low, high, best) when low > high, do: best

  defp first_index_at_or_after(tuple, at_least, low, high, best) do
    mid = div(low + high, 2)
    start_clock = elem(tuple, mid).id.clock

    if start_clock >= at_least do
      first_index_at_or_after(tuple, at_least, low, mid - 1, mid)
    else
      first_index_at_or_after(tuple, at_least, mid + 1, high, best)
    end
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

  @doc """
  CX-xes3 (E3): marks the block at `id` deleted in O(log n) — O(1)
  `MapSet` insert into `deleted_overlay[id.client]` plus the `get/2`
  lookup to confirm the id resolves to a real, not-yet-deleted block —
  with NO list mutation and NO tuple-cache touch.

  This replaces the `materialize_client/2` + `List.replace_at/3` +
  `refresh_tuple_cache/2` (or `invalidate_tuple_cache/2`) pattern
  previously used by `Yelixer.Integrate.mark_deleted/2`,
  `Yelixer.Encoding`'s delete-range application, and map-conflict
  tombstoning. That pattern's `List.replace_at/3` is unavoidably O(n)
  — Erlang lists have no O(1) (or even O(log n)) point-mutation — so
  a client whose bucket accumulates many items (a single long-lived
  authoring session, or a replica walking a long history authored
  under one client id) pays O(n) for *every single delete*: O(n²) for
  n deletes against that client, no matter how cheap the tuple-cache
  refresh itself is made. Deferring the tombstone into an overlay
  (mirroring `client_pending`'s deferred-append strategy from CX-w1fw)
  turns that into O(log n) per delete; `materialize_client/2` folds
  the overlay into the canonical list — an O(n) rewrite — only when
  something *else* already needs the canonical list rebuilt (a split,
  or an explicit direct mutation), not once per delete.

  `get/2`, `client_blocks/2`, `all_items/1`, and `get_sequence/2` all
  see the tombstone immediately (they consult the overlay, or delegate
  to something that does) — from a caller's perspective this is
  indistinguishable from mutating the list directly; only the internal
  cost profile changes. Returns `store` unchanged if `id` doesn't
  resolve to a live block (mirrors the old code's `nil ->` no-op
  branches).
  """
  @spec tombstone(t(), ID.t()) :: t()
  def tombstone(%__MODULE__{} = store, %ID{client: client, clock: clock} = id) do
    case get(store, id) do
      nil ->
        store

      %Item{deleted: true} ->
        store

      %Item{} ->
        overlay = Map.update(store.deleted_overlay, client, MapSet.new([clock]), &MapSet.put(&1, clock))
        %{store | deleted_overlay: overlay}
    end
  end

  @doc """
  CX-xes3 (E4): per-`{type_key, parent_sub}` cache of the currently
  *live* item id(s) for a YMap key. Without this, resolving a map-key
  conflict (`Yelixer.Encoding.maybe_resolve_map_conflict/3`) has to
  walk the whole type's sequence with a `get/2` per element on every
  single map write — O(n) per write, O(k·n) for k writes to a
  map-heavy document (schemas, presence, per-entity status docs).

  Usually holds exactly one id (the current winner). Returns `nil`
  when the entry is unknown — either never populated, or deliberately
  dropped by `invalidate_map_index/2` after an edge case (a split
  touching a map item) that could have made a cached list stale. `nil`
  is the signal callers use to fall back to a one-time full scan,
  which repopulates the entry for subsequent writes to the same key.

  This is *derived* state: correctness never depends on it being
  present or fully accurate. A missing/stale entry costs a slow-path
  scan, not a wrong answer — see `invalidate_map_index/2`.
  """
  def map_live_ids(%__MODULE__{map_index: mi}, type_key, sub) do
    case Map.get(mi, type_key) do
      nil -> nil
      subs -> Map.get(subs, sub)
    end
  end

  @doc """
  Records `ids` as the live item id(s) for `{type_key, sub}`. Called
  after conflict resolution settles on a winner (and tombstones the
  losers), so the next write to the same key finds a populated entry
  and skips the full-sequence scan.
  """
  def put_map_live_ids(%__MODULE__{map_index: mi} = store, type_key, sub, ids) do
    subs = Map.get(mi, type_key, %{})
    %{store | map_index: Map.put(mi, type_key, Map.put(subs, sub, ids))}
  end

  @doc """
  Drops the entire live-id index for `type_key` — every key's cached
  entry, not just one. Used wherever a map item gets tombstoned or
  reshaped through a path that doesn't itself maintain the index (the
  generic delete-set walk in `Yelixer.Encoding.apply_delete_range/4`,
  a mid-block split of a map item). Conservative: the next map write
  under this `type_key` pays for one full-sequence scan to rebuild
  the entry it needs, but every entry stays correct.
  """
  def invalidate_map_index(%__MODULE__{map_index: mi} = store, type_key) do
    %{store | map_index: Map.delete(mi, type_key)}
  end

  @doc """
  Drops just `{type_key, sub}`'s cached live-id list, leaving every
  other key under `type_key` untouched.

  CX-xes3 (E4): the generic delete-set path (`Yelixer.Encoding`'s
  `mark_item_deleted/3`, driven by `apply_delete_range/4`) can tombstone
  a map item outside `maybe_resolve_map_conflict/3`'s own bookkeeping
  — e.g. `YMap.delete/3`'s standalone deletion. It needs to invalidate
  *something* defensively for correctness, but `invalidate_map_index/2`
  (whole `type_key`) is far too broad: a `YMap` with several keys
  shares one `type_key`, and EVERY write encodes a delete-range for the
  key's own previous value (see `YMap.set/4`) — so wiping the whole
  `type_key` on every delete throws away the entry
  `maybe_resolve_map_conflict/3` just correctly populated for every
  OTHER key changed in the same batch (items integrate before the
  delete set applies — see `integrate_batch/3` — so by the time a
  delete lands, later writes to other keys have already updated their
  own entries). That reintroduces the full-scan cost on every write to
  a multi-key map — exactly the O(n) per-write blowup this issue set
  out to remove.
  """
  def invalidate_map_index_key(%__MODULE__{map_index: mi} = store, type_key, sub) do
    case Map.get(mi, type_key) do
      nil -> store
      subs -> %{store | map_index: Map.put(mi, type_key, Map.delete(subs, sub))}
    end
  end

  @doc """
  CX-xes3 (E4/YATA): returns `{index_or_nil, store}` — the position of
  block-start id `id` within `type_name`'s materialized sequence, and
  the (possibly newly-cached) store.

  This is the position lookup `Yelixer.Integrate.find_insertion_index/3`
  needs to bracket its two-set conflict scan around `origin` /
  `right_origin`. Before this cache, `Integrate`'s `find_id_index/3`
  did an `Enum.find_index/2` over the *entire* sequence — with a
  `BlockStore.get/2` per element — every single time an item's anchor
  wasn't the sequence's immediate last element. That's the overwhelming
  common case for `YMap` writes: a `set/3` anchors its item's `origin`
  at the *previous write to the same key*, which sits a few slots
  behind the sequence's true last element (other keys' writes
  interleave in between) — never the fast-append shape. The result
  was an O(n) scan on every map write to a long-lived document
  (schemas, presence, per-entity status: exactly the shape that
  stalled a real replay for hours — see the CX-xes3 issue).

  Builds the reverse map (`id -> index`) once per `type_name`, lazily,
  from the already-materialized `sequences[type_name]` — callers here
  always materialize first (see `find_insertion_index/3`). Kept valid
  across pure appends by `extend_sequence_index/3` (O(1) per append);
  dropped by `invalidate_sequence_index/2` wherever something splices
  into the *middle* of the sequence (a mid-history insert, a block
  split introducing a new id after an existing one), since that shifts
  every later index and increment-in-place would cost as much as a
  rebuild anyway.
  """
  @spec sequence_index_of(t(), String.t(), ID.t()) :: {non_neg_integer() | nil, t()}
  def sequence_index_of(%__MODULE__{} = store, type_name, %ID{} = id) do
    store = ensure_sequence_index(store, type_name)
    idx_map = Map.get(store.sequence_index, type_name, %{})
    {Map.get(idx_map, id), store}
  end

  @doc """
  CX-xes3 (YATA): the companion lookup to `sequence_index_of/3` — id
  at a given position instead of position of a given id. Used by
  `Yelixer.Integrate`'s two-set conflict scan to read the sequence
  entry at each scanned index.

  Before this, the scan converted the *entire* materialized
  `sequences[type_name]` list to a tuple on every call
  (`List.to_tuple/1`, O(n)) just to get O(1) access to a handful of
  slots inside a small bracket — same asymptotic cost as the O(n) scan
  it replaced, just moved. This shares the same lazily-built,
  incrementally-extended cache as `sequence_index_of/3` (built
  together in one pass), so repeat calls for the same `type_name`
  (the common case — one two-set scan makes several) are O(log n)
  map lookups, and the O(n) build cost is paid at most once per
  `type_name` between invalidations.
  """
  @spec sequence_id_at(t(), String.t(), non_neg_integer()) :: {ID.t() | nil, t()}
  def sequence_id_at(%__MODULE__{} = store, type_name, index) when is_integer(index) do
    store = ensure_sequence_index(store, type_name)
    pos_map = Map.get(store.sequence_positions, type_name, %{})
    {Map.get(pos_map, index), store}
  end

  # Builds both directions of the cache together from
  # `sequences[type_name]` (already materialized by callers) if
  # neither has been built yet since the last invalidation.
  defp ensure_sequence_index(%__MODULE__{sequence_index: si, sequence_positions: sp} = store, type_name) do
    if Map.has_key?(si, type_name) do
      store
    else
      seq = Map.get(store.sequences, type_name, [])

      {idx_map, pos_map} =
        seq
        |> Enum.with_index()
        |> Enum.reduce({%{}, %{}}, fn {seq_id, idx}, {idx_acc, pos_acc} ->
          {Map.put(idx_acc, seq_id, idx), Map.put(pos_acc, idx, seq_id)}
        end)

      %{store |
        sequence_index: Map.put(si, type_name, idx_map),
        sequence_positions: Map.put(sp, type_name, pos_map)
      }
    end
  end

  # O(1) incremental extension of the cached reverse index (both
  # directions) when a new id is appended at the sequence's current
  # end. No-op if the cache for `type_name` hasn't been built yet —
  # it'll pick up this id (and everything else) the next time
  # `sequence_index_of/3` or `sequence_id_at/3` builds it from
  # `sequences[type_name]`.
  @doc false
  def extend_sequence_index(%__MODULE__{sequence_index: si, sequence_positions: sp} = store, type_name, id, at_index) do
    case Map.get(si, type_name) do
      nil ->
        store

      idx_map ->
        pos_map = Map.get(sp, type_name, %{})

        %{store |
          sequence_index: Map.put(si, type_name, Map.put(idx_map, id, at_index)),
          sequence_positions: Map.put(sp, type_name, Map.put(pos_map, at_index, id))
        }
    end
  end

  # Drops the cached reverse index (both directions) for `type_name`.
  # Required before any mutation that inserts into the MIDDLE of
  # `sequences[type_name]` (shifting every later element's index) —
  # the append path (`extend_sequence_index/4`) is the only mutation
  # cheap enough to maintain incrementally.
  @doc false
  def invalidate_sequence_index(%__MODULE__{sequence_index: si, sequence_positions: sp} = store, type_name) do
    %{store | sequence_index: Map.delete(si, type_name), sequence_positions: Map.delete(sp, type_name)}
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
