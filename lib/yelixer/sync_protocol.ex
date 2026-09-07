defmodule Yelixer.SyncProtocol do
  @moduledoc """
  Yjs content synchronization frames, compatible with y-protocols 1.0.7.

  A complete frame is `<varUint tag, varUint payload_byte_length, payload>`:

  * 0: state vector (step 1); the receiver returns a framed step 2.
  * 1: V1 document update (step 2).
  * 2: incremental V1 document update.

  Both peers initiate step 1 to exchange changes in both directions. This
  module handles one complete frame at a time; transport envelopes, rooms,
  awareness, retries and persistence belong to the caller. Malformed or unknown
  frames return `{:error, reason}` without replacing the caller's document.

  Earlier Yelixer versions omitted the payload length and handled only tags
  0 and 1. That custom framing is not accepted as an alternative: it is ambiguous
  with standard frames. Callers using it must move both ends coherently.
  """

  alias Yelixer.{Doc, Encoding}

  @doc "Encodes this replica's state vector as a sync step 1 frame."
  def encode_step1(%Doc{} = doc) do
    encode_frame(0, Encoding.encode_state_vector(Doc.state_vector(doc)))
  end

  @doc "Frames an already encoded V1 document update with upstream update tag 2."
  def encode_update(update) when is_binary(update), do: encode_frame(2, update)

  @doc """
  Returns `{:step2, frame}`, `{:update, doc}`, or `{:error, reason}`.

  An empty document update is encoded as `<<0, 0>>`; a zero-byte update payload
  is malformed. Extra bytes after a frame are rejected rather than discarded.
  """
  def handle_message(%Doc{} = doc, binary) when is_binary(binary) do
    with {:ok, tag, payload} <- decode_frame(binary) do
      handle_payload(doc, tag, payload)
    end
  end

  defp handle_payload(doc, 0, payload) do
    case Encoding.decode_state_vector(payload) do
      {:ok, {remote_sv, <<>>}} ->
        {:step2, encode_frame(1, Encoding.encode_diff(doc, remote_sv))}

      {:ok, {_remote_sv, _trailing}} ->
        {:error, :trailing_state_vector_bytes}

      {:error, _} = error ->
        error
    end
  end

  defp handle_payload(doc, tag, payload) when tag in [1, 2] do
    case Encoding.apply_update(doc, payload) do
      {:ok, updated} -> {:update, updated}
      {:error, _} = error -> error
    end
  end

  defp handle_payload(_doc, tag, _payload), do: {:error, {:unknown_sync_message, tag}}

  defp encode_frame(tag, payload) do
    <<Encoding.encode_uint(tag)::binary, Encoding.encode_uint(byte_size(payload))::binary,
      payload::binary>>
  end

  defp decode_frame(binary) do
    {tag, rest} = Encoding.decode_uint(binary)
    {length, rest} = Encoding.decode_uint(rest)
    <<payload::binary-size(length)>> = rest
    {:ok, tag, payload}
  rescue
    _error in [MatchError, FunctionClauseError, ArgumentError] ->
      {:error, :malformed_sync_frame}
  end
end
