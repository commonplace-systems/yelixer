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
end
