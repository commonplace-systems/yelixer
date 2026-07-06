defmodule Yelixer.Encoding do
  @moduledoc """
  Binary serialization for the Yjs V1 wire protocol — the byte-level
  bridge between in-memory CRDT state and the network/disk.

  Three responsibilities: encode a doc to a binary update message,
  decode and integrate that message into a doc, and encode/decode the
  smaller state-vector and delete-set summaries that drive sync
  handshakes. Everything else here (varint codecs, string framing,
  lib0 Any encoding) is plumbing in service of those three.

  ## Wire-format primitives

  All numeric fields use variable-length integer (varint) encoding —
  small values take fewer bytes. Yjs uses three distinct varint
  conventions, all implemented here:

    - **Unsigned LEB128** (`encode_uint`/`decode_uint`) — the standard
      Yjs varint. Each byte carries 7 data bits; the high bit signals
      that more bytes follow. Used for clocks, lengths, counts, and
      client IDs.
    - **Zigzag signed** (`encode_sint`/`decode_sint`) — maps signed
      integers onto unsigned ones by interleaving: `0→0, -1→1, 1→2,
      -2→3, …`. Keeps small negative numbers small after LEB128
      encoding. Used for fields that legitimately go negative.
    - **lib0 writeVarInt** (`encode_var_int`/`decode_var_int`) — a
      different layout used only inside lib0 Any encoding (tag 125).
      The first byte packs a sign bit at position 6 and 6 data bits;
      subsequent bytes carry 7 data bits + continuation. Distinct from
      `decode_sint` despite both handling signed numbers — the byte
      layouts are incompatible.

  Strings are UTF-8 length-prefixed: `encode_string`/`decode_string`
  emit `<varint byte_len, bytes::binary>`.

  ## Major encoded shapes

  Each shape corresponds to a sister module (`Yelixer.ID`,
  `Yelixer.Item`, `Yelixer.DeleteSet`, `Yelixer.StateVector`,
  `Yelixer.BlockStore`):

    - **State vector** (`encode_state_vector`/`decode_state_vector`).
      A length-prefixed list of `(client, clock)` pairs representing
      the minimum "what I have" summary. Sent first in a sync
      handshake.
    - **Delete set** (`encode_delete_set`/`decode_delete_set`).
      Per-client run-length intervals of deleted clock ranges. Clients
      are sorted descending — required for byte-determinism; see below.
    - **Update message** (`encode_update`/`encode_diff` + `apply_update`).
      The full payload: a struct section (items grouped by client, each
      with origin/right_origin anchors and content) followed by a
      delete set. `encode_update/1` encodes the whole doc;
      `encode_diff/2` encodes only what a remote peer is missing.
      `apply_update/2` is the inverse: parse items, integrate them
      into the BlockStore in YATA order, then apply the delete set.
    - **lib0 Any** (`encode_any_value`/`decode_any_value`). JSON-shaped
      primitives (numbers, booleans, strings, lists, maps) with a
      one-byte type tag per value. Used inside `:any` and `:format`
      content variants and for embed payloads.

  ## Round-trip property

  `decode(encode(x)) == x` for all four shapes. Property tests in
  `test/yelixer/encoding_*_test.exs` exercise this with random inputs;
  the 5320-entry yrs oracle suite checks byte-for-byte parity against
  the Rust port.

  ## Byte-determinism guarantee (CX-w62 / Build 6 gate)

  `encode_update/1` is **byte-deterministic**: two independent peers
  that build the same logical state via `apply_update/2` will produce
  identical bytes from `encode_update/1`. Content-addressed storage
  (the snapshot op in CX-umz; the late-edit translator in Build 6.3)
  depends on this — hashes only match when re-encoding is canonical.

  Four invariants together ensure determinism:

    1. The struct section emits clients in descending client_id order.
    2. Items within a client are traversed in clock order by the block
       store, which keeps them sorted.
    3. `encode_delete_set/1` sorts clients descending. Without this,
       byte order would depend on Elixir's unspecified map-iteration
       order.
    4. `apply_update/2` merges incoming delete sets into
       `doc.delete_set` rather than replacing it, so receivers retain
       tombstones and can re-emit them losslessly.

  See `test/yelixer/encoder_determinism_test.exs` for cross-instance
  equality checks.

  ## Boundaries

  - Not a transport — `Yelixer.SyncProtocol` wraps encoded payloads in
    protocol messages; this module produces the bytes inside.
  - Not a doc store — `Yelixer.Doc` and `Yelixer.BlockStore` own
    in-memory state. Encoding only reads and writes it.
  - Not the integrator — `apply_update/2` parses items then delegates
    to `Yelixer.Integrate` for YATA placement. Anchor resolution and
    GC-block remapping live there, not here.
  """

  alias Yelixer.{StateVector, DeleteSet, ID, Item, BlockStore, Doc, Integrate}

  # Content type refs (matching Yjs V1 format)
  @content_ref_gc 0
  @content_ref_deleted 1
  @content_ref_json 2
  @content_ref_binary 3
  @content_ref_string 4
  @content_ref_embed 5
  @content_ref_format 6
  @content_ref_type 7
  @content_ref_any 8

  # Info byte bit flags (Yjs convention)
  @has_origin 128
  @has_right_origin 64
  @has_parent_sub 32

  # CX-wmtz (H2): the largest clock/length value a legitimate Yjs
  # client can ever produce. JS clocks are plain `Number`s, so no real
  # peer can advance a clock (or declare an item/delete-range length)
  # past `Number.MAX_SAFE_INTEGER`. A crafted update that claims a
  # larger value is not a possible legitimate state — it's an attempt
  # to poison a client's high-water mark (silently starving future
  # real items from that client, since `integrate_items/5`'s "fully
  # known" check would then treat them as already-seen) or to make
  # `apply_delete_range/4` spin over an astronomically large absent
  # range. Reject at decode time instead of letting either happen.
  @max_safe_clock 9_007_199_254_740_991

  # CX-cdyi (H1): default byte cap on the total size of `doc.pending`
  # (all currently-buffered un-integratable update binaries, summed).
  # Config-overridable via `config :yelixer, max_pending_bytes: n`.
  # Updates arrive as commits, so H2b's varint sanity bounds plus
  # commit size already bound any single blob; this cap bounds the
  # *total* a hostile or badly-ordered peer can pile up before we
  # start rejecting applies outright (see `apply_update/2`).
  @default_max_pending_bytes 10_485_760

  # --- Varint (unsigned LEB128) ---
  #
  # The default integer encoding in the Yjs wire format. Each byte
  # holds 7 data bits; the high bit is set if more bytes follow
  # (little-endian groups). The decoder accumulates 7-bit chunks at
  # increasing left-shifts until the continuation bit is clear.
  # Values < 128 fit in one byte, covering the common case of small
  # clocks and lengths.

  @doc """
  Encodes a non-negative integer as an unsigned LEB128 varint.

  Seven data bits per byte; the high bit signals that more bytes
  follow. Output ranges from 1 byte (values < 128) to 10 bytes (full
  64-bit integers).
  """
  def encode_uint(n) when n < 128, do: <<n>>

  def encode_uint(n) do
    <<1::1, Bitwise.band(n, 0x7F)::7, encode_uint(Bitwise.bsr(n, 7))::binary>>
  end

  @doc """
  Decodes an unsigned LEB128 varint from the head of `binary`.
  Returns `{value, rest}` where `rest` is the unconsumed tail.
  """
  def decode_uint(binary), do: decode_uint(binary, 0, 0)

  defp decode_uint(<<0::1, value::7, rest::binary>>, acc, shift) do
    {acc + Bitwise.bsl(value, shift), rest}
  end

  defp decode_uint(<<1::1, value::7, rest::binary>>, acc, shift) do
    decode_uint(rest, acc + Bitwise.bsl(value, shift), shift + 7)
  end

  # --- Signed varint (zigzag encoding) ---
  #
  # Maps signed integers onto unsigned ones by interleaving:
  #   0→0, -1→1, 1→2, -2→3, 2→4, …
  # Without this, a naive sign-extended representation would expand
  # small negative values to ten bytes. Used where the Yjs wire format
  # calls for a signed varint via the zigzag convention (distinct from
  # the lib0 writeVarInt sign-bit approach used in Any encoding).

  @doc "Encodes a signed integer as zigzag-mapped LEB128."
  def encode_sint(n) when n >= 0, do: encode_uint(Bitwise.bsl(n, 1))
  def encode_sint(n), do: encode_uint(Bitwise.bxor(Bitwise.bsl(n, 1), -1))

  @doc "Decodes a zigzag-encoded signed varint. Returns `{value, rest}`."
  def decode_sint(binary) do
    {n, rest} = decode_uint(binary)

    if Bitwise.band(n, 1) == 1 do
      {-Bitwise.bsr(n, 1) - 1, rest}
    else
      {Bitwise.bsr(n, 1), rest}
    end
  end

  # --- lib0 writeVarInt / readVarInt ---
  #
  # Used only for integer values in lib0 Any encoding (tag 125). Layout
  # differs from both LEB128 and zigzag:
  #   First byte:       bit 7 = continue, bit 6 = sign (negative), bits 0–5 = 6 data bits
  #   Subsequent bytes: bit 7 = continue, bits 0–6 = 7 data bits

  defp encode_var_int(n) when n >= 0 do
    if n > 63 do
      <<Bitwise.bor(128, Bitwise.band(n, 63))>> <> encode_var_int_rest(Bitwise.bsr(n, 6))
    else
      <<Bitwise.band(n, 63)>>
    end
  end

  defp encode_var_int(n) when n < 0 do
    abs_n = -n

    if abs_n > 63 do
      <<Bitwise.bor(128, Bitwise.bor(64, Bitwise.band(abs_n, 63)))>> <>
        encode_var_int_rest(Bitwise.bsr(abs_n, 6))
    else
      <<Bitwise.bor(64, Bitwise.band(abs_n, 63))>>
    end
  end

  defp encode_var_int_rest(n) when n <= 127, do: <<Bitwise.band(n, 127)>>

  defp encode_var_int_rest(n) do
    <<Bitwise.bor(128, Bitwise.band(n, 127))>> <> encode_var_int_rest(Bitwise.bsr(n, 7))
  end

  defp decode_var_int(<<byte, rest::binary>>) do
    num = Bitwise.band(byte, 63)
    is_negative = Bitwise.band(byte, 64) != 0
    has_more = Bitwise.band(byte, 128) != 0

    {num, rest} =
      if has_more, do: decode_var_int_rest(rest, num, 6), else: {num, rest}

    {if(is_negative, do: -num, else: num), rest}
  end

  defp decode_var_int_rest(<<byte, rest::binary>>, num, shift) do
    num = num + Bitwise.bsl(Bitwise.band(byte, 127), shift)

    if Bitwise.band(byte, 128) != 0 do
      decode_var_int_rest(rest, num, shift + 7)
    else
      {num, rest}
    end
  end

  # --- String ---

  @doc """
  Encodes a string as `<varint byte_len, bytes::binary>`. The length
  prefix counts UTF-8 bytes, not codepoints. The bytes are written
  verbatim.
  """
  def encode_string(s) do
    bytes = :erlang.iolist_to_binary(s)
    <<encode_uint(byte_size(bytes))::binary, bytes::binary>>
  end

  @doc "Decodes a length-prefixed UTF-8 string. Returns `{string, rest}`."
  def decode_string(binary) do
    {len, rest} = decode_uint(binary)
    <<s::binary-size(len), rest2::binary>> = rest
    {s, rest2}
  end

  # --- State Vector ---
  #
  # Wire format: `varint count` followed by `count` pairs of
  # `(varint client_id, varint clock)`. Pair order is unspecified —
  # decoders rebuild a Map, so it doesn't matter. This differs from
  # the delete set, where client order is load-bearing for
  # byte-determinism (it ends up in a hashed update payload).

  @doc """
  Encodes a `Yelixer.StateVector` to its wire format:
  `<varint num_clients, repeated (varint client, varint clock)>`.

  The state vector is the minimum "what I have" summary. Sync
  handshakes send it first so the responder can compute the diff.
  """
  def encode_state_vector(%StateVector{clocks: clocks}) do
    count = map_size(clocks)

    pairs =
      Enum.reduce(clocks, <<>>, fn {client, clock}, acc ->
        <<acc::binary, encode_uint(client)::binary, encode_uint(clock)::binary>>
      end)

    <<encode_uint(count)::binary, pairs::binary>>
  end

  @doc """
  Decodes a state vector from `binary`. Returns `{:ok, {sv, rest}}`
  on success or `{:error, {:malformed_state_vector, msg}}` on a
  truncated or otherwise invalid payload.

  One of two functions here that wraps decoding in a `try/rescue` (the
  other is `decode_update`). Most decoders crash on malformed input,
  assuming the caller has already framed the bytes; state vectors
  arrive raw from a peer, so errors are caught and returned instead.
  """
  def decode_state_vector(binary) do
    try do
      {count, rest} = decode_uint(binary)
      {sv, rest} = decode_sv_pairs(rest, count, StateVector.new())
      {:ok, {sv, rest}}
    rescue
      e in [MatchError, FunctionClauseError, ArgumentError] ->
        {:error, {:malformed_state_vector, Exception.message(e)}}
    end
  end

  defp decode_sv_pairs(rest, 0, sv), do: {sv, rest}

  defp decode_sv_pairs(binary, remaining, sv) do
    {client, rest} = decode_uint(binary)
    {clock, rest} = decode_uint(rest)
    decode_sv_pairs(rest, remaining - 1, StateVector.set(sv, client, clock))
  end

  # --- Delete Set ---
  #
  # Format: varint num_clients, then per client:
  #   varint client_id, varint num_ranges, then per range:
  #     varint clock_start, varint length
  #
  # Mirrors the in-memory `Yelixer.DeleteSet` shape — a per-client
  # list of intervals — but encodes each range as (start, length)
  # rather than (start, stop), because lengths are typically small
  # varints while stop clocks can be large.

  @doc """
  Encodes a `Yelixer.DeleteSet` to its wire format.

  Emits clients in **descending** client_id order. This is
  load-bearing for byte-determinism: without it, two peers holding
  the same logical delete set could produce different bytes because
  Elixir's map iteration order is unspecified. See the moduledoc for
  the full determinism argument.
  """
  def encode_delete_set(%DeleteSet{clients: clients}) do
    count = map_size(clients)

    # Sort descending to match encode_diff's struct-section order.
    # Without this, encode_update/1 is not byte-deterministic across
    # peers — Elixir's map iteration order is unspecified.
    sorted_clients = Enum.sort_by(clients, fn {client, _} -> client end, :desc)

    body =
      Enum.reduce(sorted_clients, <<>>, fn {client, ranges}, acc ->
        num_ranges = length(ranges)

        ranges_bin =
          Enum.reduce(ranges, <<>>, fn {start, stop}, racc ->
            <<racc::binary, encode_uint(start)::binary, encode_uint(stop - start)::binary>>
          end)

        <<acc::binary, encode_uint(client)::binary, encode_uint(num_ranges)::binary,
          ranges_bin::binary>>
      end)

    <<encode_uint(count)::binary, body::binary>>
  end

  @doc """
  Decodes a delete set from `binary`. Returns `{ds, rest}`.

  Each range is encoded as `(clock_start, length)` and fed to
  `DeleteSet.insert/4`, which maintains the sorted-disjoint invariant
  by merging any overlapping ranges automatically.
  """
  def decode_delete_set(binary) do
    {count, rest} = decode_uint(binary)
    assert_sane_count!(count, rest, "delete set client count")
    decode_ds_clients(rest, count, DeleteSet.new())
  end

  defp decode_ds_clients(rest, 0, ds), do: {ds, rest}

  defp decode_ds_clients(binary, remaining, ds) do
    {client, rest} = decode_uint(binary)
    {num_ranges, rest} = decode_uint(rest)
    assert_sane_count!(num_ranges, rest, "delete set range count")
    {ds, rest} = decode_ds_ranges(rest, num_ranges, ds, client)
    decode_ds_clients(rest, remaining - 1, ds)
  end

  defp decode_ds_ranges(rest, 0, ds, _client), do: {ds, rest}

  defp decode_ds_ranges(binary, remaining, ds, client) do
    {clock, rest} = decode_uint(binary)
    {len, rest} = decode_uint(rest)
    assert_clock_bound!(clock + len, "delete set range (client #{client}, start #{clock}, len #{len})")
    ds = DeleteSet.insert(ds, client, clock, len)
    decode_ds_ranges(rest, remaining - 1, ds, client)
  end

  # --- CX-wmtz: adversarial-input bounds ---
  #
  # Both helpers raise ArgumentError, which decode_update/1's rescue
  # clause (and decode_state_vector/1's, transitively, since it shares
  # decode_uint) already catches and reshapes into the tagged
  # {:malformed_update, reason} / {:malformed_state_vector, reason}
  # error the callers expect. Nothing else in this module needs to
  # change to surface these as rejections rather than crashes or
  # (worse) silent data corruption.

  # A varint count that claims more entries than there are bytes left
  # to hold them is definitely malformed — each entry needs at least
  # one byte. Catching this here means we fail fast instead of
  # recursing `count` times over a short (or empty) binary.
  defp assert_sane_count!(count, rest, label) do
    if count > byte_size(rest) do
      raise ArgumentError,
            "malformed #{label}: claims #{count} entries but only #{byte_size(rest)} bytes remain"
    end
  end

  # No legitimate Yjs client can produce a clock, length, or
  # clock+length beyond JS's Number.MAX_SAFE_INTEGER — see the
  # @max_safe_clock moduledoc note above.
  defp assert_clock_bound!(value, label) do
    if value > @max_safe_clock do
      raise ArgumentError,
            "malformed #{label}: value #{value} exceeds max safe clock #{@max_safe_clock}"
    end
  end

  # --- Update Encoding ---
  #
  # Format:
  #   varint num_clients
  #   for each client (descending client_id order):
  #     varint num_structs
  #     varint client_id
  #     varint first_clock
  #     for each struct:
  #       byte info:
  #         bits 0–4 = content_ref
  #         bit 5    = has_parent_sub
  #         bit 6    = has_right_origin
  #         bit 7    = has_origin
  #       [origin ID, if has_origin]
  #       [right_origin ID, if has_right_origin]
  #       [parent info, if neither origin nor right_origin]
  #       [parent_sub string, if has_parent_sub and no origin/right_origin]
  #       content payload
  #   delete_set

  @doc """
  Encodes the entire doc as a Yjs V1 update message.

  Equivalent to `encode_diff(doc, StateVector.new())` — diffing
  against an empty remote yields every item in the store. Used to
  initialize a new peer or to produce a canonical snapshot for content
  addressing (CX-umz / Build 5).
  """
  def encode_update(%Doc{} = doc) do
    encode_diff(doc, StateVector.new())
  end

  @doc """
  Encodes only the items `remote_sv` is missing, followed by the doc's
  full delete set.

  This drives a sync round: after receiving a peer's state vector, the
  local node calls `encode_diff(doc, peer_sv)` and ships the result.
  Three details worth noting:

    1. **Clients emitted in descending order** — determinism rule (1)
       from the moduledoc. Without it, byte order depends on map
       iteration, which is unspecified.
    2. **Blocks split at the remote clock boundary** — when a block
       straddles the cutoff (`clock < remote_clock < clock + len`),
       only its tail is encoded via `Item.split/2`.
    3. **Tombstoned items emit `:deleted` content** — the original
       payload is dropped but the ID-range slot is preserved, matching
       the in-memory `:deleted` content variant.
  """
  def encode_diff(%Doc{store: store, delete_set: ds}, %StateVector{} = remote_sv) do
    local_sv = BlockStore.state_vector(store)

    # Find clients where we have items the remote doesn't
    diff_clients =
      local_sv.clocks
      |> Enum.filter(fn {client, local_clock} ->
        StateVector.get(remote_sv, client) < local_clock
      end)
      |> Enum.sort_by(fn {client, _} -> client end, :desc)

    num_clients = length(diff_clients)

    # CX-xes3 (E3): `ds` is fixed for this whole call — build the
    # binary-search cache once instead of paying `DeleteSet.deleted?/3`'s
    # O(range count) linear scan per item below (a document with many
    # scattered/non-coalesced deletions on one client would otherwise
    # make this diff O(items * ranges) for that client).
    ds_cache = DeleteSet.range_cache(ds)

    structs_bin =
      Enum.reduce(diff_clients, <<>>, fn {client, _local_clock}, acc ->
        remote_clock = StateVector.get(remote_sv, client)
        # CX-w1fw: materialized *view* — recent pushes may still be
        # sitting in client_pending, not yet folded into store.clients.
        all_items = BlockStore.client_blocks(store, client)

        # Filter to items at or after the remote clock
        items =
          Enum.filter(all_items, fn item ->
            item.id.clock + item.length > remote_clock
          end)

        if items == [] do
          acc
        else
          first_clock = max(hd(items).id.clock, remote_clock)
          num_items = length(items)

          items_bin =
            Enum.reduce(items, <<>>, fn item, iacc ->
              item =
                if item.deleted or DeleteSet.deleted_in_cache?(ds_cache, item.id.client, item.id.clock) do
                  %{item | content: {:deleted, item.length}, deleted: true}
                else
                  item
                end

              if item.id.clock < remote_clock do
                # Partial item — only encode the portion after remote_clock
                offset = remote_clock - item.id.clock
                {_left, right} = Item.split(item, offset)
                <<iacc::binary, encode_item(right, store)::binary>>
              else
                <<iacc::binary, encode_item(item, store)::binary>>
              end
            end)

          <<acc::binary, encode_uint(num_items)::binary, encode_uint(client)::binary,
            encode_uint(first_clock)::binary, items_bin::binary>>
        end
      end)

    ds_bin = encode_delete_set(ds)

    <<encode_uint(num_clients)::binary, structs_bin::binary, ds_bin::binary>>
  end

  defp encode_item(%Item{content: {:gc, n}}, _store) do
    # GC blocks: info byte 0 + length
    <<@content_ref_gc, encode_uint(n)::binary>>
  end

  defp encode_item(%Item{} = item, store) do
    content_ref = content_type_ref(item.content)

    # Remap origin/right_origin past any GC blocks to the nearest non-GC neighbor
    origin = remap_gc_origin(item.origin, store)
    right_origin = remap_gc_right_origin(item.right_origin, store)

    # parent_sub is only written when parent is also written explicitly
    # (no origin, no right_origin). When origin is set, parent_sub is
    # recovered during integration by inheriting from the origin item
    # via resolve_parent/2. This matches the yjs/yrs wire format.
    write_parent_sub? = item.parent_sub != nil and origin == nil and right_origin == nil

    info =
      content_ref
      |> Bitwise.bor(if origin != nil, do: @has_origin, else: 0)
      |> Bitwise.bor(if right_origin != nil, do: @has_right_origin, else: 0)
      |> Bitwise.bor(if write_parent_sub?, do: @has_parent_sub, else: 0)

    bin = <<info>>

    # Write origin
    bin =
      if origin != nil do
        <<bin::binary, encode_id(origin)::binary>>
      else
        bin
      end

    # Write right_origin
    bin =
      if right_origin != nil do
        <<bin::binary, encode_id(right_origin)::binary>>
      else
        bin
      end

    # Write parent if no origin and no right_origin
    bin =
      if origin == nil and right_origin == nil do
        case item.parent do
          {:named, name} ->
            <<bin::binary, encode_uint(1)::binary, encode_string(name)::binary>>

          {:id, id} ->
            <<bin::binary, encode_uint(0)::binary, encode_id(id)::binary>>
        end
      else
        bin
      end

    # Write parent_sub — only when we also wrote parent explicitly.
    bin =
      if write_parent_sub? do
        <<bin::binary, encode_string(item.parent_sub)::binary>>
      else
        bin
      end

    # Write content
    <<bin::binary, encode_content(item.content)::binary>>
  end

  # Remap origin through GC blocks only — not through deleted-but-live
  # items (those with `deleted: true` but intact content). Deleted-live
  # items still sit in the block store with valid position info; their
  # parent is recoverable through the YATA chain at decode time.
  # Walking across them during encoding can cross sequence boundaries
  # (e.g. from a "content" text item into a "root" map entry) and
  # corrupt the decoded parent assignment. (CX-2sv.)
  defp remap_gc_origin(nil, _store), do: nil

  defp remap_gc_origin(%ID{} = id, store) do
    case BlockStore.get(store, id) do
      %Item{content: {:gc, _}} ->
        # GC blocks have no content — walk back to the nearest non-GC
        # predecessor from the same client.
        blocks = BlockStore.client_blocks(store, id.client)

        blocks
        |> Enum.filter(fn
          %Item{content: {:gc, _}} -> false
          %Item{id: bid, length: len} -> bid.clock + len - 1 < id.clock
        end)
        |> List.last()
        |> case do
          nil -> nil
          %Item{id: bid, length: len} -> ID.new(bid.client, bid.clock + len - 1)
        end

      _ ->
        id
    end
  end

  # Clear right_origin only when it points to a GC block. Deleted-but-
  # live items are left intact — see the remap_gc_origin/2 comment.
  defp remap_gc_right_origin(nil, _store), do: nil

  defp remap_gc_right_origin(%ID{} = id, store) do
    case BlockStore.get(store, id) do
      %Item{content: {:gc, _}} -> nil
      _ -> id
    end
  end

  defp encode_id(%ID{client: client, clock: clock}) do
    <<encode_uint(client)::binary, encode_uint(clock)::binary>>
  end

  defp decode_id(binary) do
    {client, rest} = decode_uint(binary)
    {clock, rest} = decode_uint(rest)
    {ID.new(client, clock), rest}
  end

  defp content_type_ref({:gc, _}), do: @content_ref_gc
  defp content_type_ref({:deleted, _}), do: @content_ref_deleted
  defp content_type_ref({:json, _}), do: @content_ref_json
  defp content_type_ref({:binary, _}), do: @content_ref_binary
  defp content_type_ref({:string, _}), do: @content_ref_string
  defp content_type_ref({:embed, _}), do: @content_ref_embed
  defp content_type_ref({:format, _}), do: @content_ref_format
  defp content_type_ref({:type, _}), do: @content_ref_type
  defp content_type_ref({:any, _}), do: @content_ref_any

  defp encode_content({:gc, n}), do: encode_uint(n)
  defp encode_content({:string, s}), do: encode_string(s)
  defp encode_content({:deleted, n}), do: encode_uint(n)
  defp encode_content({:any, values}), do: encode_any_list(values)
  defp encode_content({:binary, b}), do: <<encode_uint(byte_size(b))::binary, b::binary>>
  defp encode_content({:embed, value}), do: encode_string(Jason.encode!(value))

  defp encode_content({:format, {key, value}}) do
    <<encode_string(key)::binary, encode_string(Jason.encode!(value))::binary>>
  end

  # ContentType wire format: a varint type ref, plus a tag-name string
  # when the type is XmlElement or XmlHook.
  # (Mirrors yjs `readTypeRef` / `readYXmlElement`.)
  defp encode_content({:type, {:xml_element, tag}}) do
    <<encode_uint(type_ref_to_int(:xml_element))::binary, encode_string(tag)::binary>>
  end

  defp encode_content({:type, type_ref}), do: encode_uint(type_ref_to_int(type_ref))
  defp encode_content({:json, values}), do: encode_json_list(values)

  # Encodes a length-prefixed list of lib0 Any values
  defp encode_any_list(values) do
    len = length(values)
    body = Enum.reduce(values, <<>>, fn v, acc -> <<acc::binary, encode_any(v)::binary>> end)
    <<encode_uint(len)::binary, body::binary>>
  end

  # --- lib0 Any encoding ---
  #
  # Used inside `:any` content variants and for embed/format payloads.
  # Provides a structured binary form for JSON-shaped data without
  # going through Jason. Each value is prefixed with a one-byte type
  # tag:
  #
  #   116 = buffer       117 = array         118 = object
  #   119 = string       120 = true          121 = false
  #   122 = bigint       123 = float64       124 = float32
  #   125 = integer (lib0 writeVarInt — sign-bit-in-byte-6 layout,
  #                  NOT zigzag; see encode_var_int/decode_var_int)
  #   126 = null         127 = undefined
  #
  # The lib0/yrs contract picks the tag that round-trips cleanly in
  # the originating language. Elixir doesn't distinguish float32 from
  # float64, so encode always emits float64 (tag 123); decode accepts
  # float32 (tag 124) and folds it into an Elixir float.
  defp encode_any(nil), do: <<126>>
  defp encode_any(true), do: <<120>>
  defp encode_any(false), do: <<121>>

  defp encode_any(n) when is_integer(n) do
    <<125, encode_var_int(n)::binary>>
  end

  defp encode_any(f) when is_float(f) do
    <<123, f::float-64>>
  end

  defp encode_any(s) when is_binary(s) do
    <<119, encode_string(s)::binary>>
  end

  defp encode_any(list) when is_list(list) do
    body = Enum.reduce(list, <<>>, fn v, acc -> <<acc::binary, encode_any(v)::binary>> end)
    <<117, encode_uint(length(list))::binary, body::binary>>
  end

  defp encode_any(map) when is_map(map) do
    body =
      Enum.reduce(map, <<>>, fn {k, v}, acc ->
        <<acc::binary, encode_string(to_string(k))::binary, encode_any(v)::binary>>
      end)

    <<118, encode_uint(map_size(map))::binary, body::binary>>
  end

  @doc "Encodes a value using lib0 Any encoding. Returns a binary."
  def encode_any_value(value), do: encode_any(value)

  @doc "Decodes a lib0 Any value from `binary`. Returns `{value, rest}`."
  def decode_any_value(binary), do: decode_any(binary)

  defp decode_any(<<127, rest::binary>>), do: {nil, rest}
  defp decode_any(<<126, rest::binary>>), do: {nil, rest}
  defp decode_any(<<120, rest::binary>>), do: {true, rest}
  defp decode_any(<<121, rest::binary>>), do: {false, rest}
  defp decode_any(<<123, f::float-64, rest::binary>>), do: {round_if_integer(f), rest}

  defp decode_any(<<124, f::float-32, rest::binary>>), do: {round_if_integer(f), rest}

  defp decode_any(<<125, rest::binary>>) do
    decode_var_int(rest)
  end

  defp decode_any(<<122, n::signed-64, rest::binary>>), do: {n, rest}

  defp decode_any(<<119, rest::binary>>) do
    decode_string(rest)
  end

  defp decode_any(<<117, rest::binary>>) do
    {len, rest} = decode_uint(rest)
    decode_any_list(rest, len, [])
  end

  defp decode_any(<<118, rest::binary>>) do
    {len, rest} = decode_uint(rest)
    decode_any_map(rest, len, %{})
  end

  defp decode_any(<<116, rest::binary>>) do
    {len, rest} = decode_uint(rest)
    <<buf::binary-size(len), rest2::binary>> = rest
    {buf, rest2}
  end

  defp decode_any_list(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_any_list(rest, n, acc) do
    {val, rest} = decode_any(rest)
    decode_any_list(rest, n - 1, [val | acc])
  end

  defp decode_any_map(rest, 0, acc), do: {acc, rest}

  defp decode_any_map(rest, n, acc) do
    {key, rest} = decode_string(rest)
    {val, rest} = decode_any(rest)
    decode_any_map(rest, n - 1, Map.put(acc, key, val))
  end

  defp round_if_integer(f) do
    rounded = round(f)
    if rounded == f, do: rounded, else: f
  end

  defp encode_json_list(values) do
    len = length(values)
    body = Enum.reduce(values, <<>>, fn v, acc -> <<acc::binary, encode_string(v)::binary>> end)
    <<encode_uint(len)::binary, body::binary>>
  end

  defp type_ref_to_int(:array), do: 0
  defp type_ref_to_int(:map), do: 1
  defp type_ref_to_int(:text), do: 2
  defp type_ref_to_int(:xml_element), do: 3
  defp type_ref_to_int(:xml_fragment), do: 4
  defp type_ref_to_int(:xml_hook), do: 5
  defp type_ref_to_int(:xml_text), do: 6
  defp type_ref_to_int(_), do: 0

  defp int_to_type_ref(0), do: :array
  defp int_to_type_ref(1), do: :map
  defp int_to_type_ref(2), do: :text
  defp int_to_type_ref(3), do: :xml_element
  defp int_to_type_ref(4), do: :xml_fragment
  defp int_to_type_ref(5), do: :xml_hook
  defp int_to_type_ref(6), do: :xml_text
  defp int_to_type_ref(_), do: :unknown

  # --- Update Decoding ---
  #
  # Decoding is more involved than encoding. Items arrive without
  # parent_sub when they have an origin (Yjs convention — see
  # encode_item); parent_sub is recovered during integration by
  # walking the origin chain via resolve_parent/2. Items whose
  # origin/right_origin hasn't arrived yet are deferred to a pending
  # list and retried after the rest of the batch is processed.
  #
  # CX-cdyi (H1): a batch that STILL has un-integratable items after
  # every within-batch retry is exhausted is no longer pushed into the
  # store raw. The store must only ever hold sequence-integrated
  # items — every derived state vector, encode_update/encode_diff, and
  # snapshot walks the store, so anything that lands there is
  # unconditionally treated as "fully seen." An un-integrated item in
  # the store therefore poisons the SV permanently (no future sync can
  # ever re-request its missing dependency) and makes encoded bytes
  # depend on delivery order (arrival-order-dependent CIDs). See
  # `Yelixer.Doc.pending_info/1` and the design doc at
  # docs/plans/2026-07-04-yelixer-h1-pending-buffer.md (commonplace-plan
  # repo) for the full writeup.

  @doc """
  Decodes a binary update (from `encode_update` or `encode_diff`),
  integrates the items into `doc`, and applies the delete set.

  Returns `{:ok, doc}` on success, `{:error, reason}` for a malformed
  payload, or `{:error, :pending_overflow}` if buffering this update's
  un-integratable remainder would exceed the pending-bytes cap (see
  below) — in the overflow case `doc` is returned to the caller
  UNCHANGED: nothing from this update is stored or buffered, and any
  previously-buffered blobs are untouched.

  After a successful apply:

    - new items are reachable via `Yelixer.BlockStore.get/2`
    - tombstones are present in `doc.delete_set`
    - the doc's state vector has advanced for each contributing client
    - any update content that couldn't fully integrate is parked in
      `doc.pending` (see `Yelixer.Doc.pending_info/1`) rather than
      being stored — the SV never advances past it

  ## Two-phase integration, then bounded blob buffering (H1)

  1. **First pass** — items are integrated in arrival order. Any item
     whose origin or right_origin hasn't been seen yet is deferred to
     a pending list rather than failing the entire apply.
  2. **Within-batch retry** — pending items are retried to a fixpoint;
     by then their dependencies may have arrived elsewhere in the
     batch.
  3. **Blob buffering** — if items remain un-integratable even after
     the within-batch retry, the ORIGINAL update binary (not the
     leftover items) is appended to `doc.pending`, bounded by
     `Application.get_env(:yelixer, :max_pending_bytes, 10_485_760)`
     total bytes. The items that DID integrate in this pass stay
     integrated; re-applying the whole blob later is idempotent via
     the existing fully-known-skip and partial-overlap-trim paths, so
     buffering the coarse original bytes (rather than a decoded
     remainder) costs nothing extra on retry.
  4. **Level-triggered retry** — at the end of every `apply_update/2`
     call (success or blob-buffered), every currently-pending blob is
     replayed through the same decode+integrate path. A blob that
     fully integrates (or whose remainder is now fully-known) leaves
     the buffer. This repeats to a fixpoint — integrating one blob can
     unlock another — stopping once a full pass advances no client's
     state vector.

  ## Delete-set merging (CX-w62) and the delete rider (H1)

  The decoded delete set is merged into `doc.delete_set`, not
  overwritten. Without this, a round-tripped doc would lose tombstones
  on re-encode, breaking byte-determinism and causing peers to
  "re-revive" deleted items on subsequent syncs.

  A delete for an item can arrive in an *earlier* update than the item
  itself — the delete merges into `doc.delete_set` unconditionally
  (CX-w62), so nothing rejects it just because its target isn't
  integrated yet. Without a rider, that item would RESURRECT the
  moment it later integrates (the two-phase integrator has no reason
  to consult old delete-set ranges for content it's only just
  learning about). So after every item newly integrates — whether in
  this batch's first pass, its within-batch retry, or a later pending
  retry — `doc.delete_set` is consulted for ranges covering it and
  `mark_deleted` is applied immediately if it's already tombstoned.
  """
  def apply_update(%Doc{} = doc, binary) do
    case decode_update(binary) do
      {:ok, {items, ds, _rest}} ->
        {new_doc, still_pending} = integrate_batch(doc, items, ds)

        if still_pending == [] do
          {:ok, retry_all_pending(new_doc)}
        else
          max_pending_bytes =
            Application.get_env(:yelixer, :max_pending_bytes, @default_max_pending_bytes)

          candidate_bytes = new_doc.pending_bytes + byte_size(binary)

          if candidate_bytes > max_pending_bytes do
            :telemetry.execute([:yelixer, :pending, :rejected], %{bytes: byte_size(binary)}, %{})
            {:error, :pending_overflow}
          else
            :telemetry.execute([:yelixer, :pending, :deferred], %{bytes: byte_size(binary)}, %{})

            new_doc = %{
              new_doc
              | pending: new_doc.pending ++ [binary],
                pending_bytes: candidate_bytes
            }

            {:ok, retry_all_pending(new_doc)}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Integrates one decoded batch (items + delete set) into `doc`,
  # returning `{doc, still_pending_items}`. `doc` is a value — nothing
  # is mutated in place — so callers that decide NOT to keep the
  # result (the pending_overflow path in `apply_update/2`) simply
  # discard it and the caller's original `doc` is untouched.
  defp integrate_batch(doc, items, ds) do
    sv = BlockStore.state_vector(doc.store)

    {doc, sv, pending_items} = integrate_items(items, doc, sv, [])

    # Retry within this batch to a fixpoint — dependencies may have
    # arrived elsewhere in the same update. Unlike the old
    # `retry_pending/3`, this NEVER pushes leftover items into the
    # store: whatever's still pending after the fixpoint is returned
    # to the caller, which either buffers the original blob (bounded)
    # or — for a retry-of-an-already-buffered-blob — leaves it be.
    {doc, _sv, still_pending} = retry_within_batch(doc, sv, pending_items)

    # Apply delete set: walk ranges, splitting blocks at deletion boundaries.
    #
    # CX-xes3 (E3): `ds` here is the WIRE update's delete set, which —
    # per `Yelixer.Encoding.encode_diff/2` — is the peer's entire
    # ACCUMULATED delete set, not a diff since the last sync (there's
    # no per-range provenance to diff against). Replaying a long edit
    # history one small update at a time therefore re-presents the
    # SAME, ever-growing range on every single call: without the skip
    # below, `apply_delete_range/4` would re-walk the WHOLE known
    # history block-by-block on every update — idempotent, but O(n)
    # redundant work per update, O(n²) across n updates. Real
    # histories are heavily self-adjacent (a key's overwrite deletes
    # the immediately-preceding clock — see `YMap.set/4` — so
    # `add_range/2`'s coalescing keeps `doc.delete_set` compact),
    # so `DeleteSet.skip_known_prefix/4` can jump straight past the
    # already-applied portion in O(log range count) and leave only the
    # genuinely new suffix (typically the single item this very update
    # added) for `apply_delete_range/4` to walk.
    doc =
      Enum.reduce(Map.to_list(ds.clients), doc, fn {client, ranges}, doc ->
        Enum.reduce(ranges, doc, fn {start, stop}, doc ->
          effective_start = DeleteSet.skip_known_prefix(doc.delete_set, client, start, stop)

          if effective_start >= stop do
            doc
          else
            store = apply_delete_range(doc.store, client, effective_start, stop - effective_start)
            %{doc | store: store}
          end
        end)
      end)

    # Merge incoming delete set into doc.delete_set so it survives re-encode.
    # Without this, a round-tripped doc loses its tombstones, breaking
    # byte-determinism across peers (CX-w62).
    doc = %{doc | delete_set: DeleteSet.merge(doc.delete_set, ds)}

    # The delete rider (H1, CX-cdyi): items that just integrated in
    # THIS pass may be covered by a delete that arrived in an earlier
    # update (already folded into doc.delete_set above). Consult it now
    # so late-arriving items don't resurrect. Items still in
    # `still_pending` never integrated, so they're excluded — walking
    # their clock range against the store would be unsafe (nothing to
    # find, or worse, a same-client block that happens to occupy that
    # id-space from an unrelated later item).
    pending_ids = MapSet.new(still_pending, & &1.id)
    integrated_items = Enum.reject(items, fn item -> MapSet.member?(pending_ids, item.id) end)
    doc = apply_delete_rider(doc, integrated_items)

    {doc, still_pending}
  end

  # Consults `doc.delete_set` for ranges covering each just-integrated
  # `item` and marks the overlap deleted. Safe to call redundantly —
  # `apply_delete_range/4` marking an already-deleted item is a no-op
  # in effect (idempotent), and a range with no overlap contributes
  # nothing (`Enum.filter` drops it before `apply_delete_range/4` is
  # ever called).
  defp apply_delete_rider(doc, items) do
    Enum.reduce(items, doc, fn item, doc ->
      case item.content do
        {:gc, _} ->
          doc

        _ ->
          ranges = Map.get(doc.delete_set.clients, item.id.client, [])
          item_start = item.id.clock
          item_end = item.id.clock + item.length

          ranges
          |> Enum.map(fn {s, e} -> {max(s, item_start), min(e, item_end)} end)
          |> Enum.filter(fn {s, e} -> s < e end)
          |> Enum.reduce(doc, fn {s, e}, doc ->
            store = apply_delete_range(doc.store, item.id.client, s, e - s)
            %{doc | store: store}
          end)
      end
    end)
  end

  # Replays every currently-buffered blob through `integrate_batch/3`
  # to a fixpoint. Level-triggered: a full pass over `doc.pending` that
  # advances no client's state vector means nothing more can happen
  # without new data, so we stop. A blob that fully integrates (no
  # items left pending) is dropped from the buffer; one that only
  # partially integrates stays — its progress is still committed to
  # `doc`, since re-applying it again later is idempotent (fully-known
  # items skip, partial overlaps trim).
  defp retry_all_pending(%Doc{pending: []} = doc), do: doc

  defp retry_all_pending(%Doc{pending: pending} = doc) do
    sv_before = BlockStore.state_vector(doc.store)

    {doc, remaining, integrated_bytes, integrated_count} = pending_pass(doc, pending)

    if integrated_count > 0 do
      :telemetry.execute(
        [:yelixer, :pending, :integrated],
        %{bytes: integrated_bytes},
        %{count: integrated_count}
      )
    end

    doc = %{
      doc
      | pending: remaining,
        pending_bytes: Enum.reduce(remaining, 0, &(byte_size(&1) + &2))
    }

    sv_after = BlockStore.state_vector(doc.store)

    if remaining != [] and sv_after != sv_before do
      retry_all_pending(doc)
    else
      doc
    end
  end

  defp pending_pass(doc, blobs) do
    {doc, remaining, cleared_bytes, cleared_count} =
      Enum.reduce(blobs, {doc, [], 0, 0}, fn blob, {doc, remaining, cleared_bytes, cleared_count} ->
        case decode_update(blob) do
          {:ok, {items, ds, _rest}} ->
            {doc, still_pending} = integrate_batch(doc, items, ds)

            if still_pending == [] do
              {doc, remaining, cleared_bytes + byte_size(blob), cleared_count + 1}
            else
              {doc, [blob | remaining], cleared_bytes, cleared_count}
            end

          {:error, _reason} ->
            # A blob we ourselves buffered should always decode; if it
            # somehow doesn't, drop it rather than looping on it forever.
            {doc, remaining, cleared_bytes, cleared_count}
        end
      end)

    {doc, Enum.reverse(remaining), cleared_bytes, cleared_count}
  end

  @doc """
  Namespace-aware variant of `apply_update/2` (CX-4l7u).

  Applies `binary` to `doc` exactly like `apply_update/2`, then
  records each new clientID from the update under `namespace_hash` in
  `doc.client_namespaces`. "New" means not already present — existing
  entries are never overwritten (first-writer-wins, preserving the
  provenance of whichever namespace first introduced a clientID).

  Provides an O(1) Doc-level index for membership queries; see
  `Yelixer.Doc.clientID_in_namespace?/3`. The commit-chain-walk
  validator in `Commonplace.Store.Namespace` remains authoritative for
  commit acceptance; this cache serves read paths that already hold a
  Doc and need a fast check.
  """
  @spec apply_update_in_namespace(Doc.t(), binary(), binary()) ::
          {:ok, Doc.t()} | {:error, term()}
  def apply_update_in_namespace(%Doc{} = doc, binary, namespace_hash)
      when is_binary(namespace_hash) do
    case decode_update(binary) do
      {:ok, {items, _ds, _rest}} ->
        update_client_ids =
          items
          |> Enum.map(& &1.id.client)
          |> MapSet.new()

        case apply_update(doc, binary) do
          {:ok, applied} ->
            {:ok, record_client_namespaces(applied, update_client_ids, namespace_hash)}

          {:error, _} = err ->
            err
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # First-writer-wins: only add a (client_id → namespace) entry when
  # client_id isn't already tracked, preserving the provenance of the
  # namespace that first introduced it.
  defp record_client_namespaces(%Doc{client_namespaces: existing} = doc, new_client_ids, namespace_hash) do
    updated =
      Enum.reduce(new_client_ids, existing, fn cid, acc ->
        case Map.fetch(acc, cid) do
          {:ok, _} -> acc
          :error -> Map.put(acc, cid, namespace_hash)
        end
      end)

    %{doc | client_namespaces: updated}
  end

  defp apply_delete_range(store, _client, _clock, 0), do: store

  defp apply_delete_range(store, client, clock, remaining) do
    case BlockStore.get(store, ID.new(client, clock)) do
      nil ->
        # No block covers `clock`. Rather than walking absent clocks
        # one at a time (CX-wmtz: a crafted delete-set range over
        # clocks that don't exist would otherwise make this recurse
        # `remaining` times — unbounded CPU), jump straight to the
        # next existing block's start clock, or bail if the range has
        # nothing left to find.
        range_end = clock + remaining
        {next_clock, store} = BlockStore.next_block_at_or_after(store, client, clock)

        case next_clock do
          nil ->
            store

          next when next >= range_end ->
            store

          next ->
            apply_delete_range(store, client, next, remaining - (next - clock))
        end

      %Item{deleted: true} = item ->
        # CX-xes3 (E3): already tombstoned — this clock's block was
        # handled by an earlier call (the `skip_known_prefix/4` check
        # in `integrate_batch/3` covers the common case; this covers
        # everything else, e.g. a range spanning several blocks where
        # only some were already deleted). No split/mark-deleted work
        # needed; skip the WHOLE block in one step rather than walking
        # it clock by clock.
        advance = min(item.length - (clock - item.id.clock), remaining)
        apply_delete_range(store, client, clock + advance, remaining - advance)

      item ->
        offset = clock - item.id.clock
        item_remaining = item.length - offset
        to_delete = min(remaining, item_remaining)

        # Split at start of deletion if needed
        store =
          if offset > 0 do
            split_in_clients(store, client, item, offset)
          else
            store
          end

        # Re-fetch after potential split
        item = BlockStore.get(store, ID.new(client, clock))

        # Split at end of deletion if needed
        store =
          if to_delete < item.length do
            split_in_clients(store, client, item, to_delete)
          else
            store
          end

        # Re-fetch and mark deleted
        item = BlockStore.get(store, ID.new(client, clock))
        store = mark_item_deleted(store, client, item)

        apply_delete_range(store, client, clock + to_delete, remaining - to_delete)
    end
  end

  # CX-w1fw: delete-range application is a direct-mutation path (it
  # reshapes clients[client] and a sequence with List.replace_at /
  # List.insert_at), so it needs the canonical, fully-materialized
  # lists — pending buffers folded in first — rather than the
  # materialized *view* helpers used by read-only callers.
  #
  # CX-xes3 (E3): this used to fold in and scan EVERY sequence
  # (`materialize_all_sequences` + `Enum.reduce(store.sequences, ...)`
  # with an `Enum.find_index/2` per sequence) to find the one sequence
  # containing `item.id` — O(total items across every type) per split.
  # A stored item's `parent` is already resolved by the time it reaches
  # here (integration resolves it before the item is ever pushed), so
  # `parent_type_key/1` names the one sequence that matters — touch
  # only that one.
  defp split_in_clients(store, client, item, offset) do
    store = BlockStore.materialize_client(store, client)
    type_key = parent_type_key(item)
    store = if type_key, do: BlockStore.materialize_sequence(store, type_key), else: store

    {left, right} = Item.split(item, offset)

    clients =
      Map.update!(store.clients, client, fn blocks ->
        {idx, _} = BlockStore.find_block_index(blocks, item.id.clock)

        blocks
        |> List.replace_at(idx, left)
        |> List.insert_at(idx + 1, right)
      end)

    {sequences, sequence_len} =
      case type_key && Map.get(store.sequences, type_key) do
        nil ->
          {store.sequences, store.sequence_len}

        seq ->
          case Enum.find_index(seq, &(&1 == item.id)) do
            nil ->
              {store.sequences, store.sequence_len}

            idx ->
              {Map.put(store.sequences, type_key, List.insert_at(seq, idx + 1, right.id)),
               Map.update(store.sequence_len, type_key, 1, &(&1 + 1))}
          end
      end

    store = %{store | clients: clients, sequences: sequences, sequence_len: sequence_len}
    store = BlockStore.invalidate_tuple_cache(store, client)
    # Splicing `right.id` in after `item.id` shifts every later index —
    # the cached reverse index (if any) for this sequence is now stale.
    store = if type_key, do: BlockStore.invalidate_sequence_index(store, type_key), else: store

    # Map items are length-1 and effectively never split, but if one
    # somehow is, don't let a stale live-id cache corrupt later
    # conflict resolution — drop it and let the next write to this key
    # rebuild it via the full scan.
    if type_key && item.parent_sub not in [nil, :inherit] do
      BlockStore.invalidate_map_index(store, type_key)
    else
      store
    end
  end

  # CX-xes3 (E3): switched from `refresh_tuple_cache/2` (rebuilds the
  # whole tuple, O(n)) to `invalidate_tuple_cache/2` (O(1) — the next
  # reader rebuilds lazily). `apply_delete_range/4` calls this once per
  # deleted sub-range within a client, so an update deleting many
  # ranges on one client no longer pays an O(n) tuple rebuild per range.
  # CX-xes3 (E3): `BlockStore.tombstone/2` defers this into an overlay
  # (O(log n)) instead of `materialize_client/2` + `List.replace_at/3`
  # (O(n), unavoidably — see its moduledoc) — `apply_delete_range/4`
  # calls this once per affected item, so a delete-set range spanning
  # many items on one client no longer costs O(n) each.
  defp mark_item_deleted(store, _client, item) do
    store = BlockStore.tombstone(store, item.id)

    # CX-xes3 (E4): only invalidate this map key's live-id cache if the
    # item we just tombstoned was the id `map_index` currently believes
    # is live for it. `integrate_items/5` runs before delete-set
    # application (see `integrate_batch/3`), so the overwhelmingly
    # common case — `YMap.set/4`'s own delete-range for the key's PRIOR
    # value — lands here *after* `maybe_resolve_map_conflict/3` has
    # already moved the key's live id on to the NEW item. Unconditional
    # invalidation (the old behavior) would throw that fresh, correct
    # entry away on every single write to a multi-key map, forcing a
    # full-sequence scan on the very next write — reintroducing the
    # O(n)-per-write cost this issue removed. Only a delete that
    # actually outruns resolution (e.g. a standalone `YMap.delete/3`)
    # needs the defensive drop, and only for this one key — not every
    # other key sharing `type_key`.
    case parent_type_key(item) do
      nil ->
        store

      type_key ->
        if item.parent_sub not in [nil, :inherit] and
             item.id in (BlockStore.map_live_ids(store, type_key, item.parent_sub) || []) do
          BlockStore.invalidate_map_index_key(store, type_key, item.parent_sub)
        else
          store
        end
    end
  end

  defp integrate_items(items, doc, sv, pending) do
    integrate_items(items, doc, sv, pending, MapSet.new())
  end

  defp integrate_items([], doc, sv, pending, _blocked_clients), do: {doc, sv, Enum.reverse(pending)}

  defp integrate_items([item | rest], doc, sv, pending, blocked_clients) do
    client = item.id.client
    client_clock = StateVector.get(sv, client)

    cond do
      # Client already has a pending item at a lower clock — defer all
      # subsequent items for this client to maintain contiguity (yrs behavior)
      MapSet.member?(blocked_clients, client) ->
        integrate_items(rest, doc, sv, [item | pending], blocked_clients)

      item.id.clock + item.length <= client_clock ->
        # Fully known — skip entirely
        integrate_items(rest, doc, sv, pending, blocked_clients)

      item.id.clock < client_clock ->
        # Partial overlap — trim the already-known portion and integrate the rest
        offset = client_clock - item.id.clock
        {_left, trimmed} = Item.split(item, offset)
        case try_integrate_item(trimmed, doc, sv) do
          {:ok, doc, sv} ->
            integrate_items(rest, doc, sv, pending, blocked_clients)

          :pending_dep ->
            integrate_items(rest, doc, sv, [trimmed | pending], MapSet.put(blocked_clients, client))

          :pending_parent ->
            integrate_items(rest, doc, sv, [trimmed | pending], blocked_clients)
        end

      true ->
        # Completely new — integrate as-is
        case try_integrate_item(item, doc, sv) do
          {:ok, doc, sv} ->
            integrate_items(rest, doc, sv, pending, blocked_clients)

          :pending_dep ->
            integrate_items(rest, doc, sv, [item | pending], MapSet.put(blocked_clients, client))

          :pending_parent ->
            integrate_items(rest, doc, sv, [item | pending], blocked_clients)
        end
    end
  end

  defp try_integrate_item(%Item{content: {:gc, _}} = item, doc, sv) do
    # GC blocks go directly into the store — they don't belong to a type sequence
    store = BlockStore.push(doc.store, item)
    sv = StateVector.advance(sv, item.id.client, item.id.clock + item.length)
    {:ok, %{doc | store: store}, sv}
  end

  defp try_integrate_item(item, doc, sv) do
    # Defer if a cross-client dependency (origin or right_origin) isn't
    # integrated yet — mirrors yrs Update::missing().
    if has_missing_dep?(item, sv) do
      :pending_dep
    else
      item = resolve_parent(item, doc.store)
      type_key = parent_type_key(item)

      case type_key do
        nil ->
          # Parent not yet resolvable — defer, but don't block this client
          :pending_parent

        key ->
          type_ref = infer_type_ref(item, doc)
          {doc, _} = Doc.get_or_create_type(doc, key, type_ref)
          doc = maybe_register_xml_child_type(doc, item, key)
          {:ok, store} = Integrate.integrate(doc.store, item, key)
          # Auto-delete map conflict losers (same key, competing items)
          store = maybe_resolve_map_conflict(store, item, key)
          sv = StateVector.advance(sv, item.id.client, item.id.clock + item.length)
          {:ok, %{doc | store: store}, sv}
      end
    end
  end

  defp has_missing_dep?(item, sv) do
    missing_ref?(item.origin, item.id.client, sv) or
      missing_ref?(item.right_origin, item.id.client, sv)
  end

  defp missing_ref?(nil, _item_client, _sv), do: false

  defp missing_ref?(%ID{client: client, clock: clock}, item_client, sv) do
    client != item_client and clock >= StateVector.get(sv, client)
  end

  # Map conflict resolution for items with parent_sub (map entries).
  # The rightmost item in the YATA sequence for a key wins; all other
  # non-deleted items for the same key are auto-deleted. Matches yrs.
  #
  # CX-xes3 (E4): the naive version of this walked the ENTIRE type
  # sequence with a `get/2` per element on every single integrated map
  # write — O(n) per write, O(k·n) for k writes to one map-heavy
  # document (schemas, presence, per-entity status docs are exactly
  # this shape; see `Yelixer.BlockStore.map_live_ids/3` moduledoc for
  # the measured blowup). `BlockStore.map_index` caches the live id(s)
  # per `{type_key, sub}` so repeat writes to the same key skip the
  # scan entirely:
  #
  #   - **Known + append** — the new item landed at the end of the
  #     sequence (the overwhelmingly common case: a client's own
  #     successive writes to a key). It is now the rightmost item for
  #     the key, so it wins outright — no scan, tombstone the cached
  #     losers directly.
  #   - **Known + not-append** — a concurrent/mid-history write. Scan
  #     the sequence once, but only looking for the handful of
  #     candidate ids (the new item plus the cached live ids), not a
  #     `get/2` per element.
  #   - **Unknown** — first time this key is touched (or a
  #     conservative invalidation dropped the entry). Falls back to
  #     the full O(n) scan, then populates the index so subsequent
  #     writes to the same key take the fast path.
  defp maybe_resolve_map_conflict(store, %Item{parent_sub: nil}, _type_key), do: store
  defp maybe_resolve_map_conflict(store, %Item{parent_sub: :inherit}, _type_key), do: store

  defp maybe_resolve_map_conflict(store, %Item{parent_sub: sub, id: item_id}, type_key) do
    case BlockStore.map_live_ids(store, type_key, sub) do
      nil ->
        resolve_map_conflict_full_scan(store, type_key, sub)

      known_ids ->
        if BlockStore.last_sequence_id(store, type_key) == item_id do
          losers = Enum.reject(known_ids, &(&1 == item_id))
          store = tombstone_losers(store, losers)
          BlockStore.put_map_live_ids(store, type_key, sub, [item_id])
        else
          resolve_map_conflict_candidates(store, type_key, sub, Enum.uniq([item_id | known_ids]))
        end
    end
  end

  # Full O(n) scan over `type_key`'s sequence — the cold path, taken
  # once per key (its result seeds `map_index` for every later write to
  # that key) and as the safety fallback after a conservative
  # invalidation.
  defp resolve_map_conflict_full_scan(store, type_key, sub) do
    store = BlockStore.materialize_sequence(store, type_key)
    seq_ids = Map.get(store.sequences, type_key, [])

    same_key_items =
      seq_ids
      |> Enum.with_index()
      |> Enum.filter(fn {seq_id, _idx} ->
        case BlockStore.get(store, seq_id) do
          %Item{parent_sub: ^sub, deleted: false} -> true
          _ -> false
        end
      end)

    settle_map_conflict(store, type_key, sub, same_key_items)
  end

  # Positional resolution restricted to a small candidate set (the new
  # item plus the ids `map_index` believes are still live). Walks the
  # sequence once, recording only candidate positions, with an early
  # exit once every candidate has been located.
  defp resolve_map_conflict_candidates(store, type_key, sub, candidate_ids) do
    store = BlockStore.materialize_sequence(store, type_key)
    seq_ids = Map.get(store.sequences, type_key, [])
    candidate_set = MapSet.new(candidate_ids)
    total = MapSet.size(candidate_set)

    {positions, _remaining} =
      Enum.reduce_while(seq_ids, {[], total}, fn seq_id, {found, remaining} ->
        cond do
          remaining <= 0 ->
            {:halt, {found, remaining}}

          MapSet.member?(candidate_set, seq_id) ->
            {:cont, {[seq_id | found], remaining - 1}}

          true ->
            {:cont, {found, remaining}}
        end
      end)

    same_key_items =
      positions
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.filter(fn {seq_id, _idx} ->
        case BlockStore.get(store, seq_id) do
          %Item{parent_sub: ^sub, deleted: false} -> true
          _ -> false
        end
      end)

    case same_key_items do
      [] ->
        # A candidate vanished from the sequence entirely (shouldn't
        # happen — `map_index` only ever names ids from this same
        # type_key — but fall back to a full scan rather than leave a
        # stale/empty entry behind).
        resolve_map_conflict_full_scan(store, type_key, sub)

      items ->
        settle_map_conflict(store, type_key, sub, items)
    end
  end

  # Shared settle step: highest-index item wins, everything else in
  # the candidate set is tombstoned, and the winner alone is cached.
  defp settle_map_conflict(store, type_key, sub, []) do
    BlockStore.put_map_live_ids(store, type_key, sub, [])
  end

  defp settle_map_conflict(store, type_key, sub, indexed_items) do
    {winner_id, winner_idx} = Enum.max_by(indexed_items, fn {_id, idx} -> idx end)

    losers =
      indexed_items
      |> Enum.reject(fn {_id, idx} -> idx == winner_idx end)
      |> Enum.map(fn {id, _idx} -> id end)

    store = tombstone_losers(store, losers)
    BlockStore.put_map_live_ids(store, type_key, sub, [winner_id])
  end

  # Tombstones every id in `loser_ids`. `BlockStore.tombstone/2` defers
  # each into an overlay (O(log n)) rather than materializing the
  # loser's client bucket and `List.replace_at/3`-ing it (O(n) per
  # loser, unavoidably) — see its moduledoc. This matters most exactly
  # where map-conflict resolution runs hottest: many sequential
  # overwrites of the same key from one client, where every loser
  # lives in the SAME (large, growing) client bucket.
  defp tombstone_losers(store, loser_ids) do
    Enum.reduce(loser_ids, store, fn loser_id, store ->
      BlockStore.tombstone(store, loser_id)
    end)
  end

  defp infer_type_ref(%Item{parent: {:id, %ID{} = id}}, %Doc{store: store}) do
    case BlockStore.get(store, id) do
      %Item{content: {:type, ref}} -> ref
      _ -> :unknown
    end
  end

  defp infer_type_ref(_, _), do: :unknown

  # When integrating an XML child item (content `{:type, ref}` in a
  # `*::children` sequence), register its synthetic child name
  # (`parent::child::CLIENT:CLOCK`) in the doc's `types` map. Without
  # this, XMLElement tags and children are unrecoverable from the wire,
  # which carries items only, not doc-level type registrations.
  defp maybe_register_xml_child_type(doc, %Item{content: {:type, ref}, id: id} = _item, key) do
    case String.split(key, "::children", parts: 2) do
      [parent_name, ""] ->
        child_name = "#{parent_name}::child::#{id.client}:#{id.clock}"
        {doc, _} = Doc.get_or_create_type(doc, child_name, ref)
        doc

      _ ->
        doc
    end
  end

  defp maybe_register_xml_child_type(doc, _item, _key), do: doc

  # CX-cdyi (H1): retries pending items to a fixpoint WITHOUT ever
  # pushing a no-progress remainder into the store. The old
  # `retry_pending/3` did exactly that in its "no progress" branch —
  # items that still couldn't integrate were `BlockStore.push`ed raw
  # and the state vector advanced past them, which is the defect this
  # rewrite closes (see the moduledoc above `apply_update/2`). Callers
  # now own the decision of what to do with a non-empty remainder:
  # `integrate_batch/3` returns it so `apply_update/2` can buffer the
  # original blob instead.
  defp retry_within_batch(doc, sv, []), do: {doc, sv, []}

  defp retry_within_batch(doc, sv, pending) do
    {doc, sv, still_pending} = integrate_items(pending, doc, sv, [])

    if length(still_pending) < length(pending) do
      # Progress made — retry the remainder
      retry_within_batch(doc, sv, still_pending)
    else
      {doc, sv, still_pending}
    end
  end

  defp parent_type_key(%Item{parent: {:named, name}}), do: name
  defp parent_type_key(%Item{parent: {:id, %ID{client: c, clock: k}}}), do: "__sub:#{c}:#{k}"
  defp parent_type_key(_), do: nil

  defp resolve_parent(%Item{parent: {:infer, ref_id}} = item, store) when not is_nil(ref_id) do
    case BlockStore.get(store, ref_id) do
      nil ->
        item

      ref_item ->
        # Inherit parent_sub from the origin/right_origin item when:
        #   - the item is marked :inherit (legacy path), or
        #   - the item has nil parent_sub and the origin's parent_sub is
        #     set — how map-conflict items recover their key name after
        #     decoding (the wire format only writes parent_sub on the
        #     root item of each chain).
        item =
          cond do
            item.parent_sub == :inherit ->
              %{item | parent_sub: ref_item.parent_sub}

            item.parent_sub == nil and ref_item.parent_sub != nil ->
              %{item | parent_sub: ref_item.parent_sub}

            true ->
              item
          end

        case ref_item.parent do
          {:gc_placeholder, _} ->
            case find_parent_from_siblings(store, ref_id.client) do
              nil -> item
              parent -> %{item | parent: parent}
            end

          parent ->
            %{item | parent: parent}
        end
    end
  end

  defp resolve_parent(item, _store), do: item

  defp find_parent_from_siblings(store, client) do
    store
    |> BlockStore.client_blocks(client)
    |> Enum.find_value(fn item ->
      case item.parent do
        {:named, _} = p -> p
        {:id, _} = p -> p
        _ -> nil
      end
    end)
  end

  def decode_update(binary) do
    try do
      {num_clients, rest} = decode_uint(binary)
      assert_sane_count!(num_clients, rest, "update client count")
      {items, rest} = decode_clients(rest, num_clients, [])
      {ds, rest} = decode_delete_set(rest)
      {:ok, {items, ds, rest}}
    rescue
      # Malformed bytes can raise several exception types: MatchError
      # (pattern failures), FunctionClauseError (unknown content refs),
      # ArgumentError (varint/string overflows), Jason.DecodeError
      # (invalid embedded JSON). Catch all of them and return a typed
      # tuple so callers (MCP, sync agent) can trust this never raises.
      e ->
        {:error, {:malformed_update, Exception.message(e)}}
    end
  end

  @doc """
  Returns all clientIDs referenced by a Yjs V1 update binary, without
  applying it to a doc.

  Scans both the items list and the delete set — an update that only
  deletes still carries clientID membership via its delete set.

  Returns `{:ok, MapSet.t(non_neg_integer())}` or `{:error, reason}`
  for a malformed binary.
  """
  @spec update_client_ids(binary()) ::
          {:ok, MapSet.t()} | {:error, {:malformed_update, String.t()}}
  def update_client_ids(binary) do
    case decode_update(binary) do
      {:ok, {items, delete_set, _rest}} ->
        item_ids = Enum.reduce(items, MapSet.new(), fn it, acc -> MapSet.put(acc, it.id.client) end)

        ds_ids =
          delete_set.clients
          |> Map.keys()
          |> MapSet.new()

        {:ok, MapSet.union(item_ids, ds_ids)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Partitions the clientIDs in a Yjs V1 update binary by role
  (CX-fbs6), without applying the update.

  Returns `{:ok, %{authorship: MapSet, reference: MapSet}}` where:

  - `:authorship` — clientIDs that own newly-inserted items
    (`item.id.client` for non-GC structs). These extend the namespace
    when the commit lands.
  - `:reference` — clientIDs appearing as anchors only: item `origin`,
    `right_origin`, `{:id, _}` parent, and delete-set targets. These
    must already resolve within the namespace.

  Used by the Commonplace namespace validator to separate the
  subset-check (references) from namespace extension (authorship).
  See `Commonplace.Store.Namespace.validate_commit/2`.
  """
  @spec update_client_ids_by_role(binary()) ::
          {:ok, %{authorship: MapSet.t(), reference: MapSet.t()}}
          | {:error, {:malformed_update, String.t()}}
  def update_client_ids_by_role(binary) do
    case decode_update(binary) do
      {:ok, {items, delete_set, _rest}} ->
        {authorship, reference} =
          Enum.reduce(items, {MapSet.new(), MapSet.new()}, fn item, {auth, ref} ->
            {put_authorship(auth, item), put_refs(ref, item)}
          end)

        reference =
          delete_set.clients
          |> Map.keys()
          |> Enum.reduce(reference, &MapSet.put(&2, &1))

        {:ok, %{authorship: authorship, reference: reference}}

      {:error, _} = err ->
        err
    end
  end

  defp put_authorship(acc, %Item{content: {:gc, _}}), do: acc
  defp put_authorship(acc, %Item{id: %ID{client: client}}), do: MapSet.put(acc, client)

  defp put_refs(acc, %Item{} = item) do
    acc
    |> put_id_client(item.origin)
    |> put_id_client(item.right_origin)
    |> put_parent_client(item.parent)
  end

  defp put_id_client(acc, nil), do: acc
  defp put_id_client(acc, %ID{client: client}), do: MapSet.put(acc, client)

  defp put_parent_client(acc, {:id, %ID{client: client}}), do: MapSet.put(acc, client)
  defp put_parent_client(acc, _), do: acc

  defp decode_clients(rest, 0, acc), do: {acc, rest}

  defp decode_clients(binary, remaining, acc) do
    {num_structs, rest} = decode_uint(binary)
    {client, rest} = decode_uint(rest)
    {first_clock, rest} = decode_uint(rest)
    assert_sane_count!(num_structs, rest, "update struct count (client #{client})")
    assert_clock_bound!(first_clock, "first_clock (client #{client})")
    {items, rest} = decode_structs(rest, num_structs, client, first_clock, [])
    decode_clients(rest, remaining - 1, acc ++ items)
  end

  defp decode_structs(rest, 0, _client, _clock, acc), do: {Enum.reverse(acc), rest}

  defp decode_structs(binary, remaining, client, clock, acc) do
    {item, rest, next_clock} = decode_struct(binary, client, clock)
    decode_structs(rest, remaining - 1, client, next_clock, [item | acc])
  end

  defp decode_struct(<<@content_ref_gc, rest::binary>>, client, clock) do
    # GC blocks: info byte 0 + length only — no origin, parent, or content
    {len, rest} = decode_uint(rest)
    assert_clock_bound!(clock + len, "gc block (client #{client}, clock #{clock}, len #{len})")
    item = Item.new(ID.new(client, clock), nil, nil, {:gc, len}, {:gc_placeholder, nil}, nil)
    {item, rest, clock + len}
  end

  defp decode_struct(<<info, rest::binary>>, client, clock) do
    content_ref = Bitwise.band(info, 0x1F)
    has_origin = Bitwise.band(info, @has_origin) != 0
    has_right_origin = Bitwise.band(info, @has_right_origin) != 0
    has_parent_sub = Bitwise.band(info, @has_parent_sub) != 0

    {origin, rest} =
      if has_origin, do: decode_id(rest), else: {nil, rest}

    {right_origin, rest} =
      if has_right_origin, do: decode_id(rest), else: {nil, rest}

    # Parent is explicit only when both origin and right_origin are absent.
    # When either is present, parent is inferred from it during integration.
    {parent, rest} =
      if origin == nil and right_origin == nil do
        {parent_info, rest} = decode_uint(rest)

        if parent_info == 1 do
          {name, rest} = decode_string(rest)
          {{:named, name}, rest}
        else
          {id, rest} = decode_id(rest)
          {{:id, id}, rest}
        end
      else
        {{:infer, origin || right_origin}, rest}
      end

    # parent_sub is only in the stream when parent is explicit (no origin/right_origin).
    # Items with an origin inherit parent_sub from it via resolve_parent/2.
    {parent_sub, rest} =
      if has_parent_sub and origin == nil and right_origin == nil do
        decode_string(rest)
      else
        {nil, rest}
      end

    {content, rest} = decode_content(rest, content_ref)

    item = Item.new(ID.new(client, clock), origin, right_origin, content, parent, parent_sub)

    # Flag was set but parent_sub wasn't written — mark for inheritance
    item =
      if has_parent_sub and parent_sub == nil do
        %{item | parent_sub: :inherit}
      else
        item
      end
    next_clock = clock + item.length

    assert_clock_bound!(next_clock, "item (client #{client}, clock #{clock}, length #{item.length})")

    {item, rest, next_clock}
  end

  defp decode_content(rest, @content_ref_string) do
    {s, rest} = decode_string(rest)
    {{:string, s}, rest}
  end

  defp decode_content(rest, @content_ref_deleted) do
    {n, rest} = decode_uint(rest)
    {{:deleted, n}, rest}
  end

  defp decode_content(rest, @content_ref_any) do
    {len, rest} = decode_uint(rest)
    {values, rest} = decode_any_list(rest, len, [])
    {{:any, values}, rest}
  end

  defp decode_content(rest, @content_ref_binary) do
    {len, rest} = decode_uint(rest)
    <<b::binary-size(len), rest2::binary>> = rest
    {{:binary, b}, rest2}
  end

  defp decode_content(rest, @content_ref_type) do
    {ref_int, rest} = decode_uint(rest)

    case int_to_type_ref(ref_int) do
      :xml_element ->
        # XmlElement: tag-name string follows the type ref integer
        {tag, rest} = decode_string(rest)
        {{:type, {:xml_element, tag}}, rest}

      ref ->
        {{:type, ref}, rest}
    end
  end

  defp decode_content(rest, @content_ref_json) do
    {len, rest} = decode_uint(rest)
    {values, rest} = decode_json_list(rest, len, [])
    {{:json, values}, rest}
  end

  defp decode_content(rest, @content_ref_embed) do
    {s, rest} = decode_string(rest)
    {{:embed, Jason.decode!(s)}, rest}
  end

  defp decode_content(rest, @content_ref_format) do
    {key, rest} = decode_string(rest)
    {value_str, rest} = decode_string(rest)
    {{:format, {key, Jason.decode!(value_str)}}, rest}
  end

  defp decode_json_list(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_json_list(rest, n, acc) do
    {s, rest} = decode_string(rest)
    decode_json_list(rest, n - 1, [s | acc])
  end
end
