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
- ⛔ **`mix test --trace` disables per-test timeouts and forces `--max-cases 1`.** Never
  take a verdict from a traced run.
