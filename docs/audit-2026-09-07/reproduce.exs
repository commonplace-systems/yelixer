# Bounded synthetic audit probes; run only in a granted compute window.
# No test suite, app consumer, external network, or live document input.
alias Yelixer.{Doc, DocServer, Encoding, BlockStore, SyncProtocol}
alias Yelixer.Types.{Text, XMLText}

Logger.configure(level: :none)

defmodule AuditProbe do
  def capture(fun) do
    try do
      fun.()
    rescue
      e -> %{exception: inspect(e.__struct__), message: Exception.message(e)}
    catch
      :exit, reason -> %{exit: inspect(reason, limit: 8)}
    end
  end

  def emit(name, fun) do
    IO.puts(Jason.encode!(%{probe: name, result: capture(fun)}))
  end

  def doc(client \\ 7) do
    {doc, _} = Yelixer.Doc.get_or_create_type(Yelixer.Doc.new(client_id: client), "t", :text)
    doc
  end

  def work(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, after_work} = Process.info(self(), :reductions)
    {after_work - before, result}
  end

  def text_blocks(n) do
    Enum.reduce(0..(n - 1), doc(), fn i, doc -> Yelixer.Types.Text.insert(doc, "t", i, "a") end)
  end
end

AuditProbe.emit("sync", fn ->
  doc = AuditProbe.doc()
  %{empty_step1_hex: Base.encode16(SyncProtocol.encode_step1(doc)),
    official_empty_step1: AuditProbe.capture(fn ->
      inspect(SyncProtocol.handle_message(doc, <<0, 1, 0>>))
    end),
    official_update_tag2: AuditProbe.capture(fn ->
      inspect(SyncProtocol.handle_message(doc, <<2, 2, 0, 0>>))
    end)}
end)

AuditProbe.emit("doc_server_malformed", fn ->
  {:ok, server} = DocServer.start_link(client_id: 7)
  Process.unlink(server)
  ref = Process.monitor(server)
  :ok = DocServer.insert_text(server, "t", 0, "saved-only-in-memory")
  result = AuditProbe.capture(fn -> DocServer.apply_update(server, <<>>) end)
  down = receive do
    {:DOWN, ^ref, :process, ^server, _reason} -> true
  after
    1_000 -> false
  end
  if Process.alive?(server), do: GenServer.stop(server)
  %{call: result, server_down: down}
end)

AuditProbe.emit("any_type_roundtrip", fn ->
  for {name, bytes} <- [buffer: <<116, 2, 65, 66>>, undefined: <<127>>,
                        bigint: <<122, 42::signed-64>>], into: %{} do
    {value, <<>>} = Encoding.decode_any_value(bytes)
    {name, %{input: Base.encode16(bytes), output: Base.encode16(Encoding.encode_any_value(value))}}
  end
end)

AuditProbe.emit("snapshot_overlay_and_mapping", fn ->
  source = AuditProbe.doc() |> Text.insert("t", 0, "ab") |> Text.delete("t", 0, 1)
  {bytes, dm} = Doc.snapshot_update(%{source | client_id: 99})
  {:ok, fresh} = Encoding.apply_update(AuditProbe.doc(888), bytes)
  {:ok, overlay} = Encoding.apply_update(source, bytes)
  %{source: Text.to_string(source, "t"), fresh: Text.to_string(fresh, "t"),
    overlay: Text.to_string(overlay, "t"), derivation_map: inspect(dm),
    source_items: Enum.map(BlockStore.all_items(source.store), fn i ->
      %{clock: i.id.clock, deleted: i.deleted, content: inspect(i.content)}
    end)}
end)

AuditProbe.emit("duplicate_unresolved_update", fn ->
  base = AuditProbe.doc() |> Text.insert("t", 0, "A")
  next = Text.insert(base, "t", 1, "B")
  delta = Encoding.encode_diff(next, Doc.state_vector(base))
  pending = Enum.reduce(1..16, AuditProbe.doc(88), fn _, doc ->
    {:ok, doc} = Encoding.apply_update(doc, delta)
    doc
  end)
  {:ok, resolved} = Encoding.apply_update(pending, Encoding.encode_update(base))
  %{same_update_bytes: byte_size(delta), after_16_deliveries: Doc.pending_info(pending),
    after_dependency: Doc.pending_info(resolved), resolved_text: Text.to_string(resolved, "t")}
end)

AuditProbe.emit("xml_text_local_boundary", fn ->
  doc = AuditProbe.doc() |> XMLText.insert("t", 0, "\u{1F600}")
  doc = XMLText.insert(doc, "t", 1, "X")
  %{local: XMLText.to_string(doc, "t"),
    items: Enum.map(BlockStore.all_items(doc.store), &%{clock: &1.id.clock, length: &1.length}),
    reload: AuditProbe.capture(fn ->
      {:ok, reloaded} = Encoding.apply_update(AuditProbe.doc(88), Encoding.encode_update(doc))
      XMLText.to_string(reloaded, "t")
    end)}
end)

AuditProbe.emit("bounded_work_counts", fn ->
  Enum.map([512, 1024], fn n ->
    {build_work, doc} = AuditProbe.work(fn -> AuditProbe.text_blocks(n) end)
    {read_work, _} = AuditProbe.work(fn -> Text.to_string(doc, "t") end)
    gc_doc = Doc.gc(doc)
    {post_gc_read_work, _} = AuditProbe.work(fn -> Text.to_string(gc_doc, "t") end)
    next = Text.insert(doc, "t", n, "b")
    {diff_work, bytes} = AuditProbe.work(fn -> Encoding.encode_diff(next, Doc.state_vector(doc)) end)
    %{n: n, build_reductions: build_work, read_reductions: read_work,
      post_gc_read_reductions: post_gc_read_work, one_item_diff_reductions: diff_work,
      one_item_diff_bytes: byte_size(bytes), gc_tuple_cache_entries: map_size(gc_doc.store.client_tuples)}
  end)
end)

AuditProbe.emit("subscription_monitor_lifetime", fn ->
  {:ok, server} = DocServer.start_link(client_id: 7)
  Enum.each(1..16, fn _ -> DocServer.subscribe(server); DocServer.unsubscribe(server) end)
  {:monitors, monitors} = Process.info(server, :monitors)
  GenServer.stop(server)
  %{monitors_after_16_subscribe_unsubscribe_cycles: length(monitors)}
end)

AuditProbe.emit("compiled_identity", fn ->
  %{elixir: System.version(), otp: System.otp_release(),
    modules: Enum.map([Doc, DocServer, Encoding, BlockStore, SyncProtocol, Text, XMLText], fn mod ->
      %{module: inspect(mod), loaded_md5: Base.encode16(mod.module_info(:md5))}
    end)}
end)
