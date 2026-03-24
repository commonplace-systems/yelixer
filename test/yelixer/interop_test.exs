defmodule Yelixer.InteropTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding, Types.Text, StateVector}

  @moduletag :interop

  test "decode Yjs V1 'hello' update and produce correct state" do
    update = File.read!("test/fixtures/hello_update_v1.bin")
    doc = Doc.new(client_id: 2)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)

    {:ok, doc} = Encoding.apply_update(doc, update)
    assert Text.to_string(doc, "text") == "hello"
  end

  test "decode Yjs state vector" do
    sv_bytes = File.read!("test/fixtures/hello_sv.bin")
    {:ok, {sv, ""}} = Encoding.decode_state_vector(sv_bytes)
    assert StateVector.get(sv, 1) == 5
  end

  test "decode and merge two Yjs peer updates" do
    update_a = File.read!("test/fixtures/peer_a_update.bin")
    update_b = File.read!("test/fixtures/peer_b_update.bin")
    expected = String.trim(File.read!("test/fixtures/merged_text.txt"))

    doc = Doc.new(client_id: 99)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)

    {:ok, doc} = Encoding.apply_update(doc, update_a)
    {:ok, doc} = Encoding.apply_update(doc, update_b)

    assert Text.to_string(doc, "text") == expected
  end

  test "Yelixer update can roundtrip with itself" do
    # Create state in Yelixer, encode, decode, verify
    doc1 = Doc.new(client_id: 42)
    {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
    doc1 = Text.insert(doc1, "text", 0, "yelixer")

    update = Encoding.encode_update(doc1)

    doc2 = Doc.new(client_id: 43)
    {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)
    {:ok, doc2} = Encoding.apply_update(doc2, update)

    assert Text.to_string(doc2, "text") == "yelixer"
  end

  test "decode complex multi-client Yjs update with deletions" do
    update = File.read!("test/fixtures/complex_update.bin")
    expected = String.trim(File.read!("test/fixtures/complex_expected.txt"))

    doc = Doc.new(client_id: 99)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    {:ok, doc} = Encoding.apply_update(doc, update)

    assert Text.to_string(doc, "text") == expected
  end

  test "full roundtrip: Yelixer -> Yjs -> Yelixer" do
    # Yelixer generated an update, Yjs decoded it, made an edit, re-encoded
    update = File.read!("test/fixtures/roundtrip_yjs_update.bin")
    expected = String.trim(File.read!("test/fixtures/roundtrip_expected.txt"))

    doc = Doc.new(client_id: 300)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    {:ok, doc} = Encoding.apply_update(doc, update)

    assert Text.to_string(doc, "text") == expected
  end
end
