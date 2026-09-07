alias Yelixer.{BlockStore, Doc, Encoding, ID, Item, StateVector}

for layout <- [:pending, :materialized, :mixed], count <- [512, 1024] do
  store =
    Enum.reduce(0..(count - 1), BlockStore.new(), fn clock, store ->
      origin = if clock == 0, do: nil, else: ID.new(7, clock - 1)
      item = Item.new(ID.new(7, clock), origin, nil, {:string, "a"}, {:named, "text"}, nil)
      store = BlockStore.push(store, item)

      if layout == :mixed and clock == div(count, 2),
        do: BlockStore.materialize_all(store),
        else: store
    end)

  store = if layout == :materialized, do: BlockStore.materialize_all(store), else: store
  doc = %{Doc.new(client_id: 7) | store: store}
  sv = StateVector.set(StateVector.new(), 7, count - 1)
  Encoding.encode_diff(doc, sv)
  {:reductions, before_count} = Process.info(self(), :reductions)
  bytes = Encoding.encode_diff(doc, sv)
  {:reductions, after_count} = Process.info(self(), :reductions)

  IO.puts(
    Jason.encode!(%{
      layout: layout,
      blocks: count,
      reductions: after_count - before_count,
      bytes: byte_size(bytes),
      hex: Base.encode16(bytes, case: :lower)
    })
  )
end
