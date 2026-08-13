defmodule Yelixer.AdversarialBoundsTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding, DeleteSet}
  alias Yelixer.Types.Text

  # JS Number.MAX_SAFE_INTEGER — the largest clock/length value any
  # legitimate Yjs client can ever produce. See the @max_safe_clock
  # moduledoc note in Yelixer.Encoding.
  @max_safe 9_007_199_254_740_991

  describe "H2(a): delete-set ranges over absent clocks" do
    test "a huge range mostly over absent clocks completes promptly and deletes only real clocks" do
      # Client 7 owns exactly clocks 0,1,2 (one run-length string item).
      doc = Doc.new(client_id: 7)
      {doc, _} = Doc.get_or_create_type(doc, "body", :text)
      doc = Text.insert(doc, "body", 0, "abc")

      # Craft an update carrying no structs, just a delete-set range on
      # client 7 that starts inside the real block (clock 1) and
      # extends 10^12 clocks past it — almost entirely absent territory.
      huge_len = 1_000_000_000_000

      crafted =
        <<Encoding.encode_uint(0)::binary,
          # delete set: 1 client
          Encoding.encode_uint(1)::binary,
          Encoding.encode_uint(7)::binary,
          # 1 range
          Encoding.encode_uint(1)::binary,
          Encoding.encode_uint(1)::binary,
          Encoding.encode_uint(huge_len)::binary>>

      {time_us, result} = :timer.tc(fn -> Encoding.apply_update(doc, crafted) end)

      assert time_us < 1_000_000, "apply_update took #{time_us}us — should be near-instant"
      assert {:ok, applied} = result

      # Clock 0 (untouched by the range) survives; clocks 1 and 2 (the
      # real, existing portion of the crafted range) are deleted.
      assert DeleteSet.deleted?(applied.delete_set, 7, 1)
      assert DeleteSet.deleted?(applied.delete_set, 7, 2)
      refute DeleteSet.deleted?(applied.delete_set, 7, 0)
    end
  end

  describe "H2(b): clock/length poisoning via crafted varints" do
    test "a {:gc, huge} block beyond the safe bound is rejected, doc unchanged" do
      doc = Doc.new(client_id: 1)
      huge = @max_safe + 1

      crafted = build_single_struct_update(client: 9, clock: 0, struct_bytes: <<0, Encoding.encode_uint(huge)::binary>>)

      assert {:error, {:malformed_update, _reason}} = Encoding.apply_update(doc, crafted)
    end

    test "an item whose clock + length exceeds the safe bound is rejected" do
      doc = Doc.new(client_id: 1)
      over = @max_safe + 1

      crafted = build_deleted_content_update(client: 9, clock: 0, tombstone_len: over)

      assert {:error, {:malformed_update, _reason}} = Encoding.apply_update(doc, crafted)
    end

    test "an item whose clock + length is exactly at the safe bound is accepted" do
      doc = Doc.new(client_id: 1)

      crafted = build_deleted_content_update(client: 9, clock: 0, tombstone_len: @max_safe)

      assert {:ok, _applied} = Encoding.apply_update(doc, crafted)
    end

    test "a delete-set range whose end exceeds the safe bound is rejected" do
      doc = Doc.new(client_id: 1)
      over_len = @max_safe + 5

      crafted =
        <<Encoding.encode_uint(0)::binary,
          Encoding.encode_uint(1)::binary,
          Encoding.encode_uint(9)::binary,
          Encoding.encode_uint(1)::binary,
          Encoding.encode_uint(0)::binary,
          Encoding.encode_uint(over_len)::binary>>

      assert {:error, {:malformed_update, _reason}} = Encoding.apply_update(doc, crafted)
    end

    test "a struct count claiming more structs than remaining bytes is rejected, not crashed" do
      # num_clients=1, num_structs=1_000_000, client=9, first_clock=0, then nothing.
      crafted =
        <<Encoding.encode_uint(1)::binary,
          Encoding.encode_uint(1_000_000)::binary,
          Encoding.encode_uint(9)::binary,
          Encoding.encode_uint(0)::binary>>

      assert {:error, {:malformed_update, _reason}} = Encoding.decode_update(crafted)
    end
  end

  # --- Helpers ---

  # Builds a full update binary with exactly one client, one struct,
  # whose struct bytes are supplied verbatim (info byte + payload),
  # followed by an empty delete set.
  defp build_single_struct_update(client: client, clock: clock, struct_bytes: struct_bytes) do
    <<Encoding.encode_uint(1)::binary,
      Encoding.encode_uint(1)::binary,
      Encoding.encode_uint(client)::binary,
      Encoding.encode_uint(clock)::binary,
      struct_bytes::binary,
      Encoding.encode_uint(0)::binary>>
  end

  # Builds a full update binary with one struct carrying `:deleted`
  # content (content_ref 1) with a declared tombstone length —
  # independent of any real bytes, so it's a clean vector for the
  # clock+length bound check. No origin/right_origin, so parent is
  # written explicitly as a named root; no parent_sub flag.
  defp build_deleted_content_update(client: client, clock: clock, tombstone_len: len) do
    # info byte: content_ref = 1 (@content_ref_deleted), no flags set
    info = 1
    parent_info = 1
    parent_name = Encoding.encode_string("root")

    struct_bytes =
      <<info, parent_info, parent_name::binary, Encoding.encode_uint(len)::binary>>

    build_single_struct_update(client: client, clock: clock, struct_bytes: struct_bytes)
  end
end
