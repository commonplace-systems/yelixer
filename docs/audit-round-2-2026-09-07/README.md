# Second audit repair round — 2026-09-07

Starting production head: `c8a48aea2f85d2306efbf9a0f8913f196200bed1`.
This round ranks the remaining findings by demonstrated correctness impact and
how narrowly a repair can be verified. It does not infer a downstream incident
from a standalone library defect.

| Rank | Remaining finding | Bounded next step |
| --- | --- | --- |
| 1 | Content readers crash on nested/foreign variants or lose values; formatted Text.length counts format clocks | Verify against official Yjs 13.6.32, share variant-aware read behavior, preserve explicit buffer identity, correct read-only length |
| 2 | Unbounded structured parsing work | Bound varint widths and nested container recursion with finite malformed and maximum-valid controls |
| 3 | Snapshot replay/provenance | Preserve replacement-document semantics; repair source correspondence without a migration project or pretending overlay is ordinary sync |
| 4 | Text positional scanning | Measure the actual editing path before selecting an index/cache design |
| 5 | Uncached lookup/general pending retry costs | Separate measured cached improvements from remaining fallback costs before changing scheduling or storage |

## First batch: content views

Frozen source-only test commit: `2677535`; production files are unchanged there.
Eight finite cases in `test/yelixer/content_views_test.exs` cover foreign map and
array buffers (valid and invalid UTF-8), nested map/array values, formatted
UTF-16/embed length, and an ordinary-value control. The existing stable oracle
adds only two fixture commands. This population is separate from the original
12-case divergence instrument, which will be rerun once to establish retirement.

The two old unwrapped-binary authoring expectations do not establish that every
Elixir binary should become Uint8Array: ordinary binaries are strings by API
contract, and `Any.buffer/1` now expresses byte-buffer intent. Preserve those
measurements and distinguish that authoring policy from FOREIGN ContentBinary
reader failures. A getter returning bytes without preserving buffer intent would
reintroduce type loss when its output is passed back into a map/array author.

Text.length is a read-only count. Fixing its format-marker count is not proof
that local Text.insert/delete preserve rich-text attributes or use correct
formatted offsets; those authoring paths require separate controls. Likewise,
resolved nested values are read projections, not a promise that generic primitive
insertion recreates nested CRDT identity. JSON encoding of typed buffer values
still requires a caller-selected projection.

## Measured content-reader repair

Baseline `3ed0939` (production `c8a48ae`): eight frozen cases, **seven failures**,
one ordinary-value control passing. The failures were map/array reader exceptions
on foreign binary/nested values and formatted length **7 versus Yjs 5**.
The candidate changes production `lib/`: all eight pass. The seven original
Yjs update payloads are identical across baseline/candidate, recorded in
[same-inputs.json](same-inputs.json) and both oracle transcripts. Candidate output
or reauthoring bytes are not claimed identical to baseline output.

Map/array readers now share their variant-aware projections. Native ContentBinary
items remain unchanged in the store and wire codec; readers return Any.buffer so
subsequent authoring preserves byte-buffer intent. Missing keys/ordinary values
retain their meanings. Text.length excludes format markers without claiming a
repair of local rich-text authoring positions or attributes.

Affected gates: **48 tests, zero failures**. The original content instrument:
**12 tests, two remaining failures**, both unwrapped-binary authoring expectations.
The repaired formatted-length/nested-array cases no longer carry the exclusion
tag. CI explicitly expects two remaining failures, so neither retirement nor a
new failure can disappear into a stale count. See [baseline](baseline.txt),
[candidate](green.txt), [affected checks](affected.txt), and
[content classification](content-classification.txt).

Full regression and one external review remain required before landing; no
consumer dependency or deployment is changed by this library round.
