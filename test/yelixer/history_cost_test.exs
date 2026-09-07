defmodule Yelixer.HistoryCostTest do
  use ExUnit.Case, async: false

  alias Yelixer.{BlockStore, Doc, Encoding, ID, Item, StateVector}
  alias Yelixer.Types.Text

  # Build the encoder's clock-ordered input directly. Fixture construction
  # must not measure Text.insert's separate positional-search cost.
  defp history(count, layout) do
    {doc, _} = Doc.get_or_create_type(Doc.new(client_id: 7), "text", :text)

    store =
      Enum.reduce(0..(count - 1), doc.store, fn clock, store ->
        origin = if clock == 0, do: nil, else: ID.new(7, clock - 1)
        item = Item.new(ID.new(7, clock), origin, nil, {:string, "a"}, {:named, "text"}, nil)
        store = BlockStore.push(store, item)

        if layout == :mixed and clock == div(count, 2),
          do: BlockStore.materialize_all(store),
          else: store
      end)

    store = if layout == :materialized, do: BlockStore.materialize_all(store), else: store
    %{doc | store: store}
  end

  defp reductions(fun) do
    {:reductions, before_count} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, after_count} = Process.info(self(), :reductions)
    {result, after_count - before_count}
  end

  for layout <- [:pending, :materialized, :mixed] do
    test "one-item diff seeks past known #{layout} history" do
      layout = unquote(layout)

      [small, large] =
        for count <- [512, 1024] do
          doc = history(count, layout)
          remote_sv = StateVector.set(StateVector.new(), 7, count - 1)
          # Warm module loading before counting reductions; no wall-clock gate.
          Encoding.encode_diff(doc, remote_sv)
          {bytes, cost} = reductions(fn -> Encoding.encode_diff(doc, remote_sv) end)
          assert byte_size(bytes) == 12
          {:ok, {[item], _ds, <<>>}} = Encoding.decode_update(bytes)
          assert item.id == ID.new(7, count - 1)
          assert item.content == {:string, "a"}
          cost
        end

      assert large < small * 1.5,
             "one-item #{layout} diff grew with known history: #{small} -> #{large} reductions"
    end

    test "#{layout} history diff applies with identical clocks and bytes" do
      layout = unquote(layout)
      base = history(16, layout)
      complete = history(17, layout)
      sv = BlockStore.state_vector(base.store)
      {:ok, receiver} = Encoding.apply_update(Doc.new(), Encoding.encode_update(base))
      {:ok, receiver} = Encoding.apply_update(receiver, Encoding.encode_diff(complete, sv))
      assert Text.to_string(receiver, "text") == String.duplicate("a", 17)
      assert BlockStore.state_vector(receiver.store) == BlockStore.state_vector(complete.store)
      assert Encoding.encode_update(receiver) == Encoding.encode_update(complete)
    end
  end

  test "repeated missing-dependency delivery occupies one pending slot then converges" do
    {peer, _} = Doc.get_or_create_type(Doc.new(client_id: 7), "text", :text)
    peer = Text.insert(peer, "text", 0, "A")
    base = Encoding.encode_update(peer)
    sv = BlockStore.state_vector(peer.store)
    peer = Text.insert(peer, "text", 1, "B")
    delta = Encoding.encode_diff(peer, sv)

    receiver =
      Enum.reduce(1..16, Doc.new(), fn _, receiver ->
        {:ok, receiver} = Encoding.apply_update(receiver, delta)
        receiver
      end)

    assert Doc.pending_info(receiver) == %{count: 1, bytes: byte_size(delta)}
    assert StateVector.get(BlockStore.state_vector(receiver.store), 7) == 0
    {:ok, receiver} = Encoding.apply_update(receiver, base)
    assert Doc.pending_info(receiver) == %{count: 0, bytes: 0}
    assert Text.to_string(receiver, "text") == "AB"
    assert Encoding.encode_update(receiver) == Encoding.encode_update(peer)
  end

  test "GC retains reusable clock lookup tuples containing the collected payloads" do
    {doc, _} = Doc.get_or_create_type(Doc.new(client_id: 7), "text", :text)
    doc = doc |> Text.insert("text", 0, "abc") |> Text.delete("text", 1, 1) |> Doc.gc()
    # A missing tuple would be rebuilt and discarded on every immutable get.
    assert is_tuple(doc.store.client_tuples[7])

    for item <- BlockStore.client_blocks(doc.store, 7) do
      assert BlockStore.get(doc.store, item.id) == item
      if item.deleted, do: assert(match?({:gc, _}, item.content))
    end

    {:ok, reopened} = Encoding.apply_update(Doc.new(), Encoding.encode_update(doc))
    assert Text.to_string(reopened, "text") == "ac"
  end
end
