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

  describe "string encoding" do
    test "roundtrips strings" do
      for s <- ["", "hello", "emoji: 🎉", "multi\nline"] do
        encoded = Encoding.encode_string(s)
        {decoded, ""} = Encoding.decode_string(encoded)
        assert decoded == s, "Failed roundtrip for #{inspect(s)}"
      end
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
