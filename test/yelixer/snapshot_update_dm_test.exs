defmodule Yelixer.SnapshotUpdateDmTest do
  @moduledoc """
  CX-umz: `Yelixer.Doc.snapshot_update/1` returns `{update_bytes,
  derivation_map}` where `derivation_map` maps each new item id
  `{client, clock}` to the source item id it re-authors.

  The inner DM shape is `%{new_id => old_id}`. The caller (Commonplace
  Snapshotter) wraps this under a source_snapshot_hash outer key when
  assembling commit metadata.
  """
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  describe "snapshot_update/1 returns {bytes, dm}" do
    test "empty doc — empty dm, still a tuple" do
      doc = Doc.new(client_id: 1)
      assert {bytes, dm} = Doc.snapshot_update(doc)
      assert is_binary(bytes)
      assert dm == %{}
    end

    test "text doc — dm maps new text item to source text item" do
      doc = Doc.new(client_id: 7)
      {doc, _} = Doc.get_or_create_type(doc, "greeting", :text)
      source = Text.insert(doc, "greeting", 0, "hello")

      assert {bytes, dm} = Doc.snapshot_update(source)
      assert is_binary(bytes)
      assert map_size(dm) > 0
      # Every key and value must be a {client, clock} tuple.
      for {new_id, old_id} <- dm do
        assert match?({c, k} when is_integer(c) and is_integer(k), new_id)
        assert match?({c, k} when is_integer(c) and is_integer(k), old_id)
      end
    end

    test "byte-deterministic — same source → same {bytes, dm} across peers" do
      # Two logically-identical docs authored by different peers converge
      # after pairwise update exchange. snapshot_update on each must
      # produce byte-identical output — this is the load-bearing property
      # CX-umz asks for (enables CID dedup of concurrent snapshots).
      src_a =
        (fn ->
           d = Doc.new(client_id: 10)
           {d, _} = Doc.get_or_create_type(d, "t", :text)
           Text.insert(d, "t", 0, "xyz")
         end).()

      src_b =
        (fn ->
           d = Doc.new(client_id: 20)
           {d, _} = Doc.get_or_create_type(d, "t", :text)
           Text.insert(d, "t", 0, "xyz")
         end).()

      u_a = Encoding.encode_update(src_a)
      u_b = Encoding.encode_update(src_b)
      {:ok, converged_a} = Encoding.apply_update(src_a, u_b)
      {:ok, converged_b} = Encoding.apply_update(src_b, u_a)

      # Before running snapshot_update, normalize client_id the same way
      # Snapshotter does (min client in the store). This is the contract
      # — snapshot_update is deterministic given identical source state.
      a_min = converged_a.store.clients |> Map.keys() |> Enum.min()
      b_min = converged_b.store.clients |> Map.keys() |> Enum.min()
      a_norm = %{converged_a | client_id: a_min}
      b_norm = %{converged_b | client_id: b_min}

      {bytes_a, dm_a} = Doc.snapshot_update(a_norm)
      {bytes_b, dm_b} = Doc.snapshot_update(b_norm)

      assert bytes_a == bytes_b
      assert dm_a == dm_b
    end

    test "round-trip — applying bytes to a fresh doc recovers the source's observable content" do
      doc = Doc.new(client_id: 3)
      {doc, _} = Doc.get_or_create_type(doc, "t", :text)
      source = Text.insert(doc, "t", 0, "round-trip test")

      {bytes, _dm} = Doc.snapshot_update(source)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), bytes)
      assert Text.to_string(rebuilt, "t") == "round-trip test"
    end
  end
end
