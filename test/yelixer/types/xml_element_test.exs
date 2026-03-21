defmodule Yelixer.Types.XMLElementTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.XMLElement, Types.XMLText}

  defp new_doc(client_id \\ 1) do
    Doc.new(client_id: client_id)
  end

  test "create element with tag name" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "div")
    assert XMLElement.tag_name(doc, "root") == "div"
  end

  test "set and get attribute" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "div")
    doc = XMLElement.set_attribute(doc, "root", "class", "container")
    assert XMLElement.get_attribute(doc, "root", "class") == "container"
  end

  test "overwrite attribute" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "div")
    doc = XMLElement.set_attribute(doc, "root", "class", "old")
    doc = XMLElement.set_attribute(doc, "root", "class", "new")
    assert XMLElement.get_attribute(doc, "root", "class") == "new"
  end

  test "get_attributes returns all attributes" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "div")
    doc = XMLElement.set_attribute(doc, "root", "class", "container")
    doc = XMLElement.set_attribute(doc, "root", "id", "main")
    attrs = XMLElement.get_attributes(doc, "root")
    assert attrs == %{"class" => "container", "id" => "main"}
  end

  test "missing attribute returns nil" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "div")
    assert XMLElement.get_attribute(doc, "root", "missing") == nil
  end

  test "insert child element" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "div")
    doc = XMLElement.insert_child(doc, "root", 0, {:element, "p"})
    children = XMLElement.children(doc, "root")
    assert length(children) == 1
    assert {:element, "p", _child_name} = hd(children)
  end

  test "insert multiple children" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "div")
    doc = XMLElement.insert_child(doc, "root", 0, {:element, "p"})
    doc = XMLElement.insert_child(doc, "root", 1, {:element, "span"})
    children = XMLElement.children(doc, "root")
    assert length(children) == 2
    assert {:element, "p", _} = Enum.at(children, 0)
    assert {:element, "span", _} = Enum.at(children, 1)
  end

  test "insert child at beginning" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "div")
    doc = XMLElement.insert_child(doc, "root", 0, {:element, "p"})
    doc = XMLElement.insert_child(doc, "root", 0, {:element, "h1"})
    children = XMLElement.children(doc, "root")
    assert {:element, "h1", _} = Enum.at(children, 0)
    assert {:element, "p", _} = Enum.at(children, 1)
  end

  test "insert text child" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "p")
    doc = XMLElement.insert_child(doc, "root", 0, :text)
    children = XMLElement.children(doc, "root")
    assert length(children) == 1
    assert {:text, child_name} = hd(children)
    # The text child can be written to
    doc = XMLText.insert(doc, child_name, 0, "hello")
    assert XMLText.to_string(doc, child_name) == "hello"
  end

  test "to_string produces XML" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "div")
    doc = XMLElement.set_attribute(doc, "root", "class", "box")
    assert XMLElement.to_string(doc, "root") == ~s(<div class="box"></div>)
  end

  test "to_string with text child" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "p")
    doc = XMLElement.insert_child(doc, "root", 0, :text)
    [{:text, child_name}] = XMLElement.children(doc, "root")
    doc = XMLText.insert(doc, child_name, 0, "hello")
    assert XMLElement.to_string(doc, "root") == "<p>hello</p>"
  end

  test "child_count" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "div")
    assert XMLElement.child_count(doc, "root") == 0
    doc = XMLElement.insert_child(doc, "root", 0, {:element, "p"})
    assert XMLElement.child_count(doc, "root") == 1
    doc = XMLElement.insert_child(doc, "root", 1, {:element, "span"})
    assert XMLElement.child_count(doc, "root") == 2
  end

  test "delete_attribute" do
    doc = new_doc()
    doc = XMLElement.new_element(doc, "root", "div")
    doc = XMLElement.set_attribute(doc, "root", "class", "box")
    doc = XMLElement.delete_attribute(doc, "root", "class")
    assert XMLElement.get_attribute(doc, "root", "class") == nil
  end
end
