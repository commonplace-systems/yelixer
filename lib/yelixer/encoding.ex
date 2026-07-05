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
                if item.deleted or DeleteSet.deleted?(ds, item.id.client, item.id.clock) do
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

  @doc """
  Decodes a binary update (from `encode_update` or `encode_diff`),
  integrates the items into `doc`, and applies the delete set.

  Returns `{:ok, doc}` on success or `{:error, reason}` for a
  malformed payload. After a successful apply:

    - new items are reachable via `Yelixer.BlockStore.get/2`
    - tombstones are present in `doc.delete_set`
    - the doc's state vector has advanced for each contributing client

  ## Two-phase integration

  1. **First pass** — items are integrated in arrival order. Any item
     whose origin or right_origin hasn't been seen yet is deferred to
     a pending list rather than failing the entire apply.
  2. **Retry** — after the first pass, pending items are retried; by
     then their dependencies may have arrived elsewhere in the batch.

  ## Delete-set merging (CX-w62)

  The decoded delete set is merged into `doc.delete_set`, not
  overwritten. Without this, a round-tripped doc would lose tombstones
  on re-encode, breaking byte-determinism and causing peers to
  "re-revive" deleted items on subsequent syncs.
  """
  def apply_update(%Doc{} = doc, binary) do
    case decode_update(binary) do
      {:ok, {items, ds, _rest}} ->
        sv = BlockStore.state_vector(doc.store)

        {doc, sv, pending} = integrate_items(items, doc, sv, [])

        # Retry items deferred in the first pass — dependencies may now be present
        {doc, _sv} = retry_pending(doc, sv, pending)

        # Apply delete set: walk ranges, splitting blocks at deletion boundaries
        doc =
          Enum.reduce(Map.to_list(ds.clients), doc, fn {client, ranges}, doc ->
            Enum.reduce(ranges, doc, fn {start, stop}, doc ->
              store = apply_delete_range(doc.store, client, start, stop - start)
              %{doc | store: store}
            end)
          end)

        # Merge incoming delete set into doc.delete_set so it survives re-encode.
        # Without this, a round-tripped doc loses its tombstones, breaking
        # byte-determinism across peers (CX-w62).
        doc = %{doc | delete_set: DeleteSet.merge(doc.delete_set, ds)}

        {:ok, doc}

      {:error, reason} ->
        {:error, reason}
    end
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
  # reshapes clients[client] and every sequence with List.replace_at /
  # List.insert_at), so it needs the canonical, fully-materialized
  # lists — pending buffers folded in first — rather than the
  # materialized *view* helpers used by read-only callers.
  defp split_in_clients(store, client, item, offset) do
    store = BlockStore.materialize_client(store, client)
    store = BlockStore.materialize_all_sequences(store)

    {left, right} = Item.split(item, offset)

    clients =
      Map.update!(store.clients, client, fn blocks ->
        {idx, _} = BlockStore.find_block_index(blocks, item.id.clock)

        blocks
        |> List.replace_at(idx, left)
        |> List.insert_at(idx + 1, right)
      end)

    # Update sequences too, if the item is present in one
    {sequences, sequence_len} =
      Enum.reduce(store.sequences, {store.sequences, store.sequence_len}, fn {type_key, seq}, {sequences, lens} ->
        case Enum.find_index(seq, &(&1 == item.id)) do
          nil ->
            {sequences, lens}

          idx ->
            {Map.put(sequences, type_key, List.insert_at(seq, idx + 1, right.id)),
             Map.update(lens, type_key, 1, &(&1 + 1))}
        end
      end)

    %{store | clients: clients, sequences: sequences, sequence_len: sequence_len}
    |> BlockStore.refresh_tuple_cache(client)
  end

  defp mark_item_deleted(store, client, item) do
    store = BlockStore.materialize_client(store, client)

    clients =
      Map.update!(store.clients, client, fn blocks ->
        {idx, _} = BlockStore.find_block_index(blocks, item.id.clock)
        List.replace_at(blocks, idx, %{item | deleted: true})
      end)

    %{store | clients: clients}
    |> BlockStore.refresh_tuple_cache(client)
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
  defp maybe_resolve_map_conflict(store, %Item{parent_sub: nil}, _type_key), do: store
  defp maybe_resolve_map_conflict(store, %Item{parent_sub: :inherit}, _type_key), do: store

  defp maybe_resolve_map_conflict(store, %Item{parent_sub: sub}, type_key) do
    store = BlockStore.materialize_sequence(store, type_key)
    seq_ids = Map.get(store.sequences, type_key, [])

    # All non-deleted items sharing this parent_sub, with their sequence positions
    same_key_items =
      seq_ids
      |> Enum.with_index()
      |> Enum.filter(fn {seq_id, _idx} ->
        case BlockStore.get(store, seq_id) do
          %Item{parent_sub: ^sub, deleted: false} -> true
          _ -> false
        end
      end)

    if length(same_key_items) <= 1 do
      store
    else
      # Highest sequence index wins; delete the rest
      {_winner_id, winner_idx} = Enum.max_by(same_key_items, fn {_id, idx} -> idx end)

      losers =
        same_key_items
        |> Enum.reject(fn {_id, idx} -> idx == winner_idx end)
        |> Enum.map(fn {id, _idx} -> id end)

      Enum.reduce(losers, store, fn loser_seq_id, store ->
        case BlockStore.get(store, loser_seq_id) do
          nil ->
            store

          loser ->
            store = BlockStore.materialize_client(store, loser.id.client)

            clients =
              Map.update!(store.clients, loser.id.client, fn blocks ->
                {idx, _} = BlockStore.find_block_index(blocks, loser.id.clock)
                List.replace_at(blocks, idx, %{loser | deleted: true})
              end)

            %{store | clients: clients}
            |> BlockStore.refresh_tuple_cache(loser.id.client)
        end
      end)
    end
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

  defp retry_pending(doc, sv, []), do: {doc, sv}

  defp retry_pending(doc, sv, pending) do
    {doc, sv, still_pending} = integrate_items(pending, doc, sv, [])

    if length(still_pending) < length(pending) do
      # Progress made — retry the remainder
      retry_pending(doc, sv, still_pending)
    else
      # No progress — push remaining items into the store without sequence integration
      {doc, sv} =
        Enum.reduce(still_pending, {doc, sv}, fn item, {doc, sv} ->
          store = BlockStore.push(doc.store, item)
          sv = StateVector.advance(sv, item.id.client, item.id.clock + item.length)
          {%{doc | store: store}, sv}
        end)

      {doc, sv}
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
