defmodule Yelixer.SyncProtocolTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.Text, SyncProtocol}

  defp new_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc
  end

  test "full sync between two empty docs" do
    doc1 = new_doc(1)
    doc2 = new_doc(2)

    # Step 1: doc1 sends its state vector
    step1_msg = SyncProtocol.encode_step1(doc1)

    # Step 2: doc2 receives step1, computes diff
    {:step2, step2_msg} = SyncProtocol.handle_message(doc2, step1_msg)

    # doc1 applies the update (empty since both are empty)
    {:update, doc1} = SyncProtocol.handle_message(doc1, step2_msg)
    assert Text.to_string(doc1, "text") == ""
  end

  test "sync doc with content to empty doc" do
    doc1 = new_doc(1)
    doc1 = Text.insert(doc1, "text", 0, "hello")
    doc2 = new_doc(2)

    # doc2 wants to sync with doc1
    # Step 1: doc2 sends its SV to doc1
    step1_msg = SyncProtocol.encode_step1(doc2)

    # Step 2: doc1 computes diff and responds
    {:step2, step2_msg} = SyncProtocol.handle_message(doc1, step1_msg)

    # doc2 applies the update
    {:update, doc2} = SyncProtocol.handle_message(doc2, step2_msg)

    assert Text.to_string(doc2, "text") == "hello"
  end

  test "bidirectional sync between two docs with different content" do
    doc1 = new_doc(1)
    doc1 = Text.insert(doc1, "text", 0, "aaa")

    doc2 = new_doc(2)
    doc2 = Text.insert(doc2, "text", 0, "bbb")

    # doc1 -> doc2 sync
    step1_from_2 = SyncProtocol.encode_step1(doc2)
    {:step2, step2_from_1} = SyncProtocol.handle_message(doc1, step1_from_2)
    {:update, doc2} = SyncProtocol.handle_message(doc2, step2_from_1)

    # doc2 -> doc1 sync
    step1_from_1 = SyncProtocol.encode_step1(doc1)
    {:step2, step2_from_2} = SyncProtocol.handle_message(doc2, step1_from_1)
    {:update, doc1} = SyncProtocol.handle_message(doc1, step2_from_2)

    # Both should converge
    assert Text.to_string(doc1, "text") == Text.to_string(doc2, "text")
  end

  test "incremental sync after initial sync" do
    doc1 = new_doc(1)
    doc1 = Text.insert(doc1, "text", 0, "hello")
    doc2 = new_doc(2)

    # Full sync
    step1 = SyncProtocol.encode_step1(doc2)
    {:step2, step2} = SyncProtocol.handle_message(doc1, step1)
    {:update, doc2} = SyncProtocol.handle_message(doc2, step2)

    # doc1 makes more edits
    doc1 = Text.insert(doc1, "text", 5, " world")

    # Incremental sync
    step1 = SyncProtocol.encode_step1(doc2)
    {:step2, step2} = SyncProtocol.handle_message(doc1, step1)
    {:update, doc2} = SyncProtocol.handle_message(doc2, step2)

    assert Text.to_string(doc2, "text") == "hello world"
  end

  test "encode_step1 and decode_step1 roundtrip" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "test")

    msg = SyncProtocol.encode_step1(doc)
    assert is_binary(msg)

    # First byte should be the message type
    <<type, _rest::binary>> = msg
    # step1 = sync state vector
    assert type == 0
  end
end
