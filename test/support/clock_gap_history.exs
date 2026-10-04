defmodule Yelixer.ClockGapHistory do
  @moduledoc """
  Deterministic multi-author update histories for the yelixer#9
  clock-contiguity scan (`test/yelixer/clock_contiguity_test.exs`).

  The generation code below is copied verbatim from
  `Yelixer.CheckpointHistory` at yelixer 5f597854 (test/support/
  checkpoint_history.exs, lines 32-80 and 111-264), minus the checkpoint
  harness and the two post-delivery `:rand` draws (floor, namespaced),
  which run after `delivery`/`withheld` are fixed and so cannot change
  them. Everything is a pure function of the integer seed.
  """

  alias Yelixer.{DeleteSet, Doc, Encoding, ID, Item}
  alias Yelixer.Types.{Array, Text, XMLElement, XMLFragment, YMap}

  @roots [
    {"t", :text},
    {"m", :map},
    {"a", :array},
    {"x", {:xml_element, "div"}},
    {"f", :xml_fragment}
  ]

  @doc "A replica with the shared roots pre-registered (local, never on the wire)."
  def registered(client_id) do
    Enum.reduce(@roots, Doc.new(client_id: client_id), fn {n, r}, d -> Doc.put_type(d, n, r) end)
  end

  # ── generation ──────────────────────────────────────────────────────

  @doc """
  Returns `%{seed, delivery, withheld}`: `delivery` is the ordered list of
  update binaries the observer receives before the heal step, `withheld`
  the updates delivered only at heal.
  """
  def generate(seed, opts \\ []) do
    :rand.seed(:exsss, {seed + 1, seed * 7 + 3, seed * 13 + 5})
    steps = Keyword.get(opts, :steps, 10 + :rand.uniform(50))
    n_authors = 1 + :rand.uniform(3)

    ids =
      Enum.map(1..n_authors, fn i ->
        if :rand.uniform() < 0.1, do: 4_294_967_296 + i, else: :rand.uniform(900_000)
      end)
      |> Enum.uniq()

    authors = Map.new(ids, &{&1, registered(&1)})

    {_authors, rev_updates} =
      Enum.reduce(List.duplicate(:step, steps), {authors, []}, fn :step, {authors, ups} ->
        step(authors, ups)
      end)

    updates = Enum.reverse(rev_updates)

    updates =
      if updates != [] and :rand.uniform() < 0.35 do
        List.insert_at(updates, :rand.uniform(length(updates) + 1) - 1, crafted_update(seed))
      else
        updates
      end

    delivery = perturb(updates)

    {delivery, withheld} =
      if length(delivery) > 1 and :rand.uniform() < 0.35 do
        i = :rand.uniform(length(delivery)) - 1
        {List.delete_at(delivery, i), [Enum.at(delivery, i)]}
      else
        {delivery, []}
      end


    %{seed: seed, delivery: delivery, withheld: withheld}
  end

  defp step(authors, ups) do
    ids = Map.keys(authors) |> Enum.sort()
    a = Enum.random(ids)
    doc = Map.fetch!(authors, a)

    if length(ids) > 1 and :rand.uniform() < 0.25 do
      b = Enum.random(ids -- [a])
      diff = Encoding.encode_diff(Map.fetch!(authors, b), Doc.state_vector(doc))
      {:ok, doc} = Encoding.apply_update(doc, diff)
      {Map.put(authors, a, doc), ups}
    else
      sv0 = Doc.state_vector(doc)
      doc = random_op(doc)
      {Map.put(authors, a, doc), [Encoding.encode_diff(doc, sv0) | ups]}
    end
  end

  defp random_op(doc) do
    case :rand.uniform(100) do
      n when n <= 30 ->
        Text.insert(doc, "t", :rand.uniform(Text.length(doc, "t") + 1) - 1, random_string())

      n when n <= 45 ->
        delete_range(doc, Text.length(doc, "t"), &Text.delete(doc, "t", &1, &2))

      n when n <= 58 ->
        YMap.set(doc, "m", Enum.random(["k1", "k2", "k3"]), random_value())

      n when n <= 62 ->
        YMap.delete(doc, "m", Enum.random(["k1", "k2", "k3"]))

      n when n <= 70 ->
        vals = Enum.map(1..:rand.uniform(3), fn _ -> random_value() end)
        Array.insert(doc, "a", :rand.uniform(Array.length(doc, "a") + 1) - 1, vals)

      n when n <= 75 ->
        delete_range(doc, Array.length(doc, "a"), &Array.delete(doc, "a", &1, &2))

      n when n <= 82 ->
        XMLElement.set_attribute(doc, "x", Enum.random(["class", "id"]), random_attr())

      n when n <= 84 ->
        XMLElement.delete_attribute(doc, "x", Enum.random(["class", "id"]))

      n when n <= 90 ->
        spec = Enum.random([{:element, "p"}, :text])
        idx = :rand.uniform(XMLFragment.child_count(doc, "f") + 1) - 1
        XMLFragment.insert_child(doc, "f", idx, spec)

      n when n <= 93 ->
        count = XMLFragment.child_count(doc, "f")
        if count > 0, do: XMLFragment.delete_child(doc, "f", :rand.uniform(count) - 1), else: doc

      n when n <= 96 ->
        # A burst that is inserted and immediately deleted, then GC'd:
        # downstream replicas receive :gc blocks for it.
        len = Text.length(doc, "t")
        idx = :rand.uniform(len + 1) - 1
        doc = Text.insert(doc, "t", idx, "gcme")
        doc |> Text.delete("t", idx, 4) |> Doc.gc()

      _ ->
        # Two overlapping deletes in one step.
        len = Text.length(doc, "t")

        if len >= 4 do
          i = :rand.uniform(len - 3) - 1
          doc |> Text.delete("t", i + 1, 2) |> Text.delete("t", i, 2)
        else
          doc
        end
    end
  end

  defp delete_range(doc, 0, _fun), do: doc

  defp delete_range(_doc, len, fun) do
    i = :rand.uniform(len) - 1
    fun.(i, :rand.uniform(min(4, len - i)))
  end

  defp random_string do
    pool = ~w(a b c d e f g h i j k l m n o p q r s t u v w x y z) ++ [" ", "é", "😀", "ß"]
    Enum.map_join(1..:rand.uniform(6), fn _ -> Enum.random(pool) end)
  end

  # XMLElement.to_string/2 renders attributes with Kernel.to_string/1.
  defp random_attr, do: Enum.random(["a", "b#{:rand.uniform(9)}", :rand.uniform(99), true])

  defp random_value do
    Enum.random([
      :rand.uniform(1000),
      -:rand.uniform(1000),
      1.5,
      "s#{:rand.uniform(99)}",
      true,
      false,
      nil,
      [1, "two", 3.25],
      %{"k" => :rand.uniform(9), "nested" => %{"x" => [true]}},
      1_180_591_620_717_411_303_424
    ])
  end

  # Content variants and nested types no local API authors: a rich-text
  # run (string/format/embed/binary/json), a nested array and nested text
  # under map keys, plus a delete of part of the run.
  def crafted_update(seed) do
    c = 950_000 + rem(seed, 40_000)
    id = &ID.new(c, &1)

    items = [
      Item.new(id.(0), nil, nil, {:string, "ab"}, {:named, "rich"}, nil),
      Item.new(id.(2), id.(1), nil, {:format, {"bold", true}}, {:named, "rich"}, nil),
      Item.new(id.(3), id.(2), nil, {:embed, %{"src" => "img"}}, {:named, "rich"}, nil),
      Item.new(id.(4), id.(3), nil, {:binary, <<1, 2, 3>>}, {:named, "rich"}, nil),
      Item.new(id.(5), id.(4), nil, {:json, ["1", "\"x\""]}, {:named, "rich"}, nil),
      Item.new(id.(7), nil, nil, {:type, :array}, {:named, "nm"}, "list"),
      Item.new(id.(8), nil, nil, {:any, [1, 2]}, {:id, id.(7)}, nil),
      Item.new(id.(10), nil, nil, {:type, :text}, {:named, "nm"}, "body"),
      Item.new(id.(11), nil, nil, {:string, "hi"}, {:id, id.(10)}, nil)
    ]

    Encoding.encode_items(items, DeleteSet.insert(DeleteSet.new(), c, 0, 1))
  end

  defp perturb(updates) do
    t = List.to_tuple(updates)
    n = tuple_size(t)

    if n < 2 do
      updates
    else
      Enum.reduce(0..(n - 2), t, fn i, t ->
        if :rand.uniform() < 0.15 do
          a = elem(t, i)
          t |> put_elem(i, elem(t, i + 1)) |> put_elem(i + 1, a)
        else
          t
        end
      end)
      |> Tuple.to_list()
    end
  end

  # ── replay and observation ─────────────────────────────────────────

  def apply_all(doc, updates) do
    Enum.reduce(updates, doc, fn u, d ->
      {:ok, d} = Encoding.apply_update(d, u)
      d
    end)
  end
end
