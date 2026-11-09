defmodule Yelixer.AnySetTimeCheckTest do
  @moduledoc """
  An integer lib0 Any cannot carry exactly is refused at the write (the public
  insert paths), with the encoder's value-free ArgumentError, so it can never
  make every later encode of the whole document raise. Also pins the float
  range edge: above 2^1024 the refusal is ArgumentError, not ArithmeticError.
  """
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Array, XMLElement, YMap}

  @inexact Bitwise.bsl(1, 69) + 1
  @huge Bitwise.bsl(1, 1100)
  @bound Bitwise.bsl(1, 69)

  defp base_doc do
    Doc.new(client_id: 7) |> YMap.set("m", "ok", @bound) |> Array.insert("a", 0, [1, @bound])
  end

  defp assert_still_encodes(doc) do
    {:ok, copy} = Encoding.apply_update(Doc.new(client_id: 8), Encoding.encode_update(doc))
    assert YMap.get(copy, "m", "ok") === @bound
    assert Array.to_json(copy, "a") == [1, @bound]
  end

  test "beyond float range (+/-2^1100) is the same ArgumentError, not ArithmeticError" do
    assert_raise ArgumentError, ~r/^integer of 1101 bits /, fn ->
      Encoding.encode_any_value(@huge)
    end

    assert_raise ArgumentError, ~r/^integer of 1101 bits /, fn ->
      Encoding.encode_any_value(-@huge)
    end

    assert_raise ArgumentError, ~r/^integer of 1101 bits /, fn ->
      YMap.set(base_doc(), "m", "k", @huge)
    end

    assert_raise ArgumentError, ~r/^integer of 1101 bits /, fn ->
      YMap.set(base_doc(), "m", "k", -@huge)
    end

    assert Encoding.any_integer_form(@huge) == :inexact
    assert Encoding.any_integer_form(Bitwise.bsl(1, 1024) - 1) == :inexact
    assert {:float64, _} = Encoding.any_integer_form(Bitwise.bsl(1, 1023))
  end

  test "YMap.set refuses an inexact integer at the call, and the doc still encodes" do
    doc = base_doc()

    assert_raise ArgumentError, ~r/^integer of 70 bits /, fn ->
      YMap.set(doc, "m", "k", @inexact)
    end

    assert_still_encodes(doc)
  end

  test "Array.insert and push refuse an inexact element at the call, inserting none of the list" do
    doc = base_doc()

    assert_raise ArgumentError, ~r/^integer of 70 bits /, fn ->
      Array.insert(doc, "a", 0, [2, @inexact])
    end

    assert_raise ArgumentError, ~r/^integer of 70 bits /, fn ->
      Array.push(doc, "a", [@inexact])
    end

    assert_still_encodes(doc)
  end

  test "XMLElement.set_attribute refuses an inexact integer at the call" do
    doc = base_doc()

    assert_raise ArgumentError, ~r/^integer of 70 bits /, fn ->
      XMLElement.set_attribute(doc, "x", "k", @inexact)
    end

    assert_still_encodes(doc)
  end

  test "nested inside map values and lists is refused at the call" do
    doc = base_doc()

    assert_raise ArgumentError, fn ->
      YMap.set(doc, "m", "k", %{"a" => [1, %{"b" => @inexact}]})
    end

    assert_raise ArgumentError, fn -> Array.insert(doc, "a", 0, [[[@inexact]]]) end
    assert_still_encodes(doc)
  end

  test "everything the encoder accepts is still accepted at set time" do
    values = [
      0,
      -1,
      Bitwise.bsl(1, 69) - 1,
      @bound,
      -@bound,
      Bitwise.bsl(1, 70),
      Bitwise.bsl(1, 1023),
      1.5,
      "s",
      true,
      nil,
      [1, [@bound]],
      %{"k" => [@bound]},
      Yelixer.Any.buffer(<<1>>),
      Yelixer.Any.bigint(-5)
    ]

    doc =
      Enum.reduce(values, base_doc(), fn v, d -> YMap.set(d, "m", "v", v) end)
      |> Array.insert("a", 0, values)

    assert is_binary(Encoding.encode_update(doc))
    Enum.each(values, fn v -> assert Encoding.validate_any_value!(v) == :ok end)
  end
end
