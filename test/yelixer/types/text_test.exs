defmodule Yelixer.Types.TextTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.Text}

  defp new_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc
  end

  test "insert and read text" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")
    assert Text.to_string(doc, "text") == "hello"
  end

  test "insert at end" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")
    doc = Text.insert(doc, "text", 5, " world")
    assert Text.to_string(doc, "text") == "hello world"
  end

  test "insert at beginning" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "world")
    doc = Text.insert(doc, "text", 0, "hello ")
    assert Text.to_string(doc, "text") == "hello world"
  end

  test "insert in middle" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hllo")
    doc = Text.insert(doc, "text", 1, "e")
    assert Text.to_string(doc, "text") == "hello"
  end

  test "delete text range" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello world")
    doc = Text.delete(doc, "text", 5, 6)
    assert Text.to_string(doc, "text") == "hello"
  end

  test "delete from beginning" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")
    doc = Text.delete(doc, "text", 0, 2)
    assert Text.to_string(doc, "text") == "llo"
  end

  test "length" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")
    assert Text.length(doc, "text") == 5
  end

  test "length after delete" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")
    doc = Text.delete(doc, "text", 0, 2)
    assert Text.length(doc, "text") == 3
  end

  test "multiple inserts build up text" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "a")
    doc = Text.insert(doc, "text", 1, "b")
    doc = Text.insert(doc, "text", 2, "c")
    assert Text.to_string(doc, "text") == "abc"
  end

  test "empty text" do
    doc = new_doc(1)
    assert Text.to_string(doc, "text") == ""
    assert Text.length(doc, "text") == 0
  end

  # CX-gq7a: insert/4's moduledoc claims empty text is a no-op, but the
  # only clause guarded `byte_size(text) > 0` — insert(doc, name, idx, "")
  # raised FunctionClauseError instead. This was the crash locus for the
  # MUD @verb editor's empty/'.' save (see
  # Commonplace.MUD.PlayerSession's save_verb / VerbSource.save_verb).
  test "insert with empty text is a no-op (moduledoc contract)" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")

    assert Text.insert(doc, "text", 0, "") == doc
    assert Text.to_string(doc, "text") == "hello"
  end

  test "multi-char insert creates single item" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")
    # Should be a single item, not 5 separate ones
    seq = Yelixer.BlockStore.get_sequence(doc.store, "text")
    assert length(seq) == 1
    assert hd(seq).content == {:string, "hello"}
  end

  test "mid-item insert splits and creates three items" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hllo")
    doc = Text.insert(doc, "text", 1, "e")
    assert Text.to_string(doc, "text") == "hello"
    seq = Yelixer.BlockStore.get_sequence(doc.store, "text")
    # "h" + "e" + "llo" = 3 items
    assert length(seq) == 3
  end

  test "mid-item delete splits correctly" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "abcde")
    doc = Text.delete(doc, "text", 1, 3)
    assert Text.to_string(doc, "text") == "ae"
  end

  describe "rehydrate → modify → re-encode round-trip (CX-2sv regression)" do
    alias Yelixer.Encoding

    # This exercises the save→reload→modify pattern the MCP write tool hits
    # constantly: the sync agent stores a doc, a later write rehydrates it
    # from the binary update, mutates it, re-encodes, and reads it back.
    # A bug in Item.split caused the leftmost piece of a deleted-then-split
    # sequence to lose its parent linkage, so to_string returned "".

    defp roundtrip(doc) do
      bin = Encoding.encode_update(doc)
      {:ok, fresh} = Encoding.apply_update(Yelixer.Doc.new(), bin)
      fresh
    end

    test "insert → rehydrate → delete-from-start → rehydrate" do
      doc = new_doc(1)
      doc = Text.insert(doc, "text", 0, "hello world")

      reloaded = roundtrip(doc)
      assert Text.to_string(reloaded, "text") == "hello world"

      # Delete the first char — the leftmost split piece is what broke before.
      mutated = Text.delete(reloaded, "text", 0, 1)
      assert Text.to_string(mutated, "text") == "ello world"

      reloaded2 = roundtrip(mutated)
      assert Text.to_string(reloaded2, "text") == "ello world"
    end

    test "insert → rehydrate → delete-all-then-insert → rehydrate" do
      doc = new_doc(1)
      doc = Text.insert(doc, "text", 0, "hello world")

      reloaded = roundtrip(doc)

      # Simulate apply_diff's "replace whole content" pattern:
      # delete the 11 chars, then insert new content at position 0.
      mutated = Text.delete(reloaded, "text", 0, 11)
      mutated = Text.insert(mutated, "text", 0, "goodbye earth")

      assert Text.to_string(mutated, "text") == "goodbye earth"

      reloaded2 = roundtrip(mutated)
      assert Text.to_string(reloaded2, "text") == "goodbye earth"
    end

    test "many interleaved delete+insert after rehydrate" do
      doc = new_doc(1)
      doc = Text.insert(doc, "text", 0, "the quick brown fox")
      reloaded = roundtrip(doc)

      # Smart-merge style: several small edits scattered through the doc.
      # The goal is survival across a re-encode; exact spacing doesn't matter.
      mutated = Text.delete(reloaded, "text", 4, 5)
      mutated = Text.insert(mutated, "text", 4, "slow")
      mutated = Text.delete(mutated, "text", 10, 5)
      mutated = Text.insert(mutated, "text", 10, "red")

      live = Text.to_string(mutated, "text")
      reloaded2 = roundtrip(mutated)
      assert Text.to_string(reloaded2, "text") == live
    end

    test "many rehydrate cycles preserve content" do
      doc = new_doc(1)
      doc = Text.insert(doc, "text", 0, "start")

      # 5 cycles of rehydrate+mutate; each cycle appends a word at the end
      # and re-encodes. After the final cycle the text should still be intact.
      final =
        Enum.reduce(1..5, doc, fn i, acc ->
          acc = roundtrip(acc)
          word = " word#{i}"
          pos = String.length(Text.to_string(acc, "text"))
          Text.insert(acc, "text", pos, word)
        end)

      reloaded = roundtrip(final)
      assert Text.to_string(reloaded, "text") == "start word1 word2 word3 word4 word5"
    end
  end
end
