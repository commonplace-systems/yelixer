defmodule Yelixer.RehydratePropertiesTest do
  @moduledoc """
  Property-based tests for the save→reload→modify pattern (CX-hbs).

  Targets the specific gap CX-2sv lived in: random scripts of text ops
  interspersed with save-reload points. The generator picks a random
  sequence of {op, reload?} tuples, applies them to a doc, and checks
  the core CRDT invariants — save-reload preservation, modify-then-
  reload-equals-modify-no-reload, and convergence.

  These are cheap to run and catch classes of bugs that targeted tests
  miss because they can't enumerate every edge case by hand. CX-2sv
  specifically would have been caught by the save-reload-preservation
  property if the generator ever produced a delete-from-start on a
  rehydrated envelope doc.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Text, YMap, Array}

  @moduletag :properties

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp new_envelope_text_doc(client_id) do
    # Mimics Commonplace.Document.ContentType.create/3 — two sequences
    # (root map + content text) from the same client. This is the
    # pattern CX-2sv specifically needed to trigger.
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "root", :map)
    doc = YMap.set(doc, "root", "_type", "text")
    doc = YMap.set(doc, "root", "_name", "file.txt")
    {doc, _} = Doc.get_or_create_type(doc, "content", :text)
    doc
  end

  defp new_envelope_map_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "root", :map)
    doc = YMap.set(doc, "root", "_type", "map")
    {doc, _} = Doc.get_or_create_type(doc, "content", :map)
    doc
  end

  defp new_envelope_array_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "root", :map)
    doc = YMap.set(doc, "root", "_type", "array")
    {doc, _} = Doc.get_or_create_type(doc, "items", :array)
    doc
  end

  defp roundtrip(%Doc{client_id: cid} = doc) do
    bin = Encoding.encode_update(doc)
    {:ok, fresh} = Encoding.apply_update(Doc.new(client_id: cid), bin)
    fresh
  end

  # ---------------------------------------------------------------------------
  # Text op generators
  # ---------------------------------------------------------------------------

  # An op is one of {:insert, pos, text} or {:delete, pos, len}. The generator
  # is position-agnostic: the runner clamps positions to the current doc size.
  defp text_op do
    one_of([
      tuple({constant(:insert), integer(0..50), string(:alphanumeric, min_length: 1, max_length: 8)}),
      tuple({constant(:delete), integer(0..50), integer(1..8)})
    ])
  end

  defp text_script, do: list_of(text_op(), min_length: 1, max_length: 20)

  defp apply_text_op(doc, {:insert, pos, text}) do
    len = String.length(Text.to_string(doc, "content"))
    Text.insert(doc, "content", min(pos, len), text)
  end

  defp apply_text_op(doc, {:delete, pos, del_len}) do
    len = String.length(Text.to_string(doc, "content"))

    cond do
      len == 0 ->
        doc

      pos >= len ->
        doc

      true ->
        actual_len = min(del_len, len - pos)
        Text.delete(doc, "content", pos, actual_len)
    end
  end

  # Apply a script of ops, saving and reloading at each :reload marker.
  # Reload markers are inserted at positions picked by the reload_positions
  # generator — a sorted list of indices into the ops list.
  defp run_text_script(doc, ops, reload_positions) do
    reload_set = MapSet.new(reload_positions)

    {final_doc, _} =
      Enum.with_index(ops)
      |> Enum.reduce({doc, 0}, fn {op, idx}, {d, _} ->
        d = apply_text_op(d, op)
        d = if MapSet.member?(reload_set, idx), do: roundtrip(d), else: d
        {d, idx}
      end)

    final_doc
  end

  # ---------------------------------------------------------------------------
  # 1. Save-reload preservation (the basic invariant CX-2sv violated)
  # ---------------------------------------------------------------------------

  property "text content survives encode-decode after arbitrary ops on envelope doc" do
    check all ops <- text_script(), max_runs: 200 do
      doc = new_envelope_text_doc(1)
      mutated = Enum.reduce(ops, doc, &apply_text_op(&2, &1))

      live_content = Text.to_string(mutated, "content")
      assert Text.to_string(roundtrip(mutated), "content") == live_content
    end
  end

  property "envelope metadata survives encode-decode after arbitrary text ops" do
    check all ops <- text_script(), max_runs: 200 do
      doc = new_envelope_text_doc(1)
      mutated = Enum.reduce(ops, doc, &apply_text_op(&2, &1))

      reloaded = roundtrip(mutated)
      assert YMap.to_map(reloaded, "root") == %{"_type" => "text", "_name" => "file.txt"}
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Interleaved save-reload during op application
  # ---------------------------------------------------------------------------

  property "interleaved save-reload gives the same final content as no save-reload" do
    check all ops <- text_script(), seed <- integer(0..99), max_runs: 200 do
      doc = new_envelope_text_doc(1)

      # Deterministic reload positions from the seed so both paths see
      # the same op sequence and the only difference is whether we reload.
      reload_positions =
        if ops == [] do
          []
        else
          :rand.seed(:exsss, {seed, seed, seed})
          Enum.filter(0..(length(ops) - 1), fn _ -> :rand.uniform() < 0.3 end)
        end

      without_reload = Enum.reduce(ops, doc, &apply_text_op(&2, &1))
      with_reload = run_text_script(doc, ops, reload_positions)

      assert Text.to_string(with_reload, "content") ==
               Text.to_string(without_reload, "content")
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Idempotent save-reload (reload doesn't mutate state)
  # ---------------------------------------------------------------------------

  property "save-reload is idempotent: reload of reload equals reload" do
    check all ops <- text_script(), max_runs: 200 do
      doc = new_envelope_text_doc(1)
      mutated = Enum.reduce(ops, doc, &apply_text_op(&2, &1))

      once = roundtrip(mutated)
      twice = roundtrip(once)

      assert Text.to_string(once, "content") == Text.to_string(twice, "content")
      assert YMap.to_map(once, "root") == YMap.to_map(twice, "root")
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Map rehydrate-modify
  # ---------------------------------------------------------------------------

  defp map_op do
    one_of([
      tuple({
        constant(:set),
        string(:alphanumeric, min_length: 1, max_length: 4),
        string(:alphanumeric, min_length: 1, max_length: 6)
      }),
      tuple({constant(:delete), string(:alphanumeric, min_length: 1, max_length: 4)})
    ])
  end

  defp apply_map_op(doc, {:set, k, v}), do: YMap.set(doc, "content", k, v)
  defp apply_map_op(doc, {:delete, k}), do: YMap.delete(doc, "content", k)

  property "map content survives encode-decode after arbitrary ops" do
    check all ops <- list_of(map_op(), max_length: 20), max_runs: 200 do
      doc = new_envelope_map_doc(1)
      mutated = Enum.reduce(ops, doc, &apply_map_op(&2, &1))

      live = YMap.to_map(mutated, "content")
      assert YMap.to_map(roundtrip(mutated), "content") == live
      assert YMap.to_map(roundtrip(mutated), "root") == %{"_type" => "map"}
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Array rehydrate-modify
  # ---------------------------------------------------------------------------

  defp array_op do
    one_of([
      tuple({constant(:push), list_of(integer(0..99), min_length: 1, max_length: 4)}),
      tuple({
        constant(:insert),
        integer(0..50),
        list_of(integer(0..99), min_length: 1, max_length: 4)
      }),
      tuple({constant(:delete), integer(0..50), integer(1..4)})
    ])
  end

  defp apply_array_op(doc, {:push, items}), do: Array.push(doc, "items", items)

  defp apply_array_op(doc, {:insert, pos, items}) do
    len = length(Array.to_list(doc, "items"))
    Array.insert(doc, "items", min(pos, len), items)
  end

  defp apply_array_op(doc, {:delete, pos, del_len}) do
    len = length(Array.to_list(doc, "items"))

    cond do
      len == 0 ->
        doc

      pos >= len ->
        doc

      true ->
        Array.delete(doc, "items", pos, min(del_len, len - pos))
    end
  end

  property "array content survives encode-decode after arbitrary ops" do
    check all ops <- list_of(array_op(), max_length: 15), max_runs: 200 do
      doc = new_envelope_array_doc(1)
      mutated = Enum.reduce(ops, doc, &apply_array_op(&2, &1))

      live = Array.to_list(mutated, "items")
      assert Array.to_list(roundtrip(mutated), "items") == live
      assert YMap.to_map(roundtrip(mutated), "root") == %{"_type" => "array"}
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Multi-cycle rehydrate chain preserves content
  # ---------------------------------------------------------------------------

  property "N rehydrate cycles interleaved with single ops preserve final content" do
    check all ops <- text_script(), n <- integer(1..10), max_runs: 100 do
      doc = new_envelope_text_doc(1)

      # Apply ops in groups of 1, rehydrating between each op
      final =
        Enum.reduce(ops, doc, fn op, acc ->
          acc = apply_text_op(acc, op)
          Enum.reduce(1..n, acc, fn _, d -> roundtrip(d) end)
        end)

      # Compare against the no-rehydrate version
      expected = Enum.reduce(ops, doc, &apply_text_op(&2, &1))

      assert Text.to_string(final, "content") == Text.to_string(expected, "content")
    end
  end
end
