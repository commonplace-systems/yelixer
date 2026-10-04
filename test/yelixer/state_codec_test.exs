defmodule Yelixer.StateCodecTest do
  use ExUnit.Case, async: true

  alias Yelixer.{CheckpointHistory, Doc, Encoding, StateCodec}
  alias Yelixer.Types.{Text, YMap}

  @key "log:abc/incarnation:1/frontier:f"

  defp sample_doc do
    %{delivery: d, withheld: _} = CheckpointHistory.generate(3)
    doc = CheckpointHistory.apply_all(CheckpointHistory.registered(42), d)
    doc = Text.insert(doc, "t", 0, "😀x")
    doc = YMap.set(doc, "m", "float", 2.0)
    doc = YMap.set(doc, "m", "negzero", -0.0)
    doc = YMap.set(doc, "m", "big", -1_180_591_620_717_411_303_424)
    # Out-of-order: an update whose origin is missing stays pending.
    peer = Doc.new(client_id: 77) |> Text.insert("t", 0, "A")
    sv = Doc.state_vector(peer)
    late = peer |> Text.insert("t", 1, "B") |> Encoding.encode_diff(sv)
    {:ok, doc} = Encoding.apply_update(doc, late)
    {:ok, doc} = Encoding.apply_update(doc, CheckpointHistory.crafted_update(5))
    %{doc | client_namespaces: %{77 => "ns-hash"}, clock_floor: 9}
  end

  defp forge(term) do
    {:ok, payload} = StateCodec.encode_term(term)
    header = <<"YXSC", 1::16, byte_size(@key)::32, @key::binary, byte_size(payload)::64>>
    header <> :crypto.hash(:sha256, [header, payload]) <> payload
  end

  defp encode!(doc, key \\ @key) do
    {:ok, bytes} = StateCodec.encode(doc, key)
    bytes
  end

  describe "round trip" do
    test "decode(encode(doc)) has the same canonical state, for a rich doc with pending" do
      doc = sample_doc()
      assert doc.pending != [], "fixture must carry pending state"
      {:ok, restored} = StateCodec.decode(encode!(doc), @key)
      assert StateCodec.canonical_state(restored) == StateCodec.canonical_state(doc)
      assert restored.pending == doc.pending
      assert restored.types == doc.types
      assert restored.clock_floor == 9
      assert restored.client_namespaces == %{77 => "ns-hash"}
      assert YMap.get(restored, "m", "float") === 2.0
      assert YMap.get(restored, "m", "negzero") === -0.0
      assert Encoding.encode_update(restored) == Encoding.encode_update(doc)
    end

    test "local-only values the wire cannot carry still round-trip exactly" do
      doc = Doc.new(client_id: 1) |> YMap.set("m", "k", {:type, [:text, %{1 => 2.5}]})
      {:ok, restored} = StateCodec.decode(encode!(doc), @key)
      assert YMap.get(restored, "m", "k") === {:type, [:text, %{1 => 2.5}]}
    end

    test "empty doc round-trips" do
      doc = Doc.new(client_id: 1)
      {:ok, restored} = StateCodec.decode(encode!(doc), @key)
      assert StateCodec.canonical_state(restored) == StateCodec.canonical_state(doc)
    end

    test "encoding is deterministic and canonical" do
      doc = sample_doc()
      bytes = encode!(doc)
      assert encode!(doc) == bytes
      {:ok, restored} = StateCodec.decode(bytes, @key)
      assert encode!(restored) == bytes
    end

    test "deleted items keep their original content and flags (not a wire normalization)" do
      doc = Doc.new(client_id: 5) |> Text.insert("t", 0, "hello") |> Text.delete("t", 1, 2)
      {:ok, restored} = StateCodec.decode(encode!(doc), @key)
      contents = fn d -> Enum.map(Doc.all_items(d), &{&1.id, &1.content, &1.deleted}) end
      assert contents.(restored) == contents.(doc)
      assert Enum.any?(contents.(doc), &match?({_, {:string, "el"}, true}, &1))
    end
  end

  describe "rejected input is an explicit error, never a state" do
    test "every single-byte corruption is refused" do
      bytes = encode!(Doc.new(client_id: 3) |> Text.insert("t", 0, "abc"))

      for i <- 0..(byte_size(bytes) - 1) do
        <<pre::binary-size(i), b, post::binary>> = bytes
        corrupt = <<pre::binary, Bitwise.bxor(b, 0x5A), post::binary>>
        assert {:error, _} = StateCodec.decode(corrupt, @key), "byte #{i} accepted"
      end
    end

    test "every truncation is refused" do
      bytes = encode!(sample_doc())

      for n <- Enum.uniq(Enum.to_list(0..80) ++ Enum.to_list(0..(byte_size(bytes) - 1)//97)) do
        assert {:error, _} = StateCodec.decode(binary_part(bytes, 0, n), @key), "len #{n}"
      end
    end

    test "specific envelope errors" do
      bytes = encode!(Doc.new(client_id: 3))
      <<"YXSC", _v::16, rest::binary>> = bytes

      assert StateCodec.decode(bytes <> <<0>>, @key) == {:error, :trailing_bytes}

      assert StateCodec.decode(binary_part(bytes, 0, byte_size(bytes) - 1), @key) ==
               {:error, :truncated}

      assert StateCodec.decode("NOPE" <> rest, @key) == {:error, :bad_magic}

      assert StateCodec.decode(<<"YXSC", 2::16, rest::binary>>, @key) ==
               {:error, {:unsupported_version, 2}}

      assert StateCodec.decode(bytes, "other key") == {:error, :key_mismatch}
      assert StateCodec.decode(bytes, @key, max_bytes: 1) == {:error, :too_large}
      assert StateCodec.decode(bytes, :not_a_key) == {:error, :bad_key}
      assert StateCodec.encode(Doc.new(), String.duplicate("k", 4097)) == {:error, :bad_key}
      assert StateCodec.decode(:nope, @key) == {:error, {:malformed, :not_a_binary}}
    end

    test "a forged payload with a recomputed digest is still structurally validated" do
      forge = fn term ->
        {:ok, payload} = StateCodec.encode_term(term)
        header = <<"YXSC", 1::16, byte_size(@key)::32, @key::binary, byte_size(payload)::64>>
        header <> :crypto.hash(:sha256, [header, payload]) <> payload
      end

      {:ok, good} = StateCodec.canonical_state(Doc.new(client_id: 1) |> Text.insert("t", 0, "ab"))
      assert {:ok, _} = StateCodec.decode(forge.(good), @key)

      # Item claiming a length its content does not have.
      [{c, [item]}] = Map.to_list(elem(good, 7))
      bad_len = put_elem(good, 7, %{c => [put_elem(item, 7, 99)]})
      assert {:error, {:malformed, _}} = StateCodec.decode(forge.(bad_len), @key)

      # Sequence entry that names no stored block.
      bad_seq = put_elem(good, 8, %{"t" => [{12_345, 0}]})
      assert {:error, {:malformed, :sequence_target}} = StateCodec.decode(forge.(bad_seq), @key)

      # Overlapping blocks in one bucket.
      bad_overlap = put_elem(good, 7, %{c => [item, item]})
      assert {:error, {:malformed, _}} = StateCodec.decode(forge.(bad_overlap), @key)

      # Wrong top-level arity.
      assert {:error, {:malformed, _}} = StateCodec.decode(forge.({1, 2}), @key)
    end

    test "forged payloads violating BlockStore invariants are refused" do
      # A doc with two clients, a map key, a deletion, a pending blob.
      doc =
        Doc.new(client_id: 1)
        |> Text.insert("t", 0, "abc")
        |> YMap.set("m", "k", 1)
        |> Text.delete("t", 0, 1)

      {:ok, good} = StateCodec.canonical_state(%{doc | pending: ["xy"], pending_bytes: 2})
      assert {:ok, _} = StateCodec.decode(forge(good), @key)

      bad = fn label, term ->
        assert {:error, {:malformed, reason}} = StateCodec.decode(forge(term), @key), label
        reason
      end

      clients = elem(good, 7)
      [first | rest] = clients[1]
      last = List.last(clients[1])

      # Bucket overlap: shift every block after the first back into it.
      overlapped = [put_elem(first, 6, {:string, "aa"}) |> put_elem(7, 2) | rest]
      assert {:overlap, 1, _} = bad.("overlap", put_elem(good, 7, %{1 => overlapped}))

      # Dangling map_index id.
      assert :map_index = bad.("map_index", put_elem(good, 10, %{"m" => %{"k" => [{1, 999}]}}))

      # Delete-set ranges: inverted, empty, unsorted, overlapping.
      assert :delete_set = bad.("inverted", put_elem(good, 6, %{1 => [{3, 1}]}))
      assert :delete_set = bad.("empty range", put_elem(good, 6, %{1 => [{1, 1}]}))
      assert :delete_set = bad.("unsorted", put_elem(good, 6, %{1 => [{5, 6}, {0, 1}]}))
      assert :delete_set = bad.("overlap", put_elem(good, 6, %{1 => [{0, 3}, {2, 4}]}))
      assert :delete_set = bad.("no ranges", put_elem(good, 6, %{1 => []}))

      # pending_bytes must be the sum of the blob sizes.
      assert :pending_bytes_sum = bad.("pending sum", put_elem(good, 5, 3))

      # sequence_len must match each sequence.
      seq_len = elem(good, 9)

      assert :sequence_len =
               bad.("seq len", put_elem(good, 9, Map.update!(seq_len, "t", &(&1 + 1))))

      assert :sequence_len = bad.("seq len extra", put_elem(good, 9, Map.put(seq_len, "zz", 1)))

      # Sequence ids unique, and their items' parent is the sequence's type.
      seqs = elem(good, 8)
      [t0 | _] = seqs["t"]

      assert :sequence_duplicate =
               bad.("dup", put_elem(good, 8, Map.put(seqs, "t", [t0 | seqs["t"]])))

      moved = seqs |> Map.put("t", tl(seqs["t"])) |> Map.put("m", [t0 | seqs["m"]])
      moved_len = seq_len |> Map.update!("t", &(&1 - 1)) |> Map.update!("m", &(&1 + 1))

      assert :sequence_parent =
               bad.("parent", good |> put_elem(8, moved) |> put_elem(9, moved_len))

      # Ids and clocks stay in the Yjs number domain (< 2^53).
      assert :client_id = bad.("client_id", put_elem(good, 0, 9_007_199_254_740_992))
      assert :pending_bytes = bad.("pending_bytes", put_elem(good, 5, 9_007_199_254_740_992))

      far = %{9_007_199_254_740_992 => [put_elem(first, 0, 0)]}
      assert :clients = bad.("client bound", put_elem(good, 7, Map.merge(clients, far)))

      huge = put_elem(last, 0, 9_007_199_254_740_992)
      assert {:item, 1, _} = bad.("clock bound", put_elem(good, 7, %{1 => [huge]}))

      # Typed refs and content shapes.
      assert :types = bad.("type ref", put_elem(good, 2, %{"t" => :inherit}))
      assert :types = bad.("xml tag", put_elem(good, 2, %{"t" => {:xml_element, 1}}))
      doc_content = put_elem(first, 6, {:doc, "sub"})
      assert {:item, 1, _} = bad.("doc content", put_elem(good, 7, %{1 => [doc_content | rest]}))
      type_content = put_elem(first, 6, {:type, :map}) |> put_elem(7, 1)

      assert {:ok, _} =
               StateCodec.decode(
                 forge(
                   put_elem(good, 7, %{1 => [type_content]})
                   |> put_elem(8, %{})
                   |> put_elem(9, %{})
                   |> put_elem(10, %{})
                 ),
                 @key
               )

      bad_type = put_elem(type_content, 6, {:type, :gc})
      assert {:item, 1, _} = bad.("type content", put_elem(good, 7, %{1 => [bad_type]}))
    end

    test "an out-of-order update is held pending (fix #9) and the codec keeps it" do
      # With the clock-contiguity fix (yelixer#9) a client's later update no
      # longer integrates past a gap: it waits in pending, the state vector
      # stays at the contiguous end, and the codec must round-trip that.
      p = Doc.new(client_id: 5) |> Text.insert("t", 0, "ab")
      u1 = Encoding.encode_update(p)
      p3 = YMap.set(p, "m", "k2", 1)
      u4 = p3 |> YMap.set("m", "k4", 3) |> Encoding.encode_diff(Doc.state_vector(p3))
      {:ok, o} = Encoding.apply_update(Doc.new(client_id: 9), u1)
      {:ok, o} = Encoding.apply_update(o, u4)

      assert [%{id: %{client: 5, clock: 0}, length: 2}] = Doc.all_items(o)
      assert o.pending != [], "the gapped update must be held pending"
      assert Doc.state_vector(o).clocks == %{5 => 2}

      {:ok, restored} = StateCodec.decode(encode!(o), @key)
      assert StateCodec.canonical_state(restored) === StateCodec.canonical_state(o)
      assert restored.pending == o.pending
    end

    test "a forged per-client clock gap is still accepted (faithful to the store), overlap refused" do
      # Plan ruling #42693 (a): the codec stays faithful to whatever the store
      # holds and does not enforce clock contiguity. Engines before #9 could
      # produce such buckets; checkpoints from them are discarded by the
      # engine-identity key, not by this codec.
      p = Doc.new(client_id: 5) |> Text.insert("t", 0, "ab")
      {:ok, o} = Encoding.apply_update(Doc.new(client_id: 9), Encoding.encode_update(p))
      {:ok, good} = StateCodec.canonical_state(o)
      [ta] = elem(good, 7)[5]
      clear = fn t -> t |> put_elem(8, %{}) |> put_elem(9, %{}) |> put_elem(10, %{}) end

      assert {:ok, _} =
               StateCodec.decode(
                 forge(clear.(put_elem(good, 7, %{5 => [ta, put_elem(ta, 0, 4)]}))),
                 @key
               )

      assert {:error, {:malformed, {:overlap, 5, 1}}} =
               StateCodec.decode(
                 forge(clear.(put_elem(good, 7, %{5 => [ta, put_elem(ta, 0, 1)]}))),
                 @key
               )
    end

    test "decode bounds" do
      # Nesting deeper than the limit.
      deep = :binary.copy(<<8, 1>>, 300) <> <<0>>
      assert {:error, {:malformed, :too_deep}} = StateCodec.decode_term(deep)

      # A magnitude whose size exceeds the remaining input.
      assert {:error, {:malformed, :magnitude}} = StateCodec.decode_term(<<4, 200, 1, 2, 3>>)

      # A varint whose tenth group overflows 64 bits.
      over = <<7>> <> :binary.copy(<<0xFF>>, 9) <> <<0x7F>>
      assert {:error, {:malformed, :varint_overflow}} = StateCodec.decode_term(over)
    end

    test "non-canonical term encodings are refused" do
      # map keys out of order
      assert {:error, {:malformed, :map_key_order}} =
               StateCodec.decode_term(<<10, 2, 7, 1, ?b, 0, 7, 1, ?a, 0>>)

      # overlong varint
      assert {:error, {:malformed, :varint_overlong}} =
               StateCodec.decode_term(<<7, 0x81, 0x00, ?a>>)

      # leading-zero magnitude and negative zero
      assert {:error, {:malformed, :magnitude}} = StateCodec.decode_term(<<4, 2, 0, 1>>)
      assert {:error, {:malformed, :negative_zero}} = StateCodec.decode_term(<<5, 0>>)
      # unknown atom index, unknown tag, count beyond input
      assert {:error, {:malformed, {:atom_index, 200}}} = StateCodec.decode_term(<<3, 200, 1>>)
      assert {:error, {:malformed, {:tag, 99}}} = StateCodec.decode_term(<<99>>)
      assert {:error, {:malformed, :count}} = StateCodec.decode_term(<<8, 100>>)
      # NaN bit pattern is not a float
      assert {:error, {:malformed, :float}} =
               StateCodec.decode_term(<<6, 0x7F, 0xF8, 0, 0, 0, 0, 0, 0>>)
    end
  end

  describe "unsupported state is rejected, not normalized" do
    test "values outside the term grammar" do
      for value <- [
            self(),
            make_ref(),
            :some_atom,
            {:ok, :not_in_table},
            [1 | 2],
            <<1::3>>,
            ~D[2026-10-04]
          ] do
        doc = Doc.new(client_id: 1) |> YMap.set("m", "k", value)
        assert {:error, {:unsupported_state, _}} = StateCodec.encode(doc, @key), inspect(value)
      end
    end

    test "unknown struct fields" do
      doc = Map.put(Doc.new(client_id: 1), :surprise, 1)

      assert {:error, {:unsupported_state, {:doc_fields, [:surprise]}}} =
               StateCodec.encode(doc, @key)
    end

    test "an item filed under another client's bucket" do
      doc = Doc.new(client_id: 1) |> Text.insert("t", 0, "a")
      store = Yelixer.BlockStore.materialize_all(doc.store)
      [item] = store.clients[1]
      store = %{store | clients: %{2 => [item]}}
      assert {:error, {:unsupported_state, _}} = StateCodec.encode(%{doc | store: store}, @key)
    end
  end
end
