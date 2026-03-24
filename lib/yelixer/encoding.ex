defmodule Yelixer.Encoding do
  @moduledoc """
  Binary encoding/decoding for Yjs V1 wire protocol.
  Uses unsigned LEB128 varint encoding.
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

  # --- Varint (unsigned LEB128) ---

  def encode_uint(n) when n < 128, do: <<n>>

  def encode_uint(n) do
    <<1::1, Bitwise.band(n, 0x7F)::7, encode_uint(Bitwise.bsr(n, 7))::binary>>
  end

  def decode_uint(binary), do: decode_uint(binary, 0, 0)

  defp decode_uint(<<0::1, value::7, rest::binary>>, acc, shift) do
    {acc + Bitwise.bsl(value, shift), rest}
  end

  defp decode_uint(<<1::1, value::7, rest::binary>>, acc, shift) do
    decode_uint(rest, acc + Bitwise.bsl(value, shift), shift + 7)
  end

  # --- Signed varint (zigzag encoding) ---

  def encode_sint(n) when n >= 0, do: encode_uint(Bitwise.bsl(n, 1))
  def encode_sint(n), do: encode_uint(Bitwise.bor(Bitwise.bsl(-n, 1), 1))

  def decode_sint(binary) do
    {n, rest} = decode_uint(binary)

    if Bitwise.band(n, 1) == 1 do
      {-Bitwise.bsr(n, 1) - 1, rest}
    else
      {Bitwise.bsr(n, 1), rest}
    end
  end

  # --- String ---

  def encode_string(s) do
    bytes = :erlang.iolist_to_binary(s)
    <<encode_uint(byte_size(bytes))::binary, bytes::binary>>
  end

  def decode_string(binary) do
    {len, rest} = decode_uint(binary)
    <<s::binary-size(len), rest2::binary>> = rest
    {s, rest2}
  end

  # --- State Vector ---

  def encode_state_vector(%StateVector{clocks: clocks}) do
    count = map_size(clocks)

    pairs =
      Enum.reduce(clocks, <<>>, fn {client, clock}, acc ->
        <<acc::binary, encode_uint(client)::binary, encode_uint(clock)::binary>>
      end)

    <<encode_uint(count)::binary, pairs::binary>>
  end

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
  # Format: varint num_clients, then per client:
  #   varint client_id, varint num_ranges, then per range:
  #     varint clock, varint length

  def encode_delete_set(%DeleteSet{clients: clients}) do
    count = map_size(clients)

    body =
      Enum.reduce(clients, <<>>, fn {client, ranges}, acc ->
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

  def decode_delete_set(binary) do
    {count, rest} = decode_uint(binary)
    decode_ds_clients(rest, count, DeleteSet.new())
  end

  defp decode_ds_clients(rest, 0, ds), do: {ds, rest}

  defp decode_ds_clients(binary, remaining, ds) do
    {client, rest} = decode_uint(binary)
    {num_ranges, rest} = decode_uint(rest)
    {ds, rest} = decode_ds_ranges(rest, num_ranges, ds, client)
    decode_ds_clients(rest, remaining - 1, ds)
  end

  defp decode_ds_ranges(rest, 0, ds, _client), do: {ds, rest}

  defp decode_ds_ranges(binary, remaining, ds, client) do
    {clock, rest} = decode_uint(binary)
    {len, rest} = decode_uint(rest)
    ds = DeleteSet.insert(ds, client, clock, len)
    decode_ds_ranges(rest, remaining - 1, ds, client)
  end

  # --- Update Encoding ---
  # Format:
  #   varint num_clients
  #   for each client (sorted by client id descending):
  #     varint num_structs
  #     varint client_id
  #     varint first_clock
  #     for each struct:
  #       byte info (bits 0-4: content ref, bit 5: has_parent_sub, bit 6: has_right_origin, bit 7: has_origin)
  #       [origin ID if has_origin]
  #       [right_origin ID if has_right_origin]
  #       [parent info if neither origin nor right_origin]
  #       [parent_sub string if has_parent_sub]
  #       content data
  #   delete_set

  def encode_update(%Doc{} = doc) do
    encode_diff(doc, StateVector.new())
  end

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
        all_items = Map.get(store.clients, client, [])

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
    # GC blocks: just info byte (0) + length
    <<@content_ref_gc, encode_uint(n)::binary>>
  end

  defp encode_item(%Item{} = item, store) do
    content_ref = content_type_ref(item.content)

    # Remap refs through GC/deleted blocks to nearest non-GC neighbors
    origin = remap_gc_origin(item.origin, store)
    right_origin = remap_gc_right_origin(item.right_origin, store)

    info =
      content_ref
      |> Bitwise.bor(if origin != nil, do: @has_origin, else: 0)
      |> Bitwise.bor(if right_origin != nil, do: @has_right_origin, else: 0)
      |> Bitwise.bor(if item.parent_sub != nil, do: @has_parent_sub, else: 0)

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

    # Write parent_sub
    bin =
      if item.parent_sub != nil do
        <<bin::binary, encode_string(item.parent_sub)::binary>>
      else
        bin
      end

    # Write content
    <<bin::binary, encode_content(item.content)::binary>>
  end

  # Returns the ID if the referenced item is NOT a GC block, nil otherwise
  # Remap origin (left ref) through GC/deleted blocks to nearest non-GC predecessor
  defp remap_gc_origin(nil, _store), do: nil

  defp remap_gc_origin(%ID{} = id, store) do
    case BlockStore.get(store, id) do
      %Item{deleted: true} ->
        # Find last non-deleted item before this one from same client
        blocks = BlockStore.client_blocks(store, id.client)

        blocks
        |> Enum.filter(fn b -> b.id.clock + b.length - 1 < id.clock and not b.deleted end)
        |> List.last()
        |> case do
          nil -> nil
          %Item{id: bid, length: len} -> ID.new(bid.client, bid.clock + len - 1)
        end

      _ ->
        id
    end
  end

  # Clear right_origin when it points to a GC/deleted block
  defp remap_gc_right_origin(nil, _store), do: nil

  defp remap_gc_right_origin(%ID{} = id, store) do
    case BlockStore.get(store, id) do
      %Item{deleted: true} -> nil
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

  defp encode_content({:type, type_ref}), do: encode_uint(type_ref_to_int(type_ref))
  defp encode_content({:json, values}), do: encode_json_list(values)

  # Encode a list of Any values using Yjs any encoding
  defp encode_any_list(values) do
    len = length(values)
    body = Enum.reduce(values, <<>>, fn v, acc -> <<acc::binary, encode_any(v)::binary>> end)
    <<encode_uint(len)::binary, body::binary>>
  end

  # lib0 Any encoding: type byte + value
  # 116 = buffer, 117 = array, 118 = object, 119 = string,
  # 120 = false, 121 = true, 122 = bigint, 123 = float64,
  # 124 = float32, 125 = integer (zigzag), 126 = null, 127 = undefined
  defp encode_any(nil), do: <<126>>
  defp encode_any(true), do: <<121>>
  defp encode_any(false), do: <<120>>

  defp encode_any(n) when is_integer(n) do
    <<125, encode_sint(n)::binary>>
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

  @doc "Decode a lib0 Any value from binary. Returns {value, rest}."
  def decode_any_value(binary), do: decode_any(binary)

  defp decode_any(<<127, rest::binary>>), do: {nil, rest}
  defp decode_any(<<126, rest::binary>>), do: {nil, rest}
  defp decode_any(<<121, rest::binary>>), do: {true, rest}
  defp decode_any(<<120, rest::binary>>), do: {false, rest}
  defp decode_any(<<123, f::float-64, rest::binary>>), do: {round_if_integer(f), rest}

  defp decode_any(<<124, f::float-32, rest::binary>>), do: {round_if_integer(f), rest}

  defp decode_any(<<125, rest::binary>>) do
    {n, rest} = decode_sint(rest)
    {n, rest}
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

  def apply_update(%Doc{} = doc, binary) do
    case decode_update(binary) do
      {:ok, {items, ds, _rest}} ->
        # Filter out items we already have
        sv = BlockStore.state_vector(doc.store)

        {doc, sv, pending} = integrate_items(items, doc, sv, [])

        # Retry pending items whose dependencies are now available
        {doc, _sv} = retry_pending(doc, sv, pending)

        # Apply delete set — work with ranges, splitting items at boundaries
        doc =
          Enum.reduce(Map.to_list(ds.clients), doc, fn {client, ranges}, doc ->
            Enum.reduce(ranges, doc, fn {start, stop}, doc ->
              store = apply_delete_range(doc.store, client, start, stop - start)
              %{doc | store: store}
            end)
          end)

        {:ok, doc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_delete_range(store, _client, _clock, 0), do: store

  defp apply_delete_range(store, client, clock, remaining) do
    case BlockStore.get(store, ID.new(client, clock)) do
      nil ->
        # Item not found, skip this clock
        apply_delete_range(store, client, clock + 1, remaining - 1)

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

  defp split_in_clients(store, client, item, offset) do
    {left, right} = Item.split(item, offset)

    clients =
      Map.update!(store.clients, client, fn blocks ->
        {idx, _} = BlockStore.find_block_index(blocks, item.id.clock)

        blocks
        |> List.replace_at(idx, left)
        |> List.insert_at(idx + 1, right)
      end)

    # Also update sequences if the item is in one
    sequences =
      Enum.reduce(store.sequences, store.sequences, fn {type_key, seq}, sequences ->
        case Enum.find_index(seq, &(&1 == item.id)) do
          nil -> sequences
          idx -> Map.put(sequences, type_key, List.insert_at(seq, idx + 1, right.id))
        end
      end)

    %{store | clients: clients, sequences: sequences}
    |> BlockStore.refresh_tuple_cache(client)
  end

  defp mark_item_deleted(store, client, item) do
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
      # If this client has a pending item with a lower clock, defer all subsequent items
      # for that client to maintain contiguity (matching yrs behavior)
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
    # GC blocks just go into the store, not into any type sequence
    store = BlockStore.push(doc.store, item)
    sv = StateVector.advance(sv, item.id.client, item.id.clock + item.length)
    {:ok, %{doc | store: store}, sv}
  end

  defp try_integrate_item(item, doc, sv) do
    # Check for missing cross-client dependencies (origin and right_origin)
    # matching yrs Update::missing() — defer if dependency not yet integrated
    if has_missing_dep?(item, sv) do
      :pending_dep
    else
      item = resolve_parent(item, doc.store)
      type_key = parent_type_key(item)

      case type_key do
        nil ->
          # Can't resolve parent yet — defer for retry but don't block client
          :pending_parent

        key ->
          type_ref = infer_type_ref(item, doc)
          {doc, _} = Doc.get_or_create_type(doc, key, type_ref)
          {:ok, store} = Integrate.integrate(doc.store, item, key)
          # Map conflict resolution: auto-delete loser when same key has competing items
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

  # For items with parent_sub (map entries), resolve conflicts.
  # In yrs: the RIGHTMOST item in the YATA sequence for a key wins.
  # All other non-deleted items for the same key are auto-deleted.
  defp maybe_resolve_map_conflict(store, %Item{parent_sub: nil}, _type_key), do: store
  defp maybe_resolve_map_conflict(store, %Item{parent_sub: :inherit}, _type_key), do: store

  defp maybe_resolve_map_conflict(store, %Item{parent_sub: sub}, type_key) do
    seq_ids = Map.get(store.sequences, type_key, [])

    # Find ALL non-deleted items with same parent_sub, with their sequence index
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
      # Map conflict resolution: rightmost wins
      # The RIGHTMOST (highest index) wins; delete all others
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

  defp retry_pending(doc, sv, []), do: {doc, sv}

  defp retry_pending(doc, sv, pending) do
    {doc, sv, still_pending} = integrate_items(pending, doc, sv, [])

    if length(still_pending) < length(pending) do
      # Made progress, retry remaining
      retry_pending(doc, sv, still_pending)
    else
      # No progress — push remaining items to store without sequence integration
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
        # Inherit parent_sub from origin/right_origin if marked for inheritance
        item =
          if item.parent_sub == :inherit do
            %{item | parent_sub: ref_item.parent_sub}
          else
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
      {items, rest} = decode_clients(rest, num_clients, [])
      {ds, rest} = decode_delete_set(rest)
      {:ok, {items, ds, rest}}
    rescue
      e in [MatchError, FunctionClauseError, ArgumentError] ->
        {:error, {:malformed_update, Exception.message(e)}}
    end
  end

  defp decode_clients(rest, 0, acc), do: {acc, rest}

  defp decode_clients(binary, remaining, acc) do
    {num_structs, rest} = decode_uint(binary)
    {client, rest} = decode_uint(rest)
    {first_clock, rest} = decode_uint(rest)
    {items, rest} = decode_structs(rest, num_structs, client, first_clock, [])
    decode_clients(rest, remaining - 1, acc ++ items)
  end

  defp decode_structs(rest, 0, _client, _clock, acc), do: {Enum.reverse(acc), rest}

  defp decode_structs(binary, remaining, client, clock, acc) do
    {item, rest, next_clock} = decode_struct(binary, client, clock)
    decode_structs(rest, remaining - 1, client, next_clock, [item | acc])
  end

  defp decode_struct(<<@content_ref_gc, rest::binary>>, client, clock) do
    # GC blocks: just info byte (0) + length, no origin/parent/content
    {len, rest} = decode_uint(rest)
    item = Item.new(ID.new(client, clock), nil, nil, {:gc, len}, {:gc_placeholder, nil}, nil)
    {item, rest, clock + len}
  end

  defp decode_struct(<<info, rest::binary>>, client, clock) do
    content_ref = Bitwise.band(info, 0x1F)
    has_origin = Bitwise.band(info, @has_origin) != 0
    has_right_origin = Bitwise.band(info, @has_right_origin) != 0
    has_parent_sub = Bitwise.band(info, @has_parent_sub) != 0

    # Read origin
    {origin, rest} =
      if has_origin do
        decode_id(rest)
      else
        {nil, rest}
      end

    # Read right_origin
    {right_origin, rest} =
      if has_right_origin do
        decode_id(rest)
      else
        {nil, rest}
      end

    # Read parent (only if both origin and right_origin are nil)
    {parent, rest} =
      if origin == nil and right_origin == nil do
        {parent_info, rest} = decode_uint(rest)

        if parent_info == 1 do
          # Named parent
          {name, rest} = decode_string(rest)
          {{:named, name}, rest}
        else
          # ID parent
          {id, rest} = decode_id(rest)
          {{:id, id}, rest}
        end
      else
        # Parent will be inferred from origin/right_origin during integration
        {{:infer, origin || right_origin}, rest}
      end

    # Read parent_sub — only encoded when parent is explicit (no origin/right_origin)
    {parent_sub, rest} =
      if has_parent_sub and origin == nil and right_origin == nil do
        decode_string(rest)
      else
        {nil, rest}
      end

    # Read content
    {content, rest} = decode_content(rest, content_ref)

    item = Item.new(ID.new(client, clock), origin, right_origin, content, parent, parent_sub)

    # Mark that parent_sub needs inheritance if flag was set but not encoded
    item =
      if has_parent_sub and parent_sub == nil do
        %{item | parent_sub: :inherit}
      else
        item
      end
    next_clock = clock + item.length

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
    {{:type, int_to_type_ref(ref_int)}, rest}
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
