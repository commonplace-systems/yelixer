# Bounded history-cost repair

This batch repairs the encoder portion of audit finding 6, exact duplicate
retention in finding 7, and GC tuple reuse in finding 8. It does not repair
Text's linear visible-position scan, dependency-index pending retries, or every
cache invalidation path. None of these measurements identifies a live app stall.

Baseline: **2b35599a45e06595e48554d94e52c9faf9eca303**, also the reviewed tree
landed by PR #2 at main **bf651769f8ee311b762728bb7a8a8c62c9686004**.
Production files were unchanged for the baseline. Only `BlockStore`, `Encoding`
and `Doc` change in the candidate.

## Repair and regressions

- `BlockStore.client_blocks_since/3` binary-searches cached canonical blocks
  and walks the recent pending suffix in clock order. A straddling block is
  retained for the existing exact-clock split in `Encoding.encode_diff/2`.
  State-vector derivation uses the cached final item instead of `List.last`.
- Exact duplicate unresolved wire blobs no longer consume additional pending
  capacity. Integration progress and delete riders still run before retrying;
  this does not implement dependency-indexed wakeups or eliminate retry cost.
- GC builds its updated client tuples once and retains them. Previously every
  immutable lookup rebuilt and discarded a missing tuple. The cache contains
  collected content, not a stale reference to the pre-GC payload.

The original eight regressions ran **8 tests / 5 failures, rc 2** against the
baseline, then **8 / 0, rc 0** against repaired production code. Three storage
layout cost checks, duplicate retention and the GC cache check failed on the
baseline; all three wire catch-up controls passed there. Sixteen deliveries of
one missing-dependency update retained **16 blobs / 160 bytes** before, and
**1 blob / 10 bytes** after; arrival of the base then converges and clears it.

The eight-case source SHA256 before both runs was
`b48b0c522a7bf9f49580325f22fdd9b56d0ef6645cd648e7adf689ec004f138c`.
The final test file was subsequently formatted without changing its cases.
See [baseline](baseline.txt), [repaired](fixed.txt) and the final
[regressions](../../../test/yelixer/history_cost_test.exs).

## Matching encoder measurements

The same synthetic [probe](costs.exs) ran once per revision. It constructs
clock-ordered blocks outside the measurement, warms the encoder, then records
the calling process's BEAM reductions for one missing item. It does not include
the separate cost of `Text.insert/4`. The script was formatted after both runs.

| Storage layout | Before, 512 → 1,024 blocks | After, 512 → 1,024 blocks | Before / after growth |
| --- | ---: | ---: | ---: |
| Pending | 3,332 → 6,419 | 285 → 294 | 1.926× / 1.032× |
| Materialized | 2,023 → 3,825 | 241 → 243 | 1.891× / 1.008× |
| Mixed | 2,555 → 4,871 | 285 → 292 | 1.906× / 1.025× |

Every matching before/after arm emits **identical 12-byte output**. The two
history lengths have different clocks, so their bytes differ from each other.
Raw [before](baseline-costs.jsonl) and [after](fixed-costs.jsonl) include hex.
These are bounded synthetic reductions, not latency, heap-allocation totals,
or a guarantee of constant cost for all document shapes. The inherited GC
measurement did not establish quadratic reductions and is not reclassified here.

A missing canonical cache still causes an O(n) fallback conversion. Delete
splitting can invalidate that cache; this batch preserves correctness for that
path without claiming its cost is fixed. Accumulated delete-set encoding,
client enumeration and returned suffix size also remain costs of a diff.

## Validation and execution identity

All runtime used OTP 27 / Elixir 1.18.4, `MIX_ENV=test` and
`ERL_FLAGS='+S 1:1 +SDcpu 1 +SDio 1'` in the isolated library checkout.
No server, consumer, browser, network transport or local full suite ran.

| Gate | Measured result |
| --- | --- |
| Frozen regressions, baseline | 8 tests / 5 failures, rc 2 |
| Same regressions, repair | 8 / 0, rc 0 |
| BlockStore, GC, pending, update/error decoding, incoming Unicode and new clock-range controls | 53 / 0, rc 0 |
| Separate fresh-full-state control | 1 / 0, rc 0 |
| Required official Yjs 13.6.32 conformance | 11 / 0, rc 0 |
| Four new clock-range controls after fixture warning cleanup | 4 / 0, warnings as errors, rc 0 |
| Format check and compilation with warnings as errors | rc 0 |

The 53-test pass had compile-time warnings because the new generated fixture
compared known literal layouts. Moving construction into a helper removed the
warnings; only the four changed cases were rerun. The warning-bearing
[original output](affected.txt) remains distinct from the [clean rerun](clock-range-clean.txt).
Those rerun cases are not added again to the unique test total.

Initial preparation [refused before compilation](baseline-preparation-refusal.txt)
because this library ignores its local `mix.lock`. Copying the matching
[resolved dependency lock](resolved-dependencies.lock), then force-compiling all
three dependencies and all 19 library modules established the baseline. This
preparation failure is not a codec failure. The repair also force-compiled all
19 modules before the eight-case comparison. [Baseline](baseline-beams.sha256)
and [final](fixed-beams.sha256) compiled fingerprints identify the three changed
modules; the final fingerprint follows formatting and the clean compile gate.

All owned BEAM/Node processes exited before the runtime window was released.
Full GitHub-hosted CI and the single review/landing are separate gates.
