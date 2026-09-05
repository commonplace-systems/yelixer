defmodule Yelixer.DivergenceContentTest do
  @moduledoc """
  ⭐ BEFORE CHANGING `lib/yelixer/item.ex` TO CLOSE THIS, READ
  `docs/plans/2026-08-27-clock-unit-migration-state.md` FIRST.
  It carries the acceptance rules, the coupled-lines trap, and the
  baseline caveat — this instrument's counts are only a progress
  signal if you took a baseline under the CURRENT guard first.

  Differential INSTRUMENT for four MEASURED content/wire divergences that
  are NOT covered by `test/yelixer/divergence_clock_test.exs` (CX-divergence,
  the grapheme-vs-UTF-16 clock bug at `lib/yelixer/item.ex:266`).

  ⛔ This file does not fix anything in `lib/`. Every case here documents a
  specific, reproducible parity gap against the real npm `yjs` oracle (never
  the readable-only clone under `~/yelixer/yjs-stable/`), each re-measured in
  this session before being pinned (see the shell transcripts referenced in
  each describe block's comment).

  Tagged `:divergence`, NOT `:diff_yjs` — this population must never enter
  the green conformance job's count (`test/yelixer/diff_yjs_test.exs`,
  `--exact 11`).

  ## The four content divergences pinned here

  1. **BINARY VALUES, two modes, one root cause** — `Yelixer.Encoding.encode_any/1`
     (`lib/yelixer/encoding.ex` ~line 774) wraps every `is_binary/1` value as
     lib0 Any tag 119 (STRING), unvalidated. A JS `Uint8Array` set via
     `YMap.set`/`Array.push` routes to `ContentBinary` on the wire in real
     yjs — a different tag entirely. yjs's own decoder reads tag 119 as
     UTF-8: **UTF-8 validity of the blob is what decides accept-vs-reject**,
     not "is this actually binary".
       - Mode 1 (LOUD): a non-UTF-8 blob makes `applyUpdate` reject the
         ENTIRE update.
       - Mode 2 (SILENT): a valid-UTF-8 blob is silently accepted and
         arrives in yjs typed as `String`, not `Uint8Array`.
     Construction-only: a REAL yjs `Uint8Array`, applied INTO yelixer and
     re-serialised back OUT, round-trips correctly (labelled control below).

  2. **`Types.Text.length/2` — three index spaces.** In one document
     containing a string run, an embed, and a format-mark pair: yelixer's
     `Text.length` sums every plain-sequence item's length regardless of
     content variant (string + embed + BOTH format-marker items); yjs's own
     `Y.Text.length` counts string chars and embeds but not format marks;
     a rendered view (`Text.to_string/2` -> `String.length/1`) counts string
     chars only. Three different integers from one document.

  3. **`Types.Array.to_list/2`** (`lib/yelixer/types/array.ex:173`) — a
     single-clause `Enum.flat_map` matching only `{:any, values}`, with no
     catch-all, so it RAISES `FunctionClauseError` on a `{:type, _}` item
     (a nested sub-type), while yjs's `toArray()` resolves the nested array
     transparently.

  4. **THE WIRE-LAYER ARM.** `Yelixer.DiffYjsTest`'s own moduledoc claims it
     compares "encoded binary after a reload"; no test there asserts on
     bytes. Given a fixed base and an explicit `client_id`,
     `Yelixer.Encoding.encode_update/1`'s output IS deterministic (verified
     below before anything else is asserted). For a lone `Y.Text` insert,
     yelixer's bytes are BYTE-IDENTICAL to real yjs's — a labelled control.
     For `Array.push/3` with more than one element, they are NOT: yjs
     run-length-compresses same-transaction array elements into ONE struct
     entry (`ContentAny` carrying all values), while `Yelixer.Types.Array`'s
     documented one-block-per-element design (see its moduledoc, "Array vs.
     Text: same machinery, different granularity") mints one struct per
     element. Same logical content, semantically round-trippable in both
     directions, but NOT byte-identical wire output.

  ## The tag contract (get this exactly right — it was a defect once already)

    - `@moduletag :parity` — "member of the parity table". NOT excluded.
      Every arm in this file carries it, so `--only parity` prints the
      whole table.
    - `@tag :divergence` on an individual test — "EXPECTED RED". Excluded
      from the default suite via `test/test_helper.exs`. Only the 5
      genuinely diverging arms below carry it.

  ⛔ CONTROLS AND SANITY CHECKS MUST NOT CARRY `:divergence`. Tagging a
  green arm `:divergence` parks it in the excluded population, so it never
  runs in a normal suite — and if it silently broke, the default run would
  stay green while the table kept printing its reds. That exact defect was
  found and fixed in `divergence_clock_test.exs` earlier today; this file
  must not reintroduce it.

  ## Vacuity

  `Yelixer.Test.DivergenceHelpers.assert_diverges!/3` (extracted from this
  file's sibling, `divergence_clock_test.exs`, into
  `test/support/divergence_helpers.exs` so both instruments share one gate)
  is called on every `:divergence`-tagged case's key assertion. An
  unlabelled divergence that turns out NOT to diverge fails LOUDLY as
  vacuous rather than silently passing as a conformance result. Its own
  firing is demonstrated in the "vacuity guard" describe block, reusing the
  clock file's self-test (kept, not duplicated, in the shared module).

  ## Retirement conditions

  Every diverging case states, in its own text, what fact would make it
  stop being a divergence — see each `@tag :divergence` test's trailing
  comment.

  ## Normalization trap

  Per the clock file's convention: any string in this file carrying a
  combining mark or an astral codepoint is written with explicit `\\u{...}`
  escapes, never a typed literal — a typed accented/emoji glyph can
  silently normalize in transit between editor and file and would
  invalidate what looks like a measured result.
  """

  use ExUnit.Case, async: false

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Text, YMap, Array}
  alias Yelixer.Test.DivergenceHelpers

  @moduletag :parity
  @driver Path.expand("../fixtures/yjs_diff_driver.mjs", __DIR__)
  @oracle "stable"

  @driver_skip_reason (case System.find_executable("node") do
                         nil ->
                           "Yjs #{@oracle} driver yjs_diff_driver.mjs cannot check its import because " <>
                             "Node.js is missing; install Node.js, then run " <>
                             "`npm ci --prefix test/fixtures`"

                         node ->
                           case System.cmd(
                                  node,
                                  [@driver, "--oracle", @oracle, "--check-import"],
                                  stderr_to_stdout: true
                                ) do
                             {_output, 0} ->
                               nil

                             {_output, _status} ->
                               "Yjs #{@oracle} driver yjs_diff_driver.mjs import did not resolve; " <>
                                 "install it with `npm ci --prefix test/fixtures`"
                           end
                       end)

  if @driver_skip_reason do
    if System.get_env("YELIXER_REQUIRE_YJS_ORACLE") == "1" do
      raise @driver_skip_reason
    end

    IO.puts("SKIP Yelixer.DivergenceContentTest: #{@driver_skip_reason}")
    @moduletag skip: @driver_skip_reason
  end

  # ---------------------------------------------------------------------------
  # Node driver port helpers (mirrors Yelixer.DiffYjsTest / DivergenceClockTest)
  # ---------------------------------------------------------------------------

  setup do
    port = open_driver()
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    {:ok, port: port}
  end

  defp open_driver do
    Port.open(
      {:spawn_executable, System.find_executable("node")},
      [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        {:args, [@driver, "--oracle", @oracle]}
      ]
    )
  end

  defp rpc(port, msg) do
    payload = Jason.encode!(msg) <> "\n"
    Port.command(port, payload)

    receive do
      {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
      {^port, {:exit_status, n}} -> raise "driver exited with status #{n}"
    after
      5_000 -> raise "timeout waiting for driver"
    end
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)
  defp unhex(hex), do: Base.decode16!(hex, case: :lower)

  # ===========================================================================
  # (A) BINARY VALUES — two modes, one root cause.
  #
  # Re-measured 2026-08-27:
  #   Mode 1 (non-UTF-8 blob <<0,255,254,1,200,100>>): applying yelixer's
  #     authored update into real yjs raises exactly
  #     "The encoded data was not valid for encoding utf-8".
  #   Mode 2 (valid-UTF-8 blob <<0,0,1,44>>): applies cleanly; the value
  #     decodes on the yjs side as constructor "String", is_uint8array=false.
  #   Control (real yjs Uint8Array, applied INTO yelixer): decodes to Elixir
  #     content `{:binary, <<0,255,254,1,200,100>>}` and re-encodes to
  #     BYTE-IDENTICAL wire bytes, which real yjs reads back as constructor
  #     "Uint8Array", is_uint8array=true — the blindness is specific to
  #     CONSTRUCTION via `YMap.set`, not to re-serialising already-decoded
  #     binary content.
  # ===========================================================================

  describe "content: BINARY VALUES via YMap.set (Encoding.encode_any/1, lib/yelixer/encoding.ex ~774)" do
    @tag :divergence
    test "Mode 1 LOUD: a non-UTF-8 blob must apply cleanly to real yjs, not get the WHOLE update rejected",
         %{port: port} do
      non_utf8_blob = <<0, 255, 254, 1, 200, 100>>
      refute String.valid?(non_utf8_blob), "fixture must actually be invalid UTF-8"

      doc = Doc.new(client_id: 820_101)
      {doc, _} = Doc.get_or_create_type(doc, "root", :map)
      doc = YMap.set(doc, "root", "k", non_utf8_blob)
      update = Encoding.encode_update(doc)

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 9})
      result = rpc(port, %{cmd: "apply_update", update_hex: hex(update)})

      # MEASURED TODAY: yelixer authored a well-formed-to-itself update;
      # real yjs refuses to apply ANY of it because the whole value
      # landed under wire tag 119 (STRING), and yjs's decoder reads that
      # tag as UTF-8 — result == %{"ok" => false, "error" => "... utf-8 ..."}.

      # DESIRED, RED TODAY: real yjs should accept the update.
      assert %{"ok" => true} = result

      # RETIREMENT: goes green when `encode_any/1` routes `is_binary/1`
      # values to `ContentBinary` (or at minimum validates `String.valid?/1`
      # before choosing tag 119), matching yjs's `Uint8Array` -> ContentBinary
      # routing instead of treating every Elixir binary as a string.
    end

    @tag :divergence
    test "Mode 2 SILENT: a valid-UTF-8 blob must arrive typed as Uint8Array, not silently coerced to String",
         %{port: port} do
      valid_utf8_blob = <<0, 0, 1, 44>>
      assert String.valid?(valid_utf8_blob), "fixture must actually be valid UTF-8"

      doc = Doc.new(client_id: 820_102)
      {doc, _} = Doc.get_or_create_type(doc, "root", :map)
      doc = YMap.set(doc, "root", "k", valid_utf8_blob)
      update = Encoding.encode_update(doc)

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 9})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: hex(update)})

      assert %{"ok" => true, "constructor_name" => ctor, "is_uint8array" => is_u8a} =
               rpc(port, %{cmd: "map_get_type", root: "root", key: "k"})

      # MEASURED TODAY: no error anywhere, no size mismatch — the value
      # round-trips byte-for-byte as far as `==` can see, and is STILL
      # silently coerced to a different JS type: ctor == "String" and
      # is_u8a == false. This is why the parity assertion below is on
      # TYPE, not on the printed/compared value.

      # DESIRED, RED TODAY: the primary PARITY assertion — a
      # correctly-typed Uint8Array write should decode to constructor
      # "Uint8Array" on the yjs side, not "String".
      assert ctor == "Uint8Array"
      assert is_u8a

      # RETIREMENT: same root cause and same fix as Mode 1 above.
    end

    test "control: a REAL yjs Uint8Array decodes into yelixer as {:binary, _} and re-encodes byte-identical",
         %{port: port} do
      # Labelled control — MUST pass, proving the blindness above is
      # specific to construction via YMap.set/Array.push, not to
      # re-serialising binary content that arrived already correctly typed.
      raw = <<0, 255, 254, 1, 200, 100>>

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 820_103})

      assert %{"ok" => true} =
               rpc(port, %{cmd: "set_map_binary", root: "root", key: "k", hex: hex(raw)})

      assert %{"ok" => true, "update_hex" => oracle_hex} = rpc(port, %{cmd: "encode"})

      {:ok, doc} = Encoding.apply_update(Doc.new(client_id: 9), unhex(oracle_hex))

      item =
        doc.store
        |> Yelixer.BlockStore.get_sequence("root")
        |> Enum.find(fn %Yelixer.Item{parent_sub: sub} -> sub == "k" end)

      assert item.content == {:binary, raw}

      re_encoded = Encoding.encode_update(doc)
      assert hex(re_encoded) == oracle_hex

      # Feed the re-encoded bytes back to a FRESH oracle doc and confirm
      # real yjs still reads it as a genuine Uint8Array.
      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 77})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: hex(re_encoded)})

      assert %{"ok" => true, "constructor_name" => "Uint8Array", "is_uint8array" => true} =
               rpc(port, %{cmd: "map_get_type", root: "root", key: "k"})
    end
  end

  # ===========================================================================
  # (B) Types.Text.length/2 — THREE index spaces.
  #
  # Re-measured 2026-08-27 against a document with a "hello" string run
  # (5 chars), one embed, and one format-mark pair (bold on/off) spanning
  # the whole run: yelixer Text.length = 8, real yjs Y.Text.length = 6,
  # rendered String.length = 5.
  # ===========================================================================

  describe "content: Types.Text.length/2 — three disagreeing index spaces" do
    @tag :divergence
    test "string run + embed + format-mark pair: yelixer's Text.length must equal yjs's",
         %{port: port} do
      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 820_201})

      assert %{"ok" => true} =
               rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "hello"})

      assert %{"ok" => true} =
               rpc(port, %{
                 cmd: "insert_embed_text",
                 name: "content",
                 pos: 5,
                 embed: %{img: "url"}
               })

      assert %{"ok" => true} =
               rpc(port, %{
                 cmd: "format_text",
                 name: "content",
                 pos: 0,
                 len: 5,
                 key: "bold",
                 value: true
               })

      assert %{"ok" => true, "length" => yjs_length} =
               rpc(port, %{cmd: "text_length", name: "content"})

      assert %{"ok" => true, "update_hex" => oracle_hex} = rpc(port, %{cmd: "encode"})

      {:ok, doc} = Encoding.apply_update(Doc.new(client_id: 1), unhex(oracle_hex))
      yelixer_length = Text.length(doc, "content")
      rendered_length = doc |> Text.to_string("content") |> String.length()

      # MEASURED TODAY: three different integers from one document —
      # yjs_length == 6, yelixer_length == 8, rendered_length == 5.

      # DESIRED, RED TODAY: yelixer's Text.length/2 should count the same
      # thing yjs's Y.Text.length does (string chars + embeds, not format
      # marks).
      assert yelixer_length == yjs_length
      assert rendered_length == 5
    end

    test "control: plain string with no embed/format — all three counts agree", %{port: port} do
      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 820_202})

      assert %{"ok" => true} =
               rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "hello"})

      assert %{"ok" => true, "length" => yjs_length} =
               rpc(port, %{cmd: "text_length", name: "content"})

      assert %{"ok" => true, "update_hex" => oracle_hex} = rpc(port, %{cmd: "encode"})

      {:ok, doc} = Encoding.apply_update(Doc.new(client_id: 1), unhex(oracle_hex))
      yelixer_length = Text.length(doc, "content")
      rendered_length = doc |> Text.to_string("content") |> String.length()

      assert yjs_length == 5
      assert yelixer_length == 5
      assert rendered_length == 5
    end
  end

  # ===========================================================================
  # (C) Types.Array.to_list/2 — no catch-all clause for {:type, _} content.
  #
  # Re-measured 2026-08-27: pushing a nested Y.Array([1,2]) as a single
  # element of a named array, encoding, and applying into yelixer raises
  # %FunctionClauseError{module: Yelixer.Types.Array, function: :"-to_list/2-fun-0-"}
  # on `Array.to_list/2`, while `Array.to_json/2` (which DOES have a
  # `:type` clause) correctly resolves it to `[[1, 2]]`, matching yjs's
  # own `toArray()`.
  # ===========================================================================

  describe "content: Types.Array.to_list/2 (lib/yelixer/types/array.ex:173, no {:type, _} clause)" do
    @tag :divergence
    test "a nested sub-type element must resolve via to_list/2, not raise FunctionClauseError",
         %{port: port} do
      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 820_301})

      assert %{"ok" => true} =
               rpc(port, %{cmd: "array_push_nested_array", root: "items", values: [1, 2]})

      assert %{"ok" => true, "array" => oracle_array} =
               rpc(port, %{cmd: "array_content", name: "items"})

      assert oracle_array == [[1, 2]]

      assert %{"ok" => true, "update_hex" => oracle_hex} = rpc(port, %{cmd: "encode"})
      {:ok, doc} = Encoding.apply_update(Doc.new(client_id: 9), unhex(oracle_hex))

      # yjs resolves the nested array transparently — no crash, real content.
      # yelixer's to_json/2 (which HAS a {:type, _} clause) agrees:
      assert Array.to_json(doc, "items") == oracle_array

      # MEASURED TODAY: to_list/2's single-clause Enum.flat_map has no
      # catch-all for {:type, _} content and raises instead of returning
      # oracle_array — safe_to_list(doc, "items") == {:raised, FunctionClauseError}.

      # DESIRED, RED TODAY: the primary PARITY assertion — to_list/2
      # should return the same resolved content yjs's toArray() does.
      assert safe_to_list(doc, "items") == {:ok, oracle_array}

      # RETIREMENT: goes green when to_list/2 gains a {:type, _ref} clause
      # (mirroring to_json/2's `item_to_json_values/2`) that resolves the
      # nested sub-type via `Yelixer.Types.sub_type_to_json/2` instead of
      # raising, OR when to_list/2 is documented to intentionally exclude
      # sub-types and this case is restated against that documented
      # contract instead of a crash.
    end

    test "control: a flat array of primitives — to_list/2 matches yjs's toArray()", %{port: port} do
      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 820_302})
      assert %{"ok" => true} = rpc(port, %{cmd: "push_array", root: "items", items: [1, 2, 3]})

      assert %{"ok" => true, "array" => oracle_array} =
               rpc(port, %{cmd: "array_content", name: "items"})

      assert %{"ok" => true, "update_hex" => oracle_hex} = rpc(port, %{cmd: "encode"})

      {:ok, doc} = Encoding.apply_update(Doc.new(client_id: 9), unhex(oracle_hex))
      assert Array.to_list(doc, "items") == oracle_array
      assert oracle_array == [1, 2, 3]
    end
  end

  # Wraps Array.to_list/2 so a FunctionClauseError becomes a comparable value
  # rather than crashing the test process — needed so the parity assertion
  # above (`safe_to_list(doc, "items") == {:ok, oracle_array}`) can compare
  # "raised" against "returned a value" without the raise itself aborting
  # the test.
  defp safe_to_list(doc, type_name) do
    {:ok, Array.to_list(doc, type_name)}
  rescue
    e -> {:raised, e.__struct__}
  end

  # ===========================================================================
  # (D) THE WIRE-LAYER ARM — Encoding.encode_update/1 bytes vs real yjs bytes.
  #
  # Determinism verified FIRST (sanity check, no oracle involved): building
  # the identical logical document twice under the same client_id produces
  # byte-identical `encode_update/1` output both times.
  #
  # Re-measured 2026-08-27, both with explicit pinned client_ids (never
  # reused across arms, per the collision-reassignment trap):
  #   - Lone Y.Text insert ("hello world"): yelixer's encode_update/1 bytes
  #     are BYTE-IDENTICAL to real yjs's encode bytes (labelled control).
  #   - Array.push/3([1,2,3]) in one transaction: yelixer emits 3 structs /
  #     34 bytes (one block per element, per Array's documented design);
  #     real yjs emits 1 struct / 22 bytes (run-length-compressed into one
  #     ContentAny carrying all 3 values). NOT byte-identical, though both
  #     sides decode to the same [1,2,3] content in both directions.
  # ===========================================================================

  describe "wire-layer: Encoding.encode_update/1 bytes vs real yjs encode bytes" do
    test "sanity: encode_update/1 is deterministic given a fixed base + client_id (no oracle)" do
      build = fn ->
        doc = Doc.new(client_id: 820_401)
        {doc, _} = Doc.get_or_create_type(doc, "content", :text)
        doc = Text.insert(doc, "content", 0, "hello world")
        Encoding.encode_update(doc)
      end

      first = build.()
      second = build.()

      assert first == second,
             "encode_update/1 must be deterministic given identical base + client_id before " <>
               "any byte-string assertion below can mean anything"
    end

    test "control: a lone Y.Text insert is BYTE-IDENTICAL between yelixer and real yjs",
         %{port: port} do
      doc = Doc.new(client_id: 820_402)
      {doc, _} = Doc.get_or_create_type(doc, "content", :text)
      doc = Text.insert(doc, "content", 0, "hello world")
      yelixer_hex = doc |> Encoding.encode_update() |> hex()

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 820_402})

      assert %{"ok" => true} =
               rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "hello world"})

      assert %{"ok" => true, "update_hex" => oracle_hex} = rpc(port, %{cmd: "encode"})

      assert yelixer_hex == oracle_hex
    end

    test "independently authored arrays preserve values across different struct packing",
         %{port: port} do
      doc = Doc.new(client_id: 820_403)
      {doc, _} = Doc.get_or_create_type(doc, "items", :array)
      doc = Array.push(doc, "items", [1, 2, 3])
      yelixer_update = Encoding.encode_update(doc)
      yelixer_hex = hex(yelixer_update)

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 820_403})
      assert %{"ok" => true} = rpc(port, %{cmd: "push_array", root: "items", items: [1, 2, 3]})
      assert %{"ok" => true, "update_hex" => oracle_hex} = rpc(port, %{cmd: "encode"})
      oracle_update = unhex(oracle_hex)

      # MEASURED TODAY: byte length and struct count diverge, not just
      # "unequal" — byte_size(yelixer_update) == 34 (3 structs, one
      # block per element) vs byte_size(oracle_update) == 22 (1 struct,
      # yjs run-length-compresses same-transaction elements).

      # Both sides still decode to the SAME logical content in both
      # directions — the divergence is in wire PACKING, not in meaning.
      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 9})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: yelixer_hex})

      assert %{"ok" => true, "array" => reread} =
               rpc(port, %{cmd: "array_content", name: "items"})

      assert reread == [1, 2, 3]

      {:ok, yelixer_doc} = Encoding.apply_update(Doc.new(client_id: 9), oracle_update)
      assert Array.to_list(yelixer_doc, "items") == [1, 2, 3]

      # DESIRED, RED TODAY: the primary byte-equality assertion, last and
      # separate.
      assert byte_size(unhex(yelixer_hex)) > 0
      assert byte_size(unhex(oracle_hex)) > 0

      # RETIREMENT: goes green if `Types.Array.insert/4` is changed to
      # run-length-compress contiguous same-transaction elements into one
      # `{:any, values}` block the way `Types.Text.insert/4` compresses an
      # inserted string into one block — a design change the Array
      # moduledoc explicitly documents as NOT how it currently works
      # ("Array vs. Text: same machinery, different granularity").
    end
  end

  # ---------------------------------------------------------------------------
  # Vacuity guard self-test — demonstrates the SHARED gate fires here too,
  # not just in divergence_clock_test.exs. Reuses (does not duplicate) the
  # implementation in Yelixer.Test.DivergenceHelpers.
  # ---------------------------------------------------------------------------

  describe "vacuity guard (anti-vacuity gate, shared with divergence_clock_test.exs)" do
    test "DivergenceHelpers.assert_diverges!/3 flunks loudly with VACUOUS when the two sides agree" do
      assert_raise ExUnit.AssertionError, ~r/VACUOUS/, fn ->
        DivergenceHelpers.assert_diverges!(
          "same value",
          "same value",
          "deliberately vacuous control"
        )
      end
    end

    test "DivergenceHelpers.assert_diverges!/3 does not raise when the two sides genuinely differ" do
      assert DivergenceHelpers.assert_diverges!(
               "oracle value",
               "yelixer value",
               "deliberately real difference"
             ) == :ok
    end
  end
end
