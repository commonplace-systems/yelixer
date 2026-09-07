# Parser resource boundaries — source freeze

**UNRUN.** Baseline production is merged main
`30415798dc2d5c73f14c2b38a35e90c6bc2879c6`. Ten finite regression/control cases
are frozen in `test/yelixer/parser_budget_test.exs` (SHA-256
`4a7c536a27907d2a5035ee1d48fecc3bbced734dae6045218c38d236aff98fa8`).
No input in that file exceeds 400 bytes. No hostile large-input benchmark or
outage claim is involved.

The proposed decoder policy limits unsigned and signed varints to ten bytes,
counts Any array/object nesting to a maximum of 128, checks state-vector entries
against JavaScript's maximum safe integer, and refuses counts impossible for the
remaining bytes. The generic varint width policy is not a claim that every value
within ten bytes is a safe Yjs identity: identity/clock checks are separate.
The maximum unsigned 64-bit value is an explicit generic-codec control.

These are Yelixer resource limits, not a claim that official Yjs rejects every
padded varint or every deeply nested value. They can reject byte-legal input
outside this policy. Callers authoring deep values must remain within the receive
boundary; this proposal does not add a corresponding limit to all encoder APIs.

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

Verification proposal: the ten cases baseline first, the same ten after the
bounded decoder edit, affected Encoding/Any/state-vector/sync/fuzz checks, and the
existing stable-Yjs conformance file. Only a separately granted local window may
run these; full regression remains hosted CI, followed by one review per PR.
