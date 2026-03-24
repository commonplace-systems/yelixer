defmodule Yelixer.EncodingTest do
  use ExUnit.Case, async: true

  alias Yelixer.Encoding

  describe "varint encoding" do
    test "encodes small integers in 1 byte" do
      assert Encoding.encode_uint(0) == <<0>>
      assert Encoding.encode_uint(127) == <<127>>
    end

    test "encodes larger integers in multiple bytes" do
      assert Encoding.encode_uint(128) == <<128, 1>>
      assert Encoding.encode_uint(300) == <<172, 2>>
    end

    test "roundtrips through encode/decode" do
      for n <- [0, 1, 127, 128, 255, 256, 16383, 16384, 1_000_000] do
        encoded = Encoding.encode_uint(n)
        {decoded, ""} = Encoding.decode_uint(encoded)
        assert decoded == n, "Failed roundtrip for #{n}"
      end
    end

    test "decodes with remaining bytes" do
      data = <<172, 2, 99, 100>>
      {value, rest} = Encoding.decode_uint(data)
      assert value == 300
      assert rest == <<99, 100>>
    end
  end

  describe "signed varint (zigzag) encoding" do
    test "encode_sint(-1) produces <<1>>" do
      assert Encoding.encode_sint(-1) == <<1>>
    end

    test "encode_sint(-2) produces <<3>>" do
      assert Encoding.encode_sint(-2) == <<3>>
    end

    test "zigzag maps 0 -> 0, -1 -> 1, 1 -> 2, -2 -> 3, 2 -> 4" do
      assert Encoding.encode_sint(0) == Encoding.encode_uint(0)
      assert Encoding.encode_sint(-1) == Encoding.encode_uint(1)
      assert Encoding.encode_sint(1) == Encoding.encode_uint(2)
      assert Encoding.encode_sint(-2) == Encoding.encode_uint(3)
      assert Encoding.encode_sint(2) == Encoding.encode_uint(4)
    end

    test "roundtrips negative integers through encode/decode" do
      for n <- [-1, -2, -127, -128, -255, -256, -16383, -16384, -1_000_000] do
        encoded = Encoding.encode_sint(n)
        {decoded, ""} = Encoding.decode_sint(encoded)
        assert decoded == n, "Failed roundtrip for #{n}"
      end
    end

    test "roundtrips positive and zero through encode/decode" do
      for n <- [0, 1, 127, 128, 255, 256, 16383, 16384, 1_000_000] do
        encoded = Encoding.encode_sint(n)
        {decoded, ""} = Encoding.decode_sint(encoded)
        assert decoded == n, "Failed roundtrip for #{n}"
      end
    end
  end

  describe "string encoding" do
    test "roundtrips strings" do
      for s <- ["", "hello", "emoji: 🎉", "multi\nline"] do
        encoded = Encoding.encode_string(s)
        {decoded, ""} = Encoding.decode_string(encoded)
        assert decoded == s, "Failed roundtrip for #{inspect(s)}"
      end
    end
  end

  describe "boolean Any encoding (lib0 convention: data ? 120 : 121)" do
    test "true encodes to tag 120" do
      assert Encoding.encode_any_value(true) == <<120>>
    end

    test "false encodes to tag 121" do
      assert Encoding.encode_any_value(false) == <<121>>
    end

    test "tag 120 decodes to true" do
      assert Encoding.decode_any_value(<<120>>) == {true, <<>>}
    end

    test "tag 121 decodes to false" do
      assert Encoding.decode_any_value(<<121>>) == {false, <<>>}
    end

    test "boolean roundtrips through encode/decode" do
      for val <- [true, false] do
        encoded = Encoding.encode_any_value(val)
        {decoded, <<>>} = Encoding.decode_any_value(encoded)
        assert decoded == val, "Failed roundtrip for #{val}"
      end
    end

    test "boolean decodes with remaining bytes" do
      {val, rest} = Encoding.decode_any_value(<<120, 99, 100>>)
      assert val == true
      assert rest == <<99, 100>>
    end
  end

  describe "state vector encoding" do
    test "roundtrips state vector" do
      sv =
        Yelixer.StateVector.new()
        |> Yelixer.StateVector.set(1, 5)
        |> Yelixer.StateVector.set(42, 100)

      encoded = Encoding.encode_state_vector(sv)
      {:ok, {decoded, ""}} = Encoding.decode_state_vector(encoded)
      assert Yelixer.StateVector.get(decoded, 1) == 5
      assert Yelixer.StateVector.get(decoded, 42) == 100
    end

    test "empty state vector roundtrips" do
      sv = Yelixer.StateVector.new()
      encoded = Encoding.encode_state_vector(sv)
      {:ok, {decoded, ""}} = Encoding.decode_state_vector(encoded)
      assert decoded.clocks == %{}
    end
  end

  describe "Any integer encoding (lib0 writeVarInt)" do
    test "roundtrips integers through encode_any_value/decode_any_value" do
      for n <- [0, 1, -1, 63, 64, -64, 127, 128, -128, 1000, -1000] do
        encoded = Encoding.encode_any_value(n)
        {decoded, ""} = Encoding.decode_any_value(encoded)
        assert decoded == n, "Failed roundtrip for #{n}"
      end
    end

    test "produces correct lib0 writeVarInt wire bytes for key values" do
      # Tag 125 = integer, then lib0 writeVarInt bytes
      # 0: first byte = 0 (positive, value 0, no continuation)
      assert Encoding.encode_any_value(0) == <<125, 0>>

      # 1: first byte = 1 (positive, value 1, no continuation)
      assert Encoding.encode_any_value(1) == <<125, 1>>

      # -1: first byte = 64 | 1 = 65 (negative, value 1, no continuation)
      assert Encoding.encode_any_value(-1) == <<125, 65>>

      # 63: first byte = 63 (positive, value 63, no continuation)
      assert Encoding.encode_any_value(63) == <<125, 63>>

      # 64: first byte = 128 | 0 = 128 (positive, value 0, continuation)
      #     second byte = 1 (value 1, no continuation) -> 64 = 0 + (1 << 6)
      assert Encoding.encode_any_value(64) == <<125, 128, 1>>

      # -64: first byte = 128 | 64 | 0 = 192 (negative, value 0, continuation)
      #      second byte = 1 -> abs = 0 + (1 << 6) = 64
      assert Encoding.encode_any_value(-64) == <<125, 192, 1>>

      # 127: first byte = 128 | 63 = 191 (positive, value 63, continuation)
      #      second byte = 1 (value 1, no continuation) -> 127 = 63 + (1 << 6)
      assert Encoding.encode_any_value(127) == <<125, 191, 1>>

      # 1000: 1000 = 40 + (15 << 6) = 40 + 960
      #   first byte = 128 | 40 = 168 (positive, value 40, continuation)
      #   second byte = 15 (value 15, no continuation)
      assert Encoding.encode_any_value(1000) == <<125, 168, 15>>

      # -1000: abs=1000 = 40 + (15 << 6)
      #   first byte = 128 | 64 | 40 = 232 (negative, value 40, continuation)
      #   second byte = 15
      assert Encoding.encode_any_value(-1000) == <<125, 232, 15>>
    end

    test "does not confuse with zigzag encoding" do
      # In zigzag, 1 encodes as varuint(2) = <<2>>
      # In lib0 writeVarInt, 1 encodes as <<1>>
      # The Any tag is 125, so:
      assert Encoding.encode_any_value(1) == <<125, 1>>
      # NOT <<125, 2>> which zigzag would produce

      # In zigzag, -1 encodes as varuint(1) = <<1>>
      # In lib0 writeVarInt, -1 encodes as <<65>> (64 | 1)
      assert Encoding.encode_any_value(-1) == <<125, 65>>
      # NOT <<125, 1>> which zigzag would produce
    end
  end

  describe "delete set encoding" do
    test "roundtrips delete set" do
      ds =
        Yelixer.DeleteSet.new()
        |> Yelixer.DeleteSet.insert(1, 5, 3)
        |> Yelixer.DeleteSet.insert(2, 0, 10)

      encoded = Encoding.encode_delete_set(ds)
      {decoded, ""} = Encoding.decode_delete_set(encoded)
      assert Yelixer.DeleteSet.deleted?(decoded, 1, 5)
      assert Yelixer.DeleteSet.deleted?(decoded, 1, 7)
      refute Yelixer.DeleteSet.deleted?(decoded, 1, 8)
      assert Yelixer.DeleteSet.deleted?(decoded, 2, 0)
      assert Yelixer.DeleteSet.deleted?(decoded, 2, 9)
    end
  end
end
