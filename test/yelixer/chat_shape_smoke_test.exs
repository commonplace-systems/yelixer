defmodule Yelixer.ChatShapeSmokeTest do
  @moduledoc """
  CX-e2k8 (S1 of CX-p2qp chat-room umbrella).

  Substrate-prereq smoke test for the (β-revised) chat-room document
  shape. The chat spec (commonplace-plan/docs/chat-room.md a5f3f5e)
  picks JSON-encoded YArray entries + a top-level sibling YMap with
  flat composite keys, specifically to avoid the
  `Doc.snapshot_update/1` constraint that "sub-types nested inside
  maps/arrays are not yet replayed structurally" — Scheduler hit that
  wall and chose JSON-encoded values; chat takes the same route.

  These tests verify the (β-revised) shape DOES survive snapshot +
  apply_update roundtrip for the operations chat performs:

  - `_messages`: top-level YArray of strings (JSON entries), with
    initial inserts AND post-snapshot append-only growth
  - `_reactions`: top-level YMap with `"{message_id}:{emoji}:{signer_id}"`
    string keys → primitive `true` values, with set + delete (toggle)
    semantics

  A red result here means the (β-revised) shape itself is broken under
  Yelixer compaction and chat is gated on a substrate fix (followup α
  bead). Green unblocks D1.
  """
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Array, YMap}

  describe "_messages shape: YArray of JSON-encoded strings" do
    test "snapshot + apply roundtrip preserves observable JSON entries" do
      messages = [
        Jason.encode!(%{
          "id" => "m1",
          "ts" => "2026-04-25T19:00:00Z",
          "author_signer_id" => "alice",
          "author_path" => "alice.usr",
          "text" => "hello"
        }),
        Jason.encode!(%{
          "id" => "m2",
          "ts" => "2026-04-25T19:00:01Z",
          "author_signer_id" => "bob",
          "author_path" => "bob.usr",
          "text" => "hi back",
          "reply_to" => "m1"
        })
      ]

      doc = Doc.new(client_id: 11)
      {doc, _} = Doc.get_or_create_type(doc, "_messages", :array)
      doc = Array.push(doc, "_messages", messages)

      assert Array.to_list(doc, "_messages") == messages

      {snapshot_bin, _dm} = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), snapshot_bin)

      assert Array.to_list(rebuilt, "_messages") == messages,
             "snapshot+apply must preserve every JSON entry verbatim"
    end

    test "snapshot then post-snapshot append (edit-entry) preserves both pre- and post-snapshot entries" do
      original =
        Jason.encode!(%{
          "id" => "m1",
          "ts" => "2026-04-25T19:00:00Z",
          "author_signer_id" => "alice",
          "author_path" => "alice.usr",
          "text" => "v1"
        })

      doc = Doc.new(client_id: 22)
      {doc, _} = Doc.get_or_create_type(doc, "_messages", :array)
      doc = Array.push(doc, "_messages", [original])

      # Snapshot the doc — simulates CX-u7p compaction landing.
      {snapshot_bin, _dm} = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(client_id: 22), snapshot_bin)

      # Append an edit-entry (chat's edit_message handler does this).
      edit =
        Jason.encode!(%{
          "id" => "m1-edit-a",
          "ts" => "2026-04-25T19:00:05Z",
          "author_signer_id" => "alice",
          "author_path" => "alice.usr",
          "text" => "v2",
          "edit_of" => "m1"
        })

      rebuilt = Array.push(rebuilt, "_messages", [edit])

      assert Array.to_list(rebuilt, "_messages") == [original, edit],
             "post-snapshot appends must compose with snapshot-replayed state"

      # And the result must itself be snapshot-roundtripable.
      {bin2, _dm2} = Doc.snapshot_update(rebuilt)
      {:ok, doc3} = Encoding.apply_update(Doc.new(), bin2)

      assert Array.to_list(doc3, "_messages") == [original, edit]
    end

    test "snapshot preserves a tombstone-entry alongside the original" do
      original =
        Jason.encode!(%{
          "id" => "m1",
          "ts" => "2026-04-25T19:00:00Z",
          "author_signer_id" => "alice",
          "text" => "secret"
        })

      tombstone =
        Jason.encode!(%{
          "id" => "m1-tomb",
          "ts" => "2026-04-25T19:00:10Z",
          "author_signer_id" => "alice",
          "tombstone_of" => "m1"
        })

      doc = Doc.new(client_id: 33)
      {doc, _} = Doc.get_or_create_type(doc, "_messages", :array)
      doc = Array.push(doc, "_messages", [original, tombstone])

      {bin, _dm} = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), bin)

      assert Array.to_list(rebuilt, "_messages") == [original, tombstone]
    end
  end

  describe "_reactions shape: top-level YMap with flat composite keys" do
    test "snapshot + apply preserves all set keys and their primitive true values" do
      doc = Doc.new(client_id: 44)
      {doc, _} = Doc.get_or_create_type(doc, "_reactions", :map)

      keys = [
        "m1:thumbs_up:alice",
        "m1:thumbs_up:bob",
        "m1:heart:alice",
        "m2:thumbs_up:carol"
      ]

      doc = Enum.reduce(keys, doc, fn k, d -> YMap.set(d, "_reactions", k, true) end)

      Enum.each(keys, fn k ->
        assert YMap.get(doc, "_reactions", k) == true
      end)

      {bin, _dm} = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), bin)

      Enum.each(keys, fn k ->
        assert YMap.get(rebuilt, "_reactions", k) == true,
               "key #{k} must survive snapshot+apply roundtrip"
      end)

      # YMap.to_map round-trips the whole keyspace too.
      assert YMap.to_map(rebuilt, "_reactions") ==
               Map.new(keys, fn k -> {k, true} end)
    end

    test "snapshot preserves toggle-off (set then delete) — the deleted key must NOT reappear" do
      doc = Doc.new(client_id: 55)
      {doc, _} = Doc.get_or_create_type(doc, "_reactions", :map)

      doc = YMap.set(doc, "_reactions", "m1:fire:alice", true)
      doc = YMap.set(doc, "_reactions", "m1:fire:bob", true)

      # Toggle off alice's reaction.
      doc = YMap.delete(doc, "_reactions", "m1:fire:alice")

      assert YMap.get(doc, "_reactions", "m1:fire:alice") == nil
      assert YMap.get(doc, "_reactions", "m1:fire:bob") == true

      {bin, _dm} = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), bin)

      assert YMap.get(rebuilt, "_reactions", "m1:fire:alice") == nil,
             "deleted key must NOT reappear after snapshot+apply roundtrip"

      assert YMap.get(rebuilt, "_reactions", "m1:fire:bob") == true
    end

    test "snapshot then post-snapshot toggle (set + delete) composes cleanly" do
      doc = Doc.new(client_id: 66)
      {doc, _} = Doc.get_or_create_type(doc, "_reactions", :map)

      doc = YMap.set(doc, "_reactions", "m1:tada:alice", true)

      {bin, _dm} = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(client_id: 66), bin)

      # Post-snapshot toggle: bob reacts, alice un-reacts.
      rebuilt = YMap.set(rebuilt, "_reactions", "m1:tada:bob", true)
      rebuilt = YMap.delete(rebuilt, "_reactions", "m1:tada:alice")

      assert YMap.get(rebuilt, "_reactions", "m1:tada:alice") == nil
      assert YMap.get(rebuilt, "_reactions", "m1:tada:bob") == true
    end
  end

  describe "combined shape: _messages YArray and _reactions YMap living in the same doc-as-pair pattern" do
    # Note: in production _messages and _reactions are SEPARATE docs (different
    # UUIDs in the room dir's schema). This test bundles them into one Yelixer
    # doc just to confirm Yelixer doesn't have a "one-top-level-type-per-doc"
    # constraint that would surprise the action handlers.
    test "two top-level types coexist and both survive snapshot roundtrip" do
      doc = Doc.new(client_id: 77)
      {doc, _} = Doc.get_or_create_type(doc, "_messages", :array)
      {doc, _} = Doc.get_or_create_type(doc, "_reactions", :map)

      msg = Jason.encode!(%{"id" => "m1", "text" => "hi"})
      doc = Array.push(doc, "_messages", [msg])
      doc = YMap.set(doc, "_reactions", "m1:wave:alice", true)

      {bin, _dm} = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), bin)

      assert Array.to_list(rebuilt, "_messages") == [msg]
      assert YMap.get(rebuilt, "_reactions", "m1:wave:alice") == true
    end
  end
end
