defmodule Yelixer.DocSpecPinsTest do
  @moduledoc """
  Pins for confirmed defects where a yelixer docstring makes a
  BEHAVIOURAL claim that the code does not honour — the docs are
  written as specifications (naming variants, stating fallbacks,
  promising outcomes) while nothing in the implementation executes
  them. This is one instance of a repo-wide pattern of four; the
  other two (`Types.Array.to_list/2` and the differential harness's
  own `@moduledoc`) are pinned/tracked elsewhere.

  A prose specification that nothing runs is the most confidently
  wrong artifact a repo can hold, because it reads as a decision
  someone made — each of the claims pinned below was written by
  someone who had visibly thought about the case, and is wrong
  anyway. These tests are ordinary (untagged) so they run in the
  main suite and are expected to stay GREEN: they assert what the
  code *does*, not what its docstring promises.

  Both fixtures below were generated with the npm oracle
  (`yjs-stable`, npm:yjs@13.6.32, invoked from `test/fixtures`) and
  are embedded as base64 so the test needs no Node at run time. See
  the generating snippets in each `describe` block's moduledoc-style
  comment for how to regenerate them if the oracle's wire format
  ever changes.
  """
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.YMap

  describe "Doc.nested_subtype_names/1 vs. its docstring (CX pin A)" do
    # Generated via:
    #   const doc1 = new Y.Doc();
    #   const map1 = doc1.getMap("m");
    #   const frag = new Y.XmlFragment();
    #   map1.set("x", frag);
    #   frag.insert(0, [new Y.XmlText("hello")]);
    #   Y.encodeStateAsUpdate(doc1)
    #
    # This nests an XmlFragment/XmlText pair as a plain Map VALUE
    # (not as an XML tree-child via insert_child/4).
    @xml_as_map_value_update Base.decode64!(
                               "AQPBjfb0DgAnAQFtAXgEBwDBjfb0DgAGBADBjfb0DgEFaGVsbG8A"
                             )

    test "returns __sub:CLIENT:CLOCK names for an XML type nested as a Map value; the docstring's claim that XML sub-types are excluded and named with \"::child::\" is FALSE for this path" do
      {:ok, doc} = Doc.new(client_id: 999) |> Encoding.apply_update(@xml_as_map_value_update)

      names = Doc.nested_subtype_names(doc)

      # THE DOC IS THE WRONG HALF HERE. lib/yelixer/doc.ex's moduledoc
      # (~line 307-309, describing nested_subtype_names/1) claims XML
      # sub-types are excluded from this list and, when they do
      # appear, are named with an "::child::" convention. Neither is
      # true for an XML type nested as a Map/Array value: it goes
      # through the same generic `__sub:CLIENT:CLOCK` mechanism as
      # any other nested type. The "::child::"-style naming (if it
      # exists at all) applies only to XML tree-children reached via
      # insert_child/4, which this fixture does not exercise.
      assert length(names) == 2

      assert Enum.all?(names, &Regex.match?(~r/^__sub:\d+:\d+$/, &1)),
             "expected __sub:CLIENT:CLOCK names, got #{inspect(names)}"

      refute Enum.any?(names, &String.contains?(&1, "::child::")),
             "no ::child:: naming is produced for a Map-nested XML value"

      # RETIREMENT CONDITION: this pin should be rewritten (not
      # deleted) the day nested_subtype_names/1 actually excludes
      # Map/Array-nested XML sub-types or renames them per the
      # docstring's "::child::" convention — at that point this
      # assertion will fail, which is the signal to update both the
      # test and read the (presumably now-correct) docstring again.
    end

    test "asserting the DOCSTRING'S claim (empty/excluded list) fails against real behaviour" do
      {:ok, doc} = Doc.new(client_id: 999) |> Encoding.apply_update(@xml_as_map_value_update)

      names = Doc.nested_subtype_names(doc)

      # This demonstrates the pin above is not vacuous: the
      # docstring's claim ("XML sub-types are excluded") does NOT
      # hold, so asserting it here fails as expected.
      refute names == [],
             "if this ever passes, nested_subtype_names/1 started honouring its docstring " <>
               "and pin A above needs to be rewritten"
    end
  end

  describe "Types.YMap.get/3 vs. its docstring (CX pin B)" do
    # Generated via:
    #   const doc2 = new Y.Doc();
    #   const map2 = doc2.getMap("m");
    #   map2.set("bin", new Uint8Array([1, 2, 3, 4, 5]));
    #   Y.encodeStateAsUpdate(doc2)
    #
    # A Uint8Array map value decodes to yelixer content variant
    # `{:binary, <<1, 2, 3, 4, 5>>}`.
    @binary_map_value_update Base.decode64!("AQGEu6fjAwAjAQFtA2JpbgUBAgMEBQA=")

    test "raises CaseClauseError for a {:binary, _} value; the docstring's claim of returning nil for non-:any content is FALSE" do
      {:ok, doc} = Doc.new(client_id: 999) |> Encoding.apply_update(@binary_map_value_update)

      # THE DOC IS THE WRONG HALF HERE. lib/yelixer/types/y_map.ex's
      # doc for get/3 (~line 122-125) promises `nil` for keys whose
      # content variant is not `:any` ("sub-types, embeds, etc.").
      # The implementation's `case` only matches `{:any, [value]}`
      # and `nil` (missing/deleted); it has no fallback clause, so a
      # `{:binary, _}` item — reachable via an ordinary decoded yjs
      # update containing a Uint8Array map value — raises
      # CaseClauseError instead of returning nil.
      assert_raise CaseClauseError, fn ->
        YMap.get(doc, "m", "bin")
      end

      # RETIREMENT CONDITION: this pin should be rewritten (not
      # deleted) the day YMap.get/3 returns nil for {:binary, _} (and
      # other non-:any) content as its docstring promises — at that
      # point assert_raise above will fail with "expected exception
      # ... but nothing was raised", which is the signal to update
      # this test to assert `nil` instead.
    end

    test "asserting the DOCSTRING'S claim (nil) fails against real behaviour" do
      {:ok, doc} = Doc.new(client_id: 999) |> Encoding.apply_update(@binary_map_value_update)

      # This demonstrates the pin above is not vacuous: asserting the
      # docstring's promised nil return raises instead of passing.
      assert_raise CaseClauseError, fn ->
        assert YMap.get(doc, "m", "bin") == nil
      end
    end
  end
end
