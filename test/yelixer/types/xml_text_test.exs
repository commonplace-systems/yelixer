defmodule Yelixer.Types.XMLTextTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.XMLText}

  defp new_doc(client_id \\ 1) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "xml_text", :xml_text)
    doc
  end

  test "local surrogate-boundary insertion survives reload without duplicated text" do
    doc = new_doc() |> XMLText.insert("xml_text", 0, "\u{1F600}")
    doc = XMLText.insert(doc, "xml_text", 1, "X")
    assert XMLText.to_string(doc, "xml_text") == "\u{1F600}X"
    assert XMLText.length(doc, "xml_text") == 3

    assert {:ok, restored} =
             Yelixer.Encoding.apply_update(new_doc(2), Yelixer.Encoding.encode_update(doc))

    assert XMLText.to_string(restored, "xml_text") == XMLText.to_string(doc, "xml_text")
  end

  test "local delete endpoints normalize independently in UTF-16 units" do
    doc = new_doc() |> XMLText.insert("xml_text", 0, "\u{1F600}AB")
    doc = XMLText.delete(doc, "xml_text", 1, 1)
    assert XMLText.to_string(doc, "xml_text") == "\u{1F600}AB"

    assert {:ok, restored} =
             Yelixer.Encoding.apply_update(new_doc(2), Yelixer.Encoding.encode_update(doc))

    assert XMLText.to_string(restored, "xml_text") == "\u{1F600}AB"
  end

  test "insert and read text" do
    doc = new_doc()
    doc = XMLText.insert(doc, "xml_text", 0, "hello")
    assert XMLText.to_string(doc, "xml_text") == "hello"
  end

  test "insert at end" do
    doc = new_doc()
    doc = XMLText.insert(doc, "xml_text", 0, "hello")
    doc = XMLText.insert(doc, "xml_text", 5, " world")
    assert XMLText.to_string(doc, "xml_text") == "hello world"
  end

  test "insert at beginning" do
    doc = new_doc()
    doc = XMLText.insert(doc, "xml_text", 0, "world")
    doc = XMLText.insert(doc, "xml_text", 0, "hello ")
    assert XMLText.to_string(doc, "xml_text") == "hello world"
  end

  test "insert in middle" do
    doc = new_doc()
    doc = XMLText.insert(doc, "xml_text", 0, "hllo")
    doc = XMLText.insert(doc, "xml_text", 1, "e")
    assert XMLText.to_string(doc, "xml_text") == "hello"
  end

  test "delete text" do
    doc = new_doc()
    doc = XMLText.insert(doc, "xml_text", 0, "hello world")
    doc = XMLText.delete(doc, "xml_text", 5, 6)
    assert XMLText.to_string(doc, "xml_text") == "hello"
  end

  test "length" do
    doc = new_doc()
    doc = XMLText.insert(doc, "xml_text", 0, "hello")
    assert XMLText.length(doc, "xml_text") == 5
  end

  test "empty text" do
    doc = new_doc()
    assert XMLText.to_string(doc, "xml_text") == ""
    assert XMLText.length(doc, "xml_text") == 0
  end

  test "to_string renders text content" do
    doc = new_doc()
    doc = XMLText.insert(doc, "xml_text", 0, "some text")
    assert XMLText.to_string(doc, "xml_text") == "some text"
  end
end
