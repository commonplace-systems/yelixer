Code.require_file("../support/clock_gap_history.exs", __DIR__)

defmodule Yelixer.ClockContiguityTest do
  @moduledoc """
  yelixer#9: an item whose clock is ahead of the local state for its client
  must wait in pending, and block that client's later items, until the gap
  fills — Yjs integrates a struct only when `id.clock === getState(client)`.

  Before the fix (59b04eb) `integrate_items/5` integrated such an item, so
  `BlockStore.state_vector/1` claimed the gap as seen; the late earlier
  update was then dropped by the "fully known" clause (permanent loss), and
  a re-encode wrote the structs back-to-back with no Skip, so a peer
  re-clocked everything after the gap (the root mix in #8 seed 166).
  """
  use ExUnit.Case, async: true

  alias Yelixer.{BlockStore, ClockGapHistory, Doc, Encoding, StateVector}
  alias Yelixer.Types.{Array, Text, XMLElement, XMLFragment, YMap}

  # Authored by client 5: m1 = text "ab" (clocks 0-1), m3 = map k2 (clock 2),
  # m4 = map k4 (clock 3). Bytes from /home/jes/cn-yelixer-rootmix-1/diag.
  @issue9 ~w(010105000401017402616200 010105022801016d026b32017702763200 010105032801016d026b34017702763400)
  # Authored by client 100: u1 "ab" (A:0-1), u2 "Q" (A:2), u3 "cd" (A:3-4),
  # u4 array ["x"] (A:5), u5 "e" with origin A:4 (A:6). Author: "cdeabQ", ["x"].
  @text_gap ~w(010164000401017402616200 01016402846401015100 0101640344640002636400 01016405080101610177017800 01016406c464046400016500)

  @scan_roots %{
    "t" => "text",
    "m" => "map",
    "a" => "array",
    "x" => "xmlelement",
    "f" => "xmlfragment"
  }

  defp bytes(hexes), do: Enum.map(hexes, &Base.decode16!(&1, case: :lower))

  defp reg(client_id) do
    Doc.new(client_id: client_id)
    |> Doc.put_type("t", :text)
    |> Doc.put_type("a", :array)
    |> Doc.put_type("m", :map)
  end

  defp apply_all(doc, updates) do
    Enum.reduce(updates, doc, fn u, d ->
      {:ok, d} = Encoding.apply_update(d, u)
      d
    end)
  end

  defp step({doc, updates}, fun) do
    sv = Doc.state_vector(doc)
    doc = fun.(doc)
    {doc, updates ++ [Encoding.encode_diff(doc, sv)]}
  end

  defp sv(doc, client), do: StateVector.get(Doc.state_vector(doc), client)

  # Clients whose integrated blocks are not one contiguous run from clock 0.
  defp gapped_clients(doc) do
    Enum.filter(BlockStore.client_ids(doc.store), fn client ->
      BlockStore.client_blocks(doc.store, client)
      |> Enum.reduce_while(0, fn b, expected ->
        if b.id.clock == expected, do: {:cont, expected + b.length}, else: {:halt, :gap}
      end) == :gap
    end)
  end

  defp items(update) do
    {:ok, {items, _ds, _rest}} = Encoding.decode_update(update)
    items
  end

  # Items carried by `updates` that the doc does not hold as the in-order
  # replay `ref` holds them: missing, or a different deleted state, parent or
  # map key.
  defp dropped_items(doc, ref, updates) do
    updates
    |> Enum.flat_map(&items/1)
    |> Enum.reject(fn it ->
      mine = BlockStore.get(doc.store, it.id)
      theirs = BlockStore.get(ref.store, it.id)

      mine != nil and theirs != nil and
        {mine.deleted, mine.parent, mine.parent_sub} ==
          {theirs.deleted, theirs.parent, theirs.parent_sub}
    end)
  end

  # Delivers `updates` to a fresh observer. Returns the doc, the number of
  # steps after which some client was non-contiguous, and the number of
  # (update, client) arrivals whose lowest clock for that client was ahead of
  # the observer's state for it — an out-of-order arrival.
  defp deliver(updates) do
    Enum.reduce(updates, {ClockGapHistory.registered(999_001), 0, 0}, fn u, {d, g, ahead} ->
      state = Doc.state_vector(d)

      ahead =
        ahead +
          (items(u)
           |> Enum.group_by(& &1.id.client, & &1.id.clock)
           |> Enum.count(fn {client, clocks} ->
             Enum.min(clocks) > StateVector.get(state, client)
           end))

      {:ok, d} = Encoding.apply_update(d, u)
      {d, g + if(gapped_clients(d) == [], do: 0, else: 1), ahead}
    end)
  end

  # A renderer that raises is observable behaviour too (Array.to_list raises
  # on the pre-existing #8 root mix, in-order replay included): both replicas
  # must raise the same way.
  defp render(doc) do
    %{
      t: safe(fn -> Text.to_string(doc, "t") end),
      m: safe(fn -> YMap.to_json(doc, "m") end),
      a: safe(fn -> Array.to_list(doc, "a") end),
      x: safe(fn -> XMLElement.to_string(doc, "x") end),
      x_attrs: safe(fn -> XMLElement.get_attributes(doc, "x") end),
      f: safe(fn -> XMLFragment.to_string(doc, "f") end),
      sv: Doc.state_vector(doc),
      delete_set: doc.delete_set
    }
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> {:raised, e.__struct__}
  end

  describe "fixtures" do
    test "the pinned bytes are what the named authoring steps emit" do
      {_doc, issue9} =
        {reg(5), []}
        |> step(&Text.insert(&1, "t", 0, "ab"))
        |> step(&YMap.set(&1, "m", "k2", "v2"))
        |> step(&YMap.set(&1, "m", "k4", "v4"))

      assert issue9 == bytes(@issue9)

      {author, text_gap} =
        {reg(100), []}
        |> step(&Text.insert(&1, "t", 0, "ab"))
        |> step(&Text.insert(&1, "t", 2, "Q"))
        |> step(&Text.insert(&1, "t", 0, "cd"))
        |> step(&Array.insert(&1, "a", 0, ["x"]))
        |> step(&Text.insert(&1, "t", 2, "e"))

      assert text_gap == bytes(@text_gap)
      assert Text.to_string(author, "t") == "cdeabQ"
      assert Array.to_list(author, "a") == ["x"]
    end
  end

  describe "issue #9 repro (map writes, m3 late)" do
    test "after [m1, m4] the gap holds m4 pending and the state vector stops at 2" do
      [m1, _m3, m4] = bytes(@issue9)
      doc = apply_all(reg(9), [m1, m4])

      assert sv(doc, 5) == 2
      assert length(doc.pending) == 1
      assert YMap.to_json(doc, "m") == %{}
      assert gapped_clients(doc) == []
    end

    test "the late m3 integrates and releases m4 — nothing is dropped" do
      [m1, m3, m4] = bytes(@issue9)
      doc = apply_all(reg(9), [m1, m4, m3])

      assert sv(doc, 5) == 4
      assert doc.pending == []
      assert YMap.to_json(doc, "m") == %{"k2" => "v2", "k4" => "v4"}
      assert gapped_clients(doc) == []
    end
  end

  describe "text late arrival (A:2 withheld)" do
    test "without A:2 only the contiguous prefix integrates" do
      [u1, _u2, u3, u4, u5] = bytes(@text_gap)
      doc = apply_all(reg(200), [u1, u3, u4, u5])

      assert Text.to_string(doc, "t") == "ab"
      assert Array.to_list(doc, "a") == []
      assert sv(doc, 100) == 2
      assert doc.pending != []
      assert gapped_clients(doc) == []
    end

    test "the late A:2 yields the author's text \"cdeabQ\"" do
      [u1, u2, u3, u4, u5] = bytes(@text_gap)
      doc = apply_all(reg(200), [u1, u3, u4, u5, u2])

      assert Text.to_string(doc, "t") == "cdeabQ"
      assert Array.to_list(doc, "a") == ["x"]
      assert sv(doc, 100) == 7
      assert doc.pending == []
    end
  end

  describe "stale-peer relay (minimal_gap)" do
    test "a relay from a replica missing A:2 carries no gap and re-clocks nothing" do
      [u1, _u2, u3, u4, u5] = all = bytes(@text_gap)
      r = apply_all(reg(200), [u1, u3, u4, u5])
      relay = Encoding.encode_update(r)

      # Every struct the relay carries sits at its true clock: decoding the
      # relay yields exactly the ids the sender integrated.
      relay_ids = Enum.map(items(relay), &{&1.id.client, &1.id.clock, &1.length})
      stored = Enum.map(BlockStore.client_blocks(r.store, 100), &{100, &1.id.clock, &1.length})
      assert relay_ids == stored
      assert relay_ids == [{100, 0, 2}]

      p = apply_all(reg(300), [relay])
      assert Text.to_string(p, "t") == "ab"
      assert Array.to_list(p, "a") == []
      assert Enum.all?(BlockStore.get_sequence(p.store, "a"), &match?({:any, _}, &1.content))

      p = apply_all(p, all)
      assert Text.to_string(p, "t") == "cdeabQ"
      assert Array.to_list(p, "a") == ["x"]
      assert p.pending == []
      assert Enum.all?(BlockStore.get_sequence(p.store, "a"), &match?({:any, _}, &1.content))
    end
  end

  describe "200 generated histories (CheckpointHistory generator @ 5f59785)" do
    test "out-of-order delivery: never non-contiguous, nothing dropped, same content as in-order" do
      rows =
        for seed <- 0..199 do
          h = ClockGapHistory.generate(seed)
          all = h.delivery ++ h.withheld
          {doc, gapped_steps, ahead} = deliver(all)
          {in_order, 0, 0} = deliver(h.authored)
          mine = render(doc)
          ref = render(in_order)

          %{
            seed: seed,
            updates: length(all),
            same_updates: Enum.sort(all) == Enum.sort(h.authored),
            gapped_steps: gapped_steps,
            ahead: ahead,
            dropped: length(dropped_items(doc, in_order, all)),
            pending: length(doc.pending),
            content_diff: for(k <- Map.keys(ref), mine[k] !== ref[k], do: k),
            relay_reclocked: relay_ids(Encoding.encode_update(doc)) != stored_ids(doc)
          }
        end

      # The corpus is non-empty, is a reordering of the in-order replay, and
      # actually exercises out-of-order arrival (measured: 111 of 200 seeds;
      # 0 when the same updates arrive in authoring order — see the next test).
      assert Enum.sum(Enum.map(rows, & &1.updates)) > 2_000
      assert Enum.all?(rows, & &1.same_updates)
      assert Enum.count(rows, &(&1.ahead > 0)) >= 100

      assert Enum.filter(rows, &(&1.gapped_steps > 0)) == []
      assert Enum.filter(rows, &(&1.dropped > 0)) == []
      assert Enum.filter(rows, &(&1.pending > 0)) == []
      # Strict per-root equality with the in-order replay (t, m, a, x, f) plus
      # state vector and delete set. The map root is compared strictly too:
      # this corpus shows no #11 map-order difference against in-order replay.
      assert Enum.filter(rows, &(&1.content_diff != [])) == []
      # Re-encoding writes every struct at the clock it is stored under.
      assert Enum.filter(rows, & &1.relay_reclocked) == []
    end

    test "the out-of-order control reads zero when the same updates arrive in order" do
      seeds_ahead =
        Enum.count(0..199, fn seed ->
          {_doc, _gapped, ahead} = deliver(ClockGapHistory.generate(seed).authored)
          ahead > 0
        end)

      assert seeds_ahead == 0
    end

    test "a sample of out-of-order deliveries renders as Yjs renders it" do
      for seed <- Enum.take_every(0..199, 10) do
        h = ClockGapHistory.generate(seed)
        all = h.delivery ++ h.withheld
        {doc, _, _} = deliver(all)
        [yjs] = oracle(@scan_roots, [all])

        # t, m and a, plus state vector and pending. Not compared, because
        # they differ from Yjs 13.6.32 identically for in-order delivery (so
        # delivery order is not their cause): x (Yjs names a root XmlElement
        # "undefined"; Yelixer shows extra attributes on seeds 90, 128, 144,
        # 160, 193) and f (Yjs shows no children under the Yelixer-authored
        # fragment).
        assert Map.take(yjs["roots"], ["t", "m", "a"]) == observe(doc, ["t", "m", "a"])["roots"],
               "seed #{seed}"

        assert Map.take(yjs, ["sv", "pending"]) == Map.take(observe(doc, []), ["sv", "pending"])
      end
    end
  end

  describe "two sections of one client in one update" do
    # Hand-crafted: client 7 sections [7:5..6] then [7:3..4], doc state 3.
    # Pins current behaviour: the whole update is held (the first section
    # blocks the client, so the contiguous second section waits too) and is
    # released intact once 7:3..4 arrives separately. Yjs 13.6.32 differs: its
    # reader keeps only the last section per client, integrating 7:3..4
    # ("edabc", state 5) and silently discarding 7:5..6.
    test "is held whole, then released when the earlier clocks arrive" do
      base = <<1, 1, 7, 0, 4, 1, 1, ?t, 3, ?a, ?b, ?c, 0>>

      two =
        <<2, 2, 7, 5, struct_c(?f)::binary, struct_c(?g)::binary, 2, 7, 3, struct_c(?d)::binary,
          struct_c(?e)::binary, 0>>

      d = apply_all(Doc.new(client_id: 9) |> Doc.put_type("t", :text), [base])
      assert Enum.map(items(two), & &1.id.clock) == [5, 6, 3, 4]

      held = apply_all(d, [two])
      assert Text.to_string(held, "t") == "abc"
      assert sv(held, 7) == 3
      assert length(held.pending) == 1

      released = apply_all(held, [<<1, 2, 7, 3, struct_c(?d)::binary, struct_c(?e)::binary, 0>>])
      assert Text.to_string(released, "t") == "gfedabc"
      assert sv(released, 7) == 7
      assert released.pending == []
    end
  end

  describe "Yjs 13.6.32 oracle on the repro bytes" do
    test "issue #9 phases: state vector, pending and map agree with Yjs" do
      [m1, m3, m4] = bytes(@issue9)
      phases = [[m1, m4], [m3]]
      [yjs_gap, yjs_heal] = oracle(%{"t" => "text", "m" => "map"}, phases)

      d1 = apply_all(reg(9), [m1, m4])
      d2 = apply_all(d1, [m3])

      assert yjs_gap == %{
               "sv" => %{"5" => 2},
               "pending" => true,
               "roots" => %{"t" => "ab", "m" => %{}}
             }

      assert observe(d1, ["t", "m"]) == yjs_gap
      assert observe(d2, ["t", "m"]) == yjs_heal
      assert yjs_heal["roots"]["m"] == %{"k2" => "v2", "k4" => "v4"}
    end

    test "text gap phases: state vector, pending, text and array agree with Yjs" do
      [u1, u2, u3, u4, u5] = bytes(@text_gap)
      phases = [[u1, u3, u4, u5], [u2]]
      [yjs_gap, yjs_heal] = oracle(%{"t" => "text", "a" => "array"}, phases)

      d1 = apply_all(reg(200), [u1, u3, u4, u5])
      d2 = apply_all(d1, [u2])

      assert yjs_gap["pending"] == true
      assert observe(d1, ["t", "a"]) == yjs_gap
      assert observe(d2, ["t", "a"]) == yjs_heal
      assert yjs_heal["roots"] == %{"t" => "cdeabQ", "a" => ["x"]}
    end

    test "the stale peer's relay reads the same in Yjs as in Yelixer" do
      [u1, _u2, u3, u4, u5] = bytes(@text_gap)
      relay = Encoding.encode_update(apply_all(reg(200), [u1, u3, u4, u5]))
      [yjs] = oracle(%{"t" => "text", "a" => "array"}, [[relay]])

      assert observe(apply_all(reg(300), [relay]), ["t", "a"]) == yjs
      assert yjs["roots"] == %{"t" => "ab", "a" => []}
    end
  end

  # One struct: insert the single character `char` at the start of root "t".
  defp struct_c(char), do: <<4, 1, 1, ?t, 1, char>>

  defp relay_ids(update),
    do: update |> items() |> Enum.map(&{&1.id.client, &1.id.clock, &1.length}) |> Enum.sort()

  defp stored_ids(doc) do
    ids =
      for client <- BlockStore.client_ids(doc.store),
          b <- BlockStore.client_blocks(doc.store, client),
          do: {client, b.id.clock, b.length}

    Enum.sort(ids)
  end

  defp observe(doc, roots) do
    %{
      "sv" => Map.new(Doc.state_vector(doc).clocks, fn {c, k} -> {Integer.to_string(c), k} end),
      "pending" => doc.pending != [],
      "roots" =>
        Map.new(roots, fn
          "t" -> {"t", Text.to_string(doc, "t")}
          "m" -> {"m", YMap.to_json(doc, "m")}
          "a" -> {"a", Array.to_list(doc, "a")}
        end)
    }
  end

  defp oracle(roots, phases) do
    node = System.find_executable("node") || flunk("node is required for the Yjs oracle")
    script = Path.expand("../fixtures/clock_contiguity_oracle.mjs", __DIR__)

    input =
      Path.join(System.tmp_dir!(), "clock_contiguity_#{System.unique_integer([:positive])}.json")

    File.write!(
      input,
      Jason.encode!(%{
        roots: roots,
        phases: Enum.map(phases, fn us -> Enum.map(us, &Base.encode16(&1, case: :lower)) end)
      })
    )

    try do
      {out, status} = System.cmd(node, [script, input], stderr_to_stdout: true)
      assert status == 0, "Yjs oracle failed: #{out}"
      %{"yjs" => version, "phases" => phases} = Jason.decode!(out)
      assert version == "13.6.32"
      phases
    after
      File.rm(input)
    end
  end
end
