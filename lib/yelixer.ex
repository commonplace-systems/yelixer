defmodule Yelixer do
  @moduledoc """
  Pure-Elixir port of the Yjs CRDT library, wire-compatible with
  Y.js V1 binary updates and the yrs Rust port.

  This top-level `Yelixer` module is intentionally thin — it carries
  no state and exposes no API of its own. The work happens in the
  modules below, organized as a layer cake: lower layers know
  nothing about higher layers, higher layers compose lower ones.

  ## Layer cake

  Each box is a module under `Yelixer.*`; arrows indicate "uses."

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
      │  (passive       │  │  ↔  SyncProtocol                    │  bytes
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

  `Transaction` exists at the type-facade layer but is currently
  partial; see its moduledoc.

  ## Recommended reading order

  Start at the bottom of the cake — the foundational atoms — and
  work up. Each module's `@moduledoc` is self-contained but assumes
  the modules below it.

    1. `Yelixer.ID` — `(client, clock)` pair; what identifies anything.
    2. `Yelixer.StateVector` — per-client high-water-marks; how
       replicas summarize "what I have."
    3. `Yelixer.DeleteSet` — interval-merged tombstones; the dual to
       StateVector for "what I've removed."
    4. `Yelixer.Item` — the atomic unit, with its YATA causal anchors
       (`origin`, `right_origin`).
    5. `Yelixer.BlockStore` — storage layer with the per-client
       bucket / sequence-by-name duality, binary-search lookups,
       run-length splits.
    6. `Yelixer.Doc` — the top-level container that ties it all
       together; passive struct, no behavior of its own.
    7. `Yelixer.Integrate` — YATA placement: given an Item and its
       anchors, where does it go in the parent sequence?
    8. `Yelixer.Encoding` — V1 wire format: bytes ↔ items, with the
       byte-determinism guarantee.
    9. Type facades — `Types.Text`, `Types.Array`, `Types.YMap`,
       `Types.XMLFragment` / `XMLElement` / `XMLText`, and the
       `Types` routing utility.
    10. `Yelixer.SyncProtocol` — the two-message handshake that
        converges any pair of replicas.
    11. *(optional)* `Yelixer.DocServer` — OTP wrapper for production
        use cases that need a process and broadcast.

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

  Caller threads the new `%Doc{}` forward.

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

  Two-phase integration handles out-of-order arrivals: an Item whose
  `origin` references an Item later in the same update lands in the
  pending list and integrates once its dep arrives.

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

  After this round, `doc_A` knows everything `doc_B` knew. Items only
  `A` had are covered by the symmetric half: `B` runs the same
  protocol with the roles swapped, so a single concurrent round-trip
  pair fully converges both replicas.

  See `Yelixer.SyncProtocol`'s "Why both halves are required" for the
  asymmetry rationale (`StateVector.diff/2` iterates remote's clients
  only, so each side has to ask for its own catch-up).

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

  Tombstones are filtered at the BlockStore layer, so every read path
  composes their absence for free.

  ## Cross-cutting patterns

  Several conventions recur across modules. Knowing them up front
  saves re-deriving them per file:

  ### Half-open intervals

  `[start, stop)` semantics throughout:
  - `DeleteSet` ranges store `{start, stop}` half-open.
  - `Item.length` is the count of clocks in `[id.clock, id.clock + length)`.
  - `BlockStore`'s binary search uses `block_end = id.clock + length - 1`
    as an inclusive arithmetic alternate.
  - `ID.contains?/3` and the half-open membership test in
    `DeleteSet.deleted?/3` follow the same convention.

  Half-open is the right shape for adjacency: `[0, 3)` and `[3, 6)`
  meet cleanly at clock 3 with no gap and no overlap, merging to
  `[0, 6)` without off-by-one arithmetic.

  ### Monotonic max as the join

  `StateVector.advance(sv, c, k) = max(get(sv, c), k)`. Repeated
  application is idempotent; reordered observations converge to the
  same result. The join-on-a-max-lattice shape — every other
  module's convergence story is built on it.

  ### YATA two-anchor placement

  Every Item records both `origin` (left neighbour at authoring) and
  `right_origin` (right neighbour at authoring). Concurrent inserts
  with the same `origin` resolve via right-anchor + client-ID
  tiebreak in `Integrate`'s two-set conflict scan. The same anchors
  drive the encoding's "remap through GC blocks" path on the wire.

  ### Synthetic naming for sub-types

  Two synthetic-name schemes thread through the facades:

  - `"__sub:CLIENT:CLOCK"` — minted by `YMap.set/4` /
    `Array.insert/4` when a value is a nested CRDT. The parent block
    holds `{:type, ref}`; the children are reachable via this name.
    `Types.sub_type_to_json/2` is the read-side counterpart.
  - `"<parent>::children"` and
    `"<parent>::child::CLIENT:CLOCK"` — minted by
    `XMLFragment.insert_child/4` and `XMLElement.insert_child/4`
    for the children sequence and child sub-type registrations.

  Both schemes are recognized by `Doc.snapshot_update/1`'s replay
  machinery, which short-circuits on them during top-level type
  iteration.

  ### Tombstones, not deletion

  Items are never removed from `BlockStore`. "Delete" is a two-stage
  operation:
  1. `Integrate.mark_deleted/2` flips `deleted: true`. Content stays
     intact during this *grace period* so in-flight network anchors
     can still resolve.
  2. `Doc.gc/1` rewrites tombstoned items as `{:gc, length}`,
     freeing memory while preserving the ID slot.

  Read paths filter via `BlockStore.get_sequence/2`; encoding
  preserves tombstones because both sides need them to reconcile
  symmetrically.

  ## Byte-determinism

  `Encoding.encode_update/1` produces the same bytes on any two
  replicas that hold the same logical state. This is what
  content-addressed storage downstream depends on (Commonplace's
  snapshot commits, late-edit translator). The guarantee rests on
  four invariants distributed across modules:

    1. **`Encoding.encode_diff/2`** sorts clients descending before
       emitting the struct section.
    2. **`BlockStore`** keeps per-client lists clock-sorted, so item
       iteration within a client is deterministic.
    3. **`Encoding.encode_delete_set/1`** sorts clients descending
       (Elixir map iteration order is unspecified, so this is
       load-bearing).
    4. **`apply_update/2`** merges the incoming delete set into
       `doc.delete_set` (CX-w62) so receivers retain tombstones and
       re-emit them losslessly on the next encode.

  See `Yelixer.Encoding`'s moduledoc for the full determinism story
  and the test fixtures that exercise it.

  ## What this library is NOT

  - **Not a transport.** `SyncProtocol` produces and consumes bytes;
    the caller decides how those bytes travel.
  - **Not a persistence layer.** `Doc` lives in memory; durability
    is the caller's concern (Commonplace's `CommitStore` is one
    answer for this codebase).
  - **Not awareness/presence.** Yjs has separate awareness protocols
    for cursor positions and ephemeral state; not implemented here.
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
