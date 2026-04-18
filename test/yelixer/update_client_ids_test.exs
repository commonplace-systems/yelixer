defmodule Yelixer.UpdateClientIdsTest do
  @moduledoc """
  Tests for Yelixer.Encoding.update_client_ids/1 — extract the set of
  clientIDs that appear in a Yjs V1 update binary without applying it.

  This is the low-level primitive that Commonplace's namespace validator
  uses to check whether a regular commit's clientIDs are members of the
  namespace rooted at its `snapshot_parent`.
  """
  use ExUnit.Case

  alias Yelixer.Encoding

  test "extracts single clientID from a simple update" do
    doc = Yelixer.Doc.new(client_id: 42)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "t", :text)
    doc = Yelixer.Types.Text.insert(doc, "t", 0, "hi")

    update = Encoding.encode_update(doc)

    assert {:ok, client_ids} = Encoding.update_client_ids(update)
    assert client_ids == MapSet.new([42])
  end

  test "extracts multiple clientIDs from a merged update" do
    doc_a = Yelixer.Doc.new(client_id: 1)
    {doc_a, _} = Yelixer.Doc.get_or_create_type(doc_a, "t", :text)
    doc_a = Yelixer.Types.Text.insert(doc_a, "t", 0, "A")

    doc_b = Yelixer.Doc.new(client_id: 2)
    {doc_b, _} = Yelixer.Doc.get_or_create_type(doc_b, "t", :text)
    doc_b = Yelixer.Types.Text.insert(doc_b, "t", 0, "B")

    update_a = Encoding.encode_update(doc_a)
    {:ok, doc_b} = Encoding.apply_update(doc_b, update_a)

    merged = Encoding.encode_update(doc_b)

    assert {:ok, client_ids} = Encoding.update_client_ids(merged)
    assert MapSet.subset?(MapSet.new([1, 2]), client_ids)
  end

  test "empty update has no clientIDs" do
    doc = Yelixer.Doc.new(client_id: 7)
    update = Encoding.encode_update(doc)

    assert {:ok, client_ids} = Encoding.update_client_ids(update)
    assert MapSet.size(client_ids) == 0
  end

  test "malformed update returns an error" do
    assert {:error, {:malformed_update, _}} = Encoding.update_client_ids(<<255, 255, 255>>)
  end

  test "includes clientIDs from delete-set-only updates" do
    # Create a doc with content, then delete it, so the delete set carries the clientID
    doc = Yelixer.Doc.new(client_id: 99)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "t", :text)
    doc = Yelixer.Types.Text.insert(doc, "t", 0, "to-delete")
    doc = Yelixer.Types.Text.delete(doc, "t", 0, 9)

    update = Encoding.encode_update(doc)

    assert {:ok, client_ids} = Encoding.update_client_ids(update)
    assert MapSet.member?(client_ids, 99)
  end
end
