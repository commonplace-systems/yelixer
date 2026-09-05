# Incoming Unicode repair — 2026-09-05

The bounded codec repair matches official Yjs **13.6.32** for the identical
incremental surrogate-interior edit that both previous dependency sets accepted
with wrong text. The isolated consumer now also passes the actual acknowledged
write/reopen route. Adoption review and landing remain separate and outstanding.
The [earlier application measurements](minimal-adoption-blockers.md) remain valid
for their exact old and candidate pins; they are not measurements of this repair.

## Mechanism and unchanged input

An origin, deletion range or state vector names an exact identity clock. Applying
the local upward-clamp policy there moves the split while leaving the remote
operation anchored to its original clock. `Item.split_at_clock/2` instead follows
Yjs `ContentString.splice`: replace each orphan surrogate half with U+FFFD,
preserving one clock unit per half and valid UTF-8. The local `Item.split/2`
policy stays upward-clamped. Integration anchors, incoming delete intervals,
partial overlap trimming and outgoing state-vector tails use the wire variant.

The original fixture bytes are unchanged:

```
base:  01016400040107636f6e74656e7405f09f98804100
delta: 01016403c464006401015800
```

Yjs author 100 inserts `\u{1F600}A`, then `X` at UTF-16 position 1.
Expected text is `\u{FFFD}X\u{FFFD}A`, state vector `{100: 4}`. Fresh loading
the final full-state update already passed before repair, so it is a separate
control and cannot establish incremental correctness.

## Baseline and repaired evidence

Baseline source is `7a4d9cb2797501a535d3726b1a39a1a7131bedeb`, with unchanged
`lib/` and the identical nine-case test file ported in. Its production tree is
identical to previously measured candidate `bcaec6a3520c59464bab87daaab7e4f76546c9c5`.
Baseline ran first; each checkout force-compiled its own codec before execution.
Source hashes and compiled module hashes/timestamps are retained in the evidence.
The repair changes production `lib/`.

The [machine-readable codec packet](compatibility-evidence/unicode-inbound-codec.json)
retains named outcomes, original failure output, synthetic oracle transcripts,
unchanged fixture hashes and compiled identities. Raw full-suite output is kept
locally; the public packet contains its hash and named outcomes.

| Population | Baseline | Repair |
|---|---|---|
| Eight incremental/neighbor cases | 4 pass, 4 fail; 1 full-state control excluded | 8 pass; 1 full-state control excluded |
| Separate fresh full-state control | 1 pass; 8 excluded | 1 pass; 8 excluded |

The four baseline failures map to specific clock-boundary uses:

| Use | Baseline wrong result | Repaired/Yjs result |
|---|---|---|
| Incoming origin/right-origin split | `\u{1F600}XAA` | `\u{FFFD}X\u{FFFD}A` |
| Delete first surrogate unit | `A` | `\u{FFFD}A` |
| Delete second surrogate unit | `A` | `\u{FFFD}A` |
| Encode tail from state vector `{100: 1}` | wrong tail content/origin bytes | exact Yjs tail bytes, clock 1, length 2, content `\u{FFFD}A` |

The four ASCII/scalar neighbors pass on both sources. The primary repaired case
also checks duplicate delivery, state vectors, discard/reload and subsequent
local/browser edits. Delete cases check duplicate delivery, reload and exact
delete sets. The outgoing tail comparison uses the same original history and
checks byte equality against Yjs, rather than independently authored packing.

The full suite executed **505 checks**: 475 tests, 33 properties and one doctest,
with four excluded content cases, zero failures, rc 0. Format, compilation with
warnings as errors, and the executable application-reference boundary check pass.
The repository floor of 414 is verified from named completion events.

The first exact-count gate correctly rejected an intentional exclusion even
though its 25 executed cases passed. To retain that guard unchanged and separate
the control, the same full-state test was moved into
`unicode_full_state_control_test.exs`. The initial identical nine-case baseline
and repair evidence is retained. Only the affected counted selections are rerun
after that file separation; the full suite is not repeated for a test move.
The final gates pass: exact 25 clock/incremental tests, exact one separate
full-state control, stable conformance 11/0, and separate preview conformance
11/0. The content gate executes 12 with exactly four expected failures. The
extracted control's unused aliases were removed and its final one-case run
also passes with test compilation warnings treated as errors.

## Consumer acceptance

Repaired codec: `59b04eb1ba4c03d003e91f8867db3bd90a517bf5`.
Consumer candidate: `fbae5bc27a2d4ed09eb23694d8416a0047cc8ab5` on
`compat/unicode-inbound-1`, based on the earlier isolated Next candidate
`f041456b159d8dbd6f11fa3cb8991880cc17766a`. Only Next's top-level Yelixer pin
changes; Yepochs `f184c9e9dd99b7baced407fb46632e887e3fb948`, Merkle
`9e7caf43e541864c68e9374b7a7f414a05cdfdc4` and the reducer override remain
unchanged. All 13 installed Git dependencies match the locks. The codec and app
were force-compiled and their module hashes/timestamps captured. App `lib/` is
unchanged.

The same unchanged original consumer boundary arm runs first: one executed,
zero failures, 25 excluded, rc 0. Its acknowledged text now matches real Yjs.
The new fixed-byte arm then sends the original base and delta above as separate
Attachment author frames: one executed, zero failures, 26 excluded, rc 0.
The stored commit retains the exact delta. Both sides render `\u{FFFD}X\u{FFFD}A`
followed by the synthetic welcome document. Its fixed root anchor places it before
the welcome text, while the earlier Workspace-authored arm appends at the end.

The delta is durably acknowledged with 11 log entries; duplicate delivery adds
no write. Attachment/Realm/SQLite teardown and reopen retain the same head, text
and 11 entries. A subsequent incremental browser `^` insertion converges and
receives another durable acknowledgment, with 13 entries. Expected/actual text,
heads, counts, wire transcripts and compiled identities are retained in the
[consumer evidence packet](compatibility-evidence/unicode-inbound-consumer.json).
Formatting and warnings-as-errors checks pass. No broad consumer suite or
Chromium acceptance was repeated for this bounded repair verification.

## Limits and landing shape

The bounded incoming-edit defect now converges in both the codec and the consumer's
durable acknowledgment/reopen route at the exact revisions above. This is not
blanket editing clearance. Library landing, consumer pin adoption and deployment
remain distinct actions requiring their own review and applicable gates.
No main branch or live store has been changed by this repair.

Standalone Yepochs and Merkle candidate manifests still name the earlier codec
`bcaec6a`; Next's explicit top-level override is what selects the repaired codec
in this verification. Publishing the repaired library and coherently advancing
its standalone consumers are follow-up adoption work, not completed pin changes
in those repositories. This bounded window changed only the Next override.

The previously accepted own-history semantic break is a compatibility cost, not
a preservation requirement or an additional adoption blocker. Four unrelated
content-divergence cases remain counted as expected failures: formatted-text
positions, two untyped map/binary cases, and nested-array access. This repair
does not claim broad Yjs type parity or a general surrogate-preserving JS string
representation inside Elixir.
