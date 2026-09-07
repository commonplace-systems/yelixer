Code.require_file("../support/compat_oracle.exs", __DIR__)

defmodule Yelixer.UnicodeBoundaryTest do
  use ExUnit.Case, async: false
  alias Yelixer.{Doc, Encoding, StateVector}
  alias Yelixer.Types.Text
  alias Yelixer.Test.CompatOracle, as: O

  @fixture Jason.decode!(
             File.read!(Path.expand("../fixtures/incoming-half-surrogate.json", __DIR__))
           )["histories"]
           |> hd()
  @expected "\u{FFFD}X\u{FFFD}A"

  setup do
    p = O.open()
    on_exit(fn -> if Port.info(p), do: Port.close(p) end)
    %{port: p}
  end

  # Same original bytes as the old/candidate measurements. The incremental
  # path is primary: a fresh final full-state load already passed before repair.
  test "a browser half-surrogate edit cannot silently diverge on receipt", %{port: p} do
    [base, delta] = Enum.map(@fixture["updates_hex"], &Base.decode16!(&1, case: :lower))
    O.reset(p, 900)
    O.apply(p, base)
    doc = O.load(base, 200)
    assert Text.to_string(doc, "content") == "\u{1F600}A"
    O.apply(p, delta)
    assert O.text(p) == @expected
    {:ok, doc} = Encoding.apply_update(doc, delta)
    assert Text.to_string(doc, "content") == @expected
    assert Doc.state_vector(doc) == %StateVector{clocks: %{100 => 4}}
    assert Doc.state_vector(doc) == O.sv(p)
    {:ok, doc} = Encoding.apply_update(doc, delta)
    O.apply(p, delta)
    assert Text.to_string(doc, "content") == @expected
    assert Doc.state_vector(doc) == O.sv(p)

    doc = O.reload(doc)
    O.rpc(p, %{cmd: "reload"})
    assert Text.to_string(doc, "content") == @expected
    doc = Text.insert(doc, "content", 4, "$")
    O.apply(p, Encoding.encode_diff(doc, O.sv(p)))
    assert O.text(p) == @expected <> "$"
    O.rpc(p, %{cmd: "insert_text", pos: 0, text: "^"})
    {:ok, doc} = Encoding.apply_update(doc, O.update(p, Doc.state_vector(doc)))
    assert Text.to_string(O.reload(doc), "content") == "^" <> @expected <> "$"
    assert Doc.state_vector(doc) == O.sv(p)
  end

  for {label, base, at, expected} <- [
        {"ASCII interior", "ab", 1, "aXb"},
        {"before astral scalar", "\u{1F600}A", 0, "X\u{1F600}A"},
        {"after astral scalar", "\u{1F600}A", 2, "\u{1F600}XA"},
        {"end of astral document", "\u{1F600}A", 3, "\u{1F600}AX"}
      ] do
    @base base
    @at at
    @wanted expected
    test "adjacent valid scalar control: #{label}", %{port: p} do
      O.reset(p, 100)
      O.rpc(p, %{cmd: "insert_text", pos: 0, text: @base})
      doc = O.load(O.update(p), 200)
      vector = O.sv(p)
      O.rpc(p, %{cmd: "insert_text", pos: @at, text: "X"})
      {:ok, doc} = Encoding.apply_update(doc, O.update(p, vector))
      assert O.text(p) == @wanted
      assert Text.to_string(O.reload(doc), "content") == @wanted
      assert Doc.state_vector(doc) == O.sv(p)
    end
  end

  for at <- [0, 1] do
    @at at
    test "incoming delete of surrogate unit #{at} keeps the exact wire interval", %{port: p} do
      O.reset(p, 100)
      O.rpc(p, %{cmd: "insert_text", pos: 0, text: "\u{1F600}A"})
      doc = O.load(O.update(p), 200)
      vector = O.sv(p)
      O.rpc(p, %{cmd: "delete_text", pos: @at, len: 1})
      delta = O.update(p, vector)
      {:ok, doc} = Encoding.apply_update(doc, delta)
      {:ok, doc} = Encoding.apply_update(doc, delta)
      assert O.text(p) == "\u{FFFD}A"
      assert Text.to_string(O.reload(doc), "content") == "\u{FFFD}A"
      assert Doc.state_vector(doc) == O.sv(p)
      {:ok, {_items, ds, <<>>}} = Encoding.decode_update(O.update(p))
      assert doc.delete_set == ds
    end
  end

  test "a state-vector diff beginning inside a surrogate preserves its clock boundary", %{port: p} do
    O.reset(p, 100)
    O.rpc(p, %{cmd: "insert_text", pos: 0, text: "\u{1F600}A"})
    doc = O.load(O.update(p), 200)
    remote = %StateVector{clocks: %{100 => 1}}
    # Same original history, not independently authored equivalent packing.
    assert Encoding.encode_diff(doc, remote) == O.update(p, remote)
    {:ok, {[tail], _ds, <<>>}} = Encoding.decode_update(Encoding.encode_diff(doc, remote))
    assert tail.id.clock == 1
    assert tail.length == 2
    assert tail.content == {:string, "\u{FFFD}A"}
    assert Text.to_string(doc, "content") == "\u{1F600}A"
  end
end
