defmodule Yelixer.StateCodec do
  @moduledoc """
  Lossless, explicitly versioned checkpoint codec for a `Yelixer.Doc`'s
  full causal state (CHECKPOINT-SNAP-1, Phase B round 1).

  ## Why not a Yjs full update

  `Yelixer.Encoding.encode_update/1` is a *wire* encoding, not a state
  encoding. It drops state that changes later behaviour:

    - `doc.pending` (out-of-order update blobs still waiting for a
      dependency) and `pending_bytes` are excluded from every wire view
      by design;
    - the `types` registry (e.g. a top-level `{:xml_element, tag}` or a
      `:text` vs `:unknown` registration) is never on the wire;
    - tombstoned items keep their original content and flags in memory,
      but are re-encoded as `{:deleted, n}`;
    - `client_id`, `clock_floor`, `client_namespaces` and the map
      live-id index (`BlockStore.map_index`) are local bookkeeping.

  This codec therefore serializes the doc's *materialized logical state*
  (see `canonical_state/1`) field by field, and refuses any state it does
  not know how to represent exactly, instead of normalizing it.

  ## Envelope (format version 2)

      "YXSC"                     4 bytes magic
      version                    u16 big-endian (= 2)
      key_size                   u32 big-endian (<= 4096)
      key                        key_size bytes (caller-supplied cache key)
      payload_size               u64 big-endian
      digest                     32 bytes: SHA-256 over every byte above
                                 (magic .. payload_size) followed by payload
      payload                    payload_size bytes (canonical term, below)

  Decode checks, in order: magic, version, key size, key equality,
  payload size bound, exact total length (truncated / trailing bytes),
  digest, payload grammar, structural invariants. Any failure returns
  `{:error, reason}`; a partially-decoded state is never returned.

  Structural invariants enforced (by decode, and by encode, which runs
  the same validator): every id, clock, counter and `pending_bytes` is a
  non-negative integer below 2^53 (the Yjs number domain); each client's
  blocks are sorted and non-overlapping with lengths matching their
  content (clock gaps are allowed: the pinned `apply_update/2` produces
  them, see `decode_bucket/4`); delete-set ranges are sorted, disjoint, non-empty and
  non-inverted; `pending_bytes` is the sum of the pending blob sizes;
  every sequence entry is a unique block start whose item's parent is
  that sequence's type; `sequence_len` equals each sequence's length;
  every `map_index` id names a stored block, and every non-empty
  `map_index` entry is exactly `[id]` of its key's rightmost write in
  its type's sequence (the yelixer#11 map rule). An empty entry `[]`
  is accepted and read as "unknown" (rebuilt by the next scan); no
  current writer produces it — the version-1 writers that stored `[]`
  for a deleted key are refused by version before this check runs;
  type refs are known atoms or
  `{:xml_element, tag}`; embed/format values are JSON-shaped; `{:doc, _}`
  content (which has no wire encoding) is refused.

  ## Versioning

  Any change to the payload grammar, the atom table or the invariants
  above that changes which bytes are accepted bumps `@version`. Decoders
  refuse every version they do not know.

  History:

    - **1** — CHECKPOINT-SNAP-1 round 1.
    - **2** — yelixer#11 (Plan #42733). The payload grammar and atom
      table are unchanged, but `map_index` changed meaning: it caches a
      map key's WINNER (its rightmost write in YATA order, tombstoned or
      not), where version 1 cached the rightmost UNDELETED write. Where
      those differ, a version-1 cache answers reads wrongly and
      misplaces later writes, and a version-1 store can also hold a live
      write left of a tombstoned rightmost one. Decode now enforces the
      winner invariant (every non-empty `map_index` entry is `[id]` of
      its key's rightmost write), which changes which bytes are
      accepted, so the version is bumped and every version-1 checkpoint
      is refused with `{:error, {:unsupported_version, 1}}`: the caller
      discards it and rebuilds from its wire history.

  The digest detects corruption only. It is not authentication: a party
  that can write the checkpoint can forge one. Trust is the caller's
  filesystem trust boundary plus the key.

  ## Payload

  A single canonical term (see "Term grammar") of shape

      {client_id, clock_floor, types, client_namespaces, pending,
       pending_bytes, delete_set_clients, clients, sequences,
       sequence_len, map_index}

  where `clients` maps each client to its ordered list of item tuples
  `{clock, origin, right_origin, parent, parent_sub, deleted, content,
  length}` (IDs as `{client, clock}` tuples), `sequences` maps each type
  key to its full document-order ID list (tombstones included), and
  `map_index` is the per-`{type_key, sub}` winner cache (the key's
  rightmost write, tombstoned or not — `BlockStore.map_winner_ids/3`).
  Checkpoints written before yelixer#11 (format version 1) cached the
  rightmost UNDELETED write instead and are refused by version
  (`{:error, {:unsupported_version, 1}}`, see "Versioning"); a
  version-2 payload whose cached id is not the key's rightmost write is
  refused as `{:malformed, :map_index}`. Either way the caller rebuilds
  from its wire history.

  Deferred-write buffers (`client_pending`, `sequence_pending`,
  `deleted_overlay`) are folded in by `BlockStore.materialize_all/1`
  before encoding; lookup caches (`client_tuples`, `sequence_index`,
  `sequence_positions`) are pure mirrors of the materialized lists and
  are rebuilt (tuples) or left to lazy rebuild (sequence index).

  ## Term grammar (tags)

      0 nil   1 true   2 false   3 atom (index into the fixed atom table,
                                     unchanged since version 1)
      4 non-negative integer (varint byte count + big-endian magnitude)
      5 negative integer (same, magnitude of the absolute value)
      6 float (IEEE-754 binary64)   7 binary (varint size + bytes)
      8 list (varint count + items) 9 tuple (varint count + items)
      10 map (varint count + key/value pairs, keys strictly ascending
         by their encoded bytes)

  Encoding is canonical (minimal varints and magnitudes, sorted map
  keys), and decode rejects every non-canonical form, so
  `encode(decode(bytes)) == bytes` for every accepted input. Atoms
  outside the table, pids, references, functions, improper lists and
  non-byte bitstrings are unsupported and make `encode/2` fail.
  """

  alias Yelixer.{BlockStore, DeleteSet, Doc, ID, Item}

  @magic "YXSC"
  @version 2
  @max_key_size 4096
  @default_max_bytes 268_435_456
  @max_depth 256
  @max_safe_int 9_007_199_254_740_992
  @type_atoms [:text, :map, :array, :xml_element, :xml_fragment, :xml_hook, :xml_text, :unknown]

  # Atom table (unchanged from version 1). ANY change to this table (adding, removing, reordering)
  # is a format change and bumps @version.
  @atoms [
    :named,
    :id,
    :gc_placeholder,
    :inherit,
    :string,
    :any,
    :binary,
    :deleted,
    :gc,
    :embed,
    :format,
    :type,
    :json,
    :doc,
    :text,
    :map,
    :array,
    :xml_element,
    :xml_fragment,
    :xml_hook,
    :xml_text,
    :unknown
  ]
  @atom_index @atoms |> Enum.with_index() |> Map.new()
  @atom_by_index @atoms |> Enum.with_index() |> Map.new(fn {a, i} -> {i, a} end)

  @doc_fields [
    :__struct__,
    :client_id,
    :store,
    :delete_set,
    :types,
    :client_namespaces,
    :pending,
    :pending_bytes,
    :clock_floor
  ]
  @store_fields [
    :__struct__,
    :clients,
    :sequences,
    :client_tuples,
    :client_pending,
    :sequence_pending,
    :sequence_len,
    :map_index,
    :sequence_index,
    :sequence_positions,
    :deleted_overlay
  ]
  @item_fields [
    :__struct__,
    :id,
    :origin,
    :right_origin,
    :content,
    :parent,
    :parent_sub,
    :deleted,
    :length
  ]

  @type error ::
          :bad_magic
          | {:unsupported_version, non_neg_integer()}
          | :bad_key
          | :key_mismatch
          | :too_large
          | :truncated
          | :trailing_bytes
          | :digest_mismatch
          | {:malformed, term()}
          | {:unsupported_state, term()}

  @doc "The format version this module writes."
  def format_version, do: @version

  @doc """
  Encodes `doc`'s full causal state under `key` (a binary of at most
  #{@max_key_size} bytes identifying what this checkpoint is valid for).

  Returns `{:ok, bytes}` or `{:error, {:unsupported_state, reason}}`
  when the doc carries state this format cannot represent exactly.
  """
  @spec encode(Doc.t(), binary()) :: {:ok, binary()} | {:error, error()}
  def encode(%Doc{} = doc, key) do
    with :ok <- check_key(key),
         {:ok, canonical} <- canonical_state(doc),
         {:ok, payload} <- encode_term(canonical) do
      {:ok, envelope(key, payload)}
    end
  end

  def encode(_doc, _key), do: {:error, {:unsupported_state, :not_a_doc}}

  @doc """
  Decodes a checkpoint produced by `encode/2`, requiring it to have been
  written under exactly `key`.

  Options: `:max_bytes` bounds the payload size (default 256 MiB). Callers
  should pass a bound that fits their own storage limits; the decoder
  holds the whole payload and the restored doc in memory.
  """
  @spec decode(binary(), binary(), keyword()) :: {:ok, Doc.t()} | {:error, error()}
  def decode(bytes, key, opts \\ [])

  def decode(bytes, key, opts) when is_binary(bytes) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with :ok <- check_key(key),
         {:ok, payload} <- open_envelope(bytes, key, max_bytes),
         {:ok, term} <- decode_term(payload),
         {:ok, doc} <- doc_from_canonical(term) do
      {:ok, %{doc | pending: Enum.map(doc.pending, &:binary.copy/1)}}
    end
  end

  def decode(_bytes, _key, _opts), do: {:error, {:malformed, :not_a_binary}}

  @doc """
  The materialized logical state of `doc` that this codec preserves —
  every field that can influence later behaviour, with deferred-write
  buffers folded in and lookup caches dropped. Two docs with equal
  canonical states are, by construction, the same causal state.
  """
  @spec canonical_state(Doc.t()) :: {:ok, tuple()} | {:error, error()}
  def canonical_state(%Doc{} = doc) do
    try do
      with :ok <- check_fields(doc, @doc_fields, :doc_fields),
           %BlockStore{} = store <- doc.store,
           :ok <- check_fields(store, @store_fields, :store_fields),
           %DeleteSet{clients: ds_clients} when is_map(ds_clients) <- doc.delete_set,
           store = BlockStore.materialize_all(store),
           :ok <- check_drained(store),
           {:ok, clients} <- canonical_clients(store.clients),
           {:ok, sequences} <- canonical_sequences(store.sequences),
           {:ok, map_index} <- canonical_map_index(store.map_index) do
        canonical =
          {doc.client_id, doc.clock_floor, doc.types, doc.client_namespaces, doc.pending,
           doc.pending_bytes, ds_clients, clients, sequences, store.sequence_len, map_index}

        # The decoder's validator is the single definition of what this
        # format accepts; run it here too so encode refuses exactly what
        # decode would refuse.
        case doc_from_canonical(canonical) do
          {:ok, _} -> {:ok, canonical}
          {:error, {:malformed, reason}} -> {:error, {:unsupported_state, reason}}
        end
      else
        {:error, _} = err -> err
        other -> {:error, {:unsupported_state, {:unexpected_shape, kind_of(other)}}}
      end
    rescue
      e -> {:error, {:unsupported_state, {:raised, Exception.message(e)}}}
    end
  end

  # ── envelope ──────────────────────────────────────────────────────

  defp check_key(key) when is_binary(key) and byte_size(key) <= @max_key_size, do: :ok
  defp check_key(_), do: {:error, :bad_key}

  defp envelope(key, payload) do
    header =
      <<@magic::binary, @version::16, byte_size(key)::32, key::binary, byte_size(payload)::64>>

    <<header::binary, digest(header, payload)::binary, payload::binary>>
  end

  defp digest(header, payload), do: :crypto.hash(:sha256, [header, payload])

  defp open_envelope(<<@magic::binary, rest::binary>>, key, max_bytes) do
    case rest do
      <<@version::16, rest::binary>> -> open_body(rest, key, max_bytes)
      <<other::16, _::binary>> -> {:error, {:unsupported_version, other}}
      _ -> {:error, :truncated}
    end
  end

  defp open_envelope(bytes, _key, _max) when byte_size(bytes) < 4 do
    if String.starts_with?(@magic, bytes), do: {:error, :truncated}, else: {:error, :bad_magic}
  end

  defp open_envelope(_bytes, _key, _max), do: {:error, :bad_magic}

  defp open_body(<<key_size::32, rest::binary>>, key, max_bytes) do
    cond do
      key_size > @max_key_size ->
        {:error, {:malformed, :key_size}}

      byte_size(rest) < key_size ->
        {:error, :truncated}

      true ->
        <<stored_key::binary-size(key_size), rest::binary>> = rest

        if stored_key != key do
          {:error, :key_mismatch}
        else
          open_payload(rest, key, max_bytes)
        end
    end
  end

  defp open_body(_rest, _key, _max), do: {:error, :truncated}

  defp open_payload(<<size::64, digest::binary-size(32), rest::binary>>, key, max_bytes) do
    cond do
      size > max_bytes ->
        {:error, :too_large}

      byte_size(rest) < size ->
        {:error, :truncated}

      byte_size(rest) > size ->
        {:error, :trailing_bytes}

      true ->
        header = <<@magic::binary, @version::16, byte_size(key)::32, key::binary, size::64>>

        if :crypto.hash_equals(digest(header, rest), digest) do
          {:ok, rest}
        else
          {:error, :digest_mismatch}
        end
    end
  end

  defp open_payload(_rest, _key, _max), do: {:error, :truncated}

  # ── canonical state extraction ────────────────────────────────────

  defp check_fields(struct, expected, label) do
    actual = struct |> Map.keys() |> Enum.sort()

    if actual == Enum.sort(expected),
      do: :ok,
      else: {:error, {:unsupported_state, {label, actual -- expected}}}
  end

  defp check_drained(%BlockStore{} = store) do
    pending_seqs = Enum.reject(store.sequence_pending, fn {_k, v} -> v in [nil, []] end)

    cond do
      store.client_pending != %{} -> {:error, {:unsupported_state, :client_pending_not_drained}}
      pending_seqs != [] -> {:error, {:unsupported_state, :sequence_pending_not_drained}}
      store.deleted_overlay != %{} -> {:error, {:unsupported_state, :overlay_not_drained}}
      true -> :ok
    end
  end

  defp canonical_clients(clients) when is_map(clients) do
    Enum.reduce_while(clients, {:ok, %{}}, fn {client, items}, {:ok, acc} ->
      case canonical_items(client, items) do
        {:ok, tuples} -> {:cont, {:ok, Map.put(acc, client, tuples)}}
        err -> {:halt, err}
      end
    end)
  end

  defp canonical_clients(_), do: {:error, {:unsupported_state, :clients_shape}}

  defp canonical_items(client, items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case canonical_item(client, item) do
        {:ok, t} -> {:cont, {:ok, [t | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp canonical_items(_client, _), do: {:error, {:unsupported_state, :bucket_shape}}

  defp canonical_item(client, %Item{id: %ID{client: client, clock: clock}} = item) do
    with :ok <- check_fields(item, @item_fields, :item_fields),
         {:ok, origin} <- id_tuple(item.origin),
         {:ok, right_origin} <- id_tuple(item.right_origin),
         {:ok, parent} <- parent_tuple(item.parent) do
      {:ok,
       {clock, origin, right_origin, parent, item.parent_sub, item.deleted, item.content,
        item.length}}
    end
  end

  defp canonical_item(client, other),
    do: {:error, {:unsupported_state, {:item_not_in_own_bucket, client, kind_of(other)}}}

  defp id_tuple(nil), do: {:ok, nil}
  defp id_tuple(%ID{client: c, clock: k}), do: {:ok, {c, k}}
  defp id_tuple(other), do: {:error, {:unsupported_state, {:id_shape, kind_of(other)}}}

  defp parent_tuple({:named, name}), do: {:ok, {:named, name}}
  defp parent_tuple({:id, %ID{} = id}), do: with({:ok, t} <- id_tuple(id), do: {:ok, {:id, t}})
  defp parent_tuple({:gc_placeholder, nil}), do: {:ok, {:gc_placeholder, nil}}
  defp parent_tuple(other), do: {:error, {:unsupported_state, {:parent_shape, kind_of(other)}}}

  defp canonical_sequences(seqs) when is_map(seqs) do
    Enum.reduce_while(seqs, {:ok, %{}}, fn {name, ids}, {:ok, acc} ->
      case ids_to_tuples(ids) do
        {:ok, tuples} -> {:cont, {:ok, Map.put(acc, name, tuples)}}
        err -> {:halt, err}
      end
    end)
  end

  defp canonical_sequences(_), do: {:error, {:unsupported_state, :sequences_shape}}

  defp canonical_map_index(mi) when is_map(mi) do
    Enum.reduce_while(mi, {:ok, %{}}, fn
      {type_key, subs}, {:ok, acc} when is_map(subs) ->
        Enum.reduce_while(subs, {:ok, %{}}, fn {sub, ids}, {:ok, sacc} ->
          case ids_to_tuples(ids) do
            {:ok, tuples} -> {:cont, {:ok, Map.put(sacc, sub, tuples)}}
            err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, s} -> {:cont, {:ok, Map.put(acc, type_key, s)}}
          err -> {:halt, err}
        end

      _, _ ->
        {:halt, {:error, {:unsupported_state, :map_index_shape}}}
    end)
  end

  defp canonical_map_index(_), do: {:error, {:unsupported_state, :map_index_shape}}

  defp ids_to_tuples(ids) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case id_tuple(id) do
        {:ok, nil} -> {:halt, {:error, {:unsupported_state, :nil_id_in_list}}}
        {:ok, t} -> {:cont, {:ok, [t | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp ids_to_tuples(_), do: {:error, {:unsupported_state, :id_list_shape}}

  # ── canonical state → Doc (the single validator) ──────────────────

  defp doc_from_canonical(
         {client_id, clock_floor, types, namespaces, pending, pending_bytes, ds_clients, clients,
          sequences, sequence_len, map_index}
       ) do
    try do
      with :ok <- check(id_int?(client_id), :client_id),
           :ok <- check(id_int?(clock_floor), :clock_floor),
           :ok <- map_of(types, &is_binary/1, &type_ref?/1, :types),
           :ok <- map_of(namespaces, &id_int?/1, &is_binary/1, :client_namespaces),
           :ok <- list_of(pending, &is_binary/1, :pending),
           :ok <- check(id_int?(pending_bytes), :pending_bytes),
           :ok <-
             check(
               pending_bytes == Enum.reduce(pending, 0, &(byte_size(&1) + &2)),
               :pending_bytes_sum
             ),
           :ok <- map_of(ds_clients, &id_int?/1, &ranges?/1, :delete_set),
           {:ok, items_by_client} <- decode_clients(clients),
           index = block_index(items_by_client),
           :ok <- map_of(sequences, &is_binary/1, &id_tuple_list?/1, :sequences),
           :ok <- check_sequences(sequences, index),
           :ok <- map_of(sequence_len, &is_binary/1, &id_int?/1, :sequence_len),
           :ok <- check_sequence_len(sequences, sequence_len),
           :ok <- check_map_index(map_index, index),
           :ok <- check_map_index_winners(map_index, sequences, index) do
        store = %BlockStore{
          clients: items_by_client,
          sequences: Map.new(sequences, fn {name, ids} -> {name, Enum.map(ids, &to_id/1)} end),
          client_tuples: Map.new(items_by_client, fn {c, l} -> {c, List.to_tuple(l)} end),
          sequence_len: sequence_len,
          map_index:
            Map.new(map_index, fn {tk, subs} ->
              {tk, Map.new(subs, fn {sub, ids} -> {sub, Enum.map(ids, &to_id/1)} end)}
            end)
        }

        {:ok,
         %Doc{
           client_id: client_id,
           store: store,
           delete_set: %DeleteSet{clients: ds_clients},
           types: types,
           client_namespaces: namespaces,
           pending: pending,
           pending_bytes: pending_bytes,
           clock_floor: clock_floor
         }}
      end
    rescue
      e -> {:error, {:malformed, {:raised, Exception.message(e)}}}
    end
  end

  defp doc_from_canonical(other), do: {:error, {:malformed, {:top_level, kind_of(other)}}}

  defp check(true, _label), do: :ok
  defp check(_, label), do: {:error, {:malformed, label}}

  # Yjs ids, clocks and counters are JavaScript numbers: integers must stay
  # below 2^53 to mean the same thing on every peer.
  defp id_int?(n), do: is_integer(n) and n >= 0 and n < @max_safe_int

  defp map_of(m, key_ok, val_ok, label) when is_map(m) do
    if Enum.all?(m, fn {k, v} -> key_ok.(k) and val_ok.(v) end),
      do: :ok,
      else: {:error, {:malformed, label}}
  end

  defp map_of(_m, _k, _v, label), do: {:error, {:malformed, label}}

  defp list_of(l, ok, label) when is_list(l) do
    if Enum.all?(l, ok), do: :ok, else: {:error, {:malformed, label}}
  end

  defp list_of(_l, _ok, label), do: {:error, {:malformed, label}}

  # DeleteSet's own invariant: sorted, disjoint, non-empty, non-inverted.
  defp ranges?(l) when is_list(l) and l != [], do: ranges?(l, -1)
  defp ranges?(_), do: false

  defp ranges?([], _prev_end), do: true

  defp ranges?([{s, e} | rest], prev_end) do
    id_int?(s) and id_int?(e) and s < e and s >= prev_end and ranges?(rest, e)
  end

  defp ranges?(_, _), do: false

  defp id_tuple?({c, k}), do: id_int?(c) and id_int?(k)
  defp id_tuple?(_), do: false

  defp opt_id_tuple?(nil), do: true
  defp opt_id_tuple?(t), do: id_tuple?(t)

  defp id_tuple_list?(l) when is_list(l), do: Enum.all?(l, &id_tuple?/1)
  defp id_tuple_list?(_), do: false

  defp to_id(nil), do: nil
  defp to_id({c, k}), do: ID.new(c, k)

  defp type_ref?(a) when a in @type_atoms, do: true
  defp type_ref?({:xml_element, tag}), do: is_binary(tag)
  defp type_ref?(_), do: false

  defp decode_clients(clients) when is_map(clients) do
    Enum.reduce_while(clients, {:ok, %{}}, fn
      {client, [_ | _] = tuples}, {:ok, acc} ->
        with true <- id_int?(client),
             {:ok, items} <- decode_bucket(client, tuples, nil, []) do
          {:cont, {:ok, Map.put(acc, client, items)}}
        else
          false -> {:halt, {:error, {:malformed, :clients}}}
          err -> {:halt, err}
        end

      _, _ ->
        {:halt, {:error, {:malformed, :clients}}}
    end)
  end

  defp decode_clients(_), do: {:error, {:malformed, :clients}}

  defp decode_bucket(_client, [], _next_free, acc), do: {:ok, Enum.reverse(acc)}

  # BlockStore invariants 1 and 3: a client's blocks are sorted and
  # non-overlapping.
  #
  # Invariant 2 (contiguity, no clock gaps) is NOT enforced: the pinned
  # `Encoding.apply_update/2` itself produces gapped buckets whenever a
  # client's later update arrives before an earlier one and the later
  # items' dependencies are otherwise satisfied (e.g. a YMap write with an
  # explicit parent). Those are reachable states — 89 of the 200 proof
  # histories reach one — and this codec preserves them exactly rather
  # than refusing them.
  defp decode_bucket(client, [tuple | rest], next_free, acc) do
    with {:ok, %Item{id: %ID{clock: clock}, length: len} = item} <- decode_item(client, tuple) do
      cond do
        len < 1 ->
          {:error, {:malformed, {:empty_item, client, clock}}}

        not id_int?(clock + len) ->
          {:error, {:malformed, {:clock_bound, client, clock}}}

        next_free != nil and clock < next_free ->
          {:error, {:malformed, {:overlap, client, clock}}}

        true ->
          decode_bucket(client, rest, clock + len, [item | acc])
      end
    end
  end

  defp decode_item(
         client,
         {clock, origin, right_origin, parent, parent_sub, deleted, content, length}
       ) do
    with true <- id_int?(clock) and opt_id_tuple?(origin) and opt_id_tuple?(right_origin),
         true <- parent_ok?(parent),
         true <- parent_sub == nil or parent_sub == :inherit or is_binary(parent_sub),
         true <- is_boolean(deleted),
         true <- content_ok?(content),
         true <- id_int?(length),
         rebuilt =
           Item.new(
             ID.new(client, clock),
             to_id(origin),
             to_id(right_origin),
             copy_content(content),
             decode_parent(parent),
             copy(parent_sub)
           ),
         true <- rebuilt.length == length do
      {:ok, %{rebuilt | deleted: deleted}}
    else
      _ -> {:error, {:malformed, {:item, client, kind_of(clock)}}}
    end
  end

  defp decode_item(client, _), do: {:error, {:malformed, {:item_shape, client}}}

  defp parent_ok?({:named, name}), do: is_binary(name)
  defp parent_ok?({:id, t}), do: id_tuple?(t)
  defp parent_ok?({:gc_placeholder, nil}), do: true
  defp parent_ok?(_), do: false

  defp decode_parent({:id, t}), do: {:id, to_id(t)}
  defp decode_parent({:named, name}), do: {:named, copy(name)}
  defp decode_parent(other), do: other

  # Content shapes the wire encoder can produce. `{:doc, _}` has no wire
  # encoding at all and is refused. `:any` keeps any grammar term: it is
  # exactly what the local type APIs stored.
  defp content_ok?({:string, s}), do: is_binary(s) and String.valid?(s)
  defp content_ok?({:any, l}), do: is_list(l)
  defp content_ok?({:binary, b}), do: is_binary(b)
  defp content_ok?({:deleted, n}), do: id_int?(n)
  defp content_ok?({:gc, n}), do: id_int?(n)
  defp content_ok?({:embed, v}), do: json?(v)
  defp content_ok?({:format, {k, v}}), do: is_binary(k) and json?(v)
  defp content_ok?({:type, ref}), do: type_ref?(ref)
  defp content_ok?({:json, l}), do: is_list(l) and Enum.all?(l, &is_binary/1)
  defp content_ok?(_), do: false

  defp json?(v) when is_nil(v) or is_boolean(v) or is_number(v) or is_binary(v), do: true
  defp json?(l) when is_list(l), do: Enum.all?(l, &json?/1)

  defp json?(m) when is_map(m) and not is_struct(m),
    do: Enum.all?(m, fn {k, v} -> is_binary(k) and json?(v) end)

  defp json?(_), do: false

  defp block_index(items_by_client) do
    for {_c, items} <- items_by_client, item <- items, into: %{} do
      {{item.id.client, item.id.clock}, item}
    end
  end

  # BlockStore invariant 5 and its sequence shape: every entry names the
  # exact start of a stored block, appears once in its sequence, and that
  # block's parent is the type the sequence belongs to.
  defp check_sequences(sequences, index) do
    Enum.reduce_while(sequences, :ok, fn {name, ids}, :ok ->
      cond do
        length(Enum.uniq(ids)) != length(ids) ->
          {:halt, {:error, {:malformed, :sequence_duplicate}}}

        not Enum.all?(ids, &Map.has_key?(index, &1)) ->
          {:halt, {:error, {:malformed, :sequence_target}}}

        not Enum.all?(ids, &(parent_key(Map.fetch!(index, &1)) == name)) ->
          {:halt, {:error, {:malformed, :sequence_parent}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp parent_key(%Item{parent: {:named, name}}), do: name
  defp parent_key(%Item{parent: {:id, %ID{client: c, clock: k}}}), do: "__sub:#{c}:#{k}"
  defp parent_key(_), do: nil

  # With every pending write drained, the O(1) length counter must equal
  # the real sequence length for every type.
  defp check_sequence_len(sequences, sequence_len) do
    names = MapSet.union(MapSet.new(Map.keys(sequences)), MapSet.new(Map.keys(sequence_len)))

    if Enum.all?(names, &(Map.get(sequence_len, &1, 0) == length(Map.get(sequences, &1, [])))),
      do: :ok,
      else: {:error, {:malformed, :sequence_len}}
  end

  defp check_map_index(mi, index) when is_map(mi) do
    ok =
      Enum.all?(mi, fn
        {tk, subs} when is_binary(tk) and is_map(subs) ->
          Enum.all?(subs, fn {_sub, ids} ->
            id_tuple_list?(ids) and Enum.all?(ids, &Map.has_key?(index, &1))
          end)

        _ ->
          false
      end)

    if ok, do: :ok, else: {:error, {:malformed, :map_index}}
  end

  defp check_map_index(_, _), do: {:error, {:malformed, :map_index}}

  # yelixer#11: a cached `[id]` must be its key's rightmost write in the
  # type's sequence, tombstones included. Runs after `check_map_index/2`
  # and `check_sequences/2`, so every id here names a stored block.
  defp check_map_index_winners(mi, sequences, index) do
    ok =
      Enum.all?(mi, fn {tk, subs} ->
        nonempty = Enum.reject(subs, fn {_sub, ids} -> ids == [] end)

        nonempty == [] or
          (
            rightmost =
              sequences
              |> Map.get(tk, [])
              |> Enum.reduce(%{}, fn t, acc ->
                case Map.fetch!(index, t) do
                  %Item{parent_sub: sub} when is_binary(sub) -> Map.put(acc, sub, t)
                  _ -> acc
                end
              end)

            Enum.all?(nonempty, fn {sub, ids} -> ids == [Map.get(rightmost, sub)] end)
          )
      end)

    if ok, do: :ok, else: {:error, {:malformed, :map_index}}
  end

  # Decoded binaries are sub-binaries of the payload; copy the larger ones
  # so a restored doc does not keep the whole checkpoint alive.
  defp copy(b) when is_binary(b) and byte_size(b) > 64, do: :binary.copy(b)
  defp copy(other), do: other

  defp copy_content({tag, b}) when tag in [:string, :binary], do: {tag, copy(b)}
  defp copy_content(other), do: other

  defp kind_of(t) when is_tuple(t), do: {:tuple, tuple_size(t)}
  defp kind_of(t) when is_map(t), do: :map
  defp kind_of(t) when is_list(t), do: :list
  defp kind_of(t) when is_binary(t), do: :binary
  defp kind_of(t) when is_integer(t), do: :integer
  defp kind_of(t) when is_atom(t), do: :atom
  defp kind_of(_), do: :other

  # ── term codec ────────────────────────────────────────────────────

  @doc false
  # Exposed for the codec's own tests.
  def encode_term(term) do
    try do
      {:ok, IO.iodata_to_binary(enc(term, 0))}
    catch
      {:unsupported, reason} -> {:error, {:unsupported_state, reason}}
    end
  end

  @doc false
  def decode_term(bin) do
    try do
      case dec(bin, 0) do
        {term, <<>>} -> {:ok, term}
        {_term, _rest} -> {:error, {:malformed, :payload_trailing}}
      end
    rescue
      e -> {:error, {:malformed, {:raised, Exception.message(e)}}}
    catch
      {:malformed, reason} -> {:error, {:malformed, reason}}
    end
  end

  defp enc(_t, depth) when depth > @max_depth, do: throw({:unsupported, :too_deep})
  defp enc(nil, _), do: <<0>>
  defp enc(true, _), do: <<1>>
  defp enc(false, _), do: <<2>>

  defp enc(a, _) when is_atom(a) do
    case Map.fetch(@atom_index, a) do
      {:ok, i} -> [<<3>>, varint(i)]
      :error -> throw({:unsupported, {:atom, a}})
    end
  end

  defp enc(n, _) when is_integer(n) and n >= 0, do: [<<4>>, magnitude(n)]
  defp enc(n, _) when is_integer(n), do: [<<5>>, magnitude(-n)]
  defp enc(f, _) when is_float(f), do: <<6, f::float-64>>
  defp enc(b, _) when is_binary(b), do: [<<7>>, varint(byte_size(b)), b]

  defp enc(l, depth) when is_list(l) do
    count =
      try do
        length(l)
      rescue
        ArgumentError -> throw({:unsupported, :improper_list})
      end

    [<<8>>, varint(count) | Enum.map(l, &enc(&1, depth + 1))]
  end

  defp enc(t, depth) when is_tuple(t) do
    [<<9>>, varint(tuple_size(t)) | Enum.map(Tuple.to_list(t), &enc(&1, depth + 1))]
  end

  defp enc(%_{} = s, _), do: throw({:unsupported, {:struct, s.__struct__}})

  defp enc(m, depth) when is_map(m) do
    pairs =
      m
      |> Enum.map(fn {k, v} ->
        {IO.iodata_to_binary(enc(k, depth + 1)), enc(v, depth + 1)}
      end)
      |> Enum.sort_by(fn {kb, _} -> kb end)

    [<<10>>, varint(map_size(m)) | Enum.map(pairs, fn {kb, v} -> [kb, v] end)]
  end

  defp enc(other, _), do: throw({:unsupported, {:term, kind_of(other)}})

  defp magnitude(0), do: varint(0)

  defp magnitude(n) do
    bytes = :binary.encode_unsigned(n)
    [varint(byte_size(bytes)), bytes]
  end

  defp varint(n) when n < 128, do: <<n>>
  defp varint(n), do: [<<1::1, Bitwise.band(n, 127)::7>>, varint(Bitwise.bsr(n, 7))]

  defp dec(_bin, depth) when depth > @max_depth, do: throw({:malformed, :too_deep})
  defp dec(<<0, rest::binary>>, _), do: {nil, rest}
  defp dec(<<1, rest::binary>>, _), do: {true, rest}
  defp dec(<<2, rest::binary>>, _), do: {false, rest}

  defp dec(<<3, rest::binary>>, _) do
    {i, rest} = dec_varint(rest)

    case Map.fetch(@atom_by_index, i) do
      {:ok, a} -> {a, rest}
      :error -> throw({:malformed, {:atom_index, i}})
    end
  end

  defp dec(<<4, rest::binary>>, _), do: dec_magnitude(rest, & &1, false)
  defp dec(<<5, rest::binary>>, _), do: dec_magnitude(rest, &(-&1), true)

  defp dec(<<6, rest::binary>>, _) do
    case rest do
      <<f::float-64, rest::binary>> -> {f, rest}
      _ -> throw({:malformed, :float})
    end
  end

  defp dec(<<7, rest::binary>>, _) do
    {size, rest} = dec_varint(rest)

    case rest do
      <<b::binary-size(size), rest::binary>> -> {b, rest}
      _ -> throw({:malformed, :binary_size})
    end
  end

  defp dec(<<8, rest::binary>>, depth) do
    {count, rest} = dec_count(rest)
    dec_seq(rest, count, depth + 1, [])
  end

  defp dec(<<9, rest::binary>>, depth) do
    {count, rest} = dec_count(rest)
    {items, rest} = dec_seq(rest, count, depth + 1, [])
    {List.to_tuple(items), rest}
  end

  defp dec(<<10, rest::binary>>, depth) do
    {count, rest} = dec_count(rest)
    dec_map(rest, count, depth + 1, nil, %{})
  end

  defp dec(<<tag, _::binary>>, _), do: throw({:malformed, {:tag, tag}})
  defp dec(<<>>, _), do: throw({:malformed, :eof})

  defp dec_seq(rest, 0, _depth, acc), do: {Enum.reverse(acc), rest}

  defp dec_seq(rest, n, depth, acc) do
    {t, rest} = dec(rest, depth)
    dec_seq(rest, n - 1, depth, [t | acc])
  end

  defp dec_map(rest, 0, _depth, _prev, acc), do: {acc, rest}

  defp dec_map(bin, n, depth, prev, acc) do
    {k, rest} = dec(bin, depth)
    kb = binary_part(bin, 0, byte_size(bin) - byte_size(rest))

    if prev != nil and kb <= prev, do: throw({:malformed, :map_key_order})

    {v, rest} = dec(rest, depth)
    dec_map(rest, n - 1, depth, kb, Map.put(acc, k, v))
  end

  # Every element takes at least one byte, so a count above the
  # remaining size is malformed — refuse before allocating.
  defp dec_count(bin) do
    {count, rest} = dec_varint(bin)
    if count > byte_size(rest), do: throw({:malformed, :count})
    {count, rest}
  end

  defp dec_magnitude(bin, sign, negative?) do
    {size, rest} = dec_varint(bin)

    cond do
      size == 0 and negative? ->
        throw({:malformed, :negative_zero})

      size == 0 ->
        {0, rest}

      true ->
        case rest do
          <<first, _::binary>> = r when first != 0 and byte_size(r) >= size ->
            <<mag::binary-size(size), rest::binary>> = r
            {sign.(:binary.decode_unsigned(mag)), rest}

          _ ->
            throw({:malformed, :magnitude})
        end
    end
  end

  # Minimal LEB128 whose value fits in 64 bits (at most ten groups, and
  # the result is checked, since the tenth group could carry 70 bits).
  defp dec_varint(bin), do: dec_varint(bin, 0, 0)

  defp dec_varint(_bin, _acc, shift) when shift > 63, do: throw({:malformed, :varint_overflow})

  defp dec_varint(<<0::1, v::7, rest::binary>>, acc, shift) do
    if v == 0 and shift > 0, do: throw({:malformed, :varint_overlong})
    value = Bitwise.bor(acc, Bitwise.bsl(v, shift))
    if value > 0xFFFF_FFFF_FFFF_FFFF, do: throw({:malformed, :varint_overflow})
    {value, rest}
  end

  defp dec_varint(<<1::1, v::7, rest::binary>>, acc, shift),
    do: dec_varint(rest, Bitwise.bor(acc, Bitwise.bsl(v, shift)), shift + 7)

  defp dec_varint(_, _, _), do: throw({:malformed, :varint_eof})
end
