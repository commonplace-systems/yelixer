# Clock-unit migration — state at 2026-08-27, before Round 1

**Read this before touching `lib/yelixer/item.ex`.** jes authorised the migration
("sure let's migrate", 16:50Z). Round 0 (measurement) is complete and landed.
**Round 1 (the fix) has not started. `item.ex` is untouched.**

## The defect, in one paragraph

yelixer sizes a `{:string, s}` block with `String.length/1` — Elixir **graphemes** —
and mints one clock per grapheme. yjs mints one per **UTF-16 code unit**. The two
disagree at any offset past a character where the units differ, which is invisible
on ASCII. Four populations, one root cause:

| population | mechanism | closed by a fresh client id? |
|---|---|---|
| **LOST / SILENTLY TRUNCATED** | reused `client_id` mints a clock the peer already consumed | **yes** |
| **CORRUPTED** | the origin reference into the base block lands mid-surrogate | **no** — a fresh id changes *who writes*, not *which position they point at* |
| **UNDER-DELETED** | a delete-set names the *deleted item's* client, so any deleter hits diverged clocks | n/a — never over-deletes, never lost |
| **MISPLACED ON READ** | the *integrating* side also counts graphemes | n/a — a minting-only fix leaves it |

The damage is **bounded, not cumulative**: the deficit is spent once and the clocks
realign. That is worse news than it sounds — **no state-vector comparison can detect
it afterwards**, because by the time anyone looks the clocks agree again.

## Round 1's scope (settled in Round 0, do not re-derive)

1. **Two coupled lines, not one.** `item.ex:263` `content_length` **measures**;
   `item.ex:230` `split_content` **slices** via `String.split_at/2`, which slices by
   grapheme regardless of what unit the offset arrives in. **Fixing only `:263` hands
   every offset computed against the new length to a splitter still in the old unit —
   silent corruption introduced by the fix.**
2. **`{:binary, _}` length**: `byte_size(b)` vs yjs's `ContentBinary.getLength() → 1`.
   One clock per byte against one total; on a 1 KB blob the deficit is 1023. **This is
   `commonplace-plan`'s extension under jes's parity goal, not something his words
   covered** — say so in the commit.
3. **Surrogate splits: B-up (clamp past the whole character).** Basis, and cite it:
   `y-crdt/yrs/src/block.rs:1488-1507` rounds up, and at `:1857-1865` the yjs U+FFFD
   logic was **ported and then commented out** with `//TODO: do we need that in Rust?`.
   yjs itself destroys the character (`yjs/yjs#248`). "Match yjs" here means reproduce
   data corruption. ⛔ **Port yrs's CHOICE, not yrs's CODE** — its `Block::splice`
   raw-offset handling is unconfirmed and is not a warrant.
4. **`text.ex:76-83` with the code**: it claims offsets count "codepoints, not
   graphemes" — false in both directions, naming a third unit the code never used.
5. **Public API contract → UTF-16**, ruled by default, jes's veto open.

## The acceptance document

`/tmp/.../scratchpad/L-postfix-predictions.md` held the 29-arm table; **the durable
copy is the arms' own retirement conditions, which every case carries in its text.**

⭐ **The rule that makes it an acceptance document: an arm that moves differently than
predicted is a FINDING, not an edit to the table.** Do not update a prediction to
match a result.

⚠️ **But first check the box line.** Each guarded run prints
`box: min avail X / peak BEAM rss Y / peak suites Z, over N samples`. A host-manufactured
red is indistinguishable from a prediction miss — the instrument drives a Node
subprocess with a per-RPC 5 s bound inside ExUnit's 60 s, and a loaded box has been
measured slowing things ~25×. **A miss whose box line shows a memory excursion is a
RE-RUN, not a finding and not a partial acceptance.**

## Counts, each over the population it names

| assertion | population | state |
|---|---|---|
| `--exact 11` | conformance | **green**, untouched by all of this |
| `--exact 17 --expect-failures 5` | clock divergence | **red by design, counts DOWN to 0** |
| `--exact 12 --expect-failures 5` | content divergence | **red by design** — independent defects the clock fix does NOT touch |
| `--min 414` | main suite | green |

⭐ **The clock job was 7 and is 5 because two arms MOVED, not because anything was
fixed.** The two `CORRUPTED` arms carry `@tag :parity_exception` — not excluded, green
today — because under B-up yelixer *preserves* the character where yjs destroys it.
**That is a decision, permanently correct-but-different, and must never be counted as
an unfixed defect.**

⚠️ **Known gap in those two arms, to fix in Round 1:** they assert absence of
corruption and that the two sides differ; **neither asserts the resulting POSITION.**
A B-up implementation that clamped the wrong way would leave every assertion green.
Add the exact expected string after a clamp-up.

## Not claimed by this migration

**`Array.push([1,2,3])` emits 3 structs / 34 bytes where yjs emits 1 struct / 22 bytes**,
both decoding to identical content. Real, unrelated to the clock unit, and the
migration's acceptance explicitly does not claim it.

## Traps that cost hours

- ⛔ **Build every fixture AND expectation from `\u{...}` escapes.** A typed `"Café"`
  normalises precomposed and is a *different string* from the committed decomposed
  fixture. Literals have silently normalised in transit elsewhere.
- ⛔ **The gap is a property of `(fixture, offset)`, not of a fixture**, and `gap_at`
  is an insufficient proxy — two adjacent offsets can both show `gap_at = 1` while only
  one destroys. Assert `splits_surrogate_pair?/2` directly.
- ⛔ **`small-test-dataset.bin` cannot diverge**: 13,108 non-ASCII characters, all BMP
  and precomposed, gap 0 everywhere. **"We tested with non-ASCII" is not the safety it
  looks like** — the protective property is gap 0, and non-ASCII is not gap 0.
- ⛔ **Auditing whether a thing is *recorded* needs an instrument that can say no.**
  A batch of probes certifies itself only when it is **mixed** — hits prove the
  search is not blind, zeros prove it can miss — and a batch is mixed **by luck**
  unless you seed it. Seed one **known-present** and one **known-absent**, and the
  absent one must be **real-but-absent** (a concept genuinely not in this tree),
  never gibberish: the fear being tested is that the probe matches your own
  vocabulary rather than your repo, and a nonsense token cannot fail that way.
  ⚠️ A mixed batch proves the instrument is not *globally* blind and says nothing
  about whether an individual zero used the right string — the failure is
  per-probe. And a **hit** is conclusive about the *string*, not about
  filed-ness: read the path, because a stale entry, a comment, and a live record
  all hit identically. Zero → control it before; hit → read the path after.
- ⛔ **`mix test --trace` disables per-test timeouts and forces `--max-cases 1`.** Never
  take a verdict from a traced run.

## The slot-gate gap, and the constraint on building it

This repo has **no `bin/require-slot.sh`**, and `bin/land-round.sh` contains no
slot check. Measured 2026-08-27 at both refs with a positive control:

    local main = origin/main = a149f7a   ahead = 0
    main:        land-round.sh grep -c require-slot -> 0   require-slot.sh -> ABSENT
    origin/main: same                               -> 0                   -> ABSENT
    control:     mix.exs present in both refs       -> OK

⛔ **Do not read that as protection.** The queue discipline that held all evening
was attention, not mechanism. A statement like "no token, so I cannot start by
accident" is a claim about the speaker, and elsewhere tonight it was *true of a
working tree and false of the deployed script* — the author reported the gate as
armed in good faith.

⛔ **Two constraints for whoever builds it, both learned from other repos' defects
rather than from ours:**

1. **The slot check must sit ABOVE the branch guard.** `land-round.sh:56` is
   `[ "$cur" = "main" ] || exit 64`. A slot gate placed below it — beside the
   other gates, which is the obvious spot — is reachable *only* from `main`, and
   `main` is precisely where it will not exist until it lands. The layout builds
   that trap automatically; nobody has to make a mistake. One repo tested its
   gate by checking out `main` to reach it, which swapped out the gate, and
   landed 18 commits out of turn.
2. **`exit 64` from a branch checkout is the BRANCH GUARD, never a slot refusal.**
   It is silent about every gate below it. "The gate refused me" and "the gate
   does not exist" are indistinguishable from off-main, and both feel like being
   stopped.

3. **The demo's negative control is the SPECIFIC rc, never a non-zero one.** A
   refusal from a non-`main` checkout must print **rc 76 (slot)**. If it prints
   **rc 64, the gate was not exercised** — the branch guard refused on its
   behalf. That is the control, not the pass. Six unreachable gates were shipped
   across the fleet on 2026-08-27 and every one would have been caught by
   demanding the specific code instead of "it refused".

⚠️ Test it by **inspecting the deployed blob**, not by running it:
`git show origin/main:bin/land-round.sh | grep -c require-slot`. Running a copy
from `/tmp` returns `rc 128` because the script does `cd "$(dirname "$0")/.."`
and leaves the repo — a plausible failure that reads like a result.

## ⚠️ FACE 5 AT THIS DOOR — DECLARED, NOT REPAIRED (19:12Z)

A RUN IS EVIDENCE ABOUT THE SHA IT RAN AGAINST AND DOES NOT TRAVEL FORWARD
(`dir`'s rule). Applied here, honestly:

```
last local run artifact:  tasks/bpwj0jeg3.output, 17:44:47Z
                          "=== clock === 17 tests, 8 failures"
arm-inversion commit:     852695a, 18:36:30Z   ← 52 MINUTES LATER
```

⇒ That artifact is a PRE-INVERSION run. Its `8 failures` is not a
contradiction of the landed `--expect-failures 5`; it is a measurement of a
different test file. **It has been reconciled by reading the two timestamps,
not by re-running anything.**

⛔ But the reconciliation does not make this tree gated. The instrument
itself moved after the last run:

```
852695a  18:36:30Z  bin/yx-test-guard  +68     ← the run predates even this
42b889e  18:38:37Z  bin/yx-test-guard  +12 -1
ca14e25  18:39:46Z  bin/yx-test-guard   +4 -2 · bin/land-round.sh · bin/README-rounds.md
```

⇒ **"My tree is gated" is FALSE here.** The true sentence is: *no suite has
ever run against the current `bin/yx-test-guard`, and the last suite that ran
at all ran against the pre-inversion divergence files.* The claim
"5-of-17 and 5-of-12 RED BY DESIGN" rests on **the text of
`.github/workflows/ci.yml`**, which is a statement of intent, not a
measurement.

⭐ This is the sharper variant of face 5, and it is `markdown`'s shape rather
than `next`'s: their ungated commits are prose on top of a gated tree; **mine
include three consecutive edits to the GATE SCRIPT.** A changed instrument
invalidates a prior reading more completely than changed prose does.

✅ Repair taken is `dir`'s: **THE HONEST FIX IS THE LABEL, NOT THE RUN.**
Re-running two divergence suites plus the conformance suite to bless a tree
whose only untested change is a comment header would consume the box `log`
holds, to change nothing that is perishable. The label goes here, where the
successor who is about to trust the count table will read it.

⛔ **Consequence for the migration, and this is the load-bearing part:** the
count table in this document is `--expect-failures 5` × 2 **as configured**,
not as observed at this sha. The FIRST act of Round 1, before any edit to
`lib/yelixer/item.ex`, is to run both divergence suites and the conformance
suite under the current guard and record the observed counts — because the
migration's entire success signal is *the failure count going DOWN*, and a
baseline you inferred from a config file cannot go down.

## ✅ FACE 5 TIMESTAMP CORRECTED BY A BETTER INSTRUMENT (19:22Z)

The declaration above dated the last run from a task-output artifact at
17:44:47Z. `markdown`'s instrument is stronger — the NEWEST `_build` mtime,
which cannot be defeated by a later overwrite the way "files touched in a
window" can:

```
_build/test/lib/yelixer/.mix/.mix_test_failures   2026-08-27 18:35:46Z
CONTROL: _build visible to find                   163 files
```

⇒ The last `mix test` at this door was **18:35:46Z**, not 17:44:47Z. It is
still BEFORE `852695a` (18:36:30Z) and before all three `bin/yx-test-guard`
edits, so **the conclusion is unchanged**: no suite has run against the
current guard. The base for the ungated set stays `d5a7aaa`.

⭐ Recorded because a claim that survives a better instrument should say
which instrument it now rests on. The 17:44 artifact was a real run; it was
not the LAST one, and "the newest artifact I happened to find" and "the
newest artifact" are different objects.

## 📋 ROUND 1 PRE-REGISTRATION — THE BASELINE, FIXED BEFORE THE SLOT

⛔ Written now, while the box belongs to another door, so it cannot be
tuned after seeing a number. Pre-registration is only worth anything if it
predates the result.

**Step 0, before ANY edit to `lib/yelixer/item.ex` — the exact commands:**
```
bin/yx-test-guard --exact 17 --expect-failures 5 -- \
    mix test test/yelixer/divergence_clock_test.exs   --include divergence
bin/yx-test-guard --exact 12 --expect-failures 5 -- \
    mix test test/yelixer/divergence_content_test.exs --include divergence
bin/yx-test-guard --exact 11 -- \
    mix test test/yelixer/diff_yjs_test.exs --include diff_yjs
```

**What each outcome MEANS, decided now:**

| observed | verdict |
|---|---|
| both divergence suites report exactly 5 failures | baseline CONFIRMED; the CI config was right; proceed |
| a different failure count, suite otherwise healthy | baseline is the OBSERVED number. Record it, do NOT edit the gate to match, and the success criterion becomes "below the observed number" |
| a count assertion fires (`--exact` mismatch) | STOP. The instrument moved under me; no migration starts against an instrument I cannot read |
| conformance `--exact 11` not green | STOP. The oracle is the thing the migration is measured against |

⛔ **No arm of this table permits editing a gate before the baseline is
recorded.** The temptation at the moment a count disagrees is to fix the
gate; that converts the only progress signal the round has into a constant.

⚠️ **This is three suites, not one — a real box cost, and it buys no
behaviour change.** It is still Step 0, because a migration whose success
signal is "the failure count went down" cannot start from a number nobody
measured.

## ✅ ROUND 1 LANDED — 5 → 2 ON THE CLOCK AXIS (19:29Z)

Both coupled lines moved together. `content_length/1` and `split_content/2`
now share `utf16_split_at/2`, so the measurer and the slicer cannot drift.

```
             BASELINE (19:26)              POST-FIX (19:29)
clock        17 tests, 5 failures          17 tests, 2 failures
content      12 tests, 5 failures          12 tests, 5 failures   (untouched — other root cause)
conformance  11 tests, 0 failures          11 tests, 0 failures   ⇒ NO REGRESSION at the oracle
```

**WHICH ARMS MOVED, by line number rather than by impression:**

| arm | before | after |
|---|---|---|
| `:886` READ/INTEGRATION, second txn dropped | RED | **RETIRED** |
| `:360` LOSS, edit shorter than the gap | RED | **RETIRED** |
| `:406` LOSS, edit longer than the gap | RED | **RETIRED** |
| `:437` LOSS, deficit spent once then realigns | RED | **RETIRED** |
| `:807` UNDER-DELETION, straddling space | RED | still RED — **but on a different line** |
| `:711` NFC pos=7 negative control | GREEN | ⛔ **NEWLY RED** |

⛔ **`:711` IS A REGRESSION AND I AM NOT BURYING IT IN A NET COUNT.** An arm
that was green is red. The net 5→2 is real and it is not the whole story.

What is checkable about it: the failure moved to line **741**, which means
line 739 — `assert oracle_text == yelixer_text` — **passed**. yjs and yelixer
now agree on this fixture; both render `"Café 👩X🏽‍💻\n"`. The failing
assertion is `oracle_text == @nfc_string <> "X"`, a HARDCODED constant that
encodes "index 7 is the end of the string", which is true in graphemes and
false in UTF-16 units (👩 occupies units 5–6, so 7 sits between 👩 and 🏽).

⛔ **I HAVE NOT EDITED THAT CONSTANT AND WILL NOT IN THIS ROUND.** "The code
is right and the test's expected value is stale" is the most dangerous
sentence available to someone who just changed the code, and my belief that
it is true here is not the same as its being demonstrated. It stays RED and
counted. A later round retires it with an oracle-derived expectation rather
than a hand-written one — the arm should not carry a constant in *either*
unit.

`:807` moved from failing at `:844` (`assert oracle_text == yelixer_text`) to
failing at `:845` (`refute String.starts_with?(oracle_text, " ")`). The
parity assertion now passes; the remaining failure is the one its own
RETIREMENT comment predicted: **the delete-set's clock range is still
expressed in the old unit.** That is a different site, untouched by this
round, and the arm names it.

### ⛔ WHAT THIS ROUND DELIBERATELY DID NOT DO

- **`content_length({:binary, b})` still returns `byte_size(b)`; yjs returns
  1.** That is a real divergence and a real wire-format change, and NO arm in
  either suite measures it. Landing it here would have made the 5→2 signal
  un-attributable — I could not have said which change moved which count.
  It is a separate round.
- **Neither surviving test was edited.** No fix rides in on a measurement,
  and no measurement gets adjusted to flatter a fix.
- **`bin/land-round.sh`'s self-test hoist** — free per `plan`'s tier-2 ruling
  and `markdown`'s split, declined on SCOPE, not on slot cost.

### PERFORMANCE NOTE, STATED NOT HIDDEN

`utf16_length/1` allocates a UTF-16 binary per call, where `String.length/1`
did not. `content_length/1` is on the split path. No benchmark was run, so
this is a named cost with no number attached — it is not a claim that the
cost is small.

## ✅ ROUND 1 COMPLETE — 5 → 1 ON THE CLOCK AXIS, MAIN SUITE GREEN (22:08Z)

```
                       BASELINE 19:26     AFTER 22:08
full suite             (not taken)        423 tests, 0 FAILURES, 10 excluded   rc 0
clock divergence       17 / 5 failures    17 / 1 failure  (expected 1)         rc 0
content divergence     12 / 5 failures    12 / 5 failures (untouched)          rc 0
conformance oracle     11 / 0             11 / 0                               rc 0
box, whole window      —                  267 samples, MIN avail 2723 MB, MAX beams 4
```

**FOUR arms retired outright** (`:886` READ/INTEGRATION · `:360` and `:406` LOSS
· `:437` deficit-realign). **ONE remains** (`:807` UNDER-DELETION): its parity
assertion now PASSES and the residual failure is the one its own RETIREMENT
comment predicted — **the delete-set's clock range is still expressed in the
old unit.** That is a different site, untouched here, and it is Round 2's.

### ⛔ THE INTERMEDIATE STATE, RECORDED BECAUSE THE NET NUMBER HIDES IT

The first measurement after the code change read **5 → 2, not 5 → 1**. The
extra red was `:711`, an UNTAGGED test in the divergence file, which had been
GREEN: a regression into the DEFAULT suite, which would have made CI job 1
red. It is in this record because a net count of retired arms would have
concealed a green→red flip entirely.

Its cause was a hand-written constant with an unstated unit (`X` at the end
of the string — true only if `pos: 7` means seven GRAPHEMES). It was restated
positionally, deriving the expected value from the fixture and the DECLARED
UTF-16 unit, with a splitter independent of the subject's own.

### ⭐ THE MUTATION DEMONSTRATION, INCLUDING THE ARM THAT DID NOT FIRE

```
unmutated                          -> GREEN
utf16_split_at  offset + 1         -> RED, and the rendered text is visibly corrupted
utf16_split_at  offset - 1         -> GREEN  <- THE MUTATION WAS ABSORBED
```

The `-1` arm did not go red, and the reason is not that the assertion is
weak: offset 7 minus one lands on unit 6, the LOW surrogate of the woman
emoji, so `utf16_cut/2` reports `:surrogate` and the B-up clamp restores it
to 7. **The mutation landed on the one offset the clamp is built to repair.**

⭐ Established by POSITIVE CONTROL rather than assumed: the same mutation
takes the full clock suite from 2 failures to 6, so it was live and reaching
the code. Without that control, "both arms green" reads identically to "the
assertion cannot fail" — which is the vacuity this instrument exists to catch.
