defmodule Yelixer.CxMchnDeleteSetReproTest do
  @moduledoc """
  CX-mchn reproduction: silent data loss when a whole-doc
  `delete_text(0, len)` is followed by a fresh insert, both folded
  into ONE full-state `encode_update` snapshot (the "chained commit"
  pattern used by `create_chained_commit` callers), and that snapshot
  is later re-folded via `apply_update` onto a doc built by replaying
  the full commit chain from scratch (the `reconstruct_doc` pattern,
  see `Commonplace.Tree.DocBuilder.reconstruct_doc/3`).

  This is a REPRODUCE-AND-LOCALIZE test only. No fix is attempted
  here.
  """
  use ExUnit.Case

  alias Yelixer.{Doc, Encoding, Types.Text, Types.YMap}

  test "whole-doc delete-then-reinsert, folded as two full-state snapshots, must not silently empty the doc" do
    doc0 = Doc.new(client_id: 1)
    doc1 = Text.insert(doc0, "text", 0, "Hello")
    commit1 = Encoding.encode_update(doc1)

    doc2 = Text.delete(doc1, "text", 0, String.length("Hello"))
    doc3 = Text.insert(doc2, "text", 0, "World")
    commit2 = Encoding.encode_update(doc3)

    assert Text.to_string(doc3, "text") == "World"

    fresh = Doc.new(client_id: 1)
    {:ok, fresh} = Encoding.apply_update(fresh, commit1)
    {:ok, fresh} = Encoding.apply_update(fresh, commit2)

    result = Text.to_string(fresh, "text")
    IO.puts("\n=== CX-mchn 2-round repro ===")
    IO.puts("reconstructed text: #{inspect(result)}")
    assert result == "World"
  end

  test "ACCUMULATED: N rounds of delete-all-reinsert, each a full-state chained commit, replayed via full-chain apply_update fold" do
    doc = Doc.new(client_id: 1)
    doc = Text.insert(doc, "text", 0, ~s({"kind":"room","description":"seed"}))

    commits = [Encoding.encode_update(doc)]

    {_final_doc, commits, first_bad} =
      Enum.reduce_while(1..40, {doc, commits, nil}, fn i, {doc, commits, _} ->
        old = Text.to_string(doc, "text")
        new = ~s({"kind":"room","description":"round #{i} with some length #{String.duplicate("x", rem(i, 7))}"})

        doc2 = Text.delete(doc, "text", 0, String.length(old))
        doc3 = Text.insert(doc2, "text", 0, new)
        commit = Encoding.encode_update(doc3)
        commits = commits ++ [commit]

        # Replay the FULL chain from scratch, exactly like
        # DocBuilder.reconstruct_doc, and check whether it still
        # matches the writer's own live content.
        fresh = Doc.new(client_id: 1)

        {:ok, fresh} =
          Enum.reduce(commits, {:ok, fresh}, fn c, {:ok, d} -> Encoding.apply_update(d, c) end)

        reconstructed = Text.to_string(fresh, "text")

        if reconstructed == new do
          {:cont, {doc3, commits, nil}}
        else
          IO.puts(
            "CORRUPTED at round #{i}: writer content=#{inspect(new)} reconstructed=#{inspect(reconstructed)}"
          )

          {:halt, {doc3, commits, i}}
        end
      end)

    IO.puts("\n=== CX-mchn accumulated repro ===")
    IO.puts("first corrupting round: #{inspect(first_bad)} (nil = survived all rounds)")

    if first_bad do
      # Dump the delete_set and the fresh insert's id-range at the
      # corrupting round for suspect (i) vs (ii) diagnosis.
      bad_commit = Enum.at(commits, first_bad)
      {:ok, {items, ds, _rest}} = Encoding.decode_update(bad_commit)

      IO.puts("bad commit delete_set: #{inspect(ds)}")

      new_items =
        Enum.filter(items, fn item ->
          match?({:string, s} when byte_size(s) > 0, item.content)
        end)

      for item <- new_items do
        IO.puts(
          "item id=(client=#{item.id.client}, clock=#{item.id.clock}) length=#{item.length} " <>
            "content=#{inspect(item.content)}"
        )
      end
    end

    assert is_nil(first_bad), "CX-mchn reproduced: corrupted at accumulation round #{inspect(first_bad)}"
  end

  test "same repro with a genuinely fresh client for the reinsert (rules out clock reuse)" do
    doc0 = Doc.new(client_id: 1)
    doc1 = Text.insert(doc0, "text", 0, "Hello")
    commit1 = Encoding.encode_update(doc1)

    doc2 = Text.delete(doc1, "text", 0, String.length("Hello"))
    commit_delete_only = Encoding.encode_update(doc2)

    doc2b =
      Doc.new(client_id: 999)
      |> then(fn d -> %{d | store: doc2.store, delete_set: doc2.delete_set} end)

    doc3 = Text.insert(doc2b, "text", 0, "World")
    commit2 = Encoding.encode_update(doc3)

    fresh = Doc.new(client_id: 1)
    {:ok, fresh} = Encoding.apply_update(fresh, commit1)
    {:ok, fresh} = Encoding.apply_update(fresh, commit_delete_only)
    {:ok, fresh} = Encoding.apply_update(fresh, commit2)

    result = Text.to_string(fresh, "text")
    IO.puts("\n=== CX-mchn fresh-client repro dump ===")
    IO.puts("reconstructed text: #{inspect(result)}")

    assert result == "World"
  end

  test "FIX: a plain Text insert in a named type that also holds a Y.Map keyed item does not anchor across the keyed/plain boundary, and both survive encode/decode" do
    # Minimal 2-item repro from the CX-mchn layer-1 fix spec: a single
    # doc where "content" holds BOTH a Y.Map keyed entry ("description")
    # and a plain Text sequence. Before the fix, Text.insert's neighbor
    # search treated the keyed item as a plain-sequence member and
    # anchored right_origin at it; on decode, resolve_parent inherited
    # parent_sub from that anchor, turning the fresh text item into a
    # same-key map write that Y.Map rightmost-wins silently discarded.
    d = Doc.new(client_id: 1)
    {d, _} = Doc.get_or_create_type(d, "content", :map)
    d = YMap.set(d, "content", "description", "LEGACY KEY VALUE")
    d = Text.insert(d, "content", 0, "PLAIN TEXT BLOB")

    {:ok, wire} = Encoding.apply_update(Doc.new(), Encoding.encode_update(d))

    assert Text.to_string(wire, "content") == "PLAIN TEXT BLOB",
           "CX-mchn fix regressed: plain text was silently discarded across encode/decode"

    assert YMap.to_map(wire, "content") == %{"description" => "LEGACY KEY VALUE"},
           "CX-mchn fix regressed: legacy map key was disturbed by the text insert"
  end

  test "MINIMAL PURE-YELIXER: fresh Text insert anchored (right_origin) against an unrelated stray YMap-key item in the SAME named type is silently tombstoned on decode re-fold" do
    # This is the mechanism actually observed on the real cx_k20z fixture:
    # NOT delete-set range coalescing (suspect i), NOT position-resolved
    # delete (suspect ii as literally described) — a THIRD mechanism:
    # wire-decode parent_sub INHERITANCE (Yelixer.Encoding.resolve_parent/2)
    # blindly copies parent_sub from an item's origin/right_origin anchor
    # whenever the anchor has a non-nil parent_sub, even when the new item
    # is NOT a genuine same-key map overwrite of that anchor — merely
    # positionally adjacent to it in the shared named-type sequence.
    #
    # Setup: a doc where a Y.Map-style keyed entry ("description") and a
    # plain Text sequence share the SAME named type ("content") — exactly
    # what the real MUD room-meta docs look like after their per-field ->
    # single-blob schema migration (a stray leftover map item coexists
    # with the current Text blob under the same type name).
    doc = Doc.new(client_id: 1)
    # Stray legacy YMap-key entry under "content", written by a DIFFERENT
    # client (as in the live fixture — client 138940312 vs the writer's
    # own client 1).
    stray_doc = Doc.new(client_id: 42)
    stray_doc = YMap.set(stray_doc, "content", "description", "x")
    stray_update = Encoding.encode_update(stray_doc)

    {:ok, doc} = Encoding.apply_update(doc, stray_update)

    # Now insert plain Text content at position 0 of the SAME named type.
    # Because the stray map item is the sequence's only (hence first)
    # entry, `Text.insert/4`'s neighbor search anchors the new item's
    # right_origin at the stray item's ID.
    doc = Text.insert(doc, "content", 0, "Hello World")

    fresh_item =
      Yelixer.BlockStore.client_blocks(doc.store, 1) |> Enum.find(&match?({:string, _}, &1.content))

    IO.puts("\n=== CX-mchn minimal parent_sub-inheritance repro ===")
    IO.puts(
      "PRE encode/decode: fresh item origin=#{inspect(fresh_item.origin)} " <>
        "right_origin=#{inspect(fresh_item.right_origin)} parent_sub=#{inspect(fresh_item.parent_sub)} " <>
        "deleted=#{fresh_item.deleted}"
    )

    update = Encoding.encode_update(doc)

    replay = Doc.new(client_id: 1)
    {:ok, replay} = Encoding.apply_update(replay, stray_update)
    {:ok, replay} = Encoding.apply_update(replay, update)

    replayed_item = Yelixer.BlockStore.get(replay.store, fresh_item.id)

    IO.puts(
      "POST encode/decode re-fold: replayed item parent_sub=#{inspect(replayed_item.parent_sub)} " <>
        "deleted=#{replayed_item.deleted}"
    )

    text = Text.to_string(replay, "content")
    IO.puts("Text.to_string(replay, \"content\") = #{inspect(text)}")

    assert replayed_item.parent_sub == nil,
           "CX-mchn mechanism reproduced: fresh Text item's parent_sub was corrupted to " <>
             "#{inspect(replayed_item.parent_sub)} (inherited from an unrelated anchor item) on decode re-fold"

    assert text == "Hello World",
           "CX-mchn mechanism reproduced: fresh Text insert silently vanished (tombstoned via " <>
             "spurious map-conflict resolution) on decode re-fold. Got #{inspect(text)}"
  end

  test "REAL FIXTURE: cx_k20z_start_meta_precorruption.bin at pure-Yelixer level" do
    fixture =
      Path.join([__DIR__, "..", "..", "commonplace", "test", "fixtures", "cx_k20z_start_meta_precorruption.bin"])
      |> Path.expand()

    if File.exists?(fixture) do
      state_bin = File.read!(fixture)

      seeded = Doc.new(client_id: 1)
      {:ok, seeded} = Encoding.apply_update(seeded, state_bin)
      content = Text.to_string(seeded, "content")
      IO.puts("\n=== CX-mchn fixture repro ===")
      IO.puts("fixture content prefix: #{inspect(String.slice(content, 0, 60))}")

      assert content != "", "fixture must seed valid, non-empty content"

      # Reproduce the OLD (pre-CX-k20z-fix) write_meta_doc pattern:
      # whole-doc delete + full reinsert, as ONE full-state chained commit.
      new_json =
        Jason.encode!(
          Jason.decode!(content) |> Map.update("exits", %{}, &Map.put(&1, "probeexit", "somewhere"))
        )

      sv = Yelixer.BlockStore.state_vector(seeded.store)
      IO.puts("seeded state_vector: #{inspect(sv)}")
      IO.puts("seeded delete_set: #{inspect(seeded.delete_set)}")

      edited = Text.delete(seeded, "content", 0, String.length(content))
      edited = Text.insert(edited, "content", 0, new_json)
      update2 = Encoding.encode_update(edited)

      IO.puts("edited delete_set: #{inspect(edited.delete_set)}")

      new_items =
        Yelixer.BlockStore.client_blocks(edited.store, edited.client_id)
        |> Enum.filter(fn item -> match?({:string, s} when byte_size(s) > 100, item.content) end)

      for item <- new_items do
        IO.puts(
          "fresh insert item (PRE encode/decode, in edited.store) id=(client=#{item.id.client}, clock=#{item.id.clock}) length=#{item.length} " <>
            "origin=#{inspect(item.origin)} right_origin=#{inspect(item.right_origin)} deleted=#{item.deleted} " <>
            "parent=#{inspect(item.parent)} parent_sub=#{inspect(item.parent_sub)}"
        )
      end

      # Also dump the LAST few items of the seeded doc's own client_blocks
      # for the client that owns the right_origin anchor, to see what
      # parent_sub immediately precedes our fresh item in wire order.
      case new_items do
        [item | _] ->
          anchor_client = item.right_origin && item.right_origin.client

          if anchor_client do
            anchor_items = Yelixer.BlockStore.client_blocks(edited.store, anchor_client)
            IO.puts("anchor client #{anchor_client} has #{length(anchor_items)} block(s):")

            for ai <- anchor_items do
              IO.puts(
                "  anchor item id=(#{ai.id.client},#{ai.id.clock}) len=#{ai.length} parent=#{inspect(ai.parent)} parent_sub=#{inspect(ai.parent_sub)} deleted=#{ai.deleted}"
              )
            end
          end

        [] ->
          :ok
      end

      seq_before_insert =
        Text.delete(seeded, "content", 0, String.length(content)).store
        |> Yelixer.BlockStore.get_sequence("content")

      IO.puts("live-sequence length AFTER delete, BEFORE insert (get_sequence): #{length(seq_before_insert)}")
      IO.puts("all deleted?: #{Enum.all?(seq_before_insert, & &1.deleted)}")

      ds_ranges_for_client = Map.get(edited.delete_set.clients, edited.client_id, [])
      IO.puts("delete_set ranges for edited.client_id (#{edited.client_id}): #{inspect(ds_ranges_for_client)}")

      fresh = Doc.new(client_id: 1)
      {:ok, fresh} = Encoding.apply_update(fresh, state_bin)
      {:ok, fresh} = Encoding.apply_update(fresh, update2)

      reconstructed = Text.to_string(fresh, "content")
      IO.puts("reconstructed after delete-all+reinsert: #{inspect(String.slice(reconstructed, 0, 60))} (len=#{String.length(reconstructed)})")

      fresh_world_item = Yelixer.BlockStore.get(fresh.store, %Yelixer.ID{client: 1, clock: 0})
      IO.puts("fresh doc's copy of the (client=1,clock=0) item: #{inspect(fresh_world_item)}")
      IO.puts("fresh.delete_set: #{inspect(fresh.delete_set)}")
      IO.puts("DeleteSet.deleted?(fresh.delete_set, 1, 0): #{Yelixer.DeleteSet.deleted?(fresh.delete_set, 1, 0)}")

      assert reconstructed == new_json,
             "CX-mchn reproduced on REAL fixture: doc emptied/corrupted after delete-all+reinsert refold. " <>
               "Got length #{String.length(reconstructed)} instead of #{String.length(new_json)}"
    else
      IO.puts("Fixture not found at #{fixture} — skipping fixture-based repro")
      :ok
    end
  end
end
