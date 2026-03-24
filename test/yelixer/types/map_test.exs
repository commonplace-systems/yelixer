defmodule Yelixer.Types.MapTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.YMap, Encoding}

  defp new_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "m", :map)
    doc
  end

  test "set and get values" do
    doc = new_doc(1)
    doc = YMap.set(doc, "m", "key", "value")
    assert YMap.get(doc, "m", "key") == "value"
  end

  test "overwrite a key" do
    doc = new_doc(1)
    doc = YMap.set(doc, "m", "key", "v1")
    doc = YMap.set(doc, "m", "key", "v2")
    assert YMap.get(doc, "m", "key") == "v2"
  end

  test "delete a key" do
    doc = new_doc(1)
    doc = YMap.set(doc, "m", "key", "value")
    doc = YMap.delete(doc, "m", "key")
    assert YMap.get(doc, "m", "key") == nil
  end

  test "to_map returns all entries" do
    doc = new_doc(1)
    doc = YMap.set(doc, "m", "a", 1)
    doc = YMap.set(doc, "m", "b", 2)
    assert YMap.to_map(doc, "m") == %{"a" => 1, "b" => 2}
  end

  test "missing key returns nil" do
    doc = new_doc(1)
    assert YMap.get(doc, "m", "missing") == nil
  end

  test "has_key?" do
    doc = new_doc(1)
    doc = YMap.set(doc, "m", "key", "value")
    assert YMap.has_key?(doc, "m", "key")
    refute YMap.has_key?(doc, "m", "other")
  end

  describe "deterministic iteration order (CX-sew)" do
    test "multi-client map via full-state update gives deterministic results" do
      # Client 1 sets "color" => "red"
      doc1 = new_doc(1)
      doc1 = YMap.set(doc1, "m", "color", "red")

      # Client 2 sets "color" => "blue"
      doc2 = new_doc(2)
      doc2 = YMap.set(doc2, "m", "color", "blue")

      # Client 3 sets "color" => "green"
      doc3 = new_doc(3)
      doc3 = YMap.set(doc3, "m", "color", "green")

      # Encode all three, then apply to a fresh doc in a fixed order
      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)
      u3 = Encoding.encode_update(doc3)

      target = new_doc(99)
      {:ok, target} = Encoding.apply_update(target, u1)
      {:ok, target} = Encoding.apply_update(target, u2)
      {:ok, target} = Encoding.apply_update(target, u3)

      result = YMap.to_map(target, "m")

      # Run the same sequence 10 times to confirm determinism
      for _ <- 1..10 do
        t = new_doc(99)
        {:ok, t} = Encoding.apply_update(t, u1)
        {:ok, t} = Encoding.apply_update(t, u2)
        {:ok, t} = Encoding.apply_update(t, u3)
        assert YMap.to_map(t, "m") == result
      end

      # The result should have exactly one value for "color"
      assert map_size(result) == 1
      assert Map.has_key?(result, "color")
    end

    test "sequential full-state snapshots produce consistent results" do
      # Simulate chain replay: apply full-state snapshot from doc_a,
      # then full-state snapshot from doc_b (which also contains doc_a's state)
      doc_a = new_doc(10)
      doc_a = YMap.set(doc_a, "m", "x", "first")

      snapshot_a = Encoding.encode_update(doc_a)

      # doc_b starts from doc_a's state then adds its own edit
      doc_b = new_doc(20)
      {:ok, doc_b} = Encoding.apply_update(doc_b, snapshot_a)
      doc_b = YMap.set(doc_b, "m", "x", "second")

      snapshot_b = Encoding.encode_update(doc_b)

      # Apply snapshot_a then snapshot_b to a fresh doc
      target1 = new_doc(99)
      {:ok, target1} = Encoding.apply_update(target1, snapshot_a)
      {:ok, target1} = Encoding.apply_update(target1, snapshot_b)

      # Apply only snapshot_b (which includes doc_a's items) to a fresh doc
      target2 = new_doc(99)
      {:ok, target2} = Encoding.apply_update(target2, snapshot_b)

      # Both targets should see the same result
      assert YMap.to_map(target1, "m") == YMap.to_map(target2, "m")
      assert YMap.get(target1, "m", "x") == "second"
      assert YMap.get(target2, "m", "x") == "second"
    end

    test "to_map and get agree on the winning value for concurrent edits" do
      doc1 = new_doc(1)
      doc1 = YMap.set(doc1, "m", "k", "v1")

      doc2 = new_doc(2)
      doc2 = YMap.set(doc2, "m", "k", "v2")

      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)

      target = new_doc(99)
      {:ok, target} = Encoding.apply_update(target, u1)
      {:ok, target} = Encoding.apply_update(target, u2)

      map_result = YMap.to_map(target, "m")
      get_result = YMap.get(target, "m", "k")

      # Both to_map and get should return the same winner
      assert map_result["k"] == get_result
    end

    test "has_key? is consistent with get after concurrent updates" do
      doc1 = new_doc(1)
      doc1 = YMap.set(doc1, "m", "alive", "yes")

      doc2 = new_doc(2)
      doc2 = YMap.set(doc2, "m", "alive", "no")

      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)

      target = new_doc(99)
      {:ok, target} = Encoding.apply_update(target, u1)
      {:ok, target} = Encoding.apply_update(target, u2)

      assert YMap.has_key?(target, "m", "alive")
      assert YMap.get(target, "m", "alive") != nil
    end
  end
end
