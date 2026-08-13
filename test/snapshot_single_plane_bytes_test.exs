defmodule Yelixer.SnapshotSinglePlaneBytesTest do
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Types.{Array, Text, YMap}

  @moduledoc """
  Byte-identity pin for `Doc.snapshot_update/1` on SINGLE-PLANE docs.

  CX-2xn1 taught `snapshot_update/1` to replay both storage planes (the
  Y.Map key plane and the ordered sequence plane) instead of one. The
  fix is only safe because each added plane-replay is a no-op when its
  plane is empty, so a doc with only one plane populated snapshots to
  BYTE-IDENTICAL output. That property is load-bearing well beyond this
  test: `Commonplace.Store.Snapshotter` binds these bytes into the
  commit id ("deterministic-anyone" — two independent nodes computing
  the same snapshot must agree byte-for-byte), so a silent perturbation
  would fork commit ids across nodes and break CID dedup.

  Nothing else in the suite pinned it. The yrs dataset and yrs_compat
  tests establish DECODE equivalence — that we interpret reference bytes
  the way yrs does — not ENCODE determinism. Those are different claims,
  and reading the first as covering the second is exactly the gap this
  file exists to close.

  The vectors below are the actual output of the current encoder,
  captured deliberately. Their job is to FAIL if a future change to the
  encoder, to snapshot replay, or to client-id selection perturbs
  single-plane bytes. If you are here because this test went red: that
  is the test working. A deliberate encoder change needs a
  `snapshotter_version` bump (see `Commonplace.Store.Snapshotter`) so
  the new bytes get a different commit id rather than silently aliasing
  the old ones — then update these vectors in the same commit.
  """

  defp snapshot_hex(doc) do
    {bytes, _dm} = Doc.snapshot_update(doc, force: true)
    Base.encode16(bytes, case: :lower)
  end

  test "a text-only doc snapshots to exactly these bytes" do
    doc = Doc.new(client_id: 7)
    {doc, _} = Doc.get_or_create_type(doc, "content", :text)
    doc = Text.insert(doc, "content", 0, "hello world")

    assert snapshot_hex(doc) ==
             "01010700040107636f6e74656e740b68656c6c6f20776f726c6400"
  end

  test "a map-only doc snapshots to exactly these bytes" do
    doc = Doc.new(client_id: 7)
    {doc, _} = Doc.get_or_create_type(doc, "content", :map)
    doc = YMap.set(doc, "content", "a", "one")
    doc = YMap.set(doc, "content", "b", "two")

    assert snapshot_hex(doc) ==
             "01020700280107636f6e74656e7401610177036f6e65280107636f6e74656e74016201770374776f00"
  end

  test "an array-only doc snapshots to exactly these bytes" do
    doc = Doc.new(client_id: 7)
    {doc, _} = Doc.get_or_create_type(doc, "content", :array)
    doc = Array.insert(doc, "content", 0, ["x", "y", "z"])

    assert snapshot_hex(doc) ==
             "01030700080107636f6e74656e7401770178880700017701798807010177017a00"
  end

  test "snapshotting is deterministic across repeated calls on equal docs" do
    build = fn ->
      d = Doc.new(client_id: 7)
      {d, _} = Doc.get_or_create_type(d, "content", :text)
      Text.insert(d, "content", 0, "hello world")
    end

    assert snapshot_hex(build.()) == snapshot_hex(build.())
  end
end
