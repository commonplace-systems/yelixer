defmodule Yelixer do
  @moduledoc """
  Pure-Elixir port of the [Yjs](https://yjs.dev) CRDT library,
  wire-compatible with Y.js V1 binary updates and the `yrs` Rust port.

  Intentionally thin: no state, no API. It exists as the ExDoc entry
  point and the architectural overview. All real work happens in the
  modules below, organized as a layer cake — lower layers know nothing
  about higher ones; higher layers compose them.

  ## Layer cake

  Each box is a module under `Yelixer.*`; arrows mean "uses."

      ┌─────────────────────────────────────────────────────────────┐
      │  SyncProtocol  ◄───── transport (caller's WebSocket / etc.) │  protocol
      └────────────────────────────────┬────────────────────────────┘
                                       ▼
      ┌────────────────────────────────────────────────────────────┐
      │  DocServer (OTP wrapper, broadcast)    ─── optional layer  │  process
      └────────────────────────────────┬───────────────────────────┘
                                       ▼
      ┌──────────────────────────────────────────────────────────┐
      │  Types.Text  Types.Array  Types.YMap                     │  type
      │  Types.XMLFragment  Types.XMLElement  Types.XMLText      │  facades
      │  Types  (resolve / sub_type_to_json — read routing)      │
      └────────────┬─────────────────┬───────────────────────────┘
                   ▼                 ▼
      ┌─────────────────┐  ┌─────────────────────────────────────┐
      │  Doc            │  │  Encoding (V1 wire format)          │  doc +
      │  (immutable     │  │  ↔  SyncProtocol                    │  bytes
      │   container)    │  └─────────────────────────────────────┘
      └────────┬────────┘
               ▼
      ┌──────────────────────────────────────────────────────────┐
      │  Integrate  (YATA placement)                             │  ordering
      └────────────────────────────────┬─────────────────────────┘
                                       ▼
      ┌──────────────────────────────────────────────────────────┐
      │  BlockStore  (per-client buckets + sequences)            │  storage
      └────────┬─────────────────────────┬───────────────────────┘
               ▼                         ▼
      ┌─────────────────┐  ┌─────────────────────────────────────┐
      │  Item           │  │  StateVector    DeleteSet           │  data
      │  (the atomic    │  │  (per-client    (interval-merged    │  shapes
      │   unit)         │  │   high-water)   tombstones)         │
      └────────┬────────┘  └─────────────────────────────────────┘
               ▼
      ┌──────────────────────────────────────────────────────────┐
      │  ID  (client, clock)  ─── universal identifier           │  primitive
      └──────────────────────────────────────────────────────────┘

  ## Why layered this way

  Lower layers are reusable primitives; higher layers compose them.
  Each layer can be replaced or studied independently — `Encoding` is
  the only place that knows the wire format, `Integrate` the only place
  that knows YATA, the type facades the only places that translate
  user-shaped APIs into Item creation. One concept per file; a
  wire-format change doesn't ripple into the type facades.

  ## Scope boundaries

  Before the per-module deep dives:

  - **Not a transport.** `SyncProtocol` produces and consumes bytes;
    the caller decides how they travel (WebSocket, HTTP, Phoenix
    Channels, etc.).
  - **Not a persistence layer.** `Doc` lives in memory; durability is
    the caller's concern. `Commonplace.CommitStore` is the answer in
    this codebase.
  - **Not awareness/presence.** Yjs has separate protocols for cursor
    positions and ephemeral state; those are not implemented here.

  ## Recommended reading order

  Start at the bottom of the cake and work up. Each module's
  `@moduledoc` is self-contained, but assumes the modules below it.

    1. `Yelixer.ID` — the `{client, clock}` pair that identifies
       every item in every replica.
    2. `Yelixer.StateVector` — per-client high-water marks; how a
       replica summarizes "what I have seen."
    3. `Yelixer.DeleteSet` — interval-merged tombstone ranges; the
       counterpart to `StateVector` for "what I have deleted."
    4. `Yelixer.Item` — the atomic unit of content, carrying YATA
       causal anchors (`origin`, `right_origin`). YATA (Yet Another
       Transformation Approach) is the conflict-resolution algorithm
       Yjs uses to order concurrent inserts without locking.
    5. `Yelixer.BlockStore` — storage: per-client buckets for item
       lookup, named sequences for ordered traversal, binary-search
       positioning, run-length splitting.
    6. `Yelixer.Doc` — the top-level immutable container. No actor,
       no in-place mutation — behavior lives in `Integrate`, the type
       facades, and `Encoding`. Operations take a `%Doc{}` and return
       a new `%Doc{}` with the change applied.
    7. `Yelixer.Integrate` — YATA placement: given an Item and its
       anchors, determine where it belongs in its parent sequence.
    8. `Yelixer.Encoding` — V1 wire format: bytes ↔ items, including
       the byte-determinism guarantee (same logical state → same bytes).
    9. Type facades — `Types.Text`, `Types.Array`, `Types.YMap`,
       `Types.XMLFragment` / `XMLElement` / `XMLText`, and the
       `Types` routing module.
    10. `Yelixer.SyncProtocol` — the two-message handshake that
        converges any pair of replicas.
    11. *(optional)* `Yelixer.DocServer` — OTP `GenServer` wrapper
        for production use: manages a live `Doc` process and
        broadcasts diffs to subscribers.

  ## Data-flow walkthroughs

  ### Local edit (caller mutates the doc)

      caller ──Text.insert(doc, "body", 5, "hello")──►
                                              │
                                              ▼
      Types.Text.insert/4
        └─ find_origins_with_split (split block if mid-run)
        └─ build Item with content: {:string, "hello"}, length: 5
        └─ Integrate.integrate/3  ────► YATA placement
                                              │
                                              ▼
                                    BlockStore.insert_at/4
                                    (push into client bucket
                                     + splice ID into sequence)
                                              │
                                              ▼
                                    new %Doc{} returned to caller

  The caller threads the new `%Doc{}` forward; there is no mutation
  in place.

  ### Remote update (bytes arrive from a peer)

      bytes ──► Encoding.apply_update/2
        ├─ decode struct section ─► [Item, Item, …]
        ├─ for each Item:
        │   └─ Integrate.integrate/3
        │       (anchor missing? → defer to pending list)
        ├─ retry pending items (deps may have arrived in same batch)
        ├─ apply delete set:
        │   └─ for each (client, range): Integrate.mark_deleted/2
        └─ DeleteSet.merge into doc.delete_set
                                              │
                                              ▼
                                    {:ok, doc}
                                    DocServer (if used) → broadcast diff to subscribers

  The two-phase approach (integrate, then retry pending) handles
  out-of-order arrivals: an Item whose `origin` hasn't arrived yet
  parks in the pending list and integrates once its dependency lands.

  ### Sync handshake (two replicas converge)

      A                                                     B
      │  encode_step1(doc_A)                                │
      │  ────────────────────────────────────────────────►  │
      │                                                     │  handle_message:
      │                                                     │   - decode A's state vector
      │                                                     │   - encode_diff(doc_B, sv_A)
      │                                                     │   - wrap as step2
      │  ◄────────────────────────────────────────────────  │
      │  handle_message:                                    │
      │   - apply_update(doc_A, step2)                      │
      │     (= integrate items + merge delete set)          │

  After this round `doc_A` holds everything `doc_B` knew. Items that
  only `A` had are covered by the symmetric half: `B` runs the same
  protocol with roles swapped. One concurrent round-trip pair fully
  converges both replicas.

  See `Yelixer.SyncProtocol`'s "Why both halves are required" for the
  asymmetry rationale (`StateVector.diff/2` iterates only the remote's
  clients, so each side must independently ask for its own catch-up).

  ### Render (caller reads the live document)

      caller ──Text.to_string(doc, "body")──►
                                          │
                                          ▼
      Types.Text.to_string/2
        └─ BlockStore.get_sequence(doc.store, "body")
            └─ filter out tombstoned items
        └─ Enum.flat_map per-block content extraction
        └─ Enum.join → final string

  For `to_json` paths (`Array`, `YMap`, `XMLFragment`):

      Types.<facade>.to_json/2
        └─ BlockStore.get_sequence (tombstone filter)
        └─ per-item: Types.resolve_content_value (primitives)
                  or Types.sub_type_to_json (nested CRDTs)
                                          │
                                          ▼  recurses on `{:type, ref}`
                                   look up `__sub:CLIENT:CLOCK` in doc.types
                                   dispatch to facade for that kind

  Tombstones are filtered at the `BlockStore` layer, so every read
  path gets clean output without extra filtering logic.

  ## Cross-cutting patterns

  Several conventions recur across modules. Recognizing them here
  avoids re-deriving them file by file.

  ### Half-open intervals

  `[start, stop)` semantics everywhere:

  - `DeleteSet` ranges are stored as `{start, stop}` half-open.
  - `Item.length` spans clocks `[id.clock, id.clock + length)`.
  - `BlockStore`'s binary search uses `block_end = id.clock + length - 1`
    as the equivalent inclusive upper bound.
  - `ID.contains?/3` and `DeleteSet.deleted?/3` use the same convention.

  Half-open intervals compose cleanly: `[0, 3)` and `[3, 6)` meet at
  clock 3 with no gap and no overlap, merging to `[0, 6)` with no
  off-by-one arithmetic. *Why this matters*: clock arithmetic
  recurs in `Item.split/2`, `BlockStore.split_block/3`,
  `DeleteSet.add_range/2`, and the integration retry loop. A single
  consistent convention eliminates an entire class of off-by-one bugs
  across all four sites.

  ### Monotonic max as the join

  `StateVector.advance(sv, c, k) = max(current(sv, c), k)`.
  Applied in any order, any number of times, it always yields the same
  result — a semilattice join (least-upper-bound of "higher clock =
  more recent"). Every module's convergence story rests on it.
  *Why this matters*: networks reorder, duplicate, and replay messages.
  If `advance` were anything but monotonic-max, two replicas applying
  the same observations in different orders could diverge on their
  state vectors — and the sync protocol would ship wrong diffs. The
  CRDT's correctness ultimately reduces to this one operation.

  ### YATA two-anchor placement

  Every Item records `origin` (left neighbour at authoring time) and
  `right_origin` (right neighbour at authoring time). When concurrent
  inserts share the same `origin`, `Integrate` breaks the tie with the
  right anchor plus client-ID. The same anchors drive the encoding's
  "remap through GC blocks" path on the wire. *Why this matters*:
  with only `origin`, two peers inserting "after item X" concurrently
  have no way to agree on order — they'd diverge. The right anchor
  plus client-ID tiebreak gives every replica a deterministic answer
  without coordination. That's what makes Yjs concurrent-edit-safe
  rather than merely merge-on-conflict.

  ### Synthetic naming for sub-types

  Two synthetic-name schemes thread through the facades:

  - `"__sub:CLIENT:CLOCK"` — coined by `YMap.set/4` and
    `Array.insert/4` when a value is a nested CRDT. The parent block
    holds `{:type, ref}`; the sub-type is reachable by this name.
    `Types.sub_type_to_json/2` is the read-side counterpart.
  - `"<parent>::children"` and `"<parent>::child::CLIENT:CLOCK"` —
    coined by `XMLFragment.insert_child/4` and
    `XMLElement.insert_child/4` for child sequences and sub-type
    registrations.

  Both schemes are recognized by `Doc.snapshot_update/1`'s replay
  machinery, which skips them during top-level type iteration.
  *Why this matters*: nested CRDTs need stable, collision-free
  registration names derivable from the parent's ID alone — no shared
  registry, no coordination. The `(client, clock)` pair is already
  globally unique; prefixing it with a reserved sentinel (`__sub:` or
  `<parent>::child::`) produces a name that cannot collide with any
  user-chosen top-level type name. Reads simply reverse the
  construction.

  ### Two-stage tombstones

  Items are never physically removed from `BlockStore`. Deletion is
  two stages:

  1. `Integrate.mark_deleted/2` sets `deleted: true`. Content stays
     intact so that in-flight network anchors can still resolve.
  2. `Doc.gc/1` rewrites tombstoned items as `{:gc, length}`,
     reclaiming memory while preserving the ID slot.

  Read paths skip tombstones via `BlockStore.get_sequence/2`; encoding
  preserves them so both sides reconcile symmetrically. *Why this
  matters*: the two stages serve distinct concerns. Stage 1 (flag set,
  content kept) is **correctness** — concurrent network anchors still
  need to resolve. Stage 2 (content rewritten as `:gc`) is **memory
  optimization** — once no live anchors target the slot the payload
  can be dropped while the ID slot stays live. Conflating the stages
  would either leak content forever (skip stage 2) or break causal
  anchors (skip stage 1).

  ## Byte-determinism

  `Encoding.encode_update/1` produces identical bytes on any two
  replicas that hold the same logical state. Content-addressed
  storage downstream — Commonplace's snapshot commits and the
  late-edit translator — depends on this guarantee. It rests on four
  invariants distributed across modules:

    1. **`Encoding.encode_diff/2`** sorts clients descending before
       emitting the struct section.
    2. **`BlockStore`** keeps per-client lists clock-sorted, making
       item iteration within a client deterministic.
    3. **`Encoding.encode_delete_set/1`** sorts clients descending.
       (Elixir map iteration order is unspecified, so explicit sorting
       is load-bearing here.)
    4. **`apply_update/2`** merges the incoming delete set into
       `doc.delete_set` (CX-w62) so receivers retain tombstones and
       re-emit them losslessly on the next encode.

  See `Yelixer.Encoding`'s moduledoc for the full determinism
  narrative and the test fixtures that exercise it.
  """

  @doc """
  Hello world.

  ## Examples

      iex> Yelixer.hello()
      :world

  """
  def hello do
    :world
  end
end
