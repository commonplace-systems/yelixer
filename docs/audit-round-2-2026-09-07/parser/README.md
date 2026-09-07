# Parser resource boundaries — measured repair

**Focused checks passed; hosted full CI and one review pending at this seal.**
Baseline production is merged main
`30415798dc2d5c73f14c2b38a35e90c6bc2879c6`. Ten finite regression/control cases
are frozen in `test/yelixer/parser_budget_test.exs` (SHA-256
`4a7c536a27907d2a5035ee1d48fecc3bbced734dae6045218c38d236aff98fa8`).
No input in that file exceeds 400 bytes. No hostile large-input benchmark or
outage claim is involved.

The implemented decoder policy limits unsigned and signed varints to ten bytes,
counts Any array/object nesting to a maximum of 128, checks state-vector entries
against JavaScript's maximum safe integer, and refuses counts impossible for the
remaining bytes. The generic varint width policy is not a claim that every value
within ten bytes is a safe Yjs identity: identity/clock checks are separate.
The maximum unsigned 64-bit value is an explicit generic-codec control.

These are Yelixer resource limits, not a claim that official Yjs rejects every
padded varint or every deeply nested value. They can reject byte-legal input
outside this policy. Callers authoring deep values must remain within the receive
boundary; this change does not add a corresponding limit to all encoder APIs.

ContentAny's list of values is not itself an Any array. Each value receives the
full depth budget; entering an actual Any array/object decrements it. Scalar
leaves at depth 128 remain valid. Container breadth/count is bounded by available
input bytes, not by a new arbitrary element cap. Low-level decode helpers may
raise ArgumentError; existing update/state-vector wrappers must preserve their
tagged error behavior.

This does not bound total message bytes, flat-document memory, embedded JSON
parsing, application latency, or overall CPU independent of input size. Those
limits remain caller responsibilities or separate audit work. Snapshot behavior
and rich-text authoring are unrelated to this patch.

The frozen baseline ran ten cases: five failures, five passing controls. After
the production edit, the same ten cases passed. Formatting added only a blank
line to the frozen test; its final SHA-256 is recorded below. No assertion was
changed to obtain green.

| Boundary | Baseline | Candidate |
| --- | --- | --- |
| Unsigned eleven-byte padded zero | Accepted (failure) | ArgumentError |
| Signed Any eleven-byte padded zero | Accepted (failure) | ArgumentError |
| Any array/object depth 129 | Accepted (two failures) | ArgumentError |
| Unsafe state-vector identity | Accepted (failure) | Tagged malformed-state-vector error |
| Ten-byte unsigned 64-bit maximum | Passed | Passed |
| Any array/object depth 128 and trailing byte | Passed (two controls) | Passed |
| Maximum-safe identity/clock | Passed | Passed |
| Impossible state-vector count | Passed | Passed |

The unsafe state-vector test checks client then clock. The baseline assertion
stopped at client, so it did not independently measure the unsafe clock input;
the passing candidate executed both. Count validation now rejects impossible
counts earlier, but this control was already green and is not presented as a
newly reproduced failure. Broader cost/DoS behavior was not benchmarked here.

Validation, all with one scheduler and one test case at a time:

- Baseline force compile: rc 0; ten-case baseline: rc 2, five failures.
- Candidate force compile with warnings as errors: rc 0.
- Candidate ten cases: rc 0, zero failures.
- Affected Encoding/error/update/fuzz/Any/state-vector/sync gates: 70 tests plus
  four properties, zero failures.
- Count-asserted official Yjs stable 13.6.32 conformance: exactly 11 tests,
  zero exclusions and zero failures.
- Format check: rc 0. No local full suite or consumer/browser test ran.

The first cache-preparation attempt stopped before mutation because the ignored
mix.lock was absent in the new worktree. Preparation then copied the existing
lock and caches after verifying identical mix.exs declarations. No dependency
fetch was needed. The baseline production source was byte-identical to main;
the candidate changes Encoding and its public decoder documentation only.
Before/after source and compiled Encoding SHA-256 values are committed in the
fingerprint JSON files. The granted runtime window was released after confirming
no owned BEAM/Node remained. All oracle/document inputs were synthetic.

Detailed command results and raw output are adjacent to this report. Hosted CI
will run the full default suite and separately counted conformance/divergence
populations; those results must be kept separate from this focused receipt.

Final formatted regression SHA-256: `fb272384752e83cfa48f67496bf8c1c275129c3b24c1bde0e1e6827f7e85140a`.
