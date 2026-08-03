defmodule Yelixer.Doc do
  @moduledoc """
  Top-level container for a Yjs document replica.

  A `Doc` holds five fields: `client_id` (this replica's integer
  identity), `store` (the YATA block store — see `Yelixer.BlockStore`),
  `delete_set` (the tombstone index — see `Yelixer.DeleteSet`), `types`
  (a registry of named top-level types), and `client_namespaces` (a
  provenance cache used by the namespace-aware `apply_update` path).
  All operations — edits, remote updates, encoding, GC — reach these
  fields through the modules that own each concern; `Doc` itself is
  passive.

  ## Lifecycle

  - **`new/1`** — allocate a fresh replica. A random `client_id` is
    chosen unless one is supplied. Store, delete set, and type
    registry all start empty.
  - **Local edits** — go through the type facades, not `Doc`
    directly. `Yelixer.Types.Text.insert(doc, name, index, text)`,
    `YMap.set(doc, name, key, value)`, etc. Each call returns an
    updated `%Doc{}`.
  - **Remote update** — `Yelixer.Encoding.apply_update(doc, binary)`
    decodes the wire bytes, integrates each item via
    `Yelixer.Integrate.integrate/3`, applies deletions, and merges
    tombstones into `doc.delete_set` so the receiver can re-broadcast
    them.
  - **Encoding** — `Yelixer.Encoding.encode_update(doc)` for the full
    state; `encode_diff(doc, remote_sv)` for the slice a peer is
    missing.
  - **Maintenance** — `gc/1` strips content from tombstoned items
    (see GC section below); `snapshot_update/1` rebuilds the doc's
    observable state under a single `client_id`, used by the
    compaction primitive (CX-u7p) to shrink long-lived docs that have
    accumulated many authors.

  ## Named-type roots

  `types :: %{name => type_ref}` is the lookup table for top-level
  CRDT types. A *named-type root* is a string-addressed entry point
  into the document tree. Every `Item` carries a `parent` field
  pointing either to a root (`{:named, name}`) or to another item's
  id (`{:id, parent_id}`); roots are reachable by name from outside
  the doc, while nested items are reachable only by walking from a
  root.

  `get_or_create_type/3` is the registration entry point. It binds a
  string name to a *type ref* — one of `:text`, `:map`, `:array`,
  `:xml_fragment`, `{:xml_element, tag}`, or `:xml_text` — and
  returns the binding. First-caller-wins: a second call with the same
  name and a different ref is a no-op; the original ref is returned.
  Type facades (`Text`, `YMap`, `Array`, the XML modules) call
  `get_or_create_type/3` on every operation, so callers can address
  types by name without registering them explicitly.

  ## Client-id assignment

  `client_id` is an integer assigned once per `Doc` instance. Two
  invariants must hold:

    - **Unique per live replica.** Two replicas of the same logical
      document must not share a `client_id`; their independent
      per-client clocks would produce colliding item IDs.
    - **Stable across the doc's lifetime.** Every local edit uses the
      same `client_id`. A process restart means a fresh `client_id`
      — a new replica identity — unless the caller passes the
      previous value into `new/1`.

  The default, `:rand.uniform(1_000_000_000)`, makes collisions
  between live peers vanishingly rare. Callers that need persistence
  across restarts (workspace nodes, presence docs) supply a stored id
  via `new(client_id: persistent_id)`.

  ## What this module is NOT

  `Doc` is a passive struct. The work lives in the modules that
  accept it as an argument:

    - **Local mutations** — type modules (`Yelixer.Types.Text`,
      `YMap`, `Array`, `XMLFragment`, `XMLElement`, `XMLText`). They
      read and write `doc.store`; `Doc` just carries it.
    - **Wire encoding/decoding** — `Yelixer.Encoding`. `apply_update`
      is the only path that introduces remote-originated content into
      a `Doc`.
    - **YATA insertion placement** — `Yelixer.Integrate`. `Doc` holds
      the sequences; it never decides where items land.
    - **Block storage** — `Yelixer.BlockStore`, at `doc.store`.
    - **Tombstone tracking** — `Yelixer.DeleteSet`, at
      `doc.delete_set`.
  """

  alias Yelixer.{BlockStore, DeleteSet, Item, StateVector}
  alias Yelixer.Types.{YMap, Text, Array, XMLFragment, XMLElement, XMLText}

  @type t :: %__MODULE__{
          client_id: non_neg_integer(),
          store: BlockStore.t(),
          delete_set: DeleteSet.t(),
          types: %{String.t() => atom()},
          client_namespaces: %{non_neg_integer() => binary()},
          pending: [binary()],
          pending_bytes: non_neg_integer(),
          clock_floor: non_neg_integer()
        }

  defstruct [:client_id, :store, :delete_set, :types,
             client_namespaces: %{}, pending: [], pending_bytes: 0, clock_floor: 0]

  @doc """
  Allocates a fresh document replica.

  Pass `client_id: integer` to fix the replica's identity — necessary
  when a workspace node or presence doc must survive restarts. Without
  it, a random integer in the billion-element range is chosen;
  collisions between live peers are vanishingly rare.

  Pass `clock_floor: n` to force this replica's own mint clock to start
  no lower than `n` (default `0`, meaning "use the store's own state
  vector clock" — the historical behavior). See `mint_clock/1` for the
  mechanics and the CX-b0ow.9 usage contract below.

  Store, delete set, and type registry all start empty. Type facades
  register types lazily on first use.

  ## The `clock_floor` usage contract

  `clock_floor` exists for **derived/throwaway replicas** reconstructed
  at a past point in a chain (e.g. `DocBuilder.reconstruct_doc_at/3`)
  under a *reused* `client_id` (a bridge's stable writer hand) that may
  have minted further ops later in the chain, past the reconstruction
  point. Without a floor, new local mints on the replica would restart
  at the replica's local (stale) state-vector clock and collide with
  — silently duplicate — those later ops' `(client, clock)` ids once
  both are seen by a peer that has the full chain.

  The floor sidesteps that by forcing new mints to start at
  `max(local_sv_clock, clock_floor)` (see `mint_clock/1`), typically set
  to the writer hand's clock at `:latest` before replaying forward from
  the anchor.

  **This is only safe when the replica's output is diff-encoded, never
  shipped whole.** A floored doc's FULL state (`Encoding.encode_update/1`)
  must never be sent as an update to a peer that lacks the gap blocks
  between the replica's own last-known op and `clock_floor` — the
  receiver has no way to know those clocks are intentionally absent, and
  would buffer everything past the gap in its pending buffer forever
  (see the `pending_info/1` moduledoc). Callers must instead compute
  `Yelixer.Encoding.encode_diff(replica, pre_edit_state_vector)` — which
  contains only the newly minted blocks (plus the delete set, safe to
  re-apply) — and apply that diff to a doc that DOES own the gap range
  (e.g. the chain's `:latest` reconstruction). See
  `Commonplace.GitBridge.Inbound` for the concrete flow this backs.

  Floors are purely local bookkeeping: nothing about the wire format
  changes, and non-floored docs (`clock_floor: 0`, the default) are
  byte-for-byte unaffected — `mint_clock/1` degrades to the historical
  `StateVector.get(...)` read whenever the local clock is already `>=`
  the floor, which is always true when the floor is `0`.
  """
  def new(opts \\ []) do
    client_id = Keyword.get(opts, :client_id, :rand.uniform(1_000_000_000))
    clock_floor = Keyword.get(opts, :clock_floor, 0)

    %__MODULE__{
      client_id: client_id,
      store: BlockStore.new(),
      delete_set: DeleteSet.new(),
      types: %{},
      client_namespaces: %{},
      pending: [],
      pending_bytes: 0,
      clock_floor: clock_floor
    }
  end

  @doc """
  Returns the clock this doc's `client_id` should use for its NEXT
  locally-minted item.

  Centralizes the mint-clock read that every type module (`Text`,
  `YMap`, `Array`, the XML modules) previously performed inline as
  `StateVector.get(BlockStore.state_vector(store), doc.client_id)`.
  Returns `max(local_state_vector_clock, doc.clock_floor)` — a pure
  refactor for non-floored docs (`clock_floor` defaults to `0`, and
  `max(n, 0) == n` for any `n >= 0`), and the floor-respecting behavior
  described in `new/1`'s moduledoc for floored replicas.
  """
  @spec mint_clock(t()) :: non_neg_integer()
  def mint_clock(%__MODULE__{store: store, client_id: client_id, clock_floor: floor}) do
    max(StateVector.get(BlockStore.state_vector(store), client_id), floor)
  end

  @doc """
  Observability-only view of the bounded pending buffer (H1 — CX-cdyi).

  `apply_update/2` never lets an un-integratable update binary poison
  the store: when a batch ends with items that still can't integrate
  (a missing origin/right_origin dependency), the ORIGINAL update
  binary is buffered in `doc.pending` rather than being pushed into
  the block store without sequence integration. Because `pending` is
  never consulted by `encode_update`/`encode_diff`/the derived state
  vector, its contents are excluded from every wire-visible view of
  the doc *by construction* — this exclusion is required for the
  same-content-same-bytes property (two replicas that received the
  same content in different orders must emit identical bytes), not an
  optimization.

  Buffered blobs are retried on every subsequent `apply_update/2` call
  (level-triggered — new data is the only wake-up this layer needs) and
  are removed once they fully integrate or their remainder becomes
  fully-known. A blob whose dependency never arrives stays here
  indefinitely; that's a re-request opportunity for upper layers
  (commit replay, federation catch-up), not a bug at this layer.

  Returns `%{count: non_neg_integer(), bytes: non_neg_integer()}`.

  ## Forward-only migration

  Docs that accumulated orphan items under the pre-H1 behavior (items
  pushed into the store without sequence integration, state vector
  advanced past them) are NOT repaired by this change — the poisoning
  is already baked into their store. A detector (store items whose
  clocks appear in no sequence) could identify such docs later if a
  real artifact surfaces; per the LWW-audit precedent, writing one
  speculatively isn't justified by dev data alone.
  """
  @spec pending_info(t()) :: %{count: non_neg_integer(), bytes: non_neg_integer()}
  def pending_info(%__MODULE__{pending: pending, pending_bytes: bytes}) do
    %{count: length(pending), bytes: bytes}
  end

  @doc """
  CX-4l7u: O(1) test whether `client_id` was first observed under
  `namespace_hash` on this doc.

  ## Why this exists

  Yjs `client_id`s are random integers. With many replicas the same
  integer can be reused by an unrelated replica later. Systems that
  care about authorship — presence docs receiving heartbeats from one
  logical client via multiple physical servers; schema docs where
  provenance drives routing — need a stable answer to "which namespace
  first produced this client_id?"

  `client_namespaces` is that index. Populated by
  `Yelixer.Encoding.apply_update_in_namespace/3` (plain `apply_update/2`
  does not touch it), it records the namespace that first introduced
  each `client_id` and never overwrites that binding. First-writer-wins:
  a later update carrying the same `client_id` under a different
  namespace cannot displace the original record.

  This function is the read side: given a `client_id` and a candidate
  namespace, returns `true` if that was the namespace it was first seen
  under. Used by routing code that forwards only namespace-authentic
  items.
  """
  @spec clientID_in_namespace?(t(), non_neg_integer(), binary()) :: boolean()
  def clientID_in_namespace?(%__MODULE__{client_namespaces: ns}, client_id, namespace_hash) do
    Map.get(ns, client_id) == namespace_hash
  end

  @doc "Returns `true` if `name` is registered as a top-level type."
  def has_type?(%__MODULE__{types: types}, name), do: Map.has_key?(types, name)

  @doc """
  Returns this doc's state vector — the per-`client_id` map of "highest
  clock seen" that summarizes what content the doc holds without
  encoding the content itself.

  Thin delegate to `Yelixer.BlockStore.state_vector/1`. This is the
  consumer-facing accessor: callers outside the library should reach
  for `Doc.state_vector(doc)` rather than poking through the `store`
  field directly (`BlockStore.state_vector(doc.store)`), which leaks
  `Doc`'s internal field layout across the library boundary.
  """
  @spec state_vector(t()) :: StateVector.t()
  def state_vector(%__MODULE__{store: store}), do: BlockStore.state_vector(store)

  @doc """
  Returns the synthetic names of CRDT sub-types nested inside maps and
  arrays — the `"__sub:CLIENT:CLOCK"`-keyed types that `snapshot_update/1`
  does **not** replay structurally (`replay_named_type/3` short-circuits on
  the `__sub:` prefix). Each such type's internal CRDT state is therefore
  dropped on snapshot/compaction.

  An empty list means the doc is safe to snapshot without losing nested
  state. XML sub-types are *excluded* — they use `"::child::"` naming and
  are replayed structurally via the `replay_xml_*` helpers.

  Callers that compact docs (e.g. `Commonplace.Store.Snapshotter`) use this
  to refuse a lossy snapshot rather than silently discarding the nested
  CRDT, converting a delayed data-loss trap into a visible no-op.
  """
  @spec nested_subtype_names(t()) :: [String.t()]
  def nested_subtype_names(%__MODULE__{types: types}) do
    types
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, "__sub:"))
  end

  @doc """
  Looks up or registers a named top-level type. Returns
  `{doc, type_ref}`.

  If `name` is already registered, the original type ref is returned
  unchanged and `doc` is not modified. Registering a different
  `type_ref` against an existing name is a no-op. Type facades call
  this on every operation, so most callers never need it directly.
  """
  def get_or_create_type(%__MODULE__{types: types} = doc, name, type_ref) do
    if Map.has_key?(types, name) do
      {doc, Map.get(types, name)}
    else
      doc = %{doc | types: Map.put(types, name, type_ref)}
      {doc, type_ref}
    end
  end

  @doc """
  Strips content from tombstoned items by rewriting them as `:gc`
  blocks of the same length.

  ## Why two stages

  A peer's concurrent edits may arrive *in flight* with anchors
  pointing at an item we've just deleted locally — "insert Y after
  block X" needs to find X's id to resolve placement. Dropping content
  the instant a local delete fires would orphan those anchors.

  So Yjs separates deletion into two stages:

    1. **Flag** — `deleted: true` on the item; content untouched.
      During this grace period the item still occupies its slot and
      incoming anchors resolve normally.
    2. **GC** — once the grace period is over, `gc/1` rewrites the
      content as `{:gc, length}`. Memory drops to the bare length
      marker; the id slot survives so future anchor lookups still land.

  ## What this function does

  Walks every item: leaves live items alone, rewrites `deleted: true`
  items to `content: {:gc, item.length}` (no-op if already a `:gc`
  block). Anchors pointing *through* a GC'd block are remapped to the
  nearest live neighbour by `Yelixer.Encoding.encode_item/2` at encode
  time — `gc/1` itself doesn't touch anchors. The block-tuple cache
  (`client_tuples`) is cleared wholesale so it rebuilds on the next
  read.
  """
  def gc(%__MODULE__{store: store} = doc) do
    # CX-w1fw: gc/1 already touches every item in the store, so a full
    # materialize (folding client_pending into clients) costs no more
    # than the Map.new below would anyway — and it must happen first,
    # or any still-pending items would be silently skipped.
    store = BlockStore.materialize_all(store)

    clients =
      Map.new(store.clients, fn {client, blocks} ->
        {client, Enum.map(blocks, &gc_item/1)}
      end)

    %{doc | store: %{store | clients: clients, client_tuples: %{}}}
  end

  defp gc_item(%Item{deleted: true, content: {:gc, _}} = item), do: item
  defp gc_item(%Item{deleted: true} = item), do: %{item | content: {:gc, item.length}}
  defp gc_item(item), do: item

  # ---- Snapshot / compaction ----
  #
  # `snapshot_update/1` and the replay helpers below implement the
  # compaction primitive (CX-u7p). Long-lived docs (presence docs,
  # schema docs) accumulate `client_id`s as replicas come and go.
  # Each `client_id` adds a clock entry to the state vector and an
  # item bucket to the block store; after thousands of authors the
  # encoded update payload is O(clients) in both size and apply time.
  #
  # The compaction approach: rebuild the doc's *observable* content
  # into a fresh replica under a single stable `client_id`. The
  # rebuilt doc produces the same rendered output, but with a
  # state-vector of size 1 and a single block-store bucket. Applying
  # the resulting update over a receiver that already has the source
  # doc is idempotent in Yjs, so peers that have not yet migrated
  # still converge correctly.
  #
  # The replay machinery walks each registered named-type root in the
  # source doc and rewrites its content into the fresh doc via the
  # public type APIs. Each top-level type has a dedicated `replay_*`
  # helper; XML's recursive structure is handled by the deepest ones.

  @doc """
  Builds a self-contained Yjs V1 binary update encoding the source
  doc's current observable state under a single `client_id`.

  Used by the compaction primitive (CX-u7p). When a long-lived doc has
  accumulated thousands of distinct `client_id`s (e.g. a presence doc
  that mints a fresh id each heartbeat), the encoded update grows
  O(clients) in size and apply time. This function replays the
  observable content into a fresh replica so the returned binary
  produces equivalent output with a state vector of size 1.

  Walks the source doc's registered named-type roots and replays each
  into a new doc via the public type APIs (`YMap`, `Text`, `Array`,
  XML). Returns `{bytes, derivation_map}`. Applying the returned bytes
  on top of a receiver that already has the source doc is idempotent,
  so the snapshot can be committed and replicated to peers safely even
  before all readers learn to short-circuit on snapshot commits.

  ## The derivation map

  Compaction renames every item: the rebuilt doc uses fresh
  `(client_id, clock)` ids from the new replica's clock space, not the
  source's. That breaks external references — late edits from peers who
  haven't seen the snapshot yet, archival commits that quoted a
  pre-compaction id, etc.

  The derivation map is `%{new_id => source_id}`: for every item in the
  rebuilt doc, the id of the source item it was rebuilt from.
  Late-edit translation uses it to rewrite incoming anchors from the
  source address space into the post-compaction one, so pre-snapshot
  edits integrate correctly without their anchors pointing into
  emptiness.

  Computed atomically with the bytes (CX-umz) so both commit to the
  same `(source, client_id, iteration order)` triple. See
  `Commonplace.Store.Snapshotter` for the calling convention that
  determinizes `source.client_id` before invoking this.

  ## Refusing lossy compaction (CX-oh9z)

  If `source` carries any `__sub:CLIENT:CLOCK` nested sub-type (see
  `nested_subtype_names/1`), this function returns `{:error,
  {:lossy_nested_subtypes, names}}` instead of silently dropping that
  sub-type's CRDT state. This makes the guard load-bearing at the
  library boundary itself, rather than relying on every caller to
  remember to pre-check `nested_subtype_names/1` (exactly one caller,
  `Commonplace.Store.Snapshotter.build_payload/2`, did before this
  guard existed here — the refusal below is now redundant for that
  caller but protects every other/future one).

  Pass `force: true` to bypass the refusal and get the old
  (lossy-if-nested) behavior — `{bytes, derivation_map}` unconditionally.
  Only use `force: true` when the caller has already decided the loss
  is acceptable (e.g. it pre-checked `nested_subtype_names/1` itself
  for a different reason, or the doc shape is known never to carry
  sub-types).

  ## Sub-types and the `__sub:CLIENT:CLOCK` naming

  Nested CRDT types — a `YArray` value inside a `YMap` entry, an
  `XmlElement` child inside a fragment — have no user-facing string
  names; they're addressed by their parent item's id. The type modules
  surface them in the type registry under synthesized names of the form
  `"__sub:CLIENT:CLOCK"`.

  The convention buys two things:

    - **Collision avoidance.** The `__sub:` prefix is a reserved
      sub-namespace; user-chosen type names cannot collide with it.
    - **Reconstructibility.** A debugger inspecting the `types` map
      can recover the parent item's id by parsing the name, without
      a separate parent-pointer index.

  Sub-types nested inside maps and arrays are not yet replayed
  structurally — `replay_named_type/3` short-circuits on the `__sub:`
  prefix. Current callers (presence docs, schema docs) store only
  primitive values at top-level registered types, so the gap is
  harmless. XML sub-types *are* replayed structurally via the
  `replay_xml_*` helpers, because XML's tree shape is the whole point
  of the type.
  """
  @spec snapshot_update(t(), force: boolean()) ::
          {binary(), %{optional(tuple()) => tuple()}}
          | {:error, {:lossy_nested_subtypes, [String.t()]}}
  def snapshot_update(%__MODULE__{} = source, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    case {force, nested_subtype_names(source)} do
      {false, [_ | _] = names} -> {:error, {:lossy_nested_subtypes, names}}
      _ -> do_snapshot_update(source)
    end
  end

  defp do_snapshot_update(source) do
    fresh = new(client_id: source.client_id)

    # CX-hzdc: replay in source-clock order, not `source.types` map
    # iteration order. The downstream derivation map pairs source and
    # new items by position, so source ordering must be preserved in
    # the rebuilt doc. Without this, envelope-structure docs (root YMap
    # + named "content") get a DM that pairs `_type` with "content" and
    # causes spurious `:case_b` in late-edit translation.
    types_in_source_order = sort_types_by_earliest_item(source)
    rebuilt = Enum.reduce(types_in_source_order, fresh, &replay_named_type(&1, &2, source))
    bytes = Yelixer.Encoding.encode_update(rebuilt)

    # CX-umz: the derivation map is computed atomically with the
    # snapshot bytes so both commit to the same (source, client_id,
    # iteration order) pair. See also `Commonplace.Store.Snapshotter`
    # which determinizes source.client_id before calling this.
    {bytes, build_derivation_map(source, rebuilt)}
  end

  # Pairs each new item id with the source item at the same position in
  # deterministic iteration order (clients descending by id, items
  # ascending by clock — matches `Yelixer.Encoding.encode_update/1`).
  # If the rebuilt doc has more items than the source (rare; snapshots
  # consolidate, not split) the tail entries reuse the last source id.
  defp build_derivation_map(source, rebuilt) do
    source_ids = collect_item_ids(source)
    new_ids = collect_item_ids(rebuilt)
    pair_ids(new_ids, source_ids)
  end

  defp collect_item_ids(%__MODULE__{store: %BlockStore{} = store}) do
    # CX-w1fw: read through client_blocks/2 (materialized view), not
    # store.clients directly — recently written items may still be in
    # the pending buffer. client_blocks/2 is already clock-ascending.
    store
    |> BlockStore.client_ids()
    |> Enum.sort(:desc)
    |> Enum.flat_map(fn client ->
      store
      |> BlockStore.client_blocks(client)
      |> Enum.map(fn item -> {item.id.client, item.id.clock} end)
    end)
  end

  defp pair_ids([], _source_ids), do: %{}
  defp pair_ids(_new_ids, []), do: %{}

  defp pair_ids(new_ids, source_ids) do
    last = List.last(source_ids)
    source_tuple = List.to_tuple(source_ids)
    source_len = tuple_size(source_tuple)

    new_ids
    |> Enum.with_index()
    |> Map.new(fn {new_id, idx} ->
      src = if idx < source_len, do: elem(source_tuple, idx), else: last
      {new_id, src}
    end)
  end

  # Orders named-type roots by the `{client, clock}` of their earliest
  # item in `source`. Roots with no direct items — possible when
  # content lives only under sub-types that `snapshot_update` does not
  # yet replay structurally — sort last under a sentinel so they do not
  # perturb the clock ordering of roots that do carry items.
  defp sort_types_by_earliest_item(%__MODULE__{types: types} = source) do
    Enum.sort_by(types, fn {name, _ref} -> earliest_id_for_type(source, name) end)
  end

  defp earliest_id_for_type(%__MODULE__{store: %BlockStore{} = store}, name) do
    # CX-w1fw: all_items/1 view — see collect_item_ids/1.
    store
    |> BlockStore.all_items()
    |> Enum.filter(fn
      %Item{parent: {:named, ^name}} -> true
      _ -> false
    end)
    |> Enum.map(fn %Item{id: id} -> {id.client, id.clock} end)
    |> case do
      [] -> {:no_items, name}
      ids -> Enum.min(ids)
    end
  end

  # Sub-types nested inside maps/arrays use synthetic names keyed
  # `__sub:CLIENT:CLOCK`. They are not yet replayed structurally;
  # current callers (presence, schema) store only primitive values.
  defp replay_named_type({"__sub:" <> _ = _name, _ref}, doc, _source), do: doc

  # XML child types are registered under synthetic names of the form
  # `parent::child::CLIENT:CLOCK` when their parent calls
  # `insert_child`. They are replayed recursively when the top-level
  # parent is processed — skip them here to avoid double-replay.
  defp replay_named_type({name, ref}, doc, source) do
    cond do
      String.contains?(name, "::child::") -> doc
      # The `::children` sub-sequence belongs to an XML element/fragment;
      # it isn't a named top-level type (Doc.get_or_create_type is never
      # called for it), but guard defensively for decoded updates.
      String.ends_with?(name, "::children") -> doc
      true -> replay_top_level_type(name, ref, source, doc)
    end
  end

  defp replay_top_level_type(name, ref, source, doc) do
    # `apply_update` cannot recover the symbolic type ref from the wire
    # format, so decoded top-level types arrive as `:unknown`. Infer
    # the actual shape from the source's block-store sequence so we
    # can dispatch to the correct type API for reading and replay.
    effective_ref = if ref == :unknown, do: infer_type_from_sequence(source, name), else: ref

    case effective_ref do
      :text -> replay_text(doc, source, name)
      :map -> replay_map(doc, source, name)
      :array -> replay_array(doc, source, name)
      :xml_fragment -> replay_xml_fragment(doc, source, name, name)
      {:xml_element, tag} -> replay_xml_element(doc, source, name, name, tag)
      :xml_text -> replay_xml_text(doc, source, name, name)
      _ ->
        # Unknown/stub ref types: register the name so the resulting doc
        # carries the type registration, but skip content replay.
        {doc, _} = get_or_create_type(doc, name, effective_ref)
        doc
    end
  end

  defp replay_text(doc, source, name) do
    {doc, _} = get_or_create_type(doc, name, :text)
    text = Text.to_string(source, name)
    if text == "", do: doc, else: Text.insert(doc, name, 0, text)
  end

  defp replay_map(doc, source, name) do
    {doc, _} = get_or_create_type(doc, name, :map)

    YMap.to_map(source, name)
    |> Enum.reduce(doc, fn {key, value}, d -> YMap.set(d, name, key, value) end)
  end

  defp replay_array(doc, source, name) do
    {doc, _} = get_or_create_type(doc, name, :array)
    values = Array.to_list(source, name)
    if values == [], do: doc, else: Array.insert(doc, name, 0, values)
  end

  # XML replay: walk the source's observable structure (tombstones are
  # already filtered by `to_list`/`children`) and rebuild it in `doc`
  # under `target_name`. Source children carry source-minted names
  # (`parent::child::CLIENT:CLOCK`) that will not match after
  # re-insertion; each source child is mapped to its freshly minted
  # name in `doc` before recursing.
  defp replay_xml_fragment(doc, source, source_name, target_name) do
    {doc, _} = get_or_create_type(doc, target_name, :xml_fragment)
    source_children = XMLFragment.to_list(source, source_name)
    replay_xml_children_into_fragment(doc, source, target_name, source_children)
  end

  defp replay_xml_element(doc, source, source_name, target_name, tag) do
    {doc, _} = get_or_create_type(doc, target_name, {:xml_element, tag})
    doc = replay_xml_attributes(doc, source, source_name, target_name)
    source_children = XMLElement.children(source, source_name)
    replay_xml_children_into_element(doc, source, target_name, source_children)
  end

  defp replay_xml_text(doc, source, source_name, target_name) do
    {doc, _} = get_or_create_type(doc, target_name, :xml_text)
    text = XMLText.to_string(source, source_name)
    if text == "", do: doc, else: XMLText.insert(doc, target_name, 0, text)
  end

  defp replay_xml_attributes(doc, source, source_name, target_name) do
    XMLElement.get_attributes(source, source_name)
    |> Enum.reduce(doc, fn {key, value}, d ->
      XMLElement.set_attribute(d, target_name, key, value)
    end)
  end

  defp replay_xml_children_into_fragment(doc, source, target_parent, source_children) do
    source_children
    |> Enum.with_index()
    |> Enum.reduce(doc, fn {source_child, idx}, d ->
      {spec, source_child_name, replay_fn} = xml_child_replay_plan(source_child)
      d = XMLFragment.insert_child(d, target_parent, idx, spec)
      target_children = XMLFragment.to_list(d, target_parent)
      target_child_name = target_child_name_at(target_children, idx)
      replay_fn.(d, source, source_child_name, target_child_name)
    end)
  end

  defp replay_xml_children_into_element(doc, source, target_parent, source_children) do
    source_children
    |> Enum.with_index()
    |> Enum.reduce(doc, fn {source_child, idx}, d ->
      {spec, source_child_name, replay_fn} = xml_child_replay_plan(source_child)
      d = XMLElement.insert_child(d, target_parent, idx, spec)
      target_children = XMLElement.children(d, target_parent)
      target_child_name = target_child_name_at(target_children, idx)
      replay_fn.(d, source, source_child_name, target_child_name)
    end)
  end

  defp xml_child_replay_plan({:element, tag, source_name}) do
    replay_fn = fn d, src, s_name, t_name ->
      replay_xml_element(d, src, s_name, t_name, tag)
    end

    {{:element, tag}, source_name, replay_fn}
  end

  defp xml_child_replay_plan({:text, source_name}) do
    replay_fn = fn d, src, s_name, t_name ->
      replay_xml_text(d, src, s_name, t_name)
    end

    {:text, source_name, replay_fn}
  end

  defp xml_child_replay_plan({:fragment, source_name}) do
    replay_fn = fn d, src, s_name, t_name ->
      replay_xml_fragment(d, src, s_name, t_name)
    end

    {{:fragment}, source_name, replay_fn}
  end

  defp target_child_name_at(target_children, idx) do
    case Enum.at(target_children, idx) do
      {:element, _tag, name} -> name
      {:text, name} -> name
      {:fragment, name} -> name
    end
  end

  # Infers the type ref for a named-type root by inspecting its YATA
  # sequence. Required because `apply_update` stores decoded top-level
  # types as `:unknown`.
  #
  # Heuristics, in order:
  #   - Any item with string content    → :text
  #   - Any item with a `parent_sub`    → :map  (entries keyed by parent_sub)
  #   - Any item with a nested XML type → :xml_fragment
  #   - Empty sequence                  → :map  (safe default)
  #   - Otherwise                       → :array
  #
  # Top-level `XMLElement` and `XMLText` cannot be inferred: the
  # element tag is not carried on the wire, and a top-level xml_text
  # sequence is indistinguishable from `:text`. Callers that use those
  # types must pre-register them on the receiver — the same contract
  # as Y.js `ydoc.get(name, Y.XmlElement)`.
  defp infer_type_from_sequence(%__MODULE__{store: store}, name) do
    items = Yelixer.BlockStore.get_sequence(store, name)

    cond do
      Enum.any?(items, &match?(%Item{content: {:string, _}}, &1)) -> :text
      Enum.any?(items, &(&1.parent_sub != nil)) -> :map
      xml_fragment_like?(items) -> :xml_fragment
      items == [] -> :map
      true -> :array
    end
  end

  defp xml_fragment_like?(items) do
    Enum.any?(items, fn
      %Item{content: {:type, {:xml_element, _}}} -> true
      %Item{content: {:type, :xml_text}} -> true
      %Item{content: {:type, :xml_fragment}} -> true
      _ -> false
    end)
  end
end
