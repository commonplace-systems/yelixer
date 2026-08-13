defmodule Yelixer.UpdateClientIdsByRoleTest do
  @moduledoc """
  Tests for Yelixer.Encoding.update_client_ids_by_role/1 (CX-fbs6).

  Splits the clientIDs in an update binary by role:

  - `:authorship` — clientIDs that own newly-inserted items (`item.id.client`
    for non-GC items). These EXTEND the namespace when the commit lands.
  - `:reference`  — clientIDs appearing in refs only (origin, right_origin,
    `{:id, _}` parent, delete_set targets). These MUST already be in the
    namespace — they point at existing items.

  Rationale: a namespace is the cumulative set of authors whose items are
  included as a commit chain grows. Translated cross-epoch commits carry
  item-authorship from peers the target namespace hasn't seen yet; those
  authors JOIN the namespace when the commit lands. But refs must resolve,
  so every ref's clientID must already be present.
  """
  use ExUnit.Case

  alias Yelixer.Encoding

  test "pure insert by a single client: authorship=[client], reference=∅" do
    doc = Yelixer.Doc.new(client_id: 42)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "t", :text)
    doc = Yelixer.Types.Text.insert(doc, "t", 0, "hi")
    update = Encoding.encode_update(doc)

    assert {:ok, %{authorship: authorship, reference: reference}} =
             Encoding.update_client_ids_by_role(update)

    assert authorship == MapSet.new([42])
    # No origin/right_origin/parent-by-id refs in a fresh insert on a named
    # type, and no deletes — reference set is empty.
    assert reference == MapSet.new()
  end

  test "later insert with left-origin: the origin clientID is a reference" do
    # Client 1 inserts "abc", then client 2 applies that and inserts "X"
    # after "c". X's origin is {1, 2} — a reference to client 1.
    doc_a = Yelixer.Doc.new(client_id: 1)
    {doc_a, _} = Yelixer.Doc.get_or_create_type(doc_a, "t", :text)
    doc_a = Yelixer.Types.Text.insert(doc_a, "t", 0, "abc")
    base = Encoding.encode_update(doc_a)

    doc_b = Yelixer.Doc.new(client_id: 2)
    {doc_b, _} = Yelixer.Doc.get_or_create_type(doc_b, "t", :text)
    {:ok, doc_b} = Encoding.apply_update(doc_b, base)
    doc_b = Yelixer.Types.Text.insert(doc_b, "t", 3, "X")

    # Encode just client 2's contribution (diff from base state vector).
    base_sv = Yelixer.BlockStore.state_vector(doc_a.store)
    update = Encoding.encode_diff(doc_b, base_sv)

    assert {:ok, %{authorship: authorship, reference: reference}} =
             Encoding.update_client_ids_by_role(update)

    assert authorship == MapSet.new([2])
    assert MapSet.member?(reference, 1)
  end

  test "delete set targets are references, not authorship" do
    # Client 99 inserts and deletes its OWN content: author+ref both 99.
    doc = Yelixer.Doc.new(client_id: 99)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "t", :text)
    doc = Yelixer.Types.Text.insert(doc, "t", 0, "to-delete")
    doc = Yelixer.Types.Text.delete(doc, "t", 0, 9)
    update = Encoding.encode_update(doc)

    assert {:ok, %{authorship: authorship, reference: reference}} =
             Encoding.update_client_ids_by_role(update)

    # Authorship comes from the inserted items; reference comes from the
    # delete set. Same client is in both — this is legal.
    assert MapSet.member?(authorship, 99)
    assert MapSet.member?(reference, 99)
  end

  test "delete-set-only update (no new items): authorship=∅, reference=[deleter target client]" do
    # Client 1 inserts "hi" and encodes a snapshot.
    doc_a = Yelixer.Doc.new(client_id: 1)
    {doc_a, _} = Yelixer.Doc.get_or_create_type(doc_a, "t", :text)
    doc_a = Yelixer.Types.Text.insert(doc_a, "t", 0, "hi")
    base = Encoding.encode_update(doc_a)

    # Client 2 applies base, deletes client 1's content, and encodes the
    # diff. The diff has NO new items — just a delete set targeting
    # client 1.
    doc_b = Yelixer.Doc.new(client_id: 2)
    {doc_b, _} = Yelixer.Doc.get_or_create_type(doc_b, "t", :text)
    {:ok, doc_b} = Encoding.apply_update(doc_b, base)
    doc_b = Yelixer.Types.Text.delete(doc_b, "t", 0, 2)

    base_sv = Yelixer.BlockStore.state_vector(doc_a.store)
    update = Encoding.encode_diff(doc_b, base_sv)

    assert {:ok, %{authorship: authorship, reference: reference}} =
             Encoding.update_client_ids_by_role(update)

    # No new items → no authorship. Delete set → reference [1].
    assert authorship == MapSet.new()
    assert reference == MapSet.new([1])
  end

  test "malformed update returns an error" do
    assert {:error, {:malformed_update, _}} =
             Encoding.update_client_ids_by_role(<<255, 255, 255>>)
  end

  test "empty update has empty role sets" do
    doc = Yelixer.Doc.new(client_id: 7)
    update = Encoding.encode_update(doc)

    assert {:ok, %{authorship: authorship, reference: reference}} =
             Encoding.update_client_ids_by_role(update)

    assert MapSet.size(authorship) == 0
    assert MapSet.size(reference) == 0
  end
end
