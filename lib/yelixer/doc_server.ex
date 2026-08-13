defmodule Yelixer.DocServer do
  @moduledoc """
  OTP companion to `Yelixer.Doc`: a GenServer that owns the live doc
  state and broadcasts incremental updates to subscribers.

  `Yelixer.Doc` is a pure immutable struct — every operation returns a
  new `%Doc{}` that the caller threads forward. That shape is right for
  CRDT logic (no shared state, easy to test, easy to compose), but
  production callers need three things the struct alone cannot provide:

    1. **Stable identity** — a registered process that concurrent
       producers (WebSocket handlers, HTTP endpoints, presence hooks)
       can all address without coordinating on who holds the ref.
    2. **Single-writer serialization** — OTP delivers messages to a
       GenServer one at a time, so concurrent callers naturally
       linearize around the live doc without locks or transactions.
    3. **Broadcast on update** — local edits must propagate to other
       participants. Pure `Doc` has no notification surface; DocServer
       adds one.

  ## Mutation surface vs. encoding surface

  Mutation functions (`insert_text/4`, `delete_text/4`, `get_text/2`)
  are **Text-only** — that was the original use case. The encoding and
  sync functions (`encode_update/1`, `encode_diff/2`, `apply_update/2`,
  `state_vector/1`) operate on the whole doc, so they reach Array, YMap,
  and XML content too; `Yelixer.Encoding` is type-agnostic.

  Adding mutation wrappers for other types is mechanical — each needs one
  `handle_call/3` clause that threads through `state.doc` and broadcasts
  the resulting diff — but none have been needed yet. Callers that need
  the broader surface today use `Yelixer.Doc` directly.

  ## Subscribe / broadcast loop

  Call `subscribe/1` to register a pid. After each local mutation the
  server snapshots the state vector *before* the change, applies the
  mutation, then calls `Yelixer.Encoding.encode_diff/2` with that
  before-snapshot as the remote state vector. This produces a binary
  containing exactly the new operations — nothing the subscriber already
  had. The binary is sent to every subscriber as `{:yelixer_update,
  binary}`. Subscribers do whatever they like with it: forward over a
  WebSocket, apply to a local doc, log it.

  Subscribers that fall behind (missed messages, reconnected late)
  reconcile via the full sync handshake in `Yelixer.SyncProtocol`.

  Each subscriber pid is monitored. When a subscriber crashes, the
  `:DOWN` message removes it from the set automatically; no manual
  unsubscribe is needed for crashed processes.

  ## Sync message flow

  DocServer has no direct dependency on `Yelixer.SyncProtocol`. The
  expected pattern: a transport layer above DocServer holds protocol
  state, calls `state_vector/1` to build step-1 messages, calls
  `apply_update/2` when a step-2 update arrives, and calls
  `encode_diff/2` to build outgoing step-2 responses. DocServer's only
  role in this flow is serialization — it ensures mutations and reads
  against the live doc are safe under concurrent access.

  ## Boundaries

  - **Not a transport.** No sockets, no PubSub, no fan-out beyond
    direct pid delivery. The layer above decides whether
    `{:yelixer_update, binary}` travels over a WebSocket,
    Phoenix.PubSub, MQTT, or something else entirely.
  - **Not the protocol layer.** `Yelixer.SyncProtocol` owns
    step-1/step-2 framing. DocServer exposes the encode/apply
    primitives that protocol implementations call.
  - **Not durable.** State lives in process memory. If the GenServer
    exits, the doc is gone unless the supervision tree rebuilds it
    (e.g. by replaying a snapshot update in `init/1`). Persistence
    is the caller's responsibility.
  """
  use GenServer

  alias Yelixer.{Doc, Types.Text, Encoding, BlockStore, StateVector}

  # Client API

  @doc """
  Starts a DocServer.

  Options:
  - `:name` — passed to `GenServer.start_link/3` for process registration.
  - `:client_id` — forwarded to `Doc.new/1` to pin this replica's identity
    across restarts. See the client-id section in `Yelixer.Doc`.
  """
  def start_link(opts \\ []) do
    {gen_opts, doc_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, doc_opts, gen_opts)
  end

  def insert_text(server, type_name, index, text) do
    GenServer.call(server, {:insert_text, type_name, index, text})
  end

  def delete_text(server, type_name, index, len) do
    GenServer.call(server, {:delete_text, type_name, index, len})
  end

  def get_text(server, type_name) do
    GenServer.call(server, {:get_text, type_name})
  end

  def encode_update(server) do
    GenServer.call(server, :encode_update)
  end

  def encode_diff(server, %StateVector{} = remote_sv) do
    GenServer.call(server, {:encode_diff, remote_sv})
  end

  def apply_update(server, update) when is_binary(update) do
    GenServer.call(server, {:apply_update, update})
  end

  def state_vector(server) do
    GenServer.call(server, :state_vector)
  end

  @doc """
  Registers the caller to receive `{:yelixer_update, binary}` after
  each local mutation. The server monitors the caller; a crash removes
  it from the subscriber set without requiring an explicit unsubscribe.
  """
  def subscribe(server) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Removes the caller from the subscriber set."
  def unsubscribe(server) do
    GenServer.call(server, {:unsubscribe, self()})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    client_id = Keyword.get(opts, :client_id, :rand.uniform(1_000_000_000))
    doc = Doc.new(client_id: client_id)
    {:ok, %{doc: doc, subscribers: MapSet.new()}}
  end

  @impl true
  def handle_call({:insert_text, type_name, index, text}, _from, state) do
    {doc, _} = Doc.get_or_create_type(state.doc, type_name, :text)
    sv_before = BlockStore.state_vector(doc.store)
    doc = Text.insert(doc, type_name, index, text)
    state = %{state | doc: doc}
    broadcast_diff(state, sv_before)
    {:reply, :ok, state}
  end

  def handle_call({:delete_text, type_name, index, len}, _from, state) do
    {doc, _} = Doc.get_or_create_type(state.doc, type_name, :text)
    sv_before = BlockStore.state_vector(doc.store)
    doc = Text.delete(doc, type_name, index, len)
    state = %{state | doc: doc}
    broadcast_diff(state, sv_before)
    {:reply, :ok, state}
  end

  def handle_call({:get_text, type_name}, _from, state) do
    {doc, _} = Doc.get_or_create_type(state.doc, type_name, :text)
    text = Text.to_string(doc, type_name)
    {:reply, text, %{state | doc: doc}}
  end

  def handle_call(:encode_update, _from, state) do
    update = Encoding.encode_update(state.doc)
    {:reply, update, state}
  end

  def handle_call({:encode_diff, remote_sv}, _from, state) do
    diff = Encoding.encode_diff(state.doc, remote_sv)
    {:reply, diff, state}
  end

  def handle_call({:apply_update, update}, _from, state) do
    {:ok, doc} = Encoding.apply_update(state.doc, update)
    {:reply, :ok, %{state | doc: doc}}
  end

  def handle_call(:state_vector, _from, state) do
    sv = BlockStore.state_vector(state.doc.store)
    {:reply, sv, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  defp broadcast_diff(state, sv_before) do
    if MapSet.size(state.subscribers) > 0 do
      diff = Encoding.encode_diff(state.doc, sv_before)

      Enum.each(state.subscribers, fn pid ->
        send(pid, {:yelixer_update, diff})
      end)
    end
  end
end
