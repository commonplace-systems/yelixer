defmodule Yelixer.DecodeFuzzTest do
  @moduledoc """
  Fuzz tests for the yelixer decode path (CX-2j4).

  The goal is NOT to verify correctness of random bytes — random bytes
  usually aren't valid yjs updates. The goal is to confirm the decoder
  returns `{:error, _}` rather than crashing the caller with an
  unhandled exception for any malformed input. Callers downstream of
  apply_update — especially the MCP server and sync agent — need to
  trust that applying an untrusted update cannot bring down the BEAM.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias Yelixer.{Doc, Encoding}

  @moduletag :properties

  property "apply_update never raises on random bytes" do
    check all bytes <- binary(min_length: 0, max_length: 200), max_runs: 500 do
      doc = Doc.new(client_id: 1)

      # apply_update should return either {:ok, doc} for any valid yjs
      # update or {:error, reason} for malformed input. It must never
      # raise an unhandled exception.
      result =
        try do
          Encoding.apply_update(doc, bytes)
        catch
          kind, reason ->
            flunk("apply_update raised #{kind}: #{inspect(reason)} on input #{inspect(bytes, limit: 100)}")
        end

      case result do
        {:ok, _doc} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  property "decode_update never raises on random bytes" do
    check all bytes <- binary(min_length: 0, max_length: 200), max_runs: 500 do
      result =
        try do
          Encoding.decode_update(bytes)
        catch
          kind, reason ->
            flunk("decode_update raised #{kind}: #{inspect(reason)} on input #{inspect(bytes, limit: 100)}")
        end

      case result do
        {:ok, _} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  property "apply_update never raises on truncated valid updates" do
    # Take a known-good update and truncate at a random offset.
    # The decoder should refuse gracefully rather than panicking on
    # an incomplete varint or missing struct.
    check all client <- integer(1..100),
              text <- string(:alphanumeric, min_length: 1, max_length: 40),
              trunc_at <- integer(0..200),
              max_runs: 200 do
      doc = Doc.new(client_id: client)
      {doc, _} = Doc.get_or_create_type(doc, "t", :text)
      doc = Yelixer.Types.Text.insert(doc, "t", 0, text)
      good_update = Encoding.encode_update(doc)

      truncated = :binary.part(good_update, 0, min(trunc_at, byte_size(good_update)))

      result =
        try do
          Encoding.apply_update(Doc.new(client_id: client + 1), truncated)
        catch
          kind, reason ->
            flunk(
              "apply_update raised #{kind}: #{inspect(reason)} on truncated input " <>
                "(trunc_at=#{trunc_at}, orig=#{byte_size(good_update)})"
            )
        end

      case result do
        {:ok, _doc} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  property "apply_update never raises on bit-flipped valid updates" do
    check all text <- string(:alphanumeric, min_length: 1, max_length: 40),
              flip_pos <- integer(0..200),
              flip_bit <- integer(0..7),
              max_runs: 200 do
      doc = Doc.new(client_id: 1)
      {doc, _} = Doc.get_or_create_type(doc, "t", :text)
      doc = Yelixer.Types.Text.insert(doc, "t", 0, text)
      good_update = Encoding.encode_update(doc)

      size = byte_size(good_update)
      pos = rem(flip_pos, max(size, 1))

      flipped =
        if size == 0 do
          good_update
        else
          <<prefix::binary-size(pos), b::8, rest::binary>> = good_update
          <<prefix::binary, Bitwise.bxor(b, 1 <<< flip_bit)::8, rest::binary>>
        end

      result =
        try do
          Encoding.apply_update(Doc.new(client_id: 2), flipped)
        catch
          kind, reason ->
            flunk(
              "apply_update raised #{kind}: #{inspect(reason)} on bit-flipped input " <>
                "(pos=#{pos}, bit=#{flip_bit})"
            )
        end

      case result do
        {:ok, _doc} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end
end
