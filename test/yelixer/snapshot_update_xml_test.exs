defmodule Yelixer.SnapshotUpdateXMLTest do
  use ExUnit.Case, async: true

  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.{XMLElement, XMLFragment, XMLText}

  describe "snapshot_update/1 XML replay (CX-b2y)" do
    test "round-trips a nested XML fragment with element + text + attribute" do
      doc = Doc.new(client_id: 7)
      doc = XMLFragment.new_fragment(doc, "frag")
      doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "p"})

      [{:element, "p", elem_name}] = XMLFragment.to_list(doc, "frag")
      doc = XMLElement.set_attribute(doc, elem_name, "class", "para")
      doc = XMLElement.insert_child(doc, elem_name, 0, :text)

      [{:text, text_name}] = XMLElement.children(doc, elem_name)
      doc = XMLText.insert(doc, text_name, 0, "hello world")

      expected = ~s(<p class="para">hello world</p>)
      assert XMLFragment.to_string(doc, "frag") == expected

      snapshot_bin = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), snapshot_bin)

      assert XMLFragment.to_string(rebuilt, "frag") == expected
      # State vector carries just the source client_id.
      assert map_size(BlockStore.state_vector(rebuilt.store).clocks) == 1
      assert Map.has_key?(BlockStore.state_vector(rebuilt.store).clocks, 7)
    end

    test "round-trips with a deleted middle child (tombstone dropped)" do
      doc = Doc.new(client_id: 9)
      doc = XMLFragment.new_fragment(doc, "frag")
      doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "a"})
      doc = XMLFragment.insert_child(doc, "frag", 1, {:element, "b"})
      doc = XMLFragment.insert_child(doc, "frag", 2, {:element, "c"})

      doc = XMLFragment.delete_child(doc, "frag", 1)

      assert XMLFragment.to_string(doc, "frag") == "<a></a><c></c>"

      snapshot_bin = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), snapshot_bin)

      assert XMLFragment.to_string(rebuilt, "frag") == "<a></a><c></c>"
      assert XMLFragment.child_count(rebuilt, "frag") == 2
    end

    test "round-trips an XMLElement top-level type with text child" do
      # Top-level XMLElement tags are not carried on the Yjs wire format
      # (same as Y.js: callers `ydoc.get('root', Y.XmlElement)` to
      # register the type and tag before applying updates). Pre-register
      # the receiver type before apply_update.
      doc = Doc.new(client_id: 13)
      doc = XMLElement.new_element(doc, "root", "div")
      doc = XMLElement.set_attribute(doc, "root", "id", "x")
      doc = XMLElement.insert_child(doc, "root", 0, :text)

      [{:text, text_name}] = XMLElement.children(doc, "root")
      doc = XMLText.insert(doc, text_name, 0, "body")

      expected = ~s(<div id="x">body</div>)
      assert XMLElement.to_string(doc, "root") == expected

      snapshot_bin = Doc.snapshot_update(doc)

      receiver = XMLElement.new_element(Doc.new(), "root", "div")
      {:ok, rebuilt} = Encoding.apply_update(receiver, snapshot_bin)

      assert XMLElement.to_string(rebuilt, "root") == expected
    end

    test "round-trips a top-level XMLText" do
      doc = Doc.new(client_id: 21)
      {doc, _} = Doc.get_or_create_type(doc, "body", :xml_text)
      doc = XMLText.insert(doc, "body", 0, "inline")

      snapshot_bin = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), snapshot_bin)

      assert XMLText.to_string(rebuilt, "body") == "inline"
    end

    test "round-trips nested fragment -> element -> element -> text" do
      doc = Doc.new(client_id: 5)
      doc = XMLFragment.new_fragment(doc, "frag")
      doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "article"})

      [{:element, "article", article_name}] = XMLFragment.to_list(doc, "frag")
      doc = XMLElement.insert_child(doc, article_name, 0, {:element, "h1"})

      [{:element, "h1", h1_name}] = XMLElement.children(doc, article_name)
      doc = XMLElement.insert_child(doc, h1_name, 0, :text)

      [{:text, h1_text_name}] = XMLElement.children(doc, h1_name)
      doc = XMLText.insert(doc, h1_text_name, 0, "Title")

      expected = "<article><h1>Title</h1></article>"
      assert XMLFragment.to_string(doc, "frag") == expected

      snapshot_bin = Doc.snapshot_update(doc)
      {:ok, rebuilt} = Encoding.apply_update(Doc.new(), snapshot_bin)

      assert XMLFragment.to_string(rebuilt, "frag") == expected
    end
  end
end
