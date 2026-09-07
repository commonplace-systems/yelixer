defmodule Yelixer.ClockRangeViewTest do
  use ExUnit.Case, async: true

  alias Yelixer.{BlockStore, Doc, Encoding, ID, Item, StateVector}

  defp store(layout) do
    first = Item.new(ID.new(7, 0), nil, nil, {:string, "😀"}, {:named, "text"}, nil)
    middle = Item.new(ID.new(7, 2), ID.new(7, 1), nil, {:string, "AB"}, {:named, "text"}, nil)
    last = Item.new(ID.new(7, 4), ID.new(7, 3), nil, {:string, "C"}, {:named, "text"}, nil)
    store = BlockStore.new() |> BlockStore.push(first) |> BlockStore.push(middle)
    store = if layout == :mixed, do: BlockStore.materialize_all(store), else: store
    store = BlockStore.push(store, last)

    store =
      if layout in [:materialized, :invalidated],
        do: BlockStore.materialize_all(store),
        else: store

    store =
      if layout == :invalidated, do: BlockStore.invalidate_tuple_cache(store, 7), else: store

    {store, middle}
  end

  for layout <- [:pending, :materialized, :mixed, :invalidated] do
    test "diff preserves a partial run and deferred deletion in #{layout} storage" do
      layout = unquote(layout)
      {store, middle} = store(layout)
      doc = %{Doc.new() | store: store}

      {:ok, {[tail, last_decoded], _ds, <<>>}} =
        Encoding.decode_update(
          Encoding.encode_diff(doc, StateVector.set(StateVector.new(), 7, 3))
        )

      assert {tail.id, tail.content, tail.origin} == {ID.new(7, 3), {:string, "B"}, ID.new(7, 2)}
      assert {last_decoded.id, last_decoded.content} == {ID.new(7, 4), {:string, "C"}}

      doc = %{doc | store: BlockStore.tombstone(store, middle.id)}

      {:ok, {[deleted_tail, retained], _ds, <<>>}} =
        Encoding.decode_update(
          Encoding.encode_diff(doc, StateVector.set(StateVector.new(), 7, 3))
        )

      assert {deleted_tail.id, deleted_tail.content} == {ID.new(7, 3), {:deleted, 1}}
      assert retained.content == {:string, "C"}
      assert Encoding.encode_diff(doc, StateVector.set(StateVector.new(), 7, 5)) == <<0, 0>>

      {:ok, {[surrogate_tail | _], _ds, <<>>}} =
        Encoding.decode_update(
          Encoding.encode_diff(doc, StateVector.set(StateVector.new(), 7, 1))
        )

      assert {surrogate_tail.id, surrogate_tail.content} == {ID.new(7, 1), {:string, "�"}}
    end
  end
end
