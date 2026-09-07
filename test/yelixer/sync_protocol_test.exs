defmodule Yelixer.SyncProtocolTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.Text, SyncProtocol}

  defp new_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc
  end

  # Golden frames from y-protocols 1.0.7 writeSyncStep1/writeSyncStep2/
  # writeUpdate with Yjs 13.6.32. Self-round-trips alone missed framing drift.
  test "step1 includes the upstream varUint8Array payload length" do
    assert SyncProtocol.encode_step1(new_doc(7)) == <<0, 1, 0>>
    doc = Text.insert(new_doc(7), "text", 0, "a")
    assert SyncProtocol.encode_step1(doc) == <<0, 3, 1, 7, 1>>
  end

  test "upstream empty step1 produces a framed step2" do
    assert {:step2, <<1, 2, 0, 0>>} = SyncProtocol.handle_message(new_doc(7), <<0, 1, 0>>)
  end

  test "upstream update tag applies an incremental document update" do
    source = Text.insert(new_doc(7), "text", 0, "hello")
    update = Yelixer.Encoding.encode_update(source)
    frame = <<2, Yelixer.Encoding.encode_uint(byte_size(update))::binary, update::binary>>
    assert {:update, received} = SyncProtocol.handle_message(new_doc(8), frame)
    assert Text.to_string(received, "text") == "hello"
    assert SyncProtocol.encode_update(update) == frame
  end

  test "malformed and unknown frames return errors instead of raising" do
    doc = new_doc(7)

    for frame <- [
          <<>>,
          <<0>>,
          <<0, 1>>,
          <<0, 1, 128>>,
          <<1, 0>>,
          <<1, 2, 128, 128>>,
          <<3, 0>>,
          <<0, 1, 0, 99>>
        ] do
      assert {:error, _} = SyncProtocol.handle_message(doc, frame)
    end

    assert Text.to_string(doc, "text") == ""
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
