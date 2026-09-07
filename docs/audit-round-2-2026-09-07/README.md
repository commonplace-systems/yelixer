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

No runtime has run for this second-round packet yet. Local verification will be
focused and separately granted; the full suite belongs to hosted CI. Each landed
PR receives one review and records its exact baseline, candidate and evidence.
