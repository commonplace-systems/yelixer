defmodule Yelixer.DocServerTest do
  use ExUnit.Case, async: true

  alias Yelixer.{DocServer, Encoding, StateVector}

  test "malformed remote update preserves the live document and process" do
    pid = start_supervised!({DocServer, client_id: 1})
    :ok = DocServer.insert_text(pid, "text", 0, "retained")
    before_update = DocServer.encode_update(pid)

    assert {:error, {:malformed_update, _}} = DocServer.apply_update(pid, <<>>)
    assert Process.alive?(pid)
    assert DocServer.encode_update(pid) == before_update
    :ok = DocServer.insert_text(pid, "text", 8, "!")
    assert DocServer.get_text(pid, "text") == "retained!"
  end

  test "subscription is idempotent and unsubscribe releases its monitor" do
    pid = start_supervised!({DocServer, client_id: 1})

    Enum.each(1..16, fn _ ->
      :ok = DocServer.subscribe(pid)
      :ok = DocServer.subscribe(pid)
      :ok = DocServer.unsubscribe(pid)
    end)

    assert {:monitors, []} = Process.info(pid, :monitors)
    :ok = DocServer.subscribe(pid)
    :ok = DocServer.insert_text(pid, "text", 0, "once")
    assert_receive {:yelixer_update, _}
    refute_receive {:yelixer_update, _}
  end

  test "start and insert text" do
    {:ok, pid} = DocServer.start_link(client_id: 1)
    :ok = DocServer.insert_text(pid, "text", 0, "hello")
    assert DocServer.get_text(pid, "text") == "hello"
  end

  test "delete text" do
    {:ok, pid} = DocServer.start_link(client_id: 1)
    :ok = DocServer.insert_text(pid, "text", 0, "hello world")
    :ok = DocServer.delete_text(pid, "text", 5, 6)
    assert DocServer.get_text(pid, "text") == "hello"
  end

  test "encode update from server" do
    {:ok, pid} = DocServer.start_link(client_id: 1)
    :ok = DocServer.insert_text(pid, "text", 0, "hello")
    update = DocServer.encode_update(pid)
    assert is_binary(update)
    assert byte_size(update) > 0
  end

  test "apply remote update" do
    {:ok, pid1} = DocServer.start_link(client_id: 1)
    {:ok, pid2} = DocServer.start_link(client_id: 2)

    :ok = DocServer.insert_text(pid1, "text", 0, "hello")
    update = DocServer.encode_update(pid1)

    :ok = DocServer.apply_update(pid2, update)
    assert DocServer.get_text(pid2, "text") == "hello"
  end

  test "get state vector" do
    {:ok, pid} = DocServer.start_link(client_id: 1)
    :ok = DocServer.insert_text(pid, "text", 0, "hi")
    sv = DocServer.state_vector(pid)
    assert StateVector.get(sv, 1) == 2
  end

  test "incremental sync with encode_diff" do
    {:ok, pid1} = DocServer.start_link(client_id: 1)
    {:ok, pid2} = DocServer.start_link(client_id: 2)

    :ok = DocServer.insert_text(pid1, "text", 0, "hello")

    # Full sync
    update = DocServer.encode_update(pid1)
    :ok = DocServer.apply_update(pid2, update)
    assert DocServer.get_text(pid2, "text") == "hello"

    # Incremental sync
    :ok = DocServer.insert_text(pid1, "text", 5, " world")
    sv2 = DocServer.state_vector(pid2)
    diff = DocServer.encode_diff(pid1, sv2)
    :ok = DocServer.apply_update(pid2, diff)
    assert DocServer.get_text(pid2, "text") == "hello world"
  end

  test "subscribe to updates" do
    {:ok, pid} = DocServer.start_link(client_id: 1)
    :ok = DocServer.subscribe(pid)

    :ok = DocServer.insert_text(pid, "text", 0, "hi")

    assert_receive {:yelixer_update, update}
    assert is_binary(update)

    # Verify the update is valid
    doc = Yelixer.Doc.new(client_id: 99)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "text", :text)
    {:ok, _} = Encoding.apply_update(doc, update)
  end
end
