defmodule Yelixer.AnyVarintBoundTest do
  @moduledoc """
  The lib0 Any integer boundary. The decoder reads signed varints of at most ten
  bytes (magnitude below 2^69); larger integers go out as float64 only when the
  double holds them exactly, and otherwise encoding raises instead of rounding.
  """
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.YMap

  @below Bitwise.bsl(1, 69) - 1
  @bound Bitwise.bsl(1, 69)
  @inexact Bitwise.bsl(1, 69) + 1
  @above Bitwise.bsl(1, 70)

  # Array.insert/4's own construction, minus its set-time check.
  defp raw_doc(value) do
    doc = Doc.new(client_id: 7)
    id = Yelixer.ID.new(doc.client_id, Doc.mint_clock(doc))
    item = Yelixer.Item.new(id, nil, nil, {:any, [value]}, {:named, "a"}, nil)
    {:ok, store} = Yelixer.Integrate.integrate(doc.store, item, "a")
    %{doc | store: store}
  end

  defp doc_round_trip(value) do
    bytes = Doc.new(client_id: 7) |> YMap.set("m", "k", value) |> Encoding.encode_update()
    {:ok, doc} = Encoding.apply_update(Doc.new(client_id: 8), bytes)
    YMap.get(doc, "m", "k")
  end

  test "2^69 - 1 stays a varint and round-trips exactly" do
    assert <<125, _::binary>> = bytes = Encoding.encode_any_value(@below)
    assert {@below, ""} = Encoding.decode_any_value(bytes)
    assert doc_round_trip(@below) === @below
    assert doc_round_trip(-@below) === -@below
  end

  test "2^69 is written as float64 and round-trips exactly" do
    assert <<123, _::float-64>> = bytes = Encoding.encode_any_value(@bound)
    assert {@bound, ""} = Encoding.decode_any_value(bytes)
    assert doc_round_trip(@bound) === @bound
    assert doc_round_trip(-@bound) === -@bound
  end

  test "2^69 + 1 is not exactly a float64, so encoding raises instead of rounding" do
    assert_raise ArgumentError, ~r/^integer of 70 bits /, fn ->
      Encoding.encode_any_value(@inexact)
    end

    # Encode-time backstop: a doc that holds the value without going through
    # a set-time check (as a decoded or hand-built doc can).
    assert {:ok, _} = Encoding.apply_update(Doc.new(), Encoding.encode_update(raw_doc(@bound)))
    doc = raw_doc(@inexact)
    assert_raise ArgumentError, ~r/^integer of 70 bits /, fn -> Encoding.encode_update(doc) end
  end

  test "2^70 round-trips exactly" do
    assert {@above, ""} = @above |> Encoding.encode_any_value() |> Encoding.decode_any_value()
    assert doc_round_trip(@above) === @above
    assert doc_round_trip(-@above) === -@above
  end
end
