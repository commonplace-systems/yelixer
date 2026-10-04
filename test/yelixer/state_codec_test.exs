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
