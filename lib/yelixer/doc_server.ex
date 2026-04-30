defmodule Yelixer.DocServer do
  @moduledoc """
  GenServer wrapper that turns a `Yelixer.Doc` into a stateful
  long-lived process with subscribe-on-update broadcast semantics.

  The rest of yelixer treats `Yelixer.Doc` as an immutable struct —
  every operation returns a fresh `%Doc{}` and the caller threads it
  through subsequent calls. That's the right shape for the core CRDT
  logic (no shared mutable state, easy to test, trivial to compose).
  But production callers usually need three things on top:

    1. A **stable identity** to send messages to from many concurrent
       producers (web sockets, HTTP handlers, presence updates) —
       a process under a registered name or pid.
    2. **Single-writer serialization** — Doc operations are pure but
       the *latest version* must be visible to all readers in
       real-time, which means somebody owns the live state. A
       GenServer is the natural place: messages serialize per
       process, so concurrent updates linearize without explicit
       locking.
    3. **Broadcast on update** — every other participant in a sync
       relationship needs to hear about local edits. Pure Doc has
       no notification surface; DocServer adds one.

  ## What's wrapped, what's not

  The current public surface is **Text-only** for mutations:
  `insert_text/4`, `delete_text/4`, `get_text/2`. Sync/encoding paths
  (`encode_update/1`, `encode_diff/2`, `apply_update/2`,
  `state_vector/1`) work on the whole doc and so cover Array, YMap,
  XML content too — they just go through `Yelixer.Encoding` directly,
  which doesn't care about facade boundaries.

  Why Text-only on the mutation side? It's a deliberately narrow
  starting surface — the original use case was a collaborative text
  editor. Extending to `Array.insert/4`, `YMap.set/4`, and the XML
  facades is mechanical (each gets a `handle_call/3` clause that
  threads through `state.doc` and broadcasts the resulting diff)
  but hasn't been needed yet. Callers that want the broader surface
  today work directly with `Yelixer.Doc` outside a GenServer, or
  layer their own wrapper.

  ## The subscribe / broadcast loop

  Subscribers register their pid via `subscribe/1`. After every
  *local* mutation, the server computes the diff between the doc
  state before and after, encodes it via
  `Yelixer.Encoding.encode_diff/2`, and `send/2`s it to every
  subscriber as `{:yelixer_update, binary}`. Subscribers handle the
  message however they like (forward to a websocket, apply to their
  own doc, log it).

  The broadcast deliberately ships only the local delta — passing in
  the *before* state vector as `encode_diff`'s remote-sv argument
  ensures the diff carries exactly the items the subscriber wouldn't
  already know about, assuming the subscriber's view was in sync
  before this update. Subscribers that fall behind reconcile via the
  full sync path (`Yelixer.SyncProtocol`).

  Subscribers are monitored, so a crashed subscriber is automatically
  removed from the set on `:DOWN`. No explicit unsubscribe required
  for crashed processes.

  ## How sync messages flow through

  DocServer doesn't know about `Yelixer.SyncProtocol` directly. The
  pattern is: a transport layer above DocServer holds protocol
  state, calls `state_vector/1` to compose its step1 messages, calls
  `apply_update/2` when step2 arrives, calls `encode_diff/2` to
  build outgoing step2 responses. DocServer is just the
  serialization point that keeps doc mutations safe under
  concurrent access.

  ## What this module is NOT

  - **Not a transport.** No sockets, no PubSub, no fan-out beyond
    direct subscriber pids. The transport layer above DocServer
    decides whether `{:yelixer_update, binary}` flows over a
    websocket, Phoenix.PubSub, MQTT, etc.
  - **Not the protocol layer.** `Yelixer.SyncProtocol` owns the
    step1/step2 framing; DocServer exposes the encode/apply
    primitives that protocol implementations call.
  - **Not durable.** Doc state lives in process memory; if the
    GenServer dies, state is lost unless the supervision tree
    restores it (e.g. by re-applying a snapshot update on init).
    Persistence is the caller's concern.
  """
  use GenServer

  alias Yelixer.{Doc, Types.Text, Encoding, BlockStore, StateVector}

  # Client API

  @doc """
  Starts a DocServer. Accepts `:name` (passed to `GenServer.start_link/3`
  for registration) and `:client_id` (forwarded to `Doc.new/1` for
  stable replica identity across restarts — see `Yelixer.Doc`'s
  client-id assignment section).
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
  Registers the calling process to receive `{:yelixer_update,
  binary}` messages after every local mutation. The server monitors
  the caller, so a crashed subscriber is removed automatically.
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
