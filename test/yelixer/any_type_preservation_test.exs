Code.require_file("../support/compat_oracle.exs", __DIR__)

defmodule Yelixer.AnyTypePreservationTest do
  use ExUnit.Case, async: false

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Test.CompatOracle, as: O

  @driver Path.expand("../fixtures/any_types_driver.mjs", __DIR__)

  for {label, hex} <- [
        {"buffer", "74040041ff80"},
        {"undefined", "7f"},
        {"bigint", "7a000000000000002a"}
      ] do
    test "Any #{label} keeps its wire type on decode and encode" do
      bytes = Base.decode16!(unquote(hex), case: :lower)
      {value, <<>>} = Encoding.decode_any_value(bytes)
      assert Encoding.encode_any_value(value) == bytes
    end
  end

  for name <- ~w(buffer undefined bigint bigint_min bigint_max nested ordinary) do
    test "official Yjs #{name} survives map and array update reloads" do
      port = O.open(@driver)
      on_exit(fn -> if Port.info(port), do: Port.close(port) end)
      source = O.rpc(port, %{cmd: "seed", case: unquote(name)})
      assert Map.has_key?(source, "update"), inspect(source)
      original = Base.decode16!(source["update"], case: :lower)
      {:ok, doc} = Encoding.apply_update(Doc.new(), original)
      encoded = Encoding.encode_update(doc)
      expected = Map.take(source, ["ok", "map", "array", "sv"])

      assert O.rpc(port, %{cmd: "inspect", update: Base.encode16(encoded, case: :lower)}) ==
               expected

      {:ok, reopened} = Encoding.apply_update(Doc.new(), encoded)
      assert Encoding.encode_update(reopened) == encoded

      assert O.rpc(port, %{
               cmd: "inspect",
               update: Base.encode16(Encoding.encode_update(reopened), case: :lower)
             }) == expected
    end
  end
end
