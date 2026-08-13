defmodule Yelixer.SyncProtocol do
  @moduledoc """
  Two-message sync protocol that converges any pair of Yjs replicas.

  Every other module in this library builds toward one outcome: two
  replicas that agree on what's in the document. `Yelixer.ID` and
  `Yelixer.Item` model the atoms; `Yelixer.BlockStore` stores them;
  `Yelixer.StateVector` and `Yelixer.DeleteSet` summarize what a
  replica has seen and what it has deleted; `Yelixer.Integrate`
  merges concurrent edits without conflicts; `Yelixer.Encoding`
  serializes all of it to bytes; `Yelixer.Doc` holds the live state;
  and the type facades (`Text`, `Array`, `YMap`, `XmlFragment`,
  `XmlElement`, `XmlText`) expose it to callers. `SyncProtocol` is
  where these pieces close the loop — the byte-level exchange that
  leaves two replicas in identical state.

  ## What sync does

  Sync brings two replicas of the same logical document — call them A
  and B — to identical state. It must work after arbitrary periods of
  disconnection, with no central authority. The protocol handles the
  worst case (both sides edited independently) and degenerates cheaply
  when one side is already current.

  ## Two messages, one round-trip

  Sync is a single request/response exchange:

      A ── step1 (sv_A) ────────► B
      A ◄────────── step2 (diff) ── B

  - **Step 1** carries A's *state vector* — a compact `%{client =>
    max_clock}` map (`Yelixer.StateVector`) that says exactly which
    items A has integrated, without sending any item content. One
    varint pair per client; no tombstones.
  - **Step 2** carries the *diff* B owes A: every item A is missing
    from B's store, plus B's full delete set, packed by
    `Yelixer.Encoding.encode_diff/2` using the state vector A sent.

  After A applies the step 2 payload via
  `Yelixer.Encoding.apply_update/2`, A's state matches B's for
  everything B knew. Items only A had are covered by the symmetric
  half: B fires its own step 1 while answering A's, so a single
  concurrent round-trip pair fully converges both replicas.

  ## Why both halves are required

  `Yelixer.StateVector.diff/2` iterates the *remote* side's clients,
  not the local side's. Items that exist only in A's store are
  invisible to `diff(sv_B, sv_A)` because the algorithm iterates B's
  clients, not A's — A's exclusive clients never appear in B's map,
  so B's diff cannot mention items it doesn't have records for. A
  must send its own step 1 to get B to emit them. One direction of
  the exchange closes one half of the gap; the reverse direction
  closes the other. The protocol is deliberately symmetric:
  `encode_step1/1` and `handle_message/2` work identically on either
  side.

  This is the byte-level realization of the asymmetry documented in
  `Yelixer.StateVector.diff/2` — "Why iterate remote's clients" and
  "Sync is symmetric" explain the data-structure rationale; this
  module is where that rationale becomes wire bytes.

  ## Convergence guarantee

  After one full round (each side sends step 1, receives step 2) both
  replicas agree on:

    - **Items** — the union of all items either side had.
      `apply_update/2` feeds each incoming item through
      `Yelixer.Integrate.integrate/3`, which resolves concurrent
      inserts deterministically under YATA, leaving both sides in
      identical sequence order.
    - **Tombstones** — the union of both delete sets.
      `apply_update/2` merges the incoming `Yelixer.DeleteSet` into
      `doc.delete_set`, so every deletion each side made is reflected
      on both.

  The result is *byte-deterministic*: calling
  `Yelixer.Encoding.encode_update/1` on either replica afterward
  produces the same bytes, because `Encoding` sorts clients
  consistently and `Integrate` resolves ties by a fixed rule. That
  byte-equality is what content-addressed storage downstream depends
  on (documented in `Yelixer.Encoding`'s moduledoc).

  ## Wire format

  Each message is a one-byte tag followed by an opaque payload:

      step1: <<0, state_vector_bin::binary>>
      step2: <<1, update_bin::binary>>

  `state_vector_bin` is the output of
  `Yelixer.Encoding.encode_state_vector/1`; `update_bin` is the
  output of `Yelixer.Encoding.encode_diff/2`. The tag is one byte
  rather than a varint — there are exactly two message types and the
  Yjs wire spec freezes this choice, so no length savings are needed.

  ## What this module is not

  - **Not a transport.** Bytes arrive via `handle_message/2` and
    leave via the return values of `encode_step1/1` and
    `handle_message/2`. WebSocket, Phoenix Channels, MQTT, raw TCP —
    all the caller's concern.
  - **Not session management.** No peer identity, retries, duplicate
    suppression, or backpressure. The protocol is idempotent because
    `Yelixer.Integrate.integrate/3` deterministically places
    concurrent inserts (re-applying the same item finds the same
    YATA position) and tombstoned items stay tombstoned (the
    `:deleted` flag and `doc.delete_set` interval are both
    idempotent under repeated application) — so replaying a step 2
    produces the same final state. Callers layer reliability above
    this surface.
  - **Not awareness or presence.** Yjs has separate protocols for
    cursor positions, selections, and ephemeral state. This module is
    content-only.
  """

  alias Yelixer.{Doc, Encoding, BlockStore}

  # Yjs message-type constants. Frozen by the Yjs wire spec — these
  # values appear on the wire literally and any peer (yrs, y.js,
  # other ports) reads them in the same byte positions.
  @msg_sync_step1 0
  @msg_sync_step2 1

  @doc """
  Builds a step 1 message: this replica's state vector, tagged for
  the wire.

  Construction is cheap: `BlockStore.state_vector/1` reads per-client
  high-water-marks from the store, then
  `Encoding.encode_state_vector/1` emits one `(client, clock)` varint
  pair per client. The result is a compact "what I have" declaration —
  no item content, no tombstones. Send this to ask the other side for
  its catch-up diff; the receiver replies with the step 2 returned by
  `handle_message/2`.
  """
  def encode_step1(%Doc{} = doc) do
    sv = BlockStore.state_vector(doc.store)
    sv_bin = Encoding.encode_state_vector(sv)
    <<@msg_sync_step1, sv_bin::binary>>
  end

  @doc """
  Dispatches an incoming sync message and returns the appropriate
  response or updated doc.

  Two arms, matched by tag byte:

  - `<<0, sv_bin::binary>>` (step 1) — the peer is requesting a
    catch-up. Decode its state vector, compute the items it lacks via
    `Encoding.encode_diff/2`, and return `{:step2, response}` for
    the caller to send back.
  - `<<1, update_bin::binary>>` (step 2) — the peer is answering an
    earlier step 1 we sent. Apply the update via
    `Encoding.apply_update/2` — which integrates new items via YATA,
    merges the incoming delete set, and retries items that were
    blocked on missing dependencies — then return `{:update, doc}`.

  An empty step-2 payload ("we have nothing for you") is valid and
  returns `{:update, doc}` with the doc unchanged.
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
