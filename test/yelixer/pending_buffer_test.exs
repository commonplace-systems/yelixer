defmodule Yelixer.PendingBufferTest do
  @moduledoc """
  Test pins for CX-cdyi (Yelixer H1: bounded pending buffer for
  out-of-order delivery). Mirrors the six pins in the design doc,
  docs/plans/2026-07-04-yelixer-h1-pending-buffer.md §6
  (commonplace-plan repo).

  The defect being closed: `retry_pending/3`'s old no-progress branch
  pushed un-integratable items into the store WITHOUT sequence
  integration and let the derived state vector advance past them.
  Since the SV is derived from the store, that meant orphans could
  never be re-requested, and two replicas that received the same
  content in different orders emitted different bytes.
  """

  use ExUnit.Case, async: false

  alias Yelixer.{Doc, Encoding, BlockStore, Types.Text}

  defp new_text_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc
  end

  describe "out-of-order convergence (pin 1)" do
    test "applying {B then A} vs {A then B} yields byte-identical encodes and SVs" do
      # Peer builds "A" then "B" (B anchored right after A) as two
      # separate wire updates.
      peer = new_text_doc(1)
      peer = Text.insert(peer, "text", 0, "A")
      update_a = Encoding.encode_update(peer)
      sv_after_a = BlockStore.state_vector(peer.store)

      peer = Text.insert(peer, "text", 1, "B")
      update_b = Encoding.encode_diff(peer, sv_after_a)

      # Order X: B arrives before A.
      doc_x = new_text_doc(2)
      {:ok, doc_x} = Encoding.apply_update(doc_x, update_b)
      {:ok, doc_x} = Encoding.apply_update(doc_x, update_a)

      # Order Y: A arrives before B (the well-behaved order).
      doc_y = new_text_doc(3)
      {:ok, doc_y} = Encoding.apply_update(doc_y, update_a)
      {:ok, doc_y} = Encoding.apply_update(doc_y, update_b)

      assert Text.to_string(doc_x, "text") == "AB"
      assert Text.to_string(doc_y, "text") == "AB"

      assert Encoding.encode_update(doc_x) == Encoding.encode_update(doc_y)
      assert BlockStore.state_vector(doc_x.store) == BlockStore.state_vector(doc_y.store)

      assert Doc.pending_info(doc_x) == %{count: 0, bytes: 0}
      assert Doc.pending_info(doc_y) == %{count: 0, bytes: 0}
    end
  end

  describe "re-request hole closed (pin 2)" do
    test "SV does not cover an item whose dependency is missing, and catch-up converges" do
      peer = new_text_doc(1)
      peer = Text.insert(peer, "text", 0, "A")
      sv_after_a = BlockStore.state_vector(peer.store)

      peer = Text.insert(peer, "text", 1, "B")
      update_b = Encoding.encode_diff(peer, sv_after_a)

      fresh = new_text_doc(2)
      {:ok, fresh} = Encoding.apply_update(fresh, update_b)

      # B never integrated (its origin, A, is missing) — the SV must
      # NOT cover client 1 at all. Under the old defect, B would have
      # been pushed raw and the SV would incorrectly claim client 1's
      # clock 1 as "seen."
      our_sv = BlockStore.state_vector(fresh.store)
      assert Yelixer.StateVector.get(our_sv, 1) == 0

      assert Doc.pending_info(fresh) == %{count: 1, bytes: byte_size(update_b)}
      assert Text.to_string(fresh, "text") == ""

      # A peer with the complete doc diffs against our (honest) SV and
      # sends everything we're missing — both A and B.
      catchup = Encoding.encode_diff(peer, our_sv)
      {:ok, fresh} = Encoding.apply_update(fresh, catchup)

      assert Doc.pending_info(fresh) == %{count: 0, bytes: 0}
      assert Text.to_string(fresh, "text") == "AB"

      ordered = new_text_doc(4)
      {:ok, ordered} = Encoding.apply_update(ordered, Encoding.encode_update(peer))
      assert Encoding.encode_update(fresh) == Encoding.encode_update(ordered)
    end
  end

  describe "delete-before-item (pin 3)" do
    test "an item whose delete arrived first is tombstoned, not resurrected" do
      peer = new_text_doc(1)
      peer = Text.insert(peer, "text", 0, "A")
      update_a = Encoding.encode_update(peer)
      sv_after_a = BlockStore.state_vector(peer.store)

      peer = Text.insert(peer, "text", 1, "B")
      sv_after_b = BlockStore.state_vector(peer.store)
      update_item_b = Encoding.encode_diff(peer, sv_after_a)

      peer = Text.delete(peer, "text", 1, 1)
      # Nothing new to insert past sv_after_b — this update carries
      # only the delete-set entry for B's clock, no items.
      update_delete_only = Encoding.encode_diff(peer, sv_after_b)

      # Deliver the delete before B's own insertion ever arrives.
      fresh = new_text_doc(2)
      {:ok, fresh} = Encoding.apply_update(fresh, update_delete_only)
      {:ok, fresh} = Encoding.apply_update(fresh, update_a)
      {:ok, fresh} = Encoding.apply_update(fresh, update_item_b)

      # B must be tombstoned, not resurrected, once it integrates.
      assert Text.to_string(fresh, "text") == "A"

      ordered = new_text_doc(3)
      {:ok, ordered} = Encoding.apply_update(ordered, update_a)
      {:ok, ordered} = Encoding.apply_update(ordered, update_item_b)
      {:ok, ordered} = Encoding.apply_update(ordered, update_delete_only)

      assert Text.to_string(ordered, "text") == "A"
      assert Encoding.encode_update(fresh) == Encoding.encode_update(ordered)
    end
  end

  describe "bounded overflow (pin 4)" do
    setup do
      original = Application.get_env(:yelixer, :max_pending_bytes)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:yelixer, :max_pending_bytes)
          val -> Application.put_env(:yelixer, :max_pending_bytes, val)
        end
      end)

      :ok
    end

    test "flooding past the cap rejects the apply without touching the doc or existing pending" do
      peer = new_text_doc(1)
      peer = Text.insert(peer, "text", 0, "A")
      update_a = Encoding.encode_update(peer)
      sv_after_a = BlockStore.state_vector(peer.store)

      peer = Text.insert(peer, "text", 1, "B")
      update_b = Encoding.encode_diff(peer, sv_after_a)

      fresh = new_text_doc(2)
      {:ok, fresh} = Encoding.apply_update(fresh, update_b)
      pending_before = Doc.pending_info(fresh)
      assert pending_before.count == 1

      # Now shrink the cap so a second un-integratable, larger blob
      # can't fit.
      Application.put_env(:yelixer, :max_pending_bytes, 4)

      peer2 = new_text_doc(5)
      peer2 = Text.insert(peer2, "text", 0, "X")
      sv_after_x = BlockStore.state_vector(peer2.store)
      peer2 = Text.insert(peer2, "text", 1, "flood-flood-flood-flood")
      oversized_orphan = Encoding.encode_diff(peer2, sv_after_x)

      assert Encoding.apply_update(fresh, oversized_orphan) == {:error, :pending_overflow}

      # Doc is untouched: same pending contents as before the rejected apply.
      assert Doc.pending_info(fresh) == pending_before
      assert Text.to_string(fresh, "text") == ""

      # Restore a generous cap and prove the earlier blob still resolves.
      Application.put_env(:yelixer, :max_pending_bytes, 10_485_760)
      {:ok, fresh} = Encoding.apply_update(fresh, update_a)

      assert Doc.pending_info(fresh) == %{count: 0, bytes: 0}
      assert Text.to_string(fresh, "text") == "AB"
    end
  end

  describe "shuffled-oracle (pin 5)" do
    test "every permutation of three dependent updates converges to the same bytes" do
      peer = new_text_doc(1)
      peer = Text.insert(peer, "text", 0, "A")
      sv1 = BlockStore.state_vector(peer.store)

      peer = Text.insert(peer, "text", 1, "B")
      sv2 = BlockStore.state_vector(peer.store)

      peer = Text.insert(peer, "text", 2, "C")

      update_a = Encoding.encode_diff(peer, Yelixer.StateVector.new())
      update_b = Encoding.encode_diff(peer, sv1)
      update_c = Encoding.encode_diff(peer, sv2)

      updates = [update_a, update_b, update_c]

      reference =
        Enum.reduce(updates, new_text_doc(100), fn u, doc ->
          {:ok, doc} = Encoding.apply_update(doc, u)
          doc
        end)

      reference_bytes = Encoding.encode_update(reference)
      reference_sv = BlockStore.state_vector(reference.store)

      updates
      |> permutations()
      |> Enum.with_index()
      |> Enum.each(fn {order, idx} ->
        doc =
          Enum.reduce(order, new_text_doc(200 + idx), fn u, doc ->
            {:ok, doc} = Encoding.apply_update(doc, u)
            doc
          end)

        assert Doc.pending_info(doc) == %{count: 0, bytes: 0}
        assert Encoding.encode_update(doc) == reference_bytes
        assert BlockStore.state_vector(doc.store) == reference_sv
        assert Text.to_string(doc, "text") == "ABC"
      end)
    end

    defp permutations([]), do: [[]]

    defp permutations(list) do
      for elem <- list, rest <- permutations(list -- [elem]), do: [elem | rest]
    end
  end

  describe "replay regression (pin 6)" do
    test "commit-replay simulation: ordered, diff-against-previous delivery keeps pending empty" do
      author = new_text_doc(1)

      {author, diffs, _final_sv} =
        Enum.reduce(1..8, {author, [], BlockStore.state_vector(author.store)}, fn i,
                                                                                    {author, diffs, sv} ->
          char = <<?a + rem(i, 26)>>
          pos = String.length(Text.to_string(author, "text"))
          author = Text.insert(author, "text", pos, char)
          diff = Encoding.encode_diff(author, sv)
          new_sv = BlockStore.state_vector(author.store)
          {author, [diff | diffs], new_sv}
        end)

      diffs = Enum.reverse(diffs)

      replayed =
        Enum.reduce(diffs, new_text_doc(2), fn diff, doc ->
          {:ok, doc} = Encoding.apply_update(doc, diff)
          assert Doc.pending_info(doc) == %{count: 0, bytes: 0}
          doc
        end)

      assert Text.to_string(replayed, "text") == Text.to_string(author, "text")
      assert Encoding.encode_update(replayed) == Encoding.encode_update(author)
    end
  end
end
