Code.require_file("../support/compat_oracle.exs", __DIR__)

defmodule Yelixer.UnicodeCompatTest do
  use ExUnit.Case, async: false
  alias Yelixer.{Doc, Encoding, Item, ID}
  alias Yelixer.Types.Text
  alias Yelixer.Test.CompatOracle, as: O

  @cases Jason.decode!(File.read!(Path.expand("../fixtures/unicode_cases.json", __DIR__)))

  setup do
    port = O.open()
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    %{port: port}
  end

  for fixture <- @cases, fresh <- [false, true] do
    @fixture fixture
    @fresh fresh
    test "#{fixture["name"]}: alternating runtimes, #{if fresh, do: "fresh", else: "reused"} server IDs, diffs and reload",
         %{port: p} do
      f = @fixture
      s = f["text"]
      n = f["units"]
      assert String.to_charlist(s) == f["codepoints"]
      assert String.length(s) == f["graphemes"]
      O.reset(p, 200)
      O.rpc(p, %{cmd: "insert_text", pos: 0, text: "L" <> s <> "R"})
      doc = O.load(O.update(p), 100)
      assert Text.length(doc, "content") == n + 2
      assert Text.to_string(doc, "content") == "L" <> s <> "R"
      doc = Text.insert(doc, "content", n + 1, "!")
      O.apply(p, Encoding.encode_diff(doc, O.sv(p)))
      assert O.text(p) == "L" <> s <> "!R"
      assert O.sv(p) == Doc.state_vector(doc)
      doc = O.reload(doc)
      O.rpc(p, %{cmd: "reload"})
      O.rpc(p, %{cmd: "insert_text", pos: 0, text: "^"})
      {:ok, doc} = Encoding.apply_update(doc, O.update(p, Doc.state_vector(doc)))
      assert Text.to_string(doc, "content") == "^L" <> s <> "!R"
      doc = if @fresh, do: %{doc | client_id: 101}, else: doc
      doc = Text.delete(doc, "content", 2, n) |> Text.insert("content", 4, "$")
      diff = Encoding.encode_diff(doc, O.sv(p))
      O.apply(p, diff)
      O.apply(p, diff)
      assert O.text(p) == "^L!R$"
      assert Text.to_string(O.reload(doc), "content") == "^L!R$"
      assert O.sv(p) == Doc.state_vector(doc)
      O.reset(p, 300)
      O.apply(p, Encoding.encode_update(doc))
      O.rpc(p, %{cmd: "delete_text", pos: 0, len: 1})
      {:ok, doc} = Encoding.apply_update(O.reload(doc), O.update(p))
      assert Text.to_string(doc, "content") == "L!R$"
      assert O.text(p) == "L!R$"
    end
  end

  for fixture <- @cases do
    @fixture fixture
    test "#{fixture["name"]}: server sequential author, delayed dependency and concurrent distinct authors",
         %{port: p} do
      s = @fixture["text"]
      n = @fixture["units"]
      a = Doc.new(client_id: 100) |> Text.insert("content", 0, s)
      b = Text.insert(a, "content", n, "!")
      first = Encoding.encode_update(a)
      second = Encoding.encode_diff(b, Doc.state_vector(a))
      O.reset(p, 200)
      O.apply(p, second)
      O.apply(p, first)
      assert O.text(p) == s <> "!"
      {:ok, pending} = Encoding.apply_update(Doc.new(client_id: 300), second)
      {:ok, loaded} = Encoding.apply_update(pending, first)
      assert Text.to_string(loaded, "content") == s <> "!"
      assert Doc.pending_info(loaded).count == 0
      # Disjoint concurrent edits, with independent expected ordering.
      server = Text.insert(O.reload(b), "content", 0, "^")
      O.rpc(p, %{cmd: "insert_text", pos: n + 1, text: "$"})
      foreign = O.update(p, Doc.state_vector(b))
      O.apply(p, Encoding.encode_diff(server, Doc.state_vector(b)))
      {:ok, merged} = Encoding.apply_update(server, foreign)
      assert Text.to_string(merged, "content") == "^" <> s <> "!$"
      assert O.text(p) == "^" <> s <> "!$"
      assert O.sv(p) == Doc.state_vector(merged)
    end
  end

  test "a combining sequence can be edited at its interior scalar boundary", %{port: p} do
    O.reset(p, 200)
    a = Doc.new(client_id: 100) |> Text.insert("content", 0, "e\u{0301}")
    O.apply(p, Encoding.encode_update(a))
    b = Text.insert(a, "content", 1, "X")
    O.apply(p, Encoding.encode_diff(b, O.sv(p)))
    assert O.text(p) == "eX\u{0301}"
    O.rpc(p, %{cmd: "delete_text", pos: 1, len: 2})
    {:ok, c} = Encoding.apply_update(b, O.update(p))
    assert Text.to_string(c, "content") == "e"
  end

  test "B-up split clocks do not overlap after a surrogate-interior request" do
    item = Item.new(ID.new(100, 0), nil, nil, {:string, "\u{1F600}A"}, {:named, "content"}, nil)
    {left, right} = Item.split(item, 1)
    assert left.content == {:string, "\u{1F600}"}
    assert left.length == 2
    assert right.id == ID.new(100, 2)
    assert right.origin == ID.new(100, 1)
    assert right.length == 1
  end

  test "a received binary consumes one clock before the same author's text", %{port: p} do
    O.reset(p, 200)
    O.rpc(p, %{cmd: "set_map_binary", root: "root", key: "bytes", hex: "00fffe01c864"})
    O.rpc(p, %{cmd: "insert_text", pos: 0, text: "\u{1F600}!"})
    doc = O.load(O.update(p), 100)
    assert Text.to_string(doc, "content") == "\u{1F600}!"
    assert Doc.state_vector(doc) == O.sv(p)
    assert Doc.state_vector(doc).clocks[200] == 4
    O.reset(p, 300)
    O.apply(p, Encoding.encode_update(doc))
    assert O.rpc(p, %{cmd: "map_get_type", root: "root", key: "bytes"})["is_uint8array"]
    assert O.text(p) == "\u{1F600}!"
  end

  test "B-up insertion at the last surrogate preserves exact position through another edit", %{
    port: p
  } do
    O.reset(p, 200)
    doc = Doc.new(client_id: 100) |> Text.insert("content", 0, "\u{1F600}")
    doc = Text.insert(doc, "content", 1, "X")
    assert Text.to_string(doc, "content") == "\u{1F600}X"
    assert Text.length(doc, "content") == 3
    assert Doc.state_vector(doc).clocks[100] == 3
    O.apply(p, Encoding.encode_update(doc))
    assert O.text(p) == "\u{1F600}X"
    doc = O.reload(doc) |> Text.insert("content", 3, "!")
    O.apply(p, Encoding.encode_diff(doc, O.sv(p)))
    assert O.text(p) == "\u{1F600}X!"
  end
end
