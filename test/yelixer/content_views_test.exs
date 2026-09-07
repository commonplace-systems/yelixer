Code.require_file("../support/compat_oracle.exs", __DIR__)

defmodule Yelixer.ContentViewsTest do
  use ExUnit.Case, async: false

  alias Yelixer.{Any, Doc, Encoding}
  alias Yelixer.Types.{Array, Text, YMap}
  alias Yelixer.Test.CompatOracle, as: O

  setup do
    port = O.open()
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    O.reset(port, 7301)
    %{port: port}
  end

  for {label, bytes} <- [{"UTF-8", <<0, 0, 1, 44>>}, {"non-UTF-8", <<0, 255, 254, 1>>}] do
    test "foreign #{label} map buffer survives every read and reauthoring", %{port: port} do
      bytes = unquote(bytes)
      O.rpc(port, %{cmd: "set_map_binary", root: "root", key: "k",
        hex: Base.encode16(bytes, case: :lower)})
      doc = O.load(O.update(port))
      assert YMap.get(doc, "root", "k") == Any.buffer(bytes)
      assert YMap.to_map(doc, "root") == %{"k" => Any.buffer(bytes)}
      assert YMap.to_json(doc, "root") == %{"k" => Any.buffer(bytes)}
      assert YMap.get(O.reload(doc), "root", "k") == Any.buffer(bytes)

      copied = YMap.set(Doc.new(client_id: 7302), "root", "k", YMap.get(doc, "root", "k"))
      O.reset(port, 7303)
      O.apply(port, Encoding.encode_update(copied))
      assert O.rpc(port, %{cmd: "map_get_type", root: "root", key: "k"})["is_uint8array"]
    end

    test "foreign #{label} array buffer remains a typed value", %{port: port} do
      bytes = unquote(bytes)
      O.rpc(port, %{cmd: "array_push_binary", root: "items",
        hex: Base.encode16(bytes, case: :lower)})
      doc = O.load(O.update(port))
      assert Array.to_list(doc, "items") == [Any.buffer(bytes)]
      assert Array.to_json(doc, "items") == [Any.buffer(bytes)]
      assert Array.to_list(O.reload(doc), "items") == [Any.buffer(bytes)]
    end
  end

  test "foreign nested map value resolves in all map readers", %{port: port} do
    O.rpc(port, %{cmd: "map_set_nested_array", root: "root", key: "k", values: [1, 2]})
    expected = O.rpc(port, %{cmd: "map_content", name: "root"})["map"]
    doc = O.load(O.update(port))
    assert YMap.get(doc, "root", "k") == expected["k"]
    assert YMap.to_map(doc, "root") == expected
    assert YMap.to_json(doc, "root") == expected
  end

  test "foreign nested array resolves through to_list", %{port: port} do
    O.rpc(port, %{cmd: "array_push_nested_array", root: "items", values: [1, 2]})
    expected = O.rpc(port, %{cmd: "array_content", name: "items"})["array"]
    doc = O.load(O.update(port))
    assert Array.to_list(doc, "items") == expected
    assert Array.to_json(doc, "items") == expected
    assert Array.to_list(O.reload(doc), "items") == expected
  end

  test "formatted text length counts UTF-16 and embeds but not format clocks", %{port: port} do
    O.rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "A\u{1F600}B"})
    O.rpc(port, %{cmd: "insert_embed_text", name: "content", pos: 4, embed: %{"img" => "x"}})
    O.rpc(port, %{cmd: "format_text", name: "content", pos: 0, len: 4, key: "bold", value: true})
    expected = O.rpc(port, %{cmd: "text_length", name: "content"})["length"]
    assert expected == 5
    doc = O.load(O.update(port))
    assert Text.length(doc, "content") == expected
    assert Text.length(O.reload(doc), "content") == expected
  end

  test "ordinary values and missing keys retain their existing meanings", %{port: port} do
    doc = Doc.new(client_id: 7304)
      |> YMap.set("root", "s", "hello")
      |> YMap.set("root", "nil", nil)
      |> Array.insert("items", 0, [1, "two", false, nil])
    assert YMap.get(doc, "root", "absent") == nil
    assert YMap.get(doc, "root", "s") == "hello"
    assert YMap.to_map(doc, "root") == %{"s" => "hello", "nil" => nil}
    assert Array.to_list(doc, "items") == [1, "two", false, nil]
    O.apply(port, Encoding.encode_update(doc))
    assert O.rpc(port, %{cmd: "map_content", name: "root"})["map"] == YMap.to_map(doc, "root")
    assert O.rpc(port, %{cmd: "array_content", name: "items"})["array"] == Array.to_list(doc, "items")
  end
end
