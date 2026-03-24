defmodule Yelixer.EncodingErrorTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding}

  describe "apply_update error handling" do
    test "apply_update with empty binary returns error" do
      doc = Doc.new(client_id: 1)
      assert {:error, {:malformed_update, _reason}} = Encoding.apply_update(doc, <<>>)
    end

    test "apply_update with truncated varint returns error" do
      doc = Doc.new(client_id: 1)
      # 0x80 = continuation bit set, but no following byte
      assert {:error, {:malformed_update, _reason}} = Encoding.apply_update(doc, <<128>>)
    end

    test "apply_update with truncated string returns error" do
      doc = Doc.new(client_id: 1)
      # Valid update header: 1 client, 1 struct, client_id=1, first_clock=0
      # Then info byte 0x24 (content_ref=4=string, no origin, no right_origin, has_parent_sub=1)
      # ... but actually, let's construct a simpler case:
      # num_clients=1, num_structs=1, client=1, clock=0, info byte with named parent
      # then a string whose declared length exceeds the binary
      header =
        <<1>> <>
          # num_clients=1
          <<1>> <>
          # num_structs=1
          <<1>> <>
          # client=1
          <<0>> <>
          # first_clock=0
          # info byte: content_ref=4 (string), no origin, no right_origin => parent inline
          # parent_info=1 (named), then parent name string
          <<4>> <>
          # info: content_ref=4, no flags
          # Since no origin and no right_origin, parent is read next
          # parent_info=1 means named parent
          <<1>> <>
          # parent_info=1
          # parent name: length=4, "test"
          <<4, 116, 101, 115, 116>> <>
          # Now content (string): declared length=100 but binary ends
          <<100>>

      assert {:error, {:malformed_update, _reason}} = Encoding.apply_update(doc, header)
    end

    test "apply_update with unknown content ref returns error" do
      doc = Doc.new(client_id: 1)
      # Build update: 1 client, 1 struct, client=1, clock=0
      # info byte with content_ref = 15 (unknown, only 0-8 are valid)
      # Since no origin/right_origin, it tries to read parent, which will also be garbage
      header =
        <<1>> <>
          <<1>> <>
          <<1>> <>
          <<0>> <>
          # info byte: content_ref=15 (bits 0-4), no origin/right_origin flags
          <<15>> <>
          # parent_info (since no origin/right_origin)
          <<1>> <>
          # named parent "t"
          <<1, 116>> <>
          # Now decode_content is called with ref=15 — no clause matches
          <<0>>

      assert {:error, {:malformed_update, _reason}} = Encoding.apply_update(doc, header)
    end
  end

  describe "decode_update error handling" do
    test "decode_update with empty binary returns error" do
      assert {:error, {:malformed_update, _reason}} = Encoding.decode_update(<<>>)
    end

    test "decode_update with garbage binary returns error" do
      # Random bytes that will fail at various decode stages
      assert {:error, {:malformed_update, _reason}} =
               Encoding.decode_update(<<255, 255, 255, 255, 255, 255>>)
    end

    test "decode_update with truncated varint returns error" do
      # Multi-byte varint that never terminates (all continuation bits set)
      assert {:error, {:malformed_update, _reason}} = Encoding.decode_update(<<128, 128, 128>>)
    end

    test "decode_update with truncated struct data returns error" do
      # num_clients=1, num_structs=1, client=1, clock=0, then binary ends
      assert {:error, {:malformed_update, _reason}} =
               Encoding.decode_update(<<1, 1, 1, 0>>)
    end

    test "decode_update with truncated content data returns error" do
      # Valid header up to content, but content is truncated
      # 1 client, 1 struct, client=1, clock=0, info=4 (string content, no flags)
      # parent_info=1 (named), parent="t", then string content length=10 but no data
      bin = <<1, 1, 1, 0, 4, 1, 1, 116, 10>>
      assert {:error, {:malformed_update, _reason}} = Encoding.decode_update(bin)
    end
  end

  describe "decode_state_vector error handling" do
    test "decode_state_vector with empty binary returns error" do
      assert {:error, {:malformed_state_vector, _reason}} =
               Encoding.decode_state_vector(<<>>)
    end

    test "decode_state_vector with truncated data returns error" do
      # count=2 but only enough data for 0 pairs
      assert {:error, {:malformed_state_vector, _reason}} =
               Encoding.decode_state_vector(<<2>>)
    end

    test "decode_state_vector with truncated varint returns error" do
      # count=1, client starts with continuation bit but ends
      assert {:error, {:malformed_state_vector, _reason}} =
               Encoding.decode_state_vector(<<1, 128>>)
    end

    test "decode_state_vector with truncated pair returns error" do
      # count=1, client=5, then binary ends (no clock)
      assert {:error, {:malformed_state_vector, _reason}} =
               Encoding.decode_state_vector(<<1, 5>>)
    end
  end
end
