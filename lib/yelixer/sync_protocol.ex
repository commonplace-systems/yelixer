defmodule Yelixer.SyncProtocol do
  @moduledoc """
  Yjs sync protocol implementation.

  The sync protocol uses two message types:
  - Step 1 (type 0): Contains a state vector. The receiver computes a diff
    and responds with Step 2.
  - Step 2 (type 1): Contains an update (the diff). The receiver applies it.

  Typical flow:
    1. Peer A sends `encode_step1(docA)` to Peer B
    2. Peer B calls `handle_message(docB, msg)` → receives `{:step2, response}`
    3. Peer B sends `response` back to Peer A
    4. Peer A calls `handle_message(docA, response)` → receives `{:update, docA}`
  """

  alias Yelixer.{Doc, Encoding, BlockStore}

  @msg_sync_step1 0
  @msg_sync_step2 1

  @doc "Encode a Step 1 message containing this doc's state vector."
  def encode_step1(%Doc{} = doc) do
    sv = BlockStore.state_vector(doc.store)
    sv_bin = Encoding.encode_state_vector(sv)
    <<@msg_sync_step1, sv_bin::binary>>
  end

  @doc """
  Handle an incoming sync message.

  Returns:
  - `{:step2, binary}` — a Step 2 response to send back (when receiving Step 1)
  - `{:update, doc}` — the updated doc (when receiving Step 2)
  - `:noop` — nothing to do (empty update)
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
