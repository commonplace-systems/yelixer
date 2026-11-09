defmodule Yelixer.CheckpointHistory do
  @moduledoc """
  Deterministic generated histories and the checkpoint-resume harness for
  CHECKPOINT-SNAP-1's precondition gate (see
  `test/yelixer/checkpoint_resume_proof_test.exs`).

  A history is the sequence of wire updates that several concurrently
  editing authors emit, delivered to an observer in a perturbed order
  (adjacent swaps produce pending state), with optionally one update
  withheld until a final "heal" step (pending that outlives the cut).

  Everything is a pure function of the integer seed.
  """

  alias Yelixer.{DeleteSet, Doc, Encoding, ID, Item, StateCodec}
  alias Yelixer.Types.{Array, Text, XMLElement, XMLFragment, YMap}

  @roots [
    {"t", :text},
    {"m", :map},
    {"a", :array},
    {"x", {:xml_element, "div"}},
    {"f", :xml_fragment}
  ]

  @observer_a 999_001
  @observer_c 999_002
  @stale_peer 999_003

  def observer_a_id, do: @observer_a

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

    # Local bookkeeping the wire never carries: a mint-clock floor on the
    # observers, and per-update namespace provenance.
    floor = if :rand.uniform() < 0.3, do: 1_000 + :rand.uniform(9_000), else: 0
    namespaced = :rand.uniform() < 0.3

    %{seed: seed, delivery: delivery, withheld: withheld, floor: floor, namespaced: namespaced}
  end

  @doc "An observer replica for history `h`."
  def observer(client_id, h) do
    %{registered(client_id) | clock_floor: Map.get(h, :floor, 0)}
  end

  @doc """
  Delivers `updates` to `doc`, the first being delivery index `offset`.
  Namespaced histories record provenance under one of three namespaces.
  """
  def deliver(doc, updates, h, offset \\ 0) do
    updates
    |> Enum.with_index(offset)
    |> Enum.reduce(doc, fn {u, i}, d ->
      {:ok, d} =
        if Map.get(h, :namespaced, false),
          do: Encoding.apply_update_in_namespace(d, u, "ns#{rem(i, 3)}"),
          else: Encoding.apply_update(d, u)

      d
    end)
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

  @doc """
  Wire- and behaviour-visible observation of a replica. `types` and
  `pending` echo internal fields; every other key is behaviour.
  """
  def observe(doc) do
    visible =
      doc.types
      |> Map.keys()
      |> Enum.sort()
      |> Map.new(fn name ->
        {name,
         doc.store
         |> Yelixer.BlockStore.get_sequence(name)
         |> Enum.map(&{&1.id, &1.content, &1.parent_sub})}
      end)

    %{
      update: Encoding.encode_update(doc),
      state_vector: Doc.state_vector(doc),
      delete_set: doc.delete_set,
      pending: {doc.pending, doc.pending_bytes},
      types: doc.types,
      snapshot: safe(fn -> Doc.snapshot_update(doc) end),
      visible: visible,
      text: safe(fn -> Text.to_string(doc, "t") end),
      map: safe(fn -> YMap.to_json(doc, "m") end),
      array: safe(fn -> Array.to_list(doc, "a") end),
      xml: safe(fn -> XMLElement.to_string(doc, "x") end),
      xml_attrs: safe(fn -> XMLElement.get_attributes(doc, "x") end),
      fragment: safe(fn -> XMLFragment.to_string(doc, "f") end),
      rich: safe(fn -> Text.to_string(doc, "rich") end),
      nested: safe(fn -> YMap.to_json(doc, "nm") end),
      next_clock: Doc.mint_clock(doc),
      provenance: provenance(doc)
    }
  end

  defp provenance(doc) do
    for c <- Enum.sort(Doc.client_ids(doc)),
        ns <- ~w(ns0 ns1 ns2),
        Doc.clientID_in_namespace?(doc, c, ns),
        do: {c, ns}
  end

  @rendered [:visible, :text, :map, :array, :xml, :xml_attrs, :fragment, :rich, :nested]
  def rendered_fields, do: @rendered

  # A renderer that raises on a state is itself observable behaviour: both
  # replicas must raise the same way. (Pre-existing renderer crashes on
  # cross-type items are not the codec's concern, but must not abort the
  # proof.)
  defp safe(fun) do
    fun.()
  rescue
    e -> {:raised, e.__struct__}
  end

  @doc "Deterministic local edits by the replica's own client id."
  def local_edits(doc) do
    len = Text.length(doc, "t")
    doc = Text.insert(doc, "t", div(len, 2), "Z")
    doc = if len >= 3, do: Text.delete(doc, "t", 1, 2), else: doc
    doc = YMap.set(doc, "m", "k1", "post")
    doc = Array.insert(doc, "a", 0, ["post"])
    doc = XMLElement.set_attribute(doc, "x", "post", 1)
    XMLFragment.insert_child(doc, "f", 0, :text)
  end

  defp stale_peer(delivery) do
    p = apply_all(registered(@stale_peer), Enum.take(delivery, div(length(delivery), 2)))
    p = Text.insert(p, "t", 0, "P")
    p = YMap.set(p, "m", "k2", "stale")
    if Text.length(p, "t") > 2, do: Text.delete(p, "t", 0, 2), else: p
  end

  # Two-way sync of `x` with a stale peer.
  defp sync(x, p) do
    {:ok, p} = Encoding.apply_update(p, Encoding.encode_diff(x, Doc.state_vector(p)))
    {:ok, x} = Encoding.apply_update(x, Encoding.encode_diff(p, Doc.state_vector(x)))
    {x, p}
  end

  # ── the proof ───────────────────────────────────────────────────────

  @key "checkpoint-proof"

  @doc "The real codec as a {checkpoint, restore} pair."
  def real_codec do
    {fn doc ->
       {:ok, bytes} = StateCodec.encode(doc, @key)
       bytes
     end,
     fn bytes ->
       {:ok, doc} = StateCodec.decode(bytes, @key)
       doc
     end}
  end

  @doc """
  Cut points for a delivery of length `n`: 0, n, up to six random interior
  points, the first point at which the observer holds pending blobs, and
  the point at which it holds the most pending bytes.
  `pending_points` is `[{index, pending_bytes}]` in delivery order.
  """
  def cut_points(n, pending_points, seed) do
    :rand.seed(:exsss, {seed + 11, seed + 17, seed + 23})
    interior = if n > 1, do: Enum.map(1..6, fn _ -> :rand.uniform(n - 1) end), else: []

    pending =
      case pending_points do
        [] -> []
        [{first, _} | _] -> [first, elem(Enum.max_by(pending_points, &elem(&1, 1)), 0)]
      end

    Enum.uniq([0, n] ++ interior ++ pending) |> Enum.sort()
  end

  @doc """
  Runs the checkpoint-resume proof for one history with the given codec.
  Returns `%{mismatches: [...], cuts: n, pending_cuts: n, pending_end: bool}`.
  A mismatch is `{seed, cut, stage, [differing fields]}`.
  """
  def prove(%{seed: seed, delivery: delivery} = h, {checkpoint, restore}) do
    n = length(delivery)

    # A: the whole history, one update at a time, remembering which
    # prefixes left pending blobs behind.
    {a_states, pending_points} =
      delivery
      |> Enum.with_index(1)
      |> Enum.reduce({[{0, observer(@observer_a, h)}], []}, fn {u, i}, {[{_, d} | _] = acc, pp} ->
        d = deliver(d, [u], h, i - 1)
        {[{i, d} | acc], if(d.pending != [], do: [{i, d.pending_bytes} | pp], else: pp)}
      end)

    a_by_cut = Map.new(a_states)
    pending_points = Enum.reverse(pending_points)
    cuts = cut_points(n, pending_points, seed)
    a = Map.fetch!(a_by_cut, n)

    # C: a fresh, independent full replay under a different observer id.
    c = deliver(observer(@observer_c, h), delivery, h)
    a_obs = observe(a)

    baseline =
      diff_fields(a_obs, observe(%{c | client_id: @observer_a}), "baseline A/C") ++
        state_diff(a, %{c | client_id: @observer_a}, "baseline A/C")

    {a_post, p_a, a_healed, p_a_healed} = continue(a, h)

    mismatches =
      Enum.flat_map(cuts, fn f ->
        a_f = Map.fetch!(a_by_cut, f)
        b_f = restore.(checkpoint.(a_f))

        at_cut =
          diff_fields(observe(a_f), observe(b_f), "at cut") ++ state_diff(a_f, b_f, "at cut")

        b = deliver(b_f, Enum.drop(delivery, f), h, f)

        suffix =
          diff_fields(a_obs, observe(b), "after suffix") ++ state_diff(a, b, "after suffix")

        {b_post, p_b, b_healed, p_b_healed} = continue(b, h)

        (at_cut ++
           suffix ++
           diff_fields(observe(a_post), observe(b_post), "after new edits + stale sync") ++
           state_diff(a_post, b_post, "after new edits + stale sync") ++
           diff_fields(observe(p_a), observe(p_b), "stale peer") ++
           diff_fields(observe(a_healed), observe(b_healed), "after heal") ++
           state_diff(a_healed, b_healed, "after heal") ++
           diff_fields(observe(p_a_healed), observe(p_b_healed), "stale peer after heal"))
        |> Enum.map(fn {stage, fields} -> {seed, f, stage, fields} end)
      end)

    %{
      mismatches:
        Enum.map(baseline, fn {stage, fields} -> {seed, :baseline, stage, fields} end) ++
          mismatches,
      cuts: length(cuts),
      pending_cuts: Enum.count(cuts, &(Map.fetch!(a_by_cut, &1).pending != [])),
      pending_end: a.pending != [],
      healed_clean: a_healed.pending == [],
      floor: Map.get(h, :floor, 0) > 0,
      namespaced: Map.get(h, :namespaced, false)
    }
  end

  defp continue(x, %{delivery: delivery, withheld: withheld} = h) do
    x = local_edits(x)
    {x, p} = sync(x, stale_peer(delivery))
    n = length(delivery)
    {x, p, deliver(x, withheld, h, n), deliver(p, withheld, h, n)}
  end

  # Strict (===) so 1 vs 1.0 or -0.0 vs 0.0 cannot hide a change.
  defp diff_fields(a, b, stage) do
    case Enum.reject(Map.keys(a), &(Map.fetch!(a, &1) === Map.fetch!(b, &1))) do
      [] -> []
      fields -> [{stage, fields}]
    end
  end

  # Full internal causal state, beyond what the wire shows.
  # Both sides must actually produce a state: two {:error, _} are not a match.
  defp state_diff(a, b, stage) do
    {:ok, sa} = StateCodec.canonical_state(a)
    {:ok, sb} = StateCodec.canonical_state(b)
    if sa === sb, do: [], else: [{stage, [:canonical_state]}]
  end

  @doc "Behaviour-visible fields only (the red arms must fail on these, not only on internal state)."
  def behavioural?({_seed, _cut, _stage, fields}),
    do: Enum.any?(fields, &(&1 != :canonical_state))
end
