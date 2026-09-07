defmodule Yelixer.DivergenceClockTest do
  @moduledoc """
  ⭐ BEFORE CHANGING `lib/yelixer/item.ex` TO CLOSE THIS, READ
  `docs/plans/2026-08-27-clock-unit-migration-state.md` FIRST.
  It carries the acceptance rules, the coupled-lines trap, and the
  baseline caveat — this instrument's counts are only a progress
  signal if you took a baseline under the CURRENT guard first.

  Differential INSTRUMENT for the grapheme-vs-UTF-16 clock bug (CX-divergence).

  ⛔ This file does not fix anything in `lib/`. It measures a known bug:
  `lib/yelixer/item.ex:266` sizes `{:string, s}` with `String.length/1`
  (Elixir GRAPHEMES) and mints one clock per grapheme, while yjs mints
  one clock per UTF-16 CODE UNIT. Every case here documents a specific,
  reproducible consequence of that mismatch against the real npm `yjs`
  oracle (never the readable-only clone under `~/yelixer/yjs-stable/`).

  Tagged `:divergence`, NOT `:diff_yjs` — this population must never
  enter the green conformance job's count (`test/yelixer/diff_yjs_test.exs`,
  `--exact 11`).

  ## Why THREE axes, not two

  1. **LOSS** — position-independent, follows the AUTHOR'S CLOCK. A doc
     reloaded under the SAME client_id mints a clock the yjs peer
     already considers consumed, so yjs (correctly, by its own rules)
     drops or truncates the update as redundant. Closed by a
     per-operation fresh id.

  2. **CORRUPTION** — clock-independent, follows the ORIGIN REFERENCE an
     edit makes into existing content. Survives a fresh id: a brand-new
     id has never seen the base block, but the numeric clock offset it
     computes for its left-origin still lands on the WRONG UTF-16 unit,
     because that offset counts graphemes, not units. When it lands
     strictly inside a surrogate pair, yjs destroys that character into
     two U+FFFD.

  3. **UNDER-DELETION** — a delete-set entry names the DELETED item's
     client, not the deleter's, so a delete authored by *any* id
     (fresh or reused) still targets the diverged clocks of the text it
     removes. Unlike LOSS, a delete is never silently dropped, and
     unlike CORRUPTION, it never destroys a character into U+FFFD —
     upstream simply removes fewer UTF-16 units than yelixer intended,
     leaving a residual character behind. Never over-deletion.

  Plus a fourth, orthogonal case: the READ/INTEGRATION path, where the
  SAME wire bytes — authored ENTIRELY by real yjs, with ZERO yelixer
  authorship — render differently on each side, because the
  *integrating* side also counts graphemes when it resolves an
  incoming item's origin reference.

  ## The discriminator rule (read this before adding a case)

  "The fixture has a gap" is NOT the discriminator — the gap is a
  property of `(fixture, offset)`, not of the fixture: a fixture with
  non-equal grapheme/codepoint/UTF-16 counts still has offsets where
  the two implementations AGREE (see the labelled negative controls
  below). `gap_at(offset)` (whether the running UTF-16-vs-grapheme
  deficit is nonzero) is *also* an insufficient proxy: two adjacent
  offsets can both show `gap_at = 1` while only one of them actually
  destroys a character (see the NFC pos=6 vs pos=7 pair below). The
  only reliable check is the programmatic one in
  `splits_surrogate_pair?/2`, computed directly against the fixture's
  real UTF-16 units — never against a proxy.

  ## The vacuity rule

  An unlabelled divergence case that turns out NOT to diverge must FAIL
  AS VACUOUS, not silently pass as if it were a parity result — an arm
  that cannot diverge is not coverage, and it looks exactly like
  coverage in a green count. `assert_diverges!/3` enforces this; its
  own firing is demonstrated in the "vacuity guard" describe block
  below (a deliberately vacuous input, asserted to raise).

  ## Retirement conditions

  Every diverging case states, in its own text, what would make it
  stop being a divergence. When that fact becomes true, the case goes
  green and the `:divergence` RED count must be explicitly restated —
  a pinned characterization with no retirement condition becomes a
  rule nobody can question.

  ## ⚖️ INVERTED ARMS: each `:divergence` case asserts the DESIRED
  ## (parity) outcome, and is RED TODAY

  Earlier, every arm here called `assert_diverges!/3` as a
  *precondition* before its final assertion — i.e. the arm's own gate
  demanded the two sides DISAGREE before letting the arm's real
  assertion run. That inverted the instrument's purpose: if the
  clock-unit fix landed and closed a divergence, `assert_diverges!/3`
  would flunk as VACUOUS one line earlier, and the arm's failure COUNT
  would stay exactly the same (measured: forcing one arm's two sides
  to agree still produced 17 tests / 7 failures, and
  `--expect-failures 7` reported green). The fix could land, work
  perfectly, and CI would be indistinguishable from the fix having
  done nothing.

  Every `:divergence` arm below now asserts the OPPOSITE: that the two
  sides AGREE. That assertion is RED today (the bug is still present)
  and goes GREEN exactly when the underlying defect closes —
  `--expect-failures` then counts DOWN (**5 → 0 here**, 5 → 0 in
  `divergence_content_test.exs`) instead of holding at a constant. The
  measured CURRENT (diverging) value is kept in a `# MEASURED TODAY:`
  comment on every arm so the evidence captured before this rewrite is
  not lost — only the ASSERTION changed, not the discriminator work.

  ⚠️ **This file's countdown target is 5, not 7.** Two of the original
  seven `:divergence` arms (both in the CORRUPTION axis — NFC pos=6 and
  NFD pos=7) were moved OUT of this population under the B-UP ruling
  (2026-08-27, see that axis's describe block below): the fix for those
  two does not converge yelixer's output with real yjs's — it makes
  them PERMANENTLY, CORRECTLY different, which can never satisfy a
  countdown defined as reaching 0. They now carry
  `@tag :parity_exception` instead, are NOT excluded from the default
  suite (their guarantee already holds today, independent of the
  clock-unit fix — see their describe block for why), and are GREEN
  today, not red. So: **`:divergence` here is 5 arms (LOSS ×3,
  UNDER-DELETION ×1, READ/INTEGRATION ×1), counting 5 → 0 as the
  clock-unit fix lands; `:parity_exception` here is 2 arms (both
  CORRUPTION), already at its permanent GREEN state today.**

  ⛔ **This inversion is permitted ONLY because the population is
  GATED.** `:divergence` is excluded from the default suite via
  `test/test_helper.exs`, so an arm that is deliberately red today
  does not break `mix test`, CI's default gate, or
  `bin/yx-test-guard`'s floor. In an UNGATED population — one that
  runs by default — shipping a test that is red on `main` on purpose
  would be actively wrong (it would either be ignored by everyone or
  it would block unrelated work); it is only sound here because
  `:divergence` tests are opt-in via `--include divergence` and are
  never part of what "the suite is green" means for this project. Do
  not copy this pattern into a test file that is not similarly gated.

  `assert_diverges!/3` did not go away — see
  `test/support/divergence_helpers.exs`'s moduledoc for what it is for
  now (a separate, labelled vacuity CONTROL, exercised only in the
  "vacuity guard" describe block below) and what it must never be used
  for again (a precondition inside a divergence arm).

  ## A trap worth naming: normalization in Elixir source

  A typed literal like `"Café"` in Elixir source is precomposed (NFC)
  and is a DIFFERENT STRING from a decomposed (NFD) fixture, even
  though they render identically. To avoid ever depending on how an
  editor/tool round-trips a pasted combining-mark glyph, every string
  in this file that carries a combining mark, an astral codepoint, or
  is compared against such a string is written with explicit `\\u{...}`
  escapes — never a typed accented character.
  """

  use ExUnit.Case, async: false

  alias Yelixer.{Doc, Encoding, StateVector}
  alias Yelixer.Types.Text
  alias Yelixer.Test.DivergenceHelpers

  # ⭐ TWO LABELS, BECAUSE THERE ARE TWO ORTHOGONAL FACTS — and one tag
  # carrying both is how a control ends up in an excluded population for a
  # reason that does not apply to it.
  #
  #   :parity     — "member of the parity table". NOT excluded. Every arm here
  #                 carries it, so `--only parity` prints the whole table.
  #   :divergence — "EXPECTED RED". Excluded from the default suite
  #                 (test/test_helper.exs). Only the diverging arms carry it.
  #
  # ⛔ THE CONTROLS DELIBERATELY DO NOT CARRY :divergence. A green control is
  # not expected-red, and tagging it so would park the anti-vacuity gates and
  # negative controls in the excluded population — meaning THE GUARDS FOR THIS
  # WHOLE TABLE WOULD NEVER RUN IN A NORMAL SUITE. If one silently broke, the
  # default run would stay green while the table kept printing its reds, which
  # is exactly what a harness that ALWAYS reports divergence would print.
  # Carrying :parity alone, they run in the default suite and a regression
  # turns the ORDINARY run red.
  #
  # ⛔ Fixed with two labels, never two copies: duplicating an arm makes two
  # tests fail together for one cause and inflates apparent protection.
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

    IO.puts("SKIP Yelixer.DivergenceClockTest: #{@driver_skip_reason}")
    @moduletag skip: @driver_skip_reason
  end

  # ---------------------------------------------------------------------------
  # Fixture bytes
  # ---------------------------------------------------------------------------

  # REAL yjs bytes, committed verbatim (not regenerated) — the canonical
  # fixture shared with commonplace-merkle-crdt's
  # test/fixtures/text_unicode_yjs.json. A Y.Text root "content" =
  # "Café 👩🏽‍💻\n" with a DECOMPOSED é (e + U+0301 combining acute) and
  # a 4-codepoint ZWJ emoji, authored by client 4103.
  @nfd_hex "0101872000040107636f6e74656e741743616665cc8120f09f91a9f09f8fbde2808df09f92bb0a00"

  # The same visible string, built explicitly PRECOMPOSED (NFC), so we
  # have a second fixture whose gap lands at a different offset.
  @nfc_string "Caf\u{00E9} \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}\u{000A}"

  # The decomposed form, spelled with explicit codepoints for every
  # assertion in this file — never pasted as a literal accented glyph.
  @nfd_string "Caf\u{0065}\u{0301} \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}\u{000A}"

  # ---------------------------------------------------------------------------
  # Unit-counting + surrogate-pair helpers (the "five facts" + discriminator)
  # ---------------------------------------------------------------------------

  defp graphemes(s), do: String.length(s)
  defp codepoints(s), do: s |> String.codepoints() |> length()

  # Expands `s` into its real UTF-16 code units (surrogate pairs split
  # out explicitly), mirroring exactly what a JS string's `.length` /
  # index space is built from. This is the ground truth the surrogate
  # check below is computed against — never a `gap_at` proxy.
  defp utf16_units(s) do
    s
    |> String.to_charlist()
    |> Enum.flat_map(&utf16_units_for_codepoint/1)
  end

  defp utf16_units_for_codepoint(cp) when cp > 0xFFFF do
    v = cp - 0x10000
    high = 0xD800 + div(v, 1024)
    low = 0xDC00 + rem(v, 1024)
    [high, low]
  end

  defp utf16_units_for_codepoint(cp), do: [cp]

  defp utf16_length(s), do: s |> utf16_units() |> length()

  defp high_surrogate?(unit), do: unit in 0xD800..0xDBFF

  # THE required programmatic check (not the `gap_at` proxy): given the
  # REAL string `s` and a 0-indexed UTF-16 unit `clock`, does splitting
  # `s` immediately after unit `clock` land strictly inside a surrogate
  # pair? True iff unit `clock` itself is a HIGH surrogate — splitting
  # right after it separates it from its LOW half.
  # Splits a string at a UTF-16 CODE UNIT offset.
  #
  # Deliberately a SEPARATE implementation from `Item.utf16_split_at/2`:
  # a test that reuses the subject's own splitter cannot fail when the
  # subject's splitter is wrong. No surrogate clamping here -- the
  # offsets this is called with are whole-character boundaries, and a
  # mid-surrogate offset should raise rather than be quietly repaired.
  defp utf16_split_units(s, offset) do
    u = :unicode.characters_to_binary(s, :utf8, {:utf16, :little})
    at = offset * 2
    <<l::binary-size(at), r::binary>> = u

    {:unicode.characters_to_binary(l, {:utf16, :little}, :utf8),
     :unicode.characters_to_binary(r, {:utf16, :little}, :utf8)}
  end

  defp splits_surrogate_pair?(s, clock) do
    units = utf16_units(s)
    clock >= 0 and clock < length(units) and high_surrogate?(Enum.at(units, clock))
  end

  # THE vacuity guard. `label` must be present in every call site so a
  # failure (vacuous or real) is self-describing without cross-referencing
  # line numbers. Fails LOUDLY and distinctly ("VACUOUS") when the two
  # sides actually agree, rather than letting the case masquerade as a
  # conformance pass.
  # Extracted to `Yelixer.Test.DivergenceHelpers` (test/support/divergence_helpers.exs)
  # so `test/yelixer/divergence_content_test.exs` (CX-content-divergence) shares
  # the exact same vacuity gate rather than a second, possibly-drifted copy.
  defp assert_diverges!(oracle_val, yelixer_val, label),
    do: DivergenceHelpers.assert_diverges!(oracle_val, yelixer_val, label)

  # ---------------------------------------------------------------------------
  # Node driver port helpers (mirrors Yelixer.DiffYjsTest)
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

  defp remote_state_vector(port) do
    %{"ok" => true, "sv" => sv} = rpc(port, %{cmd: "state_vector"})

    Enum.reduce(sv, StateVector.new(), fn {client, clock}, acc ->
      StateVector.set(acc, String.to_integer(client), clock)
    end)
  end

  # ---------------------------------------------------------------------------
  # Fixture sanity — assert counts BEFORE using either fixture, per the
  # "typed literal silently normalizes" trap.
  # ---------------------------------------------------------------------------

  describe "fixture sanity (asserted before use, not assumed)" do
    test "NFD fixture: 7 graphemes / 11 codepoints / 14 UTF-16 units" do
      assert graphemes(@nfd_string) == 7
      assert codepoints(@nfd_string) == 11
      assert utf16_length(@nfd_string) == 14
    end

    test "NFC fixture: 7 graphemes / 10 codepoints / 13 UTF-16 units" do
      assert graphemes(@nfc_string) == 7
      assert codepoints(@nfc_string) == 10
      assert utf16_length(@nfc_string) == 13
    end

    test "committed NFD update bytes decode to the exact explicit-codepoint string", %{
      port: port
    } do
      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 4103})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: @nfd_hex})
      assert %{"ok" => true, "text" => text} = rpc(port, %{cmd: "text_content", name: "content"})
      assert text == @nfd_string
    end
  end

  # ---------------------------------------------------------------------------
  # AXIS 1: LOSS — position-independent, follows the author's own clock.
  # ---------------------------------------------------------------------------

  describe "axis: LOSS (same client_id, author's own clock)" do
    test "NFD, gap=7, safe origin (pos=1) — edit shorter than the gap must NOT be totally lost",
         %{port: port} do
      # FACT 1 fixture: NFD "Café 👩🏽‍💻\n" (@nfd_hex / @nfd_string)
      # FACT 2 normalization: NFD
      # FACT 3 offset: insertion at grapheme position 1 (right after "C")
      # FACT 4 units at offset: yelixer's left-origin clock = 0 (unit "C"),
      #   a plain BMP unit — this axis does NOT depend on position, this
      #   offset is chosen only to keep the CORRUPTION axis's surrogate
      #   effect out of the picture so LOSS is observed in isolation.
      # FACT 5 surrogate check: N/A to this axis by construction — assert
      #   it explicitly so a future reader can see the origin was
      #   deliberately picked safe, not accidentally so.
      assert splits_surrogate_pair?(@nfd_string, 0) == false

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 4103})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: @nfd_hex})
      remote_sv = remote_state_vector(port)
      assert StateVector.get(remote_sv, 4103) == 14

      {:ok, base} = Encoding.apply_update(Doc.new(client_id: 4103), unhex(@nfd_hex))
      edited = Text.insert(base, "content", 1, "abc")
      diff = Encoding.encode_diff(edited, remote_sv)

      # MEASURED TODAY: the gap (7) exceeds the new content's length (3):
      # encode_diff filters this client out entirely because yelixer's
      # own (wrong, grapheme-counted) local clock is still behind the
      # peer's real clock. Nothing is even attempted to be sent, so
      # oracle_text == @nfd_string — the edit is dropped in full.
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: hex(diff)})
      %{"ok" => true, "text" => oracle_text} = rpc(port, %{cmd: "text_content", name: "content"})
      yelixer_text = Text.to_string(edited, "content")

      # DESIRED, RED TODAY: with clocks minted per UTF-16 unit,
      # encode_diff would see the peer as not-yet-caught-up and include
      # this edit, so the peer's text would match yelixer's own.
      assert oracle_text == yelixer_text

      # RETIREMENT: goes green when yelixer mints one clock per UTF-16
      # code unit (lib/yelixer/item.ex:266) — then remote_sv's 14 and
      # yelixer's own local clock agree after reload, and encode_diff
      # correctly includes this edit. Under the inversion this is
      # literally true: the assertion above IS that parity, so the fix
      # landing makes this arm GREEN, not merely non-vacuous.
    end

    test "NFD, gap=7, safe origin (pos=1) — edit longer than the gap must NOT be truncated",
         %{port: port} do
      # FACT 1/2/3 as above: NFD fixture, position 1, safe origin unit 0.
      # FACT 4/5: same safe-origin justification as the total-loss case.
      assert splits_surrogate_pair?(@nfd_string, 0) == false

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 4103})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: @nfd_hex})
      remote_sv = remote_state_vector(port)

      {:ok, base} = Encoding.apply_update(Doc.new(client_id: 4103), unhex(@nfd_hex))
      edited = Text.insert(base, "content", 1, "ABCDEFGHIJ")
      diff = Encoding.encode_diff(edited, remote_sv)

      # MEASURED TODAY: the gap is 7, so the first 7 of the 10 new
      # characters ("ABCDEFG") are silently dropped as already-known;
      # only "HIJ" survives, i.e.
      # oracle_text == "C" <> "HIJ" <> String.slice(@nfd_string, 1..-1//1).
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: hex(diff)})
      %{"ok" => true, "text" => oracle_text} = rpc(port, %{cmd: "text_content", name: "content"})
      yelixer_text = Text.to_string(edited, "content")

      # DESIRED, RED TODAY: none of the 10 new characters should be
      # dropped as already-known.
      assert oracle_text == yelixer_text

      # RETIREMENT: same root-cause fix as the total-loss case above,
      # and the same "goes green (not vacuous)" reasoning applies.
    end

    test "bounded, not cumulative: the deficit is spent once, then clocks REALIGN",
         %{port: port} do
      # This case exists to correct a too-pessimistic framing: the loss
      # is NOT unbounded/cumulative. The first edit spends the gap; a
      # second edit, once the running local clock has caught back up to
      # (or past) the peer's real clock, is integrated intact from the
      # point it catches up onward.
      #
      # ⭐ It is ALSO the reason this bug is invisible to the obvious
      # check someone would reach for: once clocks realign, a bare
      # state-vector comparison between the two sides reports EQUAL —
      # even though content was permanently and silently dropped along
      # the way. No state-vector check, alone, can detect this damage
      # after the fact.
      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 4103})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: @nfd_hex})

      {:ok, base} = Encoding.apply_update(Doc.new(client_id: 4103), unhex(@nfd_hex))

      # Edit 1: "abc" (3 chars) at pos=1 — entirely within the gap (7),
      # so it is dropped in full (see the total-loss case above).
      remote_sv_1 = remote_state_vector(port)
      edit1 = Text.insert(base, "content", 1, "abc")
      diff1 = Encoding.encode_diff(edit1, remote_sv_1)
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: hex(diff1)})

      # Edit 2: "DEFGH" (5 chars) — local clock was 7(base)+3(edit1)=10
      # going into this edit, ending at 15; the peer's real clock is
      # still 14 (edit1 never arrived). 15 > 14, so THIS TIME the diff
      # is non-empty: the tail beyond clock 14 survives ("H", the 5th
      # char), while "DEFG" (the first 4) are dropped the same way.
      remote_sv_2 = remote_state_vector(port)
      edit2 = Text.insert(edit1, "content", 4, "DEFGH")
      diff2 = Encoding.encode_diff(edit2, remote_sv_2)
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: hex(diff2)})

      yelixer_sv = Doc.state_vector(edit2)
      oracle_sv = remote_state_vector(port)

      %{"ok" => true, "text" => oracle_text} = rpc(port, %{cmd: "text_content", name: "content"})
      yelixer_text = Text.to_string(edit2, "content")

      # The clocks realign (illustrating the invisibility trap): a bare
      # state-vector comparison reports EQUAL even though content was
      # permanently and silently dropped along the way. This equality
      # holds both today and after the fix, so it is asserted, not
      # measured-as-a-symptom.
      assert StateVector.get(yelixer_sv, 4103) == StateVector.get(oracle_sv, 4103)

      # MEASURED TODAY: oracle is missing "abc" and "DEFG" that
      # yelixer's own local view still shows it accepted — content
      # permanently diverged even though the clocks above realigned.
      #   refute String.contains?(oracle_text, "abc")
      #   refute String.contains?(oracle_text, "DEFG")
      #   assert String.contains?(yelixer_text, "abc")
      #   assert String.contains?(yelixer_text, "DEFG")

      # DESIRED, RED TODAY: the primary parity assertion — no content
      # should have been dropped, so both sides' text should agree.
      assert oracle_text == yelixer_text
      assert String.contains?(oracle_text, "abc")
      assert String.contains?(oracle_text, "DEFG")

      # RETIREMENT: same root-cause fix as the other LOSS cases — once
      # clocks are minted per UTF-16 unit, there is no deficit to spend
      # in the first place, so the equal-state-vectors above stop
      # masking a real content loss and this arm goes GREEN (not merely
      # non-vacuous).
    end

    test "negative control: gap=0 pure-ASCII fixture round-trips losslessly under a reused id",
         %{port: port} do
      # Labelled negative control — this MUST pass, proving the harness
      # correctly reports agreement rather than being blind to it.
      # Fixture: plain ASCII "hello" — graphemes == codepoints == UTF-16
      # units == 5 everywhere, so there is no gap at any offset.
      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 4103})

      assert %{"ok" => true} =
               rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "hello"})

      assert %{"ok" => true} = rpc(port, %{cmd: "reload"})
      remote_sv = remote_state_vector(port)
      assert StateVector.get(remote_sv, 4103) == 5

      # Rebuild yelixer's own view of the same "hello" doc directly
      # (rather than round-tripping through the oracle's bytes), then
      # reload under the SAME client_id — the exact LOSS-axis shape —
      # and confirm that with gap=0 there is nothing to lose.
      {plain, _type} = Doc.new(client_id: 4103) |> Doc.get_or_create_type("content", :text)
      plain = Text.insert(plain, "content", 0, "hello")

      edited = Text.insert(plain, "content", 5, " world")
      diff = Encoding.encode_diff(edited, remote_sv)
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: hex(diff)})
      %{"ok" => true, "text" => oracle_text} = rpc(port, %{cmd: "text_content", name: "content"})
      yelixer_text = Text.to_string(edited, "content")

      assert oracle_text == yelixer_text
      assert oracle_text == "hello world"
    end
  end

  # ---------------------------------------------------------------------------
  # AXIS 2: CORRUPTION — clock-independent, follows the origin reference.
  # SURVIVES a fresh id: fresh client ids used throughout, never seen by
  # the peer before, so LOSS cannot be the explanation for anything here.
  # ---------------------------------------------------------------------------

  describe "axis: CORRUPTION (fresh client_id, origin reference into base block)" do
    # ⚖️ RULING (2026-08-27): B-UP — when a UTF-16 offset lands strictly
    # inside a surrogate pair, yelixer clamps UP, past the whole
    # character. Never corrupts, never refuses, never touches the wire
    # with a mid-surrogate reference.
    #
    # Basis (a reason, not a preference):
    #   - yrs (Rust, our exact UTF-8-native-string constraint) rounds up:
    #     y-crdt/yrs/src/block.rs:1488-1507 (`split_str` /
    #     `map_utf16_offset`). At block.rs:1857-1865 the yjs
    #     U+FFFD-replacement logic was ported and then commented out,
    #     with `//TODO: do we need that in Rust?` unresolved — someone
    #     with our exact constraint wrote the bug-for-bug version and
    #     chose not to enable it.
    #   - yjs's OWN behaviour is destructive: yjs-stable's
    #     src/structs/ContentString.js:47-66 replaces both surrogate
    #     halves with U+FFFD; acknowledged upstream as yjs/yjs#248 and
    #     unfixed there. "Match yjs" for this specific case means
    #     "reproduce data corruption" — not the goal.
    #   - "Up, not down" is because yrs rounds up, nothing else
    #     separates the two directions. (Carried, not re-derived: a
    #     possible latent inconsistency in yrs's own
    #     `Block::splice`/block.rs:448, setting `item.len` from the raw
    #     uncorrected offset, is unconfirmed and NOT a reason to copy
    #     yrs's arithmetic — only its CHOICE of direction is precedent.)
    #
    # The old implementation moved content but left raw clock IDs behind.
    # That was corruption in our emitted references, not a necessary consequence
    # of B-up. Local clamped edits now carry the actual scalar boundary to Yjs.
    for {label, base, position, expected} <- [
          {"NFC", @nfc_string, 6, "Caf\u{00E9} \u{1F469}X\u{1F3FD}\u{200D}\u{1F4BB}\n"},
          {"NFD", @nfd_string, 7, "Cafe\u{0301} \u{1F469}X\u{1F3FD}\u{200D}\u{1F4BB}\n"}
        ] do
      @base base
      @position position
      @expected expected
      test "#{label}: local B-up clamp preserves exact position in both runtimes", %{port: port} do
        rpc(port, %{cmd: "reset", client_id: 4103})
        rpc(port, %{cmd: "insert_text", pos: 0, text: @base})
        %{"update_hex" => base_hex} = rpc(port, %{cmd: "encode"})
        {:ok, doc} = Encoding.apply_update(Doc.new(client_id: 555_601), unhex(base_hex))
        edited = Text.insert(doc, "content", @position, "X")
        rpc(port, %{cmd: "apply_update", update_hex: hex(Encoding.encode_update(edited))})
        %{"text" => text} = rpc(port, %{cmd: "text_content"})
        assert Text.to_string(edited, "content") == @expected
        assert text == @expected
        assert remote_state_vector(port) == Doc.state_vector(edited)
      end
    end

    test "negative control: NFC pos=7 — one unit past the same emoji, origin lands on the LOW surrogate (a valid boundary) — AGREES",
         %{port: port} do
      # This is the pair the discriminator-rule comment warns about:
      # NFC pos=6 (above) and pos=7 (here) both have a nonzero running
      # deficit (`gap_at = 1`) at this point in the string, yet only
      # pos=6 destroys anything. `gap_at` cannot tell them apart; the
      # surrogate check can.
      assert splits_surrogate_pair?(@nfc_string, 6) == false

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 4103})

      assert %{"ok" => true} =
               rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: @nfc_string})

      assert %{"ok" => true, "update_hex" => nfc_hex} = rpc(port, %{cmd: "encode"})

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 9})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: nfc_hex})

      fresh_id = 555_603
      {:ok, base} = Encoding.apply_update(Doc.new(client_id: fresh_id), unhex(nfc_hex))
      edited = Text.insert(base, "content", 7, "X")
      full_update = Encoding.encode_update(edited)

      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: hex(full_update)})
      %{"ok" => true, "text" => oracle_text} = rpc(port, %{cmd: "text_content", name: "content"})
      yelixer_text = Text.to_string(edited, "content")

      refute oracle_text =~ "�"
      assert oracle_text == yelixer_text

      # POSITIONAL, AND IT NAMES ITS UNIT.
      #
      # This assertion used to read `oracle_text == @nfc_string <> "X"`
      # -- X at the END of the string. That is only correct if `pos: 7`
      # means SEVEN GRAPHEMES, which is what yelixer minted before the
      # UTF-16 clock migration. It was a constant with an UNSTATED unit,
      # and the unit is exactly what the migration changed.
      #
      # Restated so the unit is IN the assertion: index 7 is a UTF-16
      # CODE UNIT offset, so X lands after the two units of the woman
      # emoji (5,6) and BEFORE the skin-tone modifier (7,8) -- not at
      # the end of the string. The expected value is DERIVED from
      # @nfc_string and the declared unit rather than transcribed from
      # what the code produced, so it still goes RED if the surrogate
      # clamp in `Item.utf16_split_at/2` resolves the other way.
      {before_7, after_7} = utf16_split_units(@nfc_string, 7)
      assert oracle_text == before_7 <> "X" <> after_7
    end

    test "negative control: NFC pos=4 and pos=5 — before the gap starts — AGREE",
         %{port: port} do
      assert splits_surrogate_pair?(@nfc_string, 3) == false
      assert splits_surrogate_pair?(@nfc_string, 4) == false

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 4103})

      assert %{"ok" => true} =
               rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: @nfc_string})

      assert %{"ok" => true, "update_hex" => nfc_hex} = rpc(port, %{cmd: "encode"})

      for pos <- [4, 5] do
        assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 9})
        assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: nfc_hex})

        fresh_id = 555_610 + pos
        {:ok, base} = Encoding.apply_update(Doc.new(client_id: fresh_id), unhex(nfc_hex))
        edited = Text.insert(base, "content", pos, "X")
        full_update = Encoding.encode_update(edited)

        assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: hex(full_update)})

        %{"ok" => true, "text" => oracle_text} =
          rpc(port, %{cmd: "text_content", name: "content"})

        yelixer_text = Text.to_string(edited, "content")

        assert oracle_text == yelixer_text, "pos=#{pos} was expected to agree"
      end
    end

    test "negative control: NFD pos=1 — well before any multi-unit grapheme — AGREES",
         %{port: port} do
      assert splits_surrogate_pair?(@nfd_string, 0) == false

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 9})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: @nfd_hex})

      fresh_id = 555_604
      {:ok, base} = Encoding.apply_update(Doc.new(client_id: fresh_id), unhex(@nfd_hex))
      edited = Text.insert(base, "content", 1, "X")
      full_update = Encoding.encode_update(edited)

      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: hex(full_update)})
      %{"ok" => true, "text" => oracle_text} = rpc(port, %{cmd: "text_content", name: "content"})
      yelixer_text = Text.to_string(edited, "content")

      assert oracle_text == yelixer_text
      assert oracle_text == "CXaf\u{0065}\u{0301} \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}\u{000A}"
    end
  end

  # ---------------------------------------------------------------------------
  # AXIS 3: UNDER-DELETION — a delete-set entry names the DELETED item's
  # client, so a delete authored by ANY id (fresh here, on purpose, to
  # show LOSS cannot be the explanation) still targets diverged clocks.
  # Never lost, never over-deletes — strictly fewer real units removed
  # than yelixer intended.
  # ---------------------------------------------------------------------------

  describe "axis: UNDER-DELETION (any deleter id; delete-set names the deleted item's client)" do
    test "NFD delete endpoints are UTF-16 units: five leaves the space, six removes it", %{
      port: port
    } do
      emoji = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}\n"

      for {units, expected} <- [{5, " " <> emoji}, {6, emoji}] do
        {:ok, doc} = Encoding.apply_update(Doc.new(client_id: 555_701), unhex(@nfd_hex))
        edited = Text.delete(doc, "content", 0, units)
        rpc(port, %{cmd: "reset", client_id: 9})
        rpc(port, %{cmd: "apply_update", update_hex: @nfd_hex})
        rpc(port, %{cmd: "apply_update", update_hex: hex(Encoding.encode_update(edited))})
        %{"text" => text} = rpc(port, %{cmd: "text_content"})
        assert Text.to_string(edited, "content") == expected
        assert text == expected
      end
    end

    test "negative control: NFD delete(0, 3 graphemes) — entirely before any multi-unit grapheme — AGREES",
         %{port: port} do
      assert splits_surrogate_pair?(@nfd_string, 2) == false

      deleter_id = 555_702
      {:ok, doc} = Encoding.apply_update(Doc.new(client_id: deleter_id), unhex(@nfd_hex))
      edited = Text.delete(doc, "content", 0, 3)
      full_update = Encoding.encode_update(edited)

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 9})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: @nfd_hex})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: hex(full_update)})
      %{"ok" => true, "text" => oracle_text} = rpc(port, %{cmd: "text_content", name: "content"})
      yelixer_text = Text.to_string(edited, "content")

      assert oracle_text == yelixer_text
      assert oracle_text == "\u{0065}\u{0301} \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}\u{000A}"
    end
  end

  # ---------------------------------------------------------------------------
  # READ/INTEGRATION path — E(B+U) ≠ Y(B+U). SAME wire bytes, applied to
  # BOTH implementations, with ZERO yelixer authorship anywhere in the
  # bytes: every item here was created by the real oracle, in two
  # separate transactions. This is not a write-side curiosity — it is a
  # second, independent confirmation site: the INTEGRATING side (not
  # just the authoring side) resolves an incoming item's origin
  # reference using its own (wrong) grapheme clock, so a fix confined
  # to the minting/authoring path would leave this broken.
  # ---------------------------------------------------------------------------

  describe "axis: READ/INTEGRATION (same bytes, both sides render differently)" do
    test "two real-yjs transactions, applied to both sides — yelixer's integration must NOT permanently drop the second one",
         %{port: port} do
      # FACT 1 fixture: built live from two separate real-yjs
      #   transactions: insert "Caf\u{0065}\u{0301} " (NFD "Café ", 6
      #   real UTF-16 units) at pos 0, then insert
      #   "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}\u{000A}" at real UTF-16
      #   position 5 (before the trailing space).
      # FACT 2 normalization: NFD for the first transaction.
      # FACT 3 offset: the second transaction's origin is real UTF-16
      #   unit 4 (the combining acute, the last unit of transaction 1).
      # FACT 4 units at offset: yelixer decodes transaction 1's content
      #   ("Café", 4 graphemes) as spanning ITS OWN clocks [0,4) — but
      #   the wire's origin reference for transaction 2 is the REAL
      #   clock 4, which does not correspond to ANY item boundary in
      #   yelixer's re-numbered world (transaction 1 only reaches
      #   internal clock 4 as its END, not a valid referenceable unit
      #   inside it in the way upstream meant). The dependency for
      #   transaction 2 (and transitively transaction 3, the trailing
      #   " ") never resolves, so both items sit in `doc.pending`
      #   forever — this update will never fully integrate no matter
      #   how many times it is retried.
      # FACT 5 surrogate check: N/A — this divergence is caused by an
      #   unresolvable origin, not a surrogate split. Not applicable by
      #   construction; noted rather than silently omitted.
      part1 = "Caf\u{0065}\u{0301} "
      part2 = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}\u{000A}"
      assert utf16_length(part1) == 6

      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 4103})

      assert %{"ok" => true} =
               rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: part1})

      assert %{"ok" => true} =
               rpc(port, %{cmd: "insert_text", name: "content", pos: 5, text: part2})

      assert %{"ok" => true, "update_hex" => two_txn_hex} = rpc(port, %{cmd: "encode"})

      # Apply to a FRESH oracle doc — this is real yjs reading its own
      # bytes back, the ground truth for "what these bytes mean".
      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 4103})
      assert %{"ok" => true} = rpc(port, %{cmd: "apply_update", update_hex: two_txn_hex})
      %{"ok" => true, "text" => oracle_text} = rpc(port, %{cmd: "text_content", name: "content"})

      # Apply the IDENTICAL bytes to a fresh yelixer doc. No yelixer
      # authorship anywhere in this update.
      {:ok, doc} = Encoding.apply_update(Doc.new(client_id: 1), unhex(two_txn_hex))
      yelixer_text = Text.to_string(doc, "content")

      # MEASURED TODAY: oracle_text ==
      #   "Caf\u{0065}\u{0301}\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}\u{000A} "
      # yelixer's integration is permanently stuck: only transaction 1
      # ever lands (yelixer_text == "Caf\u{0065}\u{0301}"), and only
      # transaction 1's state vector advances — `Doc.pending_info/1`
      # shows at least one item stuck in `doc.pending`.

      # DESIRED, RED TODAY: both transactions should integrate and the
      # rendered text should match real yjs's, with nothing left
      # pending.
      assert oracle_text == yelixer_text
      pending = Doc.pending_info(doc)
      assert pending.count == 0

      # RETIREMENT: goes green once item content length (and therefore
      # origin/right-origin resolution) counts UTF-16 code units on the
      # INTEGRATING side, not just the authoring side — this is the
      # "second door" the root-cause fix must also close. Verified true
      # under the inversion: once both doors are closed, transaction 2's
      # origin resolves, `doc.pending` empties, and the parity asserted
      # above holds for real.
    end
  end

  # ---------------------------------------------------------------------------
  # Vacuity guard self-test — demonstrates the gate actually fires. This
  # test itself must be GREEN: it asserts that a deliberately vacuous
  # input raises, proving the guard is not decoration.
  # ---------------------------------------------------------------------------

  describe "vacuity guard (anti-vacuity gate)" do
    test "assert_diverges!/3 flunks loudly with VACUOUS when the two sides actually agree" do
      assert_raise ExUnit.AssertionError, ~r/VACUOUS/, fn ->
        assert_diverges!("same value", "same value", "deliberately vacuous control")
      end
    end

    test "assert_diverges!/3 does not raise when the two sides genuinely differ" do
      # Sanity check on the guard itself: it must not be trivially
      # always-flunking either.
      assert assert_diverges!("oracle value", "yelixer value", "deliberately real difference") ==
               :ok
    end
  end
end
