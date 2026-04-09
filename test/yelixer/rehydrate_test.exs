defmodule Yelixer.RehydrateTest do
  @moduledoc """
  Targeted integration tests for the save→reload→modify pattern (CX-3hy).

  This is the gap that CX-2sv lived in: existing tests either run ops
  without an encoding round-trip in the middle, or decode a yrs-generated
  binary once without subsequent modification. The MCP write tool and
  the sync agent hit save→reload→modify constantly, and that path was
  producing corrupted commits for months before we noticed.

  Each test exercises the pattern in some variation:
    1. create Doc
    2. apply some ops (insert / delete / set / push / etc.)
    3. encode_update → binary
    4. decode into a fresh Doc
    5. apply more ops to the rehydrated doc
    6. encode again, decode into another fresh Doc
    7. assert the content matches the in-memory doc

  A bug in any of {split, encode, decode, integrate, remap} tends to
  break at least one of these — you can't re-encode a doc if decoding
  left it in a bad state, and you can't decode correctly if encoding
  dropped metadata.
  """
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Text, YMap, Array}

  defp new_text_doc(client_id \\ 1) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc
  end

  defp new_map_doc(client_id \\ 1) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "map", :map)
    doc
  end

  defp new_array_doc(client_id \\ 1) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "arr", :array)
    doc
  end

  # Save the doc (via encode_update) and reload it into a fresh Doc.
  # Keeps the same client_id so subsequent inserts don't collide with
  # the rehydrated state.
  defp roundtrip(%Doc{client_id: cid} = doc) do
    bin = Encoding.encode_update(doc)
    {:ok, fresh} = Encoding.apply_update(Doc.new(client_id: cid), bin)
    fresh
  end

  describe "text rehydrate-modify" do
    test "1. insert then rehydrate" do
      doc = new_text_doc() |> Text.insert("text", 0, "hello world")
      reloaded = roundtrip(doc)
      assert Text.to_string(reloaded, "text") == "hello world"
    end

    test "2. insert → rehydrate → delete first char" do
      doc = new_text_doc() |> Text.insert("text", 0, "hello world")
      reloaded = roundtrip(doc) |> Text.delete("text", 0, 1)
      assert Text.to_string(reloaded, "text") == "ello world"
      assert Text.to_string(roundtrip(reloaded), "text") == "ello world"
    end

    test "3. insert → rehydrate → delete middle chars" do
      doc = new_text_doc() |> Text.insert("text", 0, "hello world")
      reloaded = roundtrip(doc) |> Text.delete("text", 5, 6)
      assert Text.to_string(reloaded, "text") == "hello"
      assert Text.to_string(roundtrip(reloaded), "text") == "hello"
    end

    test "4. insert → rehydrate → delete last char" do
      doc = new_text_doc() |> Text.insert("text", 0, "hello world")
      reloaded = roundtrip(doc) |> Text.delete("text", 10, 1)
      assert Text.to_string(reloaded, "text") == "hello worl"
      assert Text.to_string(roundtrip(reloaded), "text") == "hello worl"
    end

    test "5. insert → rehydrate → delete all → insert new" do
      doc = new_text_doc() |> Text.insert("text", 0, "hello world")

      reloaded =
        roundtrip(doc)
        |> Text.delete("text", 0, 11)
        |> Text.insert("text", 0, "goodbye earth")

      assert Text.to_string(reloaded, "text") == "goodbye earth"
      assert Text.to_string(roundtrip(reloaded), "text") == "goodbye earth"
    end

    test "6. two rehydrate cycles with different ops each time" do
      doc = new_text_doc() |> Text.insert("text", 0, "AAA")

      d1 = roundtrip(doc) |> Text.insert("text", 3, "BBB")
      assert Text.to_string(d1, "text") == "AAABBB"

      d2 = roundtrip(d1) |> Text.delete("text", 0, 3)
      assert Text.to_string(d2, "text") == "BBB"

      d3 = roundtrip(d2) |> Text.insert("text", 0, "CCC")
      assert Text.to_string(d3, "text") == "CCCBBB"

      assert Text.to_string(roundtrip(d3), "text") == "CCCBBB"
    end

    test "7. 50-cycle rehydrate chain appending words" do
      initial = new_text_doc() |> Text.insert("text", 0, "start")

      final =
        Enum.reduce(1..50, initial, fn i, acc ->
          acc = roundtrip(acc)
          pos = String.length(Text.to_string(acc, "text"))
          Text.insert(acc, "text", pos, " #{i}")
        end)

      expected = "start" <> (1..50 |> Enum.map(&" #{&1}") |> Enum.join())
      assert Text.to_string(final, "text") == expected
      assert Text.to_string(roundtrip(final), "text") == expected
    end

    test "8. concurrent clients: each writes, rehydrates, reads the merged result" do
      # Two clients insert independently, then each receives the other's
      # update and applies it on top of its rehydrated state.
      a = new_text_doc(10) |> Text.insert("text", 0, "AAA")
      b = new_text_doc(20) |> Text.insert("text", 0, "BBB")

      a_bin = Encoding.encode_update(a)
      b_bin = Encoding.encode_update(b)

      {:ok, a_merged} = Encoding.apply_update(roundtrip(a), b_bin)
      {:ok, b_merged} = Encoding.apply_update(roundtrip(b), a_bin)

      # Both merged docs converge to the same content.
      assert Text.to_string(a_merged, "text") == Text.to_string(b_merged, "text")

      # And after another rehydrate, the content is preserved.
      assert Text.to_string(roundtrip(a_merged), "text") ==
               Text.to_string(a_merged, "text")
    end

    test "9. large doc (1KB) survives rehydrate-modify-rehydrate" do
      content = String.duplicate("abcdefghij", 100)
      doc = new_text_doc() |> Text.insert("text", 0, content)

      # Delete a chunk from the middle, insert a replacement.
      mutated =
        roundtrip(doc)
        |> Text.delete("text", 500, 100)
        |> Text.insert("text", 500, "XXXXXXXXXX")

      live = Text.to_string(mutated, "text")
      assert String.length(live) == 910
      assert Text.to_string(roundtrip(mutated), "text") == live
    end
  end

  describe "map rehydrate-modify" do
    test "10. set keys → rehydrate → set more keys" do
      doc =
        new_map_doc()
        |> YMap.set("map", "a", "1")
        |> YMap.set("map", "b", "2")

      reloaded =
        roundtrip(doc)
        |> YMap.set("map", "c", "3")

      assert YMap.to_map(reloaded, "map") == %{"a" => "1", "b" => "2", "c" => "3"}

      final = roundtrip(reloaded)
      assert YMap.to_map(final, "map") == %{"a" => "1", "b" => "2", "c" => "3"}
    end

    test "11. set key → rehydrate → overwrite same key" do
      doc = new_map_doc() |> YMap.set("map", "k", "v1")

      reloaded = roundtrip(doc) |> YMap.set("map", "k", "v2")
      assert YMap.to_map(reloaded, "map") == %{"k" => "v2"}

      final = roundtrip(reloaded)
      assert YMap.to_map(final, "map") == %{"k" => "v2"}
    end

    test "12. set keys → rehydrate → delete one" do
      doc =
        new_map_doc()
        |> YMap.set("map", "keep", "yes")
        |> YMap.set("map", "drop", "no")

      reloaded = roundtrip(doc) |> YMap.delete("map", "drop")
      assert YMap.to_map(reloaded, "map") == %{"keep" => "yes"}

      final = roundtrip(reloaded)
      assert YMap.to_map(final, "map") == %{"keep" => "yes"}
    end
  end

  describe "array rehydrate-modify" do
    test "13. push items → rehydrate → push more" do
      doc = new_array_doc() |> Array.push("arr", [1, 2, 3])

      reloaded = roundtrip(doc) |> Array.push("arr", [4, 5])
      assert Array.to_list(reloaded, "arr") == [1, 2, 3, 4, 5]
      assert Array.to_list(roundtrip(reloaded), "arr") == [1, 2, 3, 4, 5]
    end

    test "14. push → rehydrate → insert at beginning" do
      doc = new_array_doc() |> Array.push("arr", [2, 3])

      reloaded = roundtrip(doc) |> Array.insert("arr", 0, [1])
      assert Array.to_list(reloaded, "arr") == [1, 2, 3]
      assert Array.to_list(roundtrip(reloaded), "arr") == [1, 2, 3]
    end

    test "15. push → rehydrate → delete from middle" do
      doc = new_array_doc() |> Array.push("arr", [1, 2, 3, 4, 5])

      reloaded = roundtrip(doc) |> Array.delete("arr", 1, 3)
      assert Array.to_list(reloaded, "arr") == [1, 5]
      assert Array.to_list(roundtrip(reloaded), "arr") == [1, 5]
    end

    test "16. push → rehydrate → delete first → insert replacement" do
      doc = new_array_doc() |> Array.push("arr", ["a", "b", "c"])

      reloaded =
        roundtrip(doc)
        |> Array.delete("arr", 0, 1)
        |> Array.insert("arr", 0, ["A"])

      assert Array.to_list(reloaded, "arr") == ["A", "b", "c"]
      assert Array.to_list(roundtrip(reloaded), "arr") == ["A", "b", "c"]
    end
  end

  describe "cross-sequence rehydrate-modify (CX-2sv regression)" do
    # These are the tests that specifically reproduce the CX-2sv bug class:
    # a single client with items in TWO sequences (envelope-style) that
    # undergoes a delete-then-modify round-trip. Without the Item.split
    # and remap_gc_origin fixes, the text items' parents would be
    # remapped to point into the map sequence, corrupting the decode.

    defp new_envelope_doc(client_id \\ 1) do
      # Mimics Commonplace.Document.ContentType.create/3's envelope:
      # a "root" YMap with metadata keys, plus a separate "content" Text.
      # The "root" entries are inserted FIRST, so they get the low clocks.
      doc = Doc.new(client_id: client_id)
      {doc, _} = Doc.get_or_create_type(doc, "root", :map)
      doc = YMap.set(doc, "root", "_type", "text")
      doc = YMap.set(doc, "root", "_name", "test.txt")
      {doc, _} = Doc.get_or_create_type(doc, "content", :text)
      doc
    end

    test "17. envelope + text: insert → rehydrate → replace content" do
      doc = new_envelope_doc() |> Text.insert("content", 0, "hello world")

      reloaded = roundtrip(doc)
      assert Text.to_string(reloaded, "content") == "hello world"
      assert YMap.to_map(reloaded, "root") == %{"_type" => "text", "_name" => "test.txt"}

      # Replace the content with a diff-style delete-all + insert-new.
      mutated =
        reloaded
        |> Text.delete("content", 0, 11)
        |> Text.insert("content", 0, "replaced text")

      assert Text.to_string(mutated, "content") == "replaced text"

      final = roundtrip(mutated)
      assert Text.to_string(final, "content") == "replaced text"
      assert YMap.to_map(final, "root") == %{"_type" => "text", "_name" => "test.txt"}
    end

    test "18. envelope + text: insert → rehydrate → delete-from-start" do
      doc = new_envelope_doc() |> Text.insert("content", 0, "hello")

      reloaded = roundtrip(doc) |> Text.delete("content", 0, 1)
      assert Text.to_string(reloaded, "content") == "ello"

      final = roundtrip(reloaded)
      assert Text.to_string(final, "content") == "ello"
    end

    test "19. envelope + text: 5-cycle append with rehydrate each iteration" do
      doc = new_envelope_doc() |> Text.insert("content", 0, "start")

      final =
        Enum.reduce(1..5, doc, fn i, acc ->
          acc = roundtrip(acc)
          pos = String.length(Text.to_string(acc, "content"))
          Text.insert(acc, "content", pos, " #{i}")
        end)

      assert Text.to_string(final, "content") == "start 1 2 3 4 5"
      assert Text.to_string(roundtrip(final), "content") == "start 1 2 3 4 5"
      assert YMap.to_map(roundtrip(final), "root") == %{
               "_type" => "text",
               "_name" => "test.txt"
             }
    end

    test "20. envelope + text: interleaved edits after rehydrate" do
      doc = new_envelope_doc() |> Text.insert("content", 0, "the quick brown fox")

      mutated =
        roundtrip(doc)
        |> Text.delete("content", 4, 5)
        |> Text.insert("content", 4, "slow")
        |> Text.delete("content", 10, 5)
        |> Text.insert("content", 10, "red")

      live = Text.to_string(mutated, "content")
      assert Text.to_string(roundtrip(mutated), "content") == live
    end

    test "21. envelope + array: rehydrate + push + delete" do
      doc =
        Doc.new(client_id: 1)
        |> then(fn d -> elem(Doc.get_or_create_type(d, "root", :map), 0) end)
        |> YMap.set("root", "kind", "list")
        |> then(fn d -> elem(Doc.get_or_create_type(d, "items", :array), 0) end)
        |> Array.push("items", [1, 2, 3, 4, 5])

      mutated =
        roundtrip(doc)
        |> Array.delete("items", 0, 2)
        |> Array.push("items", [6, 7])

      assert Array.to_list(mutated, "items") == [3, 4, 5, 6, 7]
      assert Array.to_list(roundtrip(mutated), "items") == [3, 4, 5, 6, 7]
      assert YMap.to_map(roundtrip(mutated), "root") == %{"kind" => "list"}
    end
  end
end
