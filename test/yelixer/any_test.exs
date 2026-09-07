Code.require_file("../support/compat_oracle.exs", __DIR__)

defmodule Yelixer.AnyTest do
  use ExUnit.Case, async: false

  alias Yelixer.{Any, Doc, Encoding}
  alias Yelixer.Types.{Array, YMap}
  alias Yelixer.Test.CompatOracle, as: O

  test "explicit wrappers author map and array values matching official Yjs types" do
    port = O.open(Path.expand("../fixtures/any_types_driver.mjs", __DIR__))
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    for {name, value} <- [
          {"buffer", Any.buffer(<<0, 65, 255, 128>>)},
          {"undefined", Any.undefined()},
          {"bigint", Any.bigint(42)}
        ] do
      source = O.rpc(port, %{cmd: "seed", case: name})
      {doc, _} = Doc.get_or_create_type(Doc.new(client_id: 7), "values", :map)
      {doc, _} = Doc.get_or_create_type(doc, "items", :array)
      payload = %{"payload" => value}
      doc = doc |> YMap.set("values", "value", payload) |> Array.insert("items", 0, [payload])
      encoded = Encoding.encode_update(doc)

      assert O.rpc(port, %{cmd: "inspect", update: Base.encode16(encoded, case: :lower)}) ==
               Map.take(source, ["ok", "map", "array", "sv"])

      {:ok, reopened} = Encoding.apply_update(Doc.new(), encoded)
      assert YMap.get(reopened, "values", "value") == payload
      assert Array.to_list(reopened, "items") == [payload]
    end
  end

  test "bigint boundaries are exact and oversized literal structs cannot truncate" do
    for n <- [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807] do
      encoded = Encoding.encode_any_value(Any.bigint(n))
      assert encoded == <<122, n::signed-64>>
      assert Encoding.decode_any_value(encoded) == {Any.bigint(n), <<>>}
    end

    for n <- [-9_223_372_036_854_775_809, 9_223_372_036_854_775_808, 1.0] do
      assert_raise ArgumentError, fn -> Any.bigint(n) end

      assert_raise ArgumentError, fn ->
        Encoding.encode_any_value(%Any{type: :bigint, value: n})
      end
    end
  end

  test "ordinary binary, nil and integer authoring remain string, null and number" do
    assert Encoding.encode_any_value("AB") == <<119, 2, 65, 66>>
    assert Encoding.encode_any_value(nil) == <<126>>
    assert Encoding.encode_any_value(42) == <<125, 42>>
    assert Encoding.encode_any_value(Any.buffer("AB")) == <<116, 2, 65, 66>>
    assert Encoding.encode_any_value(Any.undefined()) == <<127>>
    assert Encoding.encode_any_value(Any.bigint(42)) == <<122, 42::signed-64>>
  end
end
