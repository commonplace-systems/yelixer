# Unicode compatibility hardening

This candidate uses UTF-16 code units for string clocks and plain-text positions.
Convert grapheme positions at the caller boundary. Local surrogate-interior
positions clamp upward; delete endpoints clamp independently. A clamp must move
both the string split and the resulting item IDs. Normalizing local positions
before splitting also prevents an empty item from occupying the next author clock.
Binary items cover one clock regardless of their byte length.

**Consumer adoption is blocked.** See the [complete report](cross-runtime-compatibility-report.md) for the exact dependency closure, executed cases, application results and immutable history assessment. Incoming browser edits inside surrogate pairs
are a separate contract from local clamping. `unicode_boundary_test.exs` requires
convergence or an explicit refusal and is tracked as an expected failure. A caller
must not infer an enforced input boundary from this documentation or from green
local clamp tests. Formatting-marker positions, typed binary authoring through
`YMap.set`, and nested-array access also retain the measured limitations in the
content-divergence suite.

The deterministic fixtures in `test/fixtures/unicode_cases.json` state code points,
graphemes and UTF-16 units independently. `unicode_compat_test.exs` exercises real
Yjs 13.6.32, alternating authors, fresh and reused IDs, full and incremental
updates, duplicate and delayed delivery, concurrency, reload, and subsequent edits.
It requires the Node oracle rather than silently skipping it.

```
npm ci --prefix test/fixtures
YJS_ORACLE=stable YELIXER_REQUIRE_YJS_ORACLE=1 mix test test/yelixer/unicode_compat_test.exs test/yelixer/old_history_test.exs
mix test --include divergence test/yelixer/divergence_clock_test.exs test/yelixer/unicode_boundary_test.exs test/yelixer/divergence_content_test.exs
```

At upstream `a30c81e853fc4cadd45ba4840a8ffc17a816c975`, the original focused
conformance/clock/content populations executed 40 tests with 6 failures: 11/0,
17/1, and 12/5 respectively. The new Unicode matrix executed 25 tests with 3
failures. After the production repairs its 25 tests and 39 Item/Text/XMLText
regressions pass. The old app pin `bc35a0e9ff374449c71fb29be159bd9a711635bb`,
with the same ported test harness, executed all 65 cases with 30 failures.
These runs used Elixir 1.18.4, OTP 27 and Node 24.13.1, with stable Yjs 13.6.32.
The preview oracle was not part of that comparison.

The old clock test's `delete(0, 5)` assertion expected removal of six UTF-16
units. Its acceptance now checks both endpoints explicitly: five leaves the
space and six removes it. Local B-up output is now compared at its exact position
in both runtimes; the previous corruption was caused by inconsistent item IDs.
The content packing case now compares semantic values: independently authored
equivalent arrays are allowed to use different valid struct packing.

`old-grapheme-history.json` contains synthetic immutable updates authored by the
old pin. Its `old_views` are observations of that writer, not a new reader's
expected values. To regenerate the provenance fixture, run
`HISTORY_OUTPUT=/tmp/old-history.json MIX_ENV=test mix run /path/to/generate_old_history.exs`
in an isolated checkout of that exact pin. Preserve the original update bytes.
A single old Unicode insertion is byte-identical to an independently authored
Yjs insertion: bytes alone cannot label the writer's coordinate convention.
No real application history corpus has been inspected in this pass.

The user ruling of 2026-09-05 18:52:45 UTC accepts breaking our own history where needed to match official Yjs 13.6.32. History preservation and a migration project are no longer adoption gates. The remaining blocker is silently divergent incoming browser edits; no live-store deletion or reset is authorized by that ruling.
