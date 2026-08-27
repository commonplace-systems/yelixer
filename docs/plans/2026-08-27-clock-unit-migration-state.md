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
