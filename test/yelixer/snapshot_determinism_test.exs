defmodule Yelixer.SnapshotDeterminismTest do
  @moduledoc """
  CX-6sc (Build 5 gating precondition): `Doc.snapshot_update/1` must
  produce byte-identical output on two independent Yelixer instances
  when given the same source state. This is the load-bearing property
  that lets the commit hash dedup snapshots cut by different peers.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Text, YMap, Array}

  defp round_trip(update_bytes, target_client_id) do
    {:ok, doc} = Encoding.apply_update(Doc.new(client_id: target_client_id), update_bytes)
    doc
  end

  describe "snapshot_update/1 is byte-deterministic across instances" do
    test "two independent snapshots of the same Text doc produce identical bytes" do
      # Node A constructs a doc and produces a snapshot.
      doc_a = Doc.new(client_id: 42)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
      doc_a = Text.insert(doc_a, "t", 0, "hello world")

      # Node B constructs an INDEPENDENT doc with the same logical state
      # (same client id, same text content) via the wire protocol —
      # simulating "two peers reached the same state and now both try to
      # snapshot it."
      update = Encoding.encode_update(doc_a)
      doc_b = round_trip(update, 42)

      snap_a = Doc.snapshot_update(doc_a)
      snap_b = Doc.snapshot_update(doc_b)

      assert snap_a == snap_b
    end

    test "two independent snapshots of the same YMap doc produce identical bytes" do
      doc_a = Doc.new(client_id: 7)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "m", :map)
      doc_a = YMap.set(doc_a, "m", "alpha", "one")
      doc_a = YMap.set(doc_a, "m", "beta", "two")
      doc_a = YMap.set(doc_a, "m", "gamma", "three")

      update = Encoding.encode_update(doc_a)
      doc_b = round_trip(update, 7)

      snap_a = Doc.snapshot_update(doc_a)
      snap_b = Doc.snapshot_update(doc_b)

      assert snap_a == snap_b
    end

    test "two independent snapshots of a multi-type doc produce identical bytes" do
      doc_a = Doc.new(client_id: 5)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "m", :map)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "a", :array)
      doc_a = Text.insert(doc_a, "t", 0, "txt")
      doc_a = YMap.set(doc_a, "m", "k", "v")
      doc_a = Array.insert(doc_a, "a", 0, [1, 2, 3])

      update = Encoding.encode_update(doc_a)
      doc_b = round_trip(update, 5)

      snap_a = Doc.snapshot_update(doc_a)
      snap_b = Doc.snapshot_update(doc_b)

      assert snap_a == snap_b
    end

    test "snapshotting an empty doc is deterministic and idempotent" do
      doc_a = Doc.new(client_id: 1)
      doc_b = Doc.new(client_id: 1)

      assert Doc.snapshot_update(doc_a) == Doc.snapshot_update(doc_b)
    end

    property "snapshot_update is byte-deterministic across instances (Text)" do
      check all content <- string(:printable, min_length: 0, max_length: 40),
                client_id <- integer(1..1_000_000) do
        doc_a = Doc.new(client_id: client_id)
        {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
        doc_a = if content == "", do: doc_a, else: Text.insert(doc_a, "t", 0, content)

        update = Encoding.encode_update(doc_a)
        doc_b = round_trip(update, client_id)

        assert Doc.snapshot_update(doc_a) == Doc.snapshot_update(doc_b)
      end
    end
  end
end
