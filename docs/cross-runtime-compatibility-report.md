# Cross-runtime compatibility report — 2026-09-05

**Verdict: blocked for consumer adoption.** The candidate repairs plain-text
UTF-16 scalar-boundary editing through Yelixer, Yepochs, Merkle, and Next's actual
durable route. The supported application tests and real Chromium durability arms
pass. Incoming browser half-surrogate updates remain an adoption blocker. The
known break with our own saved history is an accepted compatibility cost where
needed to match official Yjs 13.6.32, under the user ruling of 2026-09-05 18:52:45 UTC.
It is no longer an adoption gate. These experimental branches are not deployed.

The [minimal baseline/candidate blocker supplement](minimal-adoption-blockers.md)
adds identical-byte evidence: the old pinned codec also diverges on the incoming
half-surrogate delta, with different output. It separates that codec result from
both measured candidate and published-pin application admissions. The published-pin
arm also durably acknowledges divergent text; neither comparison is a live-target test.

## Configurations and provenance

| Repository | Refreshed origin/main | Application's original resolved pin |
|---|---|---|
| Yelixer | `a30c81e853fc4cadd45ba4840a8ffc17a816c975` | `bc35a0e9ff374449c71fb29be159bd9a711635bb` |
| Yepochs | `e52de214caa4dc83369108d0b6c844dec75937ea` | `fdc808f43ac42238c27abf2ff51c301b76a889cb` |
| Merkle | `484a393b2020f44cda0c36cbf01d2195677ae661` | `6608f3d7cec1fbae88826a672299812798a66b76` |
| Next | `94abc915604cf93ee6c604d33bc2e14ae2d61441` | top-level overrides select the three pins above |

| Exact candidate dependency | Resolved and installed Git revision |
|---|---|
| Yelixer | `bcaec6a3520c59464bab87daaab7e4f76546c9c5` |
| Yepochs | `f184c9e9dd99b7baced407fb46632e887e3fb948` |
| Merkle | `9e7caf43e541864c68e9374b7a7f414a05cdfdc4` |

Next consumer handoff commit: `f37b22ed3aa634d187151b88d32e50b46c0af393`.

All branches are `compat/utf16-runtime`. Later report/harness-only commits do not
change these production pins. Next changes only those three lock entries; its
reducer override remains `4695d407d7fa5775ca375962eac978fabd78a8c5`, whereas standalone
Merkle selects `d081529b8a97d31c55254b0637f404793ab35810`. Both configurations were
tested. [Baseline closure](compatibility-evidence/baseline-closure.json) records
installed Git revisions separately from locks, including the shared Yepochs
checkout's mismatching installed codec and the shared Next checkout's in-flight
Biscuit lock. Those shared trees were not the baseline oracle. The separate
`next-executed-baseline` entry records the pristine app baseline and matching installed
dependencies at the refreshed origin/main revision. [Candidate closure](compatibility-evidence/candidate-closure.json) records
the verified actual dependency directories in all isolated consumers.

Runtime: Elixir 1.18.4, OTP 27.3.4.8, Node 24.13.1, Yjs stable/browser 13.6.32.
Yelixer preview 14.0.0-16 was checked separately. Utility dependency versions are
recorded in the baseline closure; no unrelated application dependency was upgraded.
Playwright 1.62.1 and its Chromium headless shell were installed from Next's lock
into an isolated cache. Next assets were rebuilt using its existing esbuild binary.

The application baseline uses its original manifest and locks. Standalone Yepochs
and Merkle baselines use the refreshed library origins listed above, initially with
their old lower-library pins; they are not mislabeled as the older application-pinned
Yepochs/Merkle source. Candidate consumers
were cloned separately; owned beta checkouts were only read. The old Yelixer
worktree ports the modern tests, driver, and support files onto the exact old
production source. Its local utility lock matches the inspected utility versions.
Copied dependency sources and warm application build artifacts were isolated copies;
Mix recompiled the changed codec and dependent applications after repinning. No
production file in the old worktree was changed. Issue tracking was unavailable;
the coordinator relayed the user's waiver, and this report records remaining work.

## Executed comparisons and fixes

Counts below include named test cases, with properties/doctests stated separately.
[Named outcomes](compatibility-evidence/named-outcomes.json) lists pass, failure,
skip, and exclusion for the focused populations. Those deterministic runs use seed
0, one concurrent ExUnit case, and a required real Node oracle. The earlier focused
runs used one BEAM scheduler; the granted full-suite window used two. Timings are
not compared across that change.

| Run | Executed result and cause |
|---|---|
| Old Yelixer, ported conformance/clock/content/new matrix | 65 tests, 30 failures: 6 clock, 5 content, 19 new matrix |
| Refreshed Yelixer, existing instruments | 40 tests, 6 failures: 1 stale delete assertion and 5 content assertions |
| Refreshed Yelixer, new matrix | 25 tests, 3 failures: overlapping split IDs, binary clock length, surrogate clamp placement |
| Repaired Yelixer, matrix and Item/Text/XMLText regressions | 64 tests, 0 failures |
| Repaired conformance/clock/content/boundary/old history | 43 tests, 5 named expected failures |
| Yelixer full suite at production candidate | 451 tests + 33 properties + 1 doctest, 0 failures, 5 divergence exclusions |
| Added immutable pure-Yjs/candidate history acceptance | 18 tests, 0 failures; independently specified intermediate and final text |
| Yjs preview conformance | exact 11 tests, 0 failures |
| Clock/boundary guard | exact 18 tests, exactly 1 expected failure; no skipped or invalid cases |
| Content guard | exact 12 tests, exactly 4 expected failures; no skipped or invalid cases |
| Old-pin Yepochs focused baseline | 56 tests, 19 failures |
| Yepochs with new codec before reauthoring repair | 56 tests, 6 failures, all positional reauthoring |
| Repaired Yepochs focused | 96 tests, 0 failures |
| Yepochs complete `mix check` | shell self-tests, formatting, warnings-as-errors compile, 656 tests + 12 properties, Dialyzer: all pass |
| Old-pin Merkle focused baseline | 98 tests, 5 new Unicode author/opener failures |
| Candidate Merkle before characterization retirement | 101 tests, 19 failures requiring the old sequence damage |
| Merkle supported acceptance | 92 tests, 0 failures |
| Merkle full suite | first 329/1 stale rendered-coordinate control; corrected full run 329/0, no exclusions |
| Next original pins, actual route | 29 tests, 1 failure: second Unicode Workspace append refused as `unsupported_edit`; 28 existing tests pass |
| Next final pins, supported route | 29 executed, 0 failures; final file population 30 with the one separately counted boundary blocker excluded |
| Next full default regression | 571 tests, 1 trust-root subprocess harness failure, 2 browser exclusions; no Unicode semantic failure in the supported population |
| Next incoming half-surrogate probe | 1 executed failure, 25 excluded by `--only`; actual author frame durably acknowledged with divergent text |
| Next trust-root gate, normal unexported Mix environment | 2 tests, 0 failures; resolves the sole full-run harness failure without source changes |
| Next real Chromium | 2 tests, 0 failures: ASCII and Unicode durability, both explicitly included |

Prerequisite mistakes remain separate from semantic failures: one dependency fetch
used a wrong ref and failed before tests; a test-only Jason restriction conflicted
with a transitive dependency and was corrected; a Merkle run without its harness
location failed 21 oracle imports. A first Next candidate reconnect test incorrectly
submitted a full retained state as a fresh author frame and received `id_collision`.
The actual author-frame contract sends an incremental update; that correction made
the supported route pass. Full-state transfers are separately covered as sync and
materialization operations. No beta-owned protocol/lifecycle defect was reproduced. The full Next run exported
`MIX_ENV=test`, which also made its trust-root subprocess probes use test runtime
state. Re-running the existing two-test file with `env -u MIX_ENV` passed 2/0,
without a source change. The full suite was not repeated; its first 571/1/2 result
and the corrective retest are retained separately. A boundary-probe attempt
overlapping the full suite failed before tests on the shared test writer lease;
the serialized retry is the semantic evidence.

Next formatting, warnings-as-errors compilation, plan-arm inventory, spec-pristine,
landing-slot self-tests, development-path inventory and its self-tests pass. The
optional standalone population script still refuses 47 indented tests; a source
comparison confirms the exact same 47 lines at the pristine app baseline. This
pre-existing scanner assumption was not rewritten.

Production fixes are deliberately small:

* `Item.split/2` derives right IDs/origins from the actual upward-clamped split;
  local Text operations normalize positions before splitting to avoid empty items
  reusing a future clock. Incoming binary items occupy one clock, regardless of bytes.
* Yepochs reauthoring measures prefix/deletion lengths in UTF-16 and removes the
  exact scalar prefix. Deleting only a combining mark now works.
* Merkle needed the lower-library pins and explicit UTF-16 caller documentation;
  no materialization algorithm was rewritten. Next needed candidate overrides and
  tests; its production authoring and synchronization code was not changed.

The former Merkle sequence instrument is preserved verbatim as
`test/fixtures/sequence_parity_grapheme.exs.txt` at its original source revision.
Normal tests now require intended content. Next's original damage fixture bytes
remain intact; its mechanism assertion now requires the full append in real Yjs.
Independent equivalent arrays compare semantic values, not struct-packing bytes.

## Supported matrix and limits

The escaped fixture descriptions state independent code points, grapheme counts,
and UTF-16 units for ASCII, NFC, NFD, astral, ZWJ with skin tone, flag, and mixed text.
The deterministic sequences cover start/end, each valid scalar boundary, combining
mark interiors, spanning deletes, reused and fresh legitimate authors, disjoint
concurrent authors, full updates and state-vector diffs, duplicate/delayed delivery,
discard/reload, and further edits in both runtimes. Exact intended text and clock
coverage are asserted for the same replicated history. Synthetic oracle transcripts
retain the actual operations, IDs, update bytes, and responses.

Yepochs additionally covers foreign-Yjs snapshots, derivation intervals, strict
crossings both directions, bridge extension and reauthoring. Existing map/array
conformance now parses real JSON and checks exact structured values and order.
Merkle covers parent relationships, deterministic author hashes, incremental/full
materialization, exact admitted update replay, unchanged historical commit bytes,
checkpoint reopening, and supported epoch openers. New snapshots are compared by
their content contract, not by identities borrowed from a different history.

Next's test starts with actual fresh Workspace authors, exchanges edits with real
Yjs, requires Attachment's acknowledged head to equal the durable snapshot, discards
Realm/SQLite processes, reopens the same document, deletes Unicode, then continues
from a reconnected browser author. The Chromium tests exercise real keyboard input,
the saving/saved UI, page reload, server-side materialization, SQLite/Realm restart,
and a new browser context. The ASCII control is retained.

Local surrogate-interior operations keep the existing upward-clamp decision. The
repaired local operation produces exact `\u{1F600}X`, with correct clocks and future
edits in real Yjs. This does **not** enforce an inbound boundary: real Yjs inserting
`X` inside `\u{1F600}A` produces `\u{FFFD}X\u{FFFD}A`, while the accepting candidate
produces `\u{1F600}XAA`. The desired-behavior reproducer requires convergence or an
explicit refusal and remains red. The application-level probe confirms reachability: Next accepts the incremental
author frame and durably acknowledges the head, while retaining the divergent
`\u{1F600}XAA` suffix. `attachment_test.exs` keeps a desired-behavior regression
tagged `:unicode_boundary_blocker`, explicitly run with `--only unicode_boundary_blocker`.
Its one failure is separate from 25 cases excluded by that selector. Ordinary
keyboard acceptance does not eliminate this reachable wire operation.

Four other known content failures remain: formatted-text position accounting;
untyped `YMap.set` binary authoring is not Uint8Array authoring (loud and quiet
cases); and nested-array access. Binary-item clock repair does not add a new binary
authoring API. Existing XMLText regressions pass, but Unicode XML editing/crossing,
all formatted positions, embeds and every nested-type combination are not established
by this plain-text matrix. Existing explicit unsupported-crossing refusals remain.

## Immutable history and adoption

The inspected corpus is exactly four synthetic history families, each containing
ASCII, combining, astral and ZWJ cases with four stages. The families are old Yelixer,
pure Yjs, candidate Yelixer, and real-Yjs base plus an old fresh server author.
Each was read under both codecs, incrementally and as fresh full-state loads: 256
stage observations, plus local discard/reload/future-edit observations. Original
bytes, authors, coordinates, writer revisions and intended text are retained in
`test/fixtures/*history.json`; [both readers and independent browser observations](compatibility-evidence/history-observations.json)
remain separate. Existing committed fixture suites also ran. **No live beta history copy was inspected or supplied for this run; availability
of other authorized copies is not established. This is not a fresh beta census.**

| Population | Observation |
|---|---|
| Old ASCII | All stages and subsequent edits preserved under both codecs and Yjs |
| Old single Unicode insertion | Initial view readable; identical bytes can be independently authored by Yjs, so wire bytes do not reveal the clock convention |
| Old multiple Unicode edits | Old reader retains its author view; candidate changes later views. Browser disagreement already exists before upgrade. Full versus incremental legacy loads can also disagree |
| Pure Yjs and candidate history | Candidate preserves every intended stage and continued edits; old readers lose/misplace later Unicode edits |
| Mixed Yjs base/old fresh author | Fresh IDs do not prevent incorrect legacy origin/deletion coordinates; later candidate views differ from old writer views |

Thus a candidate reader change is a regression relative to preserved old-server
views for these legacy histories, even when it moves some observations toward Yjs.
Astral origin references additionally hit the unresolved surrogate boundary. Neither
replica agreement nor a larger state vector recovers lost authorial intent. The
old-reader observations demonstrate that rolling back after candidate Unicode writes
is unsafe; old and new writers cannot share an unversioned Unicode history safely.

The later user ruling explicitly permits breaking compatibility with our own saved
history where needed to match the pinned official Yjs behavior. The earlier proposal
to require a versioned history transition before adoption is therefore withdrawn.
The observations above remain measurements of the accepted compatibility cost,
including changed old views and unsafe rollback to the old reader. They are not
failing acceptance conditions and do not authorize a migration project or deletion
or reset of live stores. Yepochs snapshot version 3/rebase version 1 and Merkle
reducer version 6 are unchanged in the tested candidate; that fact is recorded for
reproducibility, not imposed as a new history-preservation gate. No live history
was rewritten. Incoming new edits must still match official Yjs or encounter an
explicitly enforced safe boundary; permission to break owned history does not
permit silent browser/server divergence.

## Reproduction and remaining action

Install each repository's locked Node oracle. For an old-codec worktree, set
`COMPAT_YELIXER_HARNESS` to the candidate Yelixer checkout, solely to supply the modern
test driver/support code. It does not replace the codec. Use `MIX_ENV=test`,
`YJS_ORACLE=stable`, `YELIXER_REQUIRE_YJS_ORACLE=1`, `--seed 0 --max-cases 1` for focused
runs. The relevant test paths are linked in each repository's `docs/unicode-compatibility.md`.

```
mix test test/yelixer/unicode_compat_test.exs test/yelixer/old_history_test.exs
mix test test/yelixer/diff_yjs_test.exs test/yelixer/divergence_clock_test.exs test/yelixer/divergence_content_test.exs test/yelixer/unicode_boundary_test.exs --include divergence
HISTORY_INPUT=test/fixtures/old-grapheme-history.json HISTORY_REPORT=/tmp/history.json mix run test/support/report_history.exs
```

Run the history reporter from each exact reader checkout with the same immutable
input; repeat for `pure-yjs`, `candidate-utf16`, and `mixed-legacy`. The old worktree
can execute the reporter by absolute path from the candidate checkout. Generators
record source writer revisions and explicit operations; do not regenerate the old
fixture with the candidate. New-history tests specify the intermediate strings
independently of recorded candidate writer observations.

Remaining adoption work is concrete: enforce a safe inbound surrogate contract or
repair convergence, then retest the final adoption set through the application.
Legacy-history preservation and a migration project are not required for adoption
under the later ruling. The limits of the inspected synthetic corpus remain explicit. Broader type support needs separate
evidence if those document profiles are enabled. Deployment and beta feature work
remain outside this pass.
