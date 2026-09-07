# Yelixer project audit — 2026-09-07

The audit found that Yelixer's public compatibility claim was broader than its
implementation. The highest-impact repairs have now landed: sync framing,
malformed-update state retention, XMLText boundaries, Any wire types, duplicate
pending retention, GC cache reuse, and subscription cleanup. Diff encoding also
seeks past known cached history. The exact baseline findings remain below.

**Highest remaining issue: snapshot overlay and provenance are unsafe.** The
public contract is corrected to disclose this; its runtime is not repaired.
Text positional authoring still scans visible history, uncached lookups and
general pending retries still have growth costs, and parser budgets remain
incomplete. The four existing content divergences are still separately counted.

This is a baseline audit of **20f55acda3547599ea7ba95509d54c005499d929**,
production tree **2d9db6bdd2581f87aace1af36d15eb536fb5ff10**, identical to codec
59b04eb. Recommendations were ranked before production edits. The subsequent
instruction to implement the highest-impact repairs supersedes the initial
audit-only scope; changes and their validation will be recorded separately.

## Evidence and limits

The [Elixir probe](reproduce.exs) ran once after a forced 19-module compile with
warnings treated as errors, OTP 27 / Elixir 1.18.4, one normal scheduler and one
of each dirty scheduler. The [upstream oracle](upstream.mjs) ran once against
existing Yjs 13.6.32, y-protocols 1.0.7 and lib0 0.2.117. See
[baseline observations](baseline.jsonl) and [upstream observations](upstream.json).
All three commands exited 0: **the probes completed, not that conformance passed**.
They intentionally record wrong outputs and caught exceptions.

No full suite, browser, consumer application, network transport or live document
was exercised. Reduction counts measure BEAM work for the stated synthetic
shapes, not live-service latency, complete allocation costs, or a universal
complexity benchmark. No result here identifies the application's saving stall.

[Source hashes](source.sha256) and [baseline configuration hashes](baseline-files.sha256)
are retained. [Before](beams-before.sha256) and [after](beams-after.sha256) compiled
hashes differ for BlockStore; four other captured modules match. Only the forced
compile's AFTER hashes and the probe's loaded-module MD5s identify executed code.
The first coordination message incorrectly called all five identical; that claim
was immediately corrected after inspecting the diff. No baseline source changed.

## Findings, ranked by impact

### 1. High — the exported sync protocol is not y-protocols framing

[SyncProtocol](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/sync_protocol.ex#L139)
writes a tag followed directly by state-vector/update bytes. Upstream wraps the
payload with `writeVarUint8Array`, including its length, and supports update tag
2 in addition to handshake tags 0 and 1. The empty step1 is `00 01 00` upstream
versus `00 00` here. Feeding the official frame raises MatchError; official update
tag 2 raises FunctionClauseError. Existing SyncProtocol tests mostly exchange
frames between two instances of the same implementation, masking this mismatch.

**Recommendation:** implement the upstream length-delimited frames and tag 2,
return tagged malformed/unknown-frame errors, and retain upstream-produced golden
frames alongside self-round-trips. This changes the library's old custom framing;
callers using it must move coherently. Do not conflate it with a consumer's own
protocol adapter. The API handles a complete sync frame, not transport room or
awareness envelopes.

### 2. High — malformed updates kill the process holding a document

[DocServer.apply_update callback](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/doc_server.ex#L180)
pattern-matches `{:ok, doc}`. The codec correctly returns a tagged error for an
empty binary, but the wrapper crashes on that return. The probe inserted text,
submitted `<<>>`, and observed the server terminate. This loses its in-memory
state; external persistence/recovery is a separate caller responsibility.

**Recommendation:** handle `{:error, reason}` explicitly, return it without
changing state, and prove the same process still accepts an edit afterward.
Apply the same error contract at SyncProtocol's boundary. Avoid blanket exception
swallowing that would conceal internal programmer errors.

### 3. High — XMLText's duplicated boundary code corrupts local state

[XMLText](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/types/xml_text.ex#L74)
retains a copy of Text's old position/splitting code and lacks its endpoint
normalization. Inserting `X` at UTF-16 position 1 inside a lone astral scalar
produces local `\u{1F600}XX`, but reload yields `\u{1F600}X`. The store contains
both a zero-length item and the real `X` at clock 2. This is a local-versus-reload
correctness defect, not merely a difference from JavaScript's surrogate policy.

**Recommendation:** share Text's local positional implementation rather than
maintaining a second copy. Preserve the documented upward-clamp local policy;
incoming wire operations continue to use exact clock splitting. Cover insertion,
independently normalized deletion endpoints, and reload. Sharing implementation
does not establish rich-text formatting parity.

### 4. High for compaction callers — snapshot overlay and derivation claims fail

[snapshot_update](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/doc.ex#L450)
claims its reauthored output can safely be applied atop the source. The probe
creates `ab`, deletes `a`, and snapshots under a fresh author 99: a fresh reader
renders `b`, but applying that snapshot to the source renders **`bb`**. Fresh
identities are additional CRDT operations, not replacements for old identities.

The [derivation map](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/doc.ex#L558)
pairs rebuilt items with all source items by position, including tombstones.
The same probe maps new live `b` `{99,0}` to deleted `a` `{7,0}`, not live `b`
`{7,1}`. Existing fresh-reader tests do not establish safe overlay or correct
late-edit translation.

**Recommendation:** first correct the unsafe public contract. Treat reauthoring
as a replacement snapshot with an explicit version/identity boundary, or provide
a genuinely compatible update preserving original identities. Build derivation
provenance during replay, including run/offset mapping, rather than zipping raw
item lists. No live store reset or migration is implied by this audit.

### 5. High for general values — Any decoding destroys wire type information

[Any codec](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/encoding.ex#L764)
decodes buffer to an ordinary Elixir binary, undefined to nil, and bigint to an
ordinary integer. Re-encoding chooses string, null and number respectively.
The probe and upstream lib0 oracle confirm:

| Input | Re-encoded | JavaScript type change |
| --- | --- | --- |
| `74 02 41 42` | `77 02 41 42` | Uint8Array → string |
| `7f` | `7e` | undefined → null |
| `7a 000000000000002a` | `7d 2a` | bigint → number |

This applies to the Any representation, including nested object/array values.
It is distinct from top-level `ContentBinary`, whose retained existing control
round-trips correctly. Plain Elixir binary authoring also has the two previously
recorded string-versus-Uint8Array divergences.

**Recommendation:** add explicit typed representations for values Elixir cannot
distinguish, preserving them through decode/encode and nested containers. Keep
ordinary binary-as-string authoring explicit for compatibility. Add actual Yjs
update round-trips, not just primitive codec tests, before changing the API.

### 6. Medium–high — small edits still perform whole-history work

[Text positional lookup](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/types/text.ex#L235)
materializes the sequence, resolves items and walks offsets for each insertion.
Building 512 versus 1,024 single-letter blocks consumed **6,733,204 versus
27,200,684 reductions (4.04×)**. Integration's append fast path does not remove
the facade's preceding full-sequence work.

[encode_diff](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/encoding.ex#L521)
materializes and filters an entire client's history to emit a one-item tail.
The same 12-byte output cost 3,401 versus 6,491 reductions (1.91×) at those sizes.
Accumulated delete sets are also sent; that is an upstream protocol property,
not by itself a defect in this encoder.

**Recommendation:** expose a clock-range iterator that seeks into canonical and
pending indexes for diff encoding; give text a visible-position index or a safe
append cursor/fast path. Benchmark authoring and diff separately from replay.
Existing map-replay improvements and reduction gates are useful but do not cover
this authoring shape. Avoid claiming that optimizing replay fixed all text paths.

### 7. Medium — duplicate pending blobs consume capacity and repeat work

[Pending buffering/retry](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/encoding.ex#L966)
appends the original binary for every unresolved delivery and redecodes pending
blobs on each apply/fixpoint pass. Sixteen deliveries of the same ten-byte delta
retain sixteen blobs/160 bytes, then all clear when the missing dependency arrives.
The existing 10 MiB wire-byte cap prevents unlimited retained payload bytes, but
does not bound term overhead, duplicate count, or retry CPU to that same quantity.

**Recommendation:** deduplicate identical pending blobs before charging capacity;
subsequently index unresolved dependencies and wake only relevant work. Retain
out-of-order deletion riders and atomic overflow refusal in the regression set.

### 8. Medium — GC invalidates a cache that reads cannot persistently rebuild

[gc](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/doc.ex#L408)
clears client tuple caches. [get_tuple](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/block_store.ex#L700)
converts the list to a tuple when absent, returning only the tuple, so subsequent
reads repeat conversion. A sequence scan can copy the same client's list once
per item. This is source-established allocation work. The bounded post-GC read
reductions grew 27,539→60,239 (2.19×), **not a demonstrated quadratic reduction
ratio**; BIF copying/allocation is not fully represented by that counter.

**Recommendation:** build the updated tuple cache once while GC already traverses
the client buckets. Validate cached content is the GC result, not stale retained
payload. Measure allocation/copy work separately if pursuing a broader store redesign.

### 9. Medium — unsubscribe leaves process monitors behind

[DocServer subscriptions](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/doc_server.ex#L190)
create a monitor on every subscribe, store only a PID set, and never demonitor on
unsubscribe. Sixteen subscribe/unsubscribe cycles on one living caller leave
sixteen monitors. Duplicate subscriptions leak monitors despite deduplicated
delivery.

**Recommendation:** track PID→monitor reference, make subscribe idempotent, and
demonitor with flush when unsubscribing. Match DOWN against the current reference.

### 10. Medium — parser work limits are incomplete

[decode_uint](https://github.com/commonplace-systems/yelixer/blob/20f55acda3547599ea7ba95509d54c005499d929/lib/yelixer/encoding.ex#L169)
accepts arbitrarily long varints, growing the accumulator before later clock
bounds run. State-vector decoding lacks the update decoder's sane-count and safe
clock checks; nested Any containers have no depth budget. Broad rescue converts
many malformed inputs to errors, but does not impose a CPU/allocation budget.
Random-byte fuzzing currently uses at most 200 bytes, a useful but different arm.

**Recommendation:** bound varint width/value and recursive depth at decode time,
define strict single-update/trailing-byte behavior, and test structured oversized
inputs within finite limits. No large hostile-input experiment was run here, so
this is a source risk, not a measured outage or exploit claim.

### 11. Medium — package guidance and test names overstate coverage

The README is still an installation template with an unconditional wire-compatible
claim. The Hex file list excludes the compatibility reports. Four known content
failures remain explicitly counted: two binary-authoring cases, formatted-text
positions and nested Array.to_list. YMap.get/to_map similarly use narrow pattern
matches despite documentation suggesting unsupported variants return nil/are
ignored. Several long docstrings contain obsolete counts or stronger guarantees
than tests establish. For example, a GC test labelled Yjs-generated constructs
the fixture with Yelixer itself; SyncProtocol's self-tests missed external framing.

**Recommendation:** publish a short capability matrix covering V1 updates, local
UTF-16 policy, plain versus formatted text, nested-type accessors, binary typing,
raw sync versus awareness/transport, snapshot boundaries, and safe error APIs.
Link known divergences in the package README. Label source-derived fixtures versus
real upstream oracles. Reduce duplicated implementation and stale explanatory
prose around changed contracts; do not delete useful regression evidence.

## Upstream version and coverage inventory

On 2026-09-07 the [npm registry](https://registry.npmjs.org/yjs) reported `latest`
13.6.32 and `beta` 14.0.0-16, matching this repository. The `next` tag points to
14.0.0-8; it is not the newest beta. Stable gitHead is
1ce38f75f786e4bc0b2cc9703afbc6eea8fe7859; beta gitHead is
081886fed1a8489ed12950382eb5e563af182722. [y-protocols metadata](https://registry.npmjs.org/y-protocols/latest)
reports 1.0.7, gitHead 85f5f895d654d73be620f202a03a1bf81cdf4892.
The upstream oracle verifies its versions before producing observations.

The implementation is a V1 update codec, not blanket V2/subdocument/awareness
support. Its content references cover GC and refs 1–8; there is no explicit
ContentDoc or Skip decoding arm. Such unsupported surfaces should be declared
and independently covered before promising broad Yjs/y-* compatibility. Existing
yrs tests use copied compatibility bytes/datasets; they do not establish parity
against every current yrs release. See the official [update API](https://docs.yjs.dev/api/document-updates)
for the distinction between incremental document updates and update merge/diff
APIs; Yelixer's snapshot reauthoring is not upstream mergeUpdates.

Useful existing safeguards include separately counted stable/preview oracles,
required-oracle CI, explicit expected-divergence counts, malformed-input tests,
bounded pending bytes, delete-range bounds, map replay reduction gates, and the
unchanged incremental surrogate fixture plus a separate full-state control. The
earlier 505-check result remains evidence at its original codec revision; it was
not rerun or relabelled as this audit's validation.

The first implementation batch targets findings 1–3 and the small subscription
lifetime repair in finding 9. The other recommendations remain visible until
individually repaired and validated; a green focused batch cannot clear them.

## First repair batch

Findings 1, 2, 3 and 9 are repaired on the audit branch. The exact three focused
test files first ran against unchanged production code: **28 tests, 8 failures,
rc 2**. The same files after the repair ran **28 tests, 0 failures, rc 0**.
See [red](fix-baseline.txt), [green](fix-green.txt), and
[compiled fingerprints](fix-beams.sha256). Repository formatting and compilation
with warnings as errors both returned 0. No full suite or consumer acceptance
was run locally for this batch.

Sync now uses standard framing and update tag 2 with tagged boundary errors.
DocServer retains its state on codec errors and releases subscription monitors.
XMLText shares the plain Text implementation, eliminating the stale copied
boundary code. The public README now states capabilities and limits explicitly.
Production `lib/` is changed by this batch; the baseline hashes above remain
historical evidence, not descriptions of the repaired source.

Snapshot overlay/derivation, Any typing, whole-history work, pending duplication,
GC cache allocation, and parser budgets remain open.

The batch landed through [PR #2](https://github.com/commonplace-systems/yelixer/pull/2)
at main **bf651769f8ee311b762728bb7a8a8c62c9686004** after one independent review
and [GitHub-hosted CI](https://github.com/commonplace-systems/yelixer/actions/runs/34162354444)
on **2b35599a45e06595e48554d94e52c9faf9eca303**. CI measured 1 doctest +
33 properties + 483 tests, zero failures, four named exclusions; stable and
preview conformance each 11/0; clock/incremental boundary 25/0; separate
full-state control 1/0. The expected-content-divergence gate remained 12 tests
with four expected failures. Format, compilation and repository boundary gates
passed. The independent review reported 36 focused tests passing and no merge
blocker; parser resource budgets remain an explicit follow-up. No consumer
dependency pins or deployments changed through this landing.

## History-cost repair batch

The [bounded performance repair](performance/README.md) closes duplicate pending
retention and repeated GC lookup-tuple rebuilding, and removes known-history
scans from diff encoding when the canonical cache is present. The same eight
regressions went from five failures to zero. One-item diff cost grows 1–3%
when the synthetic history doubles, versus about 90% before; matching output
bytes are unchanged. Text positional authoring, uncached fallbacks, general
pending retry work, snapshots, Any typing and parser budgets remain open.

The performance batch landed through [PR #3](https://github.com/commonplace-systems/yelixer/pull/3)
at main **f36877c818977add3de8e9ad76d780bb4139d6cf**, with one independent
read-only review and [GitHub-hosted CI](https://github.com/commonplace-systems/yelixer/actions/runs/34163739261)
on **c4114f3875f71865f7f81b257d58009402b4ad2e**. The full suite passed
1 doctest + 33 properties + 495 tests, zero failures, four exclusions. Stable
and preview each passed 11/0; boundary 25/0; separate full-state 1/0; expected
content divergence remained 12 tests / four failures. Other CI gates passed.

## Any-value repair batch

The [typed-value repair](any-values/README.md) closes finding 5 for buffers,
undefined and signed 64-bit bigints. Corrected regressions went from 10 tests /
nine failures to 10 / zero, including actual Yjs map/array reloads. Its new
return types are documented explicitly for callers. The separately labelled
first adapter attempt did not exercise seven foreign comparison arms and is
not counted as conformance evidence. Snapshot derivation/overlay, Text positional
work, uncached lookup fallbacks, general pending retries and parser budgets
remain open; broader numeric compatibility is not claimed by these three types.

The Any batch landed through [PR #4](https://github.com/commonplace-systems/yelixer/pull/4)
at main **5c842fab5860bc310c3b222e59c5dc8726dd8e1c** after one independent
read-only review and [GitHub-hosted CI](https://github.com/commonplace-systems/yelixer/actions/runs/34164551169)
on **fbad7e205dc8829b973807df7ecf99bde08c7e3d**, which includes the performance
landing. Full CI passed 1 doctest + 33 properties + 508 tests, zero failures,
four exclusions; stable and preview 11/0 each, boundary 25/0, separate
full-state 1/0, and expected content divergence 12 tests / four failures.
Compilation, formatting and repository boundary gates also passed.

## Snapshot contract correction and remaining recommendation

`Doc.snapshot_update/2` documentation now states that its reauthored bytes
require a fresh isolated replacement document and cannot safely merge into the
source history. Its positional map is explicitly unsuitable for late-edit
anchor translation or provenance. Ordinary replica synchronization should use
`Encoding.encode_update/1`, retaining original identities.

Only documentation/comments changed in this correction. The
[source comparison](snapshot-contract-source.json) confirms identical remaining
source after stripping docstrings, full-line comments and blank lines.
The measured `b → bb` overlay and wrong deleted-`a` provenance remain real;
this does not repair them or clear replacement adoption. No live stores,
consumer dependencies, migration machinery or deployment changed.

A bounded runtime repair should record source intervals as each new block is
authored during replay, preserve enough run boundaries to represent that mapping,
and make the replacement-document boundary explicit. Merely skipping tombstones
in the positional zip would fix the smallest example while remaining wrong when
replay combines multiple source runs or reorders roots. Any proposed repair needs
deleted-prefix, multi-client, multiple-root and merged-run controls before it can
claim reliable provenance; fresh-reader output equality alone is insufficient.
