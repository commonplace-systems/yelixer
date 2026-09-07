defmodule Yelixer.ParserBudgetTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Encoding, StateVector}

  test "unsigned varints reject continuation beyond ten bytes" do
    padded_zero = :binary.copy(<<128>>, 10) <> <<0>>
    assert_raise ArgumentError, fn -> Encoding.decode_uint(padded_zero) end
  end

  test "unsigned 64-bit maximum remains readable with its trailing payload" do
    maximum = 18_446_744_073_709_551_615
    bytes = Encoding.encode_uint(maximum)
    assert byte_size(bytes) == 10
    assert Encoding.decode_uint(bytes <> <<42>>) == {maximum, <<42>>}
  end

  test "signed Any varints reject excessive zero padding" do
    padded_zero = <<125>> <> :binary.copy(<<128>>, 10) <> <<0>>
    assert_raise ArgumentError, fn -> Encoding.decode_any_value(padded_zero) end
  end

  for {name, prefix} <- [{"array", <<117, 1>>}, {"object", <<118, 1, 0>>}] do
    test "Any #{name} nesting rejects depth 129" do
      bytes = :binary.copy(unquote(prefix), 129) <> <<126>>
      assert_raise ArgumentError, fn -> Encoding.decode_any_value(bytes) end
    end

    test "Any #{name} nesting permits depth 128 and preserves the tail" do
      bytes = :binary.copy(unquote(prefix), 128) <> <<126>>
      {value, <<42>>} = Encoding.decode_any_value(bytes <> <<42>>)
      assert Encoding.encode_any_value(value) == bytes
    end
  end

  test "state vector rejects unsafe client and clock integers" do
    unsafe = Encoding.encode_uint(9_007_199_254_740_992)
    for bytes <- [<<1>> <> unsafe <> <<0>>, <<1, 1>> <> unsafe] do
      assert {:error, {:malformed_state_vector, _}} = Encoding.decode_state_vector(bytes)
    end
  end

  test "state vector keeps maximum-safe identities and clocks" do
    maximum = 9_007_199_254_740_991
    sv = StateVector.new() |> StateVector.set(maximum, maximum)
    assert Encoding.decode_state_vector(Encoding.encode_state_vector(sv)) == {:ok, {sv, <<>>}}
  end

  test "malformed state-vector count returns a tagged refusal" do
    assert {:error, {:malformed_state_vector, _}} =
             Encoding.decode_state_vector(<<255, 255, 255, 255, 15>>)
  end
end
