defmodule Yelixer.SyncProtocol do
  @moduledoc """
  Two-message sync protocol that converges any pair of Yjs replicas.

  This module is the wire-protocol home of every other piece of
  yelixer. The data-structure layer (`Yelixer.Item`, `Yelixer.ID`,
  `Yelixer.BlockStore`, `Yelixer.DeleteSet`, `Yelixer.StateVector`),
  the integration layer (`Yelixer.Integrate`), the type facades
  (`Yelixer.Types.Text`, `Array`, `YMap`, `XMLFragment`,
  `XMLElement`, `XMLText`), the document container (`Yelixer.Doc`),
  and the binary serialization (`Yelixer.Encoding`) all converge on
  one purpose: making two replicas agree on what's in the document.
  `SyncProtocol` is where they finally close the loop.

  ## What sync is

  Sync is the algorithm that brings two replicas of the same logical
  document — call them A and B — to byte-identical state. It must
  work over a noisy channel, after arbitrary periods of disconnection,
  and without a central authority. The protocol is designed for the
  worst case (A and B have been editing independently for a while)
  but degenerates gracefully to the cheap case (one replica is fully
  up-to-date with the other).

  ## Two messages, one round-trip

  Sync runs as a single request/response exchange:

      A ── step1 (sv_A) ────────► B
      A ◄────────── step2 (diff) ── B

  - **Step 1** carries A's state vector — the "what I have" summary
    described in `Yelixer.StateVector`. It's tiny: one varint pair
    per client A has seen, no item content, no tombstones.
  - **Step 2** carries the diff B owes A — the items A is missing
    plus B's full delete set. Computed via
    `Yelixer.Encoding.encode_diff/2` against the state vector A
    just sent.

  After A applies the step 2 payload via `Yelixer.Encoding.apply_update/2`,
  A's state matches B's *for the things B knew about*. Anything A
  knew that B didn't is symmetric: B initiates its own round in the
  reverse direction.

  ## Why two halves are required

  `Yelixer.StateVector.diff/2` only returns the catch-up A needs from
  B — it iterates B's clients, not A's. Items that exist only in A's
  store appear nowhere in `diff(B, A)`. So a single round closes one
  direction; full convergence needs both replicas to play the role
  of "asker" once. The protocol is intentionally symmetric:
  `encode_step1` + `handle_message` work the same on either side.
  In practice, peers run both halves concurrently (each side fires
  its own step 1 while answering the other's), so a single
  round-trip pair converges them.

  This symmetry is the same shape we documented in
  `Yelixer.StateVector.diff/2`'s "Why iterate remote's clients" and
  "Sync is symmetric" sections — those are the data-structure
  rationale; this module is its concrete byte-level realization.

  ## Convergence guarantee

  After one round (step 1 + step 2 in each direction) the two
  replicas agree on:

    - **Items**: the union of all items either side has seen.
      `apply_update/2` integrates each incoming item via
      `Yelixer.Integrate.integrate/3`, which is deterministic
      under YATA — so both sides land identical sequences.
    - **Tombstones**: the union of both delete sets.
      `apply_update/2` merges the incoming set into
      `doc.delete_set` (CX-w62), so re-encodes preserve the
      deletions.

  The result is byte-identical: re-encoding via
  `Yelixer.Encoding.encode_update/1` on either replica produces the
  same bytes (the byte-determinism guarantee documented in
  `Yelixer.Encoding`'s moduledoc). That equality is what
  content-addressed storage downstream relies on.

  ## Wire format

  Each message is a single byte tag followed by an opaque payload:

      step1: <<0, state_vector_bin::binary>>
      step2: <<1, update_bin::binary>>

  `state_vector_bin` is whatever `Yelixer.Encoding.encode_state_vector/1`
  produces; `update_bin` is whatever
  `Yelixer.Encoding.encode_diff/2` produces. Tagging is one byte
  rather than a varint because there are only two message types and
  no expectation of growth — the Yjs protocol freezes this choice.

  ## What this module is NOT

  - Not a transport — bytes go in via `handle_message/2`, bytes come
    out from `encode_step1/1` and `handle_message/2`'s return tuple.
    Whether they travel over WebSocket, MQTT, Phoenix Channels, raw
    TCP, or `IO.binwrite/2` is the caller's concern.
  - Not session management — there's no peer identity, retries,
    duplicate suppression, or backpressure. The protocol is
    idempotent (replaying step 2 produces the same final state via
    `apply_update/2`'s integration semantics), so callers can layer
    those concerns above this module's surface.
  - Not awareness or presence — Yjs has separate awareness
    protocols for cursor positions, selection, and ephemeral state.
    This file is content-only.
  """

  alias Yelixer.{Doc, Encoding, BlockStore}

  # Yjs message-type constants. Frozen by the Yjs wire spec — these
  # values appear on the wire literally and any peer (yrs, y.js,
  # other ports) reads them in the same byte positions.
  @msg_sync_step1 0
  @msg_sync_step2 1

  @doc """
  Builds a Step 1 message — this replica's state vector wrapped with
  the sync-step-1 tag byte.

  Cheap to construct: `BlockStore.state_vector/1` walks the per-client
  buckets to derive the high-water-marks, then
  `Encoding.encode_state_vector/1` emits one `(client, clock)` varint
  pair per client. The payload is a compact summary of "what I
  have" — no item content, no tombstones. Send this when you want
  the other side to send you a catch-up; receivers respond with the
  step 2 produced by `handle_message/2`.
  """
  def encode_step1(%Doc{} = doc) do
    sv = BlockStore.state_vector(doc.store)
    sv_bin = Encoding.encode_state_vector(sv)
    <<@msg_sync_step1, sv_bin::binary>>
  end

  @doc """
  Dispatches an incoming sync message to the right handler.

  Two arms by tag byte:

  - `<<0, sv_bin::binary>>` (step 1) — the peer is asking for a
    catch-up. Decode their state vector, compute the items they
    don't have via `Encoding.encode_diff/2`, wrap the result in a
    step-2 frame, and return `{:step2, response}` for the caller to
    send back.
  - `<<1, update_bin::binary>>` (step 2) — the peer is answering an
    earlier step 1. Apply the update via `Encoding.apply_update/2`
    (which integrates new items, merges the delete set, and runs
    pending-retry for items missing dependencies) and return
    `{:update, doc}`.

  An empty step-2 update is a meaningful "we have nothing for you"
  signal and still results in `{:update, doc}` — the doc is just
  unchanged.
  """
  def handle_message(%Doc{} = doc, <<@msg_sync_step1, sv_bin::binary>>) do
    {:ok, {remote_sv, _}} = Encoding.decode_state_vector(sv_bin)
    diff = Encoding.encode_diff(doc, remote_sv)
    {:step2, <<@msg_sync_step2, diff::binary>>}
  end

  def handle_message(%Doc{} = doc, <<@msg_sync_step2, update::binary>>) do
    {:ok, doc} = Encoding.apply_update(doc, update)
    {:update, doc}
  end
end
