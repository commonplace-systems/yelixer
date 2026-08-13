defmodule Yelixer.Types.XMLFragmentTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.XMLFragment, Types.XMLText}

  defp new_doc(client_id \\ 1) do
    Doc.new(client_id: client_id)
  end

  test "create fragment and insert element children" do
    doc = new_doc()
    doc = XMLFragment.new_fragment(doc, "frag")
    doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "p"})
    doc = XMLFragment.insert_child(doc, "frag", 1, {:element, "div"})
    children = XMLFragment.to_list(doc, "frag")
    assert length(children) == 2
    assert {:element, "p", _} = Enum.at(children, 0)
    assert {:element, "div", _} = Enum.at(children, 1)
  end

  test "insert text child" do
    doc = new_doc()
    doc = XMLFragment.new_fragment(doc, "frag")
    doc = XMLFragment.insert_child(doc, "frag", 0, :text)
    children = XMLFragment.to_list(doc, "frag")
    assert length(children) == 1
    assert {:text, child_name} = hd(children)
    doc = XMLText.insert(doc, child_name, 0, "hello")
    assert XMLText.to_string(doc, child_name) == "hello"
  end

  test "insert at beginning" do
    doc = new_doc()
    doc = XMLFragment.new_fragment(doc, "frag")
    doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "p"})
    doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "h1"})
    children = XMLFragment.to_list(doc, "frag")
    assert {:element, "h1", _} = Enum.at(children, 0)
    assert {:element, "p", _} = Enum.at(children, 1)
  end

  test "child_count" do
    doc = new_doc()
    doc = XMLFragment.new_fragment(doc, "frag")
    assert XMLFragment.child_count(doc, "frag") == 0
    doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "p"})
    assert XMLFragment.child_count(doc, "frag") == 1
  end

  test "empty fragment" do
    doc = new_doc()
    doc = XMLFragment.new_fragment(doc, "frag")
    assert XMLFragment.to_list(doc, "frag") == []
    assert XMLFragment.child_count(doc, "frag") == 0
  end

  describe "delete_child/4" do
    test "deletes one child at index 0 (head)" do
      doc = new_doc()
      doc = XMLFragment.new_fragment(doc, "frag")
      doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "a"})
      doc = XMLFragment.insert_child(doc, "frag", 1, {:element, "b"})
      doc = XMLFragment.insert_child(doc, "frag", 2, {:element, "c"})

      doc = XMLFragment.delete_child(doc, "frag", 0)

      children = XMLFragment.to_list(doc, "frag")
      assert length(children) == 2
      assert [{:element, "b", _}, {:element, "c", _}] = children
      assert XMLFragment.child_count(doc, "frag") == 2
    end

    test "deletes one child at middle index" do
      doc = new_doc()
      doc = XMLFragment.new_fragment(doc, "frag")
      doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "a"})
      doc = XMLFragment.insert_child(doc, "frag", 1, {:element, "b"})
      doc = XMLFragment.insert_child(doc, "frag", 2, {:element, "c"})

      doc = XMLFragment.delete_child(doc, "frag", 1)

      children = XMLFragment.to_list(doc, "frag")
      assert length(children) == 2
      assert [{:element, "a", _}, {:element, "c", _}] = children
    end

    test "deletes one child at last index" do
      doc = new_doc()
      doc = XMLFragment.new_fragment(doc, "frag")
      doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "a"})
      doc = XMLFragment.insert_child(doc, "frag", 1, {:element, "b"})
      doc = XMLFragment.insert_child(doc, "frag", 2, {:element, "c"})

      doc = XMLFragment.delete_child(doc, "frag", 2)

      children = XMLFragment.to_list(doc, "frag")
      assert length(children) == 2
      assert [{:element, "a", _}, {:element, "b", _}] = children
    end

    test "deletes multiple consecutive children with length=2" do
      doc = new_doc()
      doc = XMLFragment.new_fragment(doc, "frag")
      doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "a"})
      doc = XMLFragment.insert_child(doc, "frag", 1, {:element, "b"})
      doc = XMLFragment.insert_child(doc, "frag", 2, {:element, "c"})
      doc = XMLFragment.insert_child(doc, "frag", 3, {:element, "d"})

      doc = XMLFragment.delete_child(doc, "frag", 1, 2)

      children = XMLFragment.to_list(doc, "frag")
      assert length(children) == 2
      assert [{:element, "a", _}, {:element, "d", _}] = children
    end

    test "default length is 1" do
      doc = new_doc()
      doc = XMLFragment.new_fragment(doc, "frag")
      doc = XMLFragment.insert_child(doc, "frag", 0, {:element, "a"})
      doc = XMLFragment.insert_child(doc, "frag", 1, {:element, "b"})

      doc = XMLFragment.delete_child(doc, "frag", 0)

      children = XMLFragment.to_list(doc, "frag")
      assert length(children) == 1
      assert [{:element, "b", _}] = children
    end
  end

  describe "to_string XSS-escaping (CX-n3i7)" do
    test "escapes text content in a top-level fragment (no wrapper tag)" do
      doc = new_doc()
      doc = XMLFragment.new_fragment(doc, "frag")
      doc = XMLFragment.insert_child(doc, "frag", 0, :text)
      [{:text, child_name}] = XMLFragment.to_list(doc, "frag")
      doc = XMLText.insert(doc, child_name, 0, "<script>alert(1)</script> & \"q\"")

      assert XMLFragment.to_string(doc, "frag") ==
               ~s[&lt;script&gt;alert(1)&lt;/script&gt; &amp; "q"]

      # store-raw: the underlying text is untouched
      assert XMLText.to_string(doc, child_name) == "<script>alert(1)</script> & \"q\""
    end
  end
end
