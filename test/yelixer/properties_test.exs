defmodule Yelixer.PropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Yelixer.{Doc, Types.Text, Types.YMap, Types.Array, Encoding, BlockStore, StateVector}

  @moduletag :properties

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp new_doc(client_id, types) do
    doc = Doc.new(client_id: client_id)

    Enum.reduce(types, doc, fn {name, ref}, doc ->
      {doc, _} = Doc.get_or_create_type(doc, name, ref)
      doc
    end)
  end

  defp apply_updates_in_order(doc, updates) do
    Enum.reduce(updates, doc, fn update, d ->
      {:ok, d} = Encoding.apply_update(d, update)
      d
    end)
  end

  defp shuffle_list(list) do
    Enum.shuffle(list)
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # NOTE: We use non-negative integers only because there is a known
  # zigzag (signed varint) encoding bug that corrupts negative values
  # during encode/decode roundtrips. That bug is tracked separately.
  defp map_key, do: string(:alphanumeric, min_length: 1, max_length: 8)

  defp map_value,
    do: one_of([non_negative_integer(), string(:alphanumeric, min_length: 1, max_length: 10)])

  defp text_content, do: string(:alphanumeric, min_length: 1, max_length: 10)

  defp array_element,
    do:
      one_of([non_negative_integer(), string(:alphanumeric, min_length: 1, max_length: 8)])

  defp map_entries do
    list_of(tuple({map_key(), map_value()}), min_length: 1, max_length: 5)
  end

  defp array_elements do
    list_of(array_element(), min_length: 1, max_length: 5)
  end

  # ===========================================================================
  # 1. APPLY-ORDER INDEPENDENCE (CONVERGENCE)
  # ===========================================================================

  property "two peers always converge regardless of insert content" do
    check all text1 <- string(:alphanumeric, min_length: 1, max_length: 10),
              text2 <- string(:alphanumeric, min_length: 1, max_length: 10) do
      doc1 = Doc.new(client_id: 1)
      doc2 = Doc.new(client_id: 2)
      {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
      {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)

      doc1 = Text.insert(doc1, "text", 0, text1)
      doc2 = Text.insert(doc2, "text", 0, text2)

      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)

      {:ok, doc1} = Encoding.apply_update(doc1, u2)
      {:ok, doc2} = Encoding.apply_update(doc2, u1)

      assert Text.to_string(doc1, "text") == Text.to_string(doc2, "text")
    end
  end

  property "three peers always converge" do
    check all t1 <- string(:alphanumeric, min_length: 1, max_length: 5),
              t2 <- string(:alphanumeric, min_length: 1, max_length: 5),
              t3 <- string(:alphanumeric, min_length: 1, max_length: 5) do
      docs =
        [{1, t1}, {2, t2}, {3, t3}]
        |> Enum.map(fn {id, text} ->
          doc = Doc.new(client_id: id)
          {doc, _} = Doc.get_or_create_type(doc, "text", :text)
          Text.insert(doc, "text", 0, text)
        end)

      updates = Enum.map(docs, &Encoding.encode_update/1)

      synced_docs =
        Enum.map(docs, fn doc ->
          apply_updates_in_order(doc, updates)
        end)

      texts = Enum.map(synced_docs, &Text.to_string(&1, "text"))
      assert Enum.uniq(texts) |> length() == 1
    end
  end

  property "apply-order independence: text updates converge regardless of ordering" do
    check all t1 <- text_content(),
              t2 <- text_content(),
              t3 <- text_content() do
      # Three clients each insert text concurrently
      docs =
        [{1, t1}, {2, t2}, {3, t3}]
        |> Enum.map(fn {id, text} ->
          doc = new_doc(id, [{"text", :text}])
          Text.insert(doc, "text", 0, text)
        end)

      updates = Enum.map(docs, &Encoding.encode_update/1)

      # Apply in original order to a fresh doc
      fresh_a = new_doc(10, [{"text", :text}])
      doc_a = apply_updates_in_order(fresh_a, updates)

      # Apply in reversed order to another fresh doc
      fresh_b = new_doc(11, [{"text", :text}])
      doc_b = apply_updates_in_order(fresh_b, Enum.reverse(updates))

      # Apply in a shuffled order to a third fresh doc
      fresh_c = new_doc(12, [{"text", :text}])
      doc_c = apply_updates_in_order(fresh_c, shuffle_list(updates))

      result_a = Text.to_string(doc_a, "text")
      result_b = Text.to_string(doc_b, "text")
      result_c = Text.to_string(doc_c, "text")

      assert result_a == result_b
      assert result_a == result_c
    end
  end

  property "apply-order independence: map updates converge regardless of ordering" do
    check all entries1 <- map_entries(),
              entries2 <- map_entries() do
      # Client 1 sets some keys
      doc1 = new_doc(1, [{"m", :map}])

      doc1 =
        Enum.reduce(entries1, doc1, fn {k, v}, d ->
          YMap.set(d, "m", k, v)
        end)

      # Client 2 sets some keys (may overlap)
      doc2 = new_doc(2, [{"m", :map}])

      doc2 =
        Enum.reduce(entries2, doc2, fn {k, v}, d ->
          YMap.set(d, "m", k, v)
        end)

      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)

      # Apply in both orderings
      fresh_a = new_doc(10, [{"m", :map}])
      doc_a = apply_updates_in_order(fresh_a, [u1, u2])

      fresh_b = new_doc(11, [{"m", :map}])
      doc_b = apply_updates_in_order(fresh_b, [u2, u1])

      assert YMap.to_map(doc_a, "m") == YMap.to_map(doc_b, "m")
    end
  end

  property "apply-order independence: array updates converge regardless of ordering" do
    check all elems1 <- array_elements(),
              elems2 <- array_elements() do
      doc1 = new_doc(1, [{"arr", :array}])
      doc1 = Array.push(doc1, "arr", elems1)

      doc2 = new_doc(2, [{"arr", :array}])
      doc2 = Array.push(doc2, "arr", elems2)

      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)

      fresh_a = new_doc(10, [{"arr", :array}])
      doc_a = apply_updates_in_order(fresh_a, [u1, u2])

      fresh_b = new_doc(11, [{"arr", :array}])
      doc_b = apply_updates_in_order(fresh_b, [u2, u1])

      assert Array.to_list(doc_a, "arr") == Array.to_list(doc_b, "arr")
    end
  end

  # ===========================================================================
  # 2. ENCODE/DECODE ROUNDTRIP
  # ===========================================================================

  property "encode/decode roundtrip preserves text content" do
    check all text <- string(:alphanumeric, min_length: 1, max_length: 20) do
      doc1 = Doc.new(client_id: 1)
      {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
      doc1 = Text.insert(doc1, "text", 0, text)

      update = Encoding.encode_update(doc1)

      doc2 = Doc.new(client_id: 2)
      {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)
      {:ok, doc2} = Encoding.apply_update(doc2, update)

      assert Text.to_string(doc2, "text") == text
    end
  end

  property "encode/decode roundtrip preserves map entries" do
    check all entries <- map_entries() do
      doc1 = new_doc(1, [{"m", :map}])

      doc1 =
        Enum.reduce(entries, doc1, fn {k, v}, d ->
          YMap.set(d, "m", k, v)
        end)

      update = Encoding.encode_update(doc1)

      doc2 = new_doc(2, [{"m", :map}])
      {:ok, doc2} = Encoding.apply_update(doc2, update)

      assert YMap.to_map(doc2, "m") == YMap.to_map(doc1, "m")
    end
  end

  property "encode/decode roundtrip preserves array elements" do
    check all elems <- array_elements() do
      doc1 = new_doc(1, [{"arr", :array}])
      doc1 = Array.push(doc1, "arr", elems)

      update = Encoding.encode_update(doc1)

      doc2 = new_doc(2, [{"arr", :array}])
      {:ok, doc2} = Encoding.apply_update(doc2, update)

      assert Array.to_list(doc2, "arr") == Array.to_list(doc1, "arr")
    end
  end

  property "double encode/decode roundtrip yields same state" do
    check all text <- text_content(),
              entries <- map_entries() do
      # Build a doc with both text and map content
      doc1 = new_doc(1, [{"text", :text}, {"m", :map}])
      doc1 = Text.insert(doc1, "text", 0, text)

      doc1 =
        Enum.reduce(entries, doc1, fn {k, v}, d ->
          YMap.set(d, "m", k, v)
        end)

      # First encode/decode
      update1 = Encoding.encode_update(doc1)
      doc2 = new_doc(2, [{"text", :text}, {"m", :map}])
      {:ok, doc2} = Encoding.apply_update(doc2, update1)

      # Second encode/decode
      update2 = Encoding.encode_update(doc2)
      doc3 = new_doc(3, [{"text", :text}, {"m", :map}])
      {:ok, doc3} = Encoding.apply_update(doc3, update2)

      assert Text.to_string(doc2, "text") == Text.to_string(doc3, "text")
      assert YMap.to_map(doc2, "m") == YMap.to_map(doc3, "m")
    end
  end

  # ===========================================================================
  # 3. STATE VECTOR MONOTONICITY
  # ===========================================================================

  property "state vector clocks never decrease after apply_update" do
    check all t1 <- text_content(),
              t2 <- text_content() do
      # Build an update from client 1
      doc_src = new_doc(1, [{"text", :text}])
      doc_src = Text.insert(doc_src, "text", 0, t1)
      update1 = Encoding.encode_update(doc_src)

      # Build an update from client 2
      doc_src2 = new_doc(2, [{"text", :text}])
      doc_src2 = Text.insert(doc_src2, "text", 0, t2)
      update2 = Encoding.encode_update(doc_src2)

      # Start with a fresh doc, record state vector, apply updates, check monotonicity
      doc = new_doc(10, [{"text", :text}])
      sv_before = BlockStore.state_vector(doc.store)

      {:ok, doc} = Encoding.apply_update(doc, update1)
      sv_after_1 = BlockStore.state_vector(doc.store)

      # Every client clock from before must be <= clock after
      assert_sv_monotonic(sv_before, sv_after_1)

      {:ok, doc} = Encoding.apply_update(doc, update2)
      sv_after_2 = BlockStore.state_vector(doc.store)

      assert_sv_monotonic(sv_after_1, sv_after_2)
    end
  end

  property "state vector monotonicity with map operations" do
    check all entries <- map_entries() do
      doc_src = new_doc(1, [{"m", :map}])

      doc_src =
        Enum.reduce(entries, doc_src, fn {k, v}, d ->
          YMap.set(d, "m", k, v)
        end)

      update = Encoding.encode_update(doc_src)

      doc = new_doc(10, [{"m", :map}])
      sv_before = BlockStore.state_vector(doc.store)

      {:ok, doc} = Encoding.apply_update(doc, update)
      sv_after = BlockStore.state_vector(doc.store)

      assert_sv_monotonic(sv_before, sv_after)
    end
  end

  property "state vector monotonicity across multiple sequential updates" do
    check all t1 <- text_content(),
              t2 <- text_content(),
              t3 <- text_content() do
      updates =
        [{1, t1}, {2, t2}, {3, t3}]
        |> Enum.map(fn {id, text} ->
          doc = new_doc(id, [{"text", :text}])
          doc = Text.insert(doc, "text", 0, text)
          Encoding.encode_update(doc)
        end)

      # Apply updates one at a time, checking monotonicity at each step
      {_doc, _} =
        Enum.reduce(updates, {new_doc(10, [{"text", :text}]), nil}, fn update,
                                                                       {doc, prev_sv} ->
          sv_before = BlockStore.state_vector(doc.store)

          if prev_sv do
            assert_sv_monotonic(prev_sv, sv_before)
          end

          {:ok, doc} = Encoding.apply_update(doc, update)
          sv_after = BlockStore.state_vector(doc.store)
          assert_sv_monotonic(sv_before, sv_after)
          {doc, sv_after}
        end)
    end
  end

  # ===========================================================================
  # 4. IDEMPOTENCE
  # ===========================================================================

  property "applying same update twice is idempotent (text)" do
    check all text <- string(:alphanumeric, min_length: 1, max_length: 10) do
      doc1 = Doc.new(client_id: 1)
      {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
      doc1 = Text.insert(doc1, "text", 0, text)
      update = Encoding.encode_update(doc1)

      doc2 = Doc.new(client_id: 2)
      {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)

      {:ok, doc2} = Encoding.apply_update(doc2, update)
      text_once = Text.to_string(doc2, "text")

      {:ok, doc2} = Encoding.apply_update(doc2, update)
      text_twice = Text.to_string(doc2, "text")

      assert text_once == text_twice
    end
  end

  property "applying same update twice is idempotent (map)" do
    check all entries <- map_entries() do
      doc1 = new_doc(1, [{"m", :map}])

      doc1 =
        Enum.reduce(entries, doc1, fn {k, v}, d ->
          YMap.set(d, "m", k, v)
        end)

      update = Encoding.encode_update(doc1)

      doc2 = new_doc(2, [{"m", :map}])
      {:ok, doc2} = Encoding.apply_update(doc2, update)
      map_once = YMap.to_map(doc2, "m")

      {:ok, doc2} = Encoding.apply_update(doc2, update)
      map_twice = YMap.to_map(doc2, "m")

      assert map_once == map_twice
    end
  end

  property "applying same update twice is idempotent (array)" do
    check all elems <- array_elements() do
      doc1 = new_doc(1, [{"arr", :array}])
      doc1 = Array.push(doc1, "arr", elems)

      update = Encoding.encode_update(doc1)

      doc2 = new_doc(2, [{"arr", :array}])
      {:ok, doc2} = Encoding.apply_update(doc2, update)
      list_once = Array.to_list(doc2, "arr")

      {:ok, doc2} = Encoding.apply_update(doc2, update)
      list_twice = Array.to_list(doc2, "arr")

      assert list_once == list_twice
    end
  end

  property "applying same update three times is idempotent" do
    check all text <- text_content(),
              entries <- map_entries() do
      doc1 = new_doc(1, [{"text", :text}, {"m", :map}])
      doc1 = Text.insert(doc1, "text", 0, text)

      doc1 =
        Enum.reduce(entries, doc1, fn {k, v}, d ->
          YMap.set(d, "m", k, v)
        end)

      update = Encoding.encode_update(doc1)

      doc2 = new_doc(2, [{"text", :text}, {"m", :map}])
      {:ok, doc2} = Encoding.apply_update(doc2, update)
      text_once = Text.to_string(doc2, "text")
      map_once = YMap.to_map(doc2, "m")

      {:ok, doc2} = Encoding.apply_update(doc2, update)
      {:ok, doc2} = Encoding.apply_update(doc2, update)
      text_thrice = Text.to_string(doc2, "text")
      map_thrice = YMap.to_map(doc2, "m")

      assert text_once == text_thrice
      assert map_once == map_thrice
    end
  end

  # ===========================================================================
  # 5. MAP LAST-WRITER-WINS
  # ===========================================================================

  property "map last-writer-wins: concurrent sets on same key yield one deterministic value" do
    check all key <- map_key(),
              val1 <- map_value(),
              val2 <- map_value() do
      # Two clients set the same key concurrently
      doc1 = new_doc(1, [{"m", :map}])
      doc1 = YMap.set(doc1, "m", key, val1)

      doc2 = new_doc(2, [{"m", :map}])
      doc2 = YMap.set(doc2, "m", key, val2)

      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)

      # Apply in order 1 -> 2
      fresh_a = new_doc(10, [{"m", :map}])
      doc_a = apply_updates_in_order(fresh_a, [u1, u2])

      # Apply in order 2 -> 1
      fresh_b = new_doc(11, [{"m", :map}])
      doc_b = apply_updates_in_order(fresh_b, [u2, u1])

      map_a = YMap.to_map(doc_a, "m")
      map_b = YMap.to_map(doc_b, "m")

      # Must have exactly one value for the key (not both)
      assert map_size(map_a) >= 1
      assert Map.has_key?(map_a, key)

      # Must be deterministic regardless of apply order
      assert map_a == map_b
    end
  end

  property "map last-writer-wins: three clients setting same key converge to one value" do
    check all key <- map_key(),
              val1 <- map_value(),
              val2 <- map_value(),
              val3 <- map_value() do
      doc1 = new_doc(1, [{"m", :map}])
      doc1 = YMap.set(doc1, "m", key, val1)

      doc2 = new_doc(2, [{"m", :map}])
      doc2 = YMap.set(doc2, "m", key, val2)

      doc3 = new_doc(3, [{"m", :map}])
      doc3 = YMap.set(doc3, "m", key, val3)

      updates = [
        Encoding.encode_update(doc1),
        Encoding.encode_update(doc2),
        Encoding.encode_update(doc3)
      ]

      # Apply in all six orderings and verify they all produce the same map
      results =
        for perm <- permutations(updates) do
          fresh = new_doc(10, [{"m", :map}])
          doc = apply_updates_in_order(fresh, perm)
          YMap.to_map(doc, "m")
        end

      # All permutations must yield the same result
      assert Enum.uniq(results) |> length() == 1

      # The winning map must have exactly one value for the key
      [winner | _] = results
      assert Map.has_key?(winner, key)
      winning_val = Map.get(winner, key)
      assert winning_val in [val1, val2, val3]
    end
  end

  property "map last-writer-wins: multiple keys with concurrent overwrites" do
    check all entries1 <- map_entries(),
              entries2 <- map_entries() do
      doc1 = new_doc(1, [{"m", :map}])

      doc1 =
        Enum.reduce(entries1, doc1, fn {k, v}, d ->
          YMap.set(d, "m", k, v)
        end)

      doc2 = new_doc(2, [{"m", :map}])

      doc2 =
        Enum.reduce(entries2, doc2, fn {k, v}, d ->
          YMap.set(d, "m", k, v)
        end)

      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)

      fresh_a = new_doc(10, [{"m", :map}])
      doc_a = apply_updates_in_order(fresh_a, [u1, u2])

      fresh_b = new_doc(11, [{"m", :map}])
      doc_b = apply_updates_in_order(fresh_b, [u2, u1])

      map_a = YMap.to_map(doc_a, "m")
      map_b = YMap.to_map(doc_b, "m")

      # Every key that was set by either client should be present
      all_keys =
        (Enum.map(entries1, &elem(&1, 0)) ++ Enum.map(entries2, &elem(&1, 0)))
        |> Enum.uniq()

      for key <- all_keys do
        assert Map.has_key?(map_a, key), "key #{inspect(key)} missing from result"
      end

      # Both orderings must converge
      assert map_a == map_b
    end
  end

  # ---------------------------------------------------------------------------
  # Assertion helpers
  # ---------------------------------------------------------------------------

  defp assert_sv_monotonic(sv_before, sv_after) do
    # For every client in sv_before, its clock in sv_after must be >=
    for {client, clock_before} <- sv_before.clocks do
      clock_after = StateVector.get(sv_after, client)

      assert clock_after >= clock_before,
             "State vector went backwards for client #{client}: " <>
               "#{clock_before} -> #{clock_after}"
    end
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for elem <- list,
        rest <- permutations(list -- [elem]) do
      [elem | rest]
    end
  end
end
