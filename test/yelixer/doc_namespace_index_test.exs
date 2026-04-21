defmodule Yelixer.DocNamespaceIndexTest do
  @moduledoc """
  CX-4l7u (CX-ch5 follow-up): Yelixer.Doc tracks which namespace
  introduced each clientID. Populated via the namespace-aware
  apply_update_in_namespace/3 variant; queried via
  Yelixer.Doc.clientID_in_namespace?/3.

  This is a Doc-level cache that lets callers answer the question
  "is this clientID a member of namespace N?" at O(1) without
  walking the commit chain. The commit-chain-walk validator
  (Commonplace.Store.Namespace.validate_commit_from_db/2) remains
  the authoritative source; this cache is for performance-sensitive
  read paths that already hold a Doc.
  """
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  @ns_a :crypto.hash(:sha256, "ns-a")
  @ns_b :crypto.hash(:sha256, "ns-b")

  describe "struct + defaults" do
    test "new doc has empty client_namespaces map" do
      doc = Doc.new(client_id: 1)
      assert doc.client_namespaces == %{}
    end

    test "clientID_in_namespace? on fresh doc is false for any pair" do
      doc = Doc.new(client_id: 1)
      refute Doc.clientID_in_namespace?(doc, 42, @ns_a)
      refute Doc.clientID_in_namespace?(doc, 1, @ns_a)
    end
  end

  describe "apply_update_in_namespace/3 populates the index" do
    test "records each NEW clientID against the declared namespace" do
      source = build_text_doc(7, "hello")
      update = Encoding.encode_update(source)

      target = Doc.new(client_id: 99)
      {:ok, target} = Encoding.apply_update_in_namespace(target, update, @ns_a)

      assert Doc.clientID_in_namespace?(target, 7, @ns_a)
      refute Doc.clientID_in_namespace?(target, 7, @ns_b)
    end

    test "first-writer-wins — repeat apply in same namespace is idempotent" do
      source = build_text_doc(11, "x")
      u1 = Encoding.encode_update(source)
      source2 = build_text_doc_extend(source, "y")
      u2 = Encoding.encode_update(source2)

      target = Doc.new(client_id: 99)
      {:ok, target} = Encoding.apply_update_in_namespace(target, u1, @ns_a)
      {:ok, target} = Encoding.apply_update_in_namespace(target, u2, @ns_a)

      assert Doc.clientID_in_namespace?(target, 11, @ns_a)
      # Still exactly one entry — no duplicates.
      assert Map.get(target.client_namespaces, 11) == @ns_a
    end

    test "clientID introduced under ns_a is NOT a member of ns_b" do
      source = build_text_doc(17, "a")
      update = Encoding.encode_update(source)

      target = Doc.new(client_id: 99)
      {:ok, target} = Encoding.apply_update_in_namespace(target, update, @ns_a)

      assert Doc.clientID_in_namespace?(target, 17, @ns_a)
      refute Doc.clientID_in_namespace?(target, 17, @ns_b)
    end

    test "a clientID already recorded under ns_a keeps that membership even when re-seen under ns_b" do
      # Semantics: the first namespace that introduced a clientID is the
      # authoritative one. A later re-observation under a different namespace
      # doesn't overwrite — that would erase the original provenance.
      source = build_text_doc(23, "first")
      u1 = Encoding.encode_update(source)

      target = Doc.new(client_id: 99)
      {:ok, target} = Encoding.apply_update_in_namespace(target, u1, @ns_a)
      {:ok, target} = Encoding.apply_update_in_namespace(target, u1, @ns_b)

      assert Doc.clientID_in_namespace?(target, 23, @ns_a)
      refute Doc.clientID_in_namespace?(target, 23, @ns_b)
    end

    test "multiple clientIDs in a single update each get recorded" do
      s1 = build_text_doc(5, "abc")
      u1 = Encoding.encode_update(s1)

      target = Doc.new(client_id: 100)
      {:ok, target} = Encoding.apply_update_in_namespace(target, u1, @ns_a)

      s2 = build_text_doc(6, "xyz")
      u2 = Encoding.encode_update(s2)

      {:ok, target} = Encoding.apply_update_in_namespace(target, u2, @ns_a)

      assert Doc.clientID_in_namespace?(target, 5, @ns_a)
      assert Doc.clientID_in_namespace?(target, 6, @ns_a)
    end
  end

  describe "plain apply_update/2 does NOT touch the index" do
    test "clientIDs from plain apply_update are not recorded" do
      source = build_text_doc(31, "noindex")
      update = Encoding.encode_update(source)

      target = Doc.new(client_id: 99)
      {:ok, target} = Encoding.apply_update(target, update)

      refute Doc.clientID_in_namespace?(target, 31, @ns_a)
      assert target.client_namespaces == %{}
    end
  end

  # -- helpers --

  defp build_text_doc(client_id, text) do
    d = Doc.new(client_id: client_id)
    {d, _} = Doc.get_or_create_type(d, "t", :text)
    Text.insert(d, "t", 0, text)
  end

  defp build_text_doc_extend(doc, text), do: Text.insert(doc, "t", 0, text)
end
