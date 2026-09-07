# Any wire-type preservation

Audit finding 5 is repaired for buffer, undefined and signed 64-bit bigint.
The codec retains their JavaScript types through decoding, nested containers,
re-encoding, and a document reload. Ordinary Elixir binaries still author
strings, `nil` authors null, and integers author numbers.

The measured baseline is **bf651769f8ee311b762728bb7a8a8c62c9686004** (the
PR #2 main tree). Baseline production code was unchanged. The repair adds
`Yelixer.Any` and changes the three corresponding Any encoder/decoder cases.
Its local comparison ran before integrating the separately validated performance
landing; the final rebased branch receives its own GitHub-hosted CI gate.

## API and compatibility

Use `Any.buffer/1`, `Any.undefined/0` and `Any.bigint/1` to author explicit values.
The decoder returns `%Yelixer.Any{type: ..., value: ...}` for these wire tags,
also inside maps/lists. Bigint constructors and encoding reject values outside
the signed 64-bit range instead of truncating a bitstring segment. These
wrappers are distinct from top-level Item `{:binary, bytes}` / ContentBinary,
whose representation did not change.

This is a return-type change for callers that previously depended on the lossy
buffer→binary-string, undefined→nil, or bigint→integer interpretation. It cannot
recover type information already lost in earlier re-encoded histories. JSON
cannot express these distinctions without an application-specific projection.
The change does not claim complete JavaScript numeric support (for example
negative zero/non-finite floats), rich-text parity, V2, or subdocuments. The
four existing expected content-divergence arms remain separately counted;
their ordinary-binary authoring inputs were not changed to use the new wrapper.

## Exact upstream discriminator

The [Node oracle](../../../test/fixtures/any_types_driver.mjs) requires the
installed `yjs-stable` package to be exactly **13.6.32**. Each case creates a
real Yjs map and array with the same value inside a plain object. That wrapper
forces the Any representation: a top-level JavaScript Uint8Array would exercise
the already-supported ContentBinary struct instead. Type descriptors retain
buffer hex, undefined, and bigint decimal values that plain JSON cannot carry.

Seven fixtures cover invalid-UTF8 buffer bytes, undefined, small bigint, both
signed 64-bit limits, nested arrays/objects with typed values, and ordinary
values as a passing control. A receiver applies the original Yjs update in
Elixir, re-encodes it, and asks Yjs to report the actual types. The repaired arm
also reloads the Elixir document and repeats the upstream observation. All
seven original seed updates are byte-identical between the retained
[baseline](baseline-oracle.jsonl) and [repaired](fixed-oracle.jsonl) transcripts.

| Baseline input | Actual baseline result after re-encoding |
| --- | --- |
| Buffer `00 41 ff 80` | Tag 116 becomes string tag 119; Yjs rejects invalid UTF-8 |
| Undefined | Null, while the state vector remains unchanged |
| Bigint `42n` | Ordinary number `42` |
| Bigint `-9223372036854775808n` | Ordinary number; JSON descriptor prints `-9223372036854776000` |
| Bigint `9223372036854775807n` | Yjs rejects the integer encoding as out of range |
| Nested typed values | Buffer becomes invalid UTF-8 string; Yjs rejects it |
| Ordinary values | Passes unchanged |

The signed-minimum observation establishes a **type change**; its JSON decimal
printing is not used as a separate claim that this exactly representable power
of two lost numeric precision.

Three additional fixed-byte primitive regressions separately identify the wire
tag changes. With the corrected adapter, the [baseline](baseline.txt) is
**10 tests / 9 failures, rc 2**; the same [repaired cases](fixed.txt) are
**10 / 0, rc 0**. The ordinary-value control passed on both revisions.

## Harness correction and execution identity

The first attempt omitted `ok: true` in the new oracle's successful response,
which the shared `CompatOracle.rpc/2` requires. Its three primitive failures
were codec observations, but all seven foreign cases stopped at that adapter
contract; they did not compare re-encoded content. The [invalid attempt](baseline-adapter-invalid.txt)
and [transcript](baseline-adapter-invalid-oracle.jsonl) are retained separately.
The success-envelope correction preceded production edits. [Harness hashes](baseline-harness.sha256)
identify the corrected source used on both sides; subsequent formatting did
not change cases. The original ten-failure count is **not** a conformance result.

The isolated local run used OTP 27 / Elixir 1.18.4, `MIX_ENV=test`, one normal
scheduler and one of each dirty scheduler. Cached dependencies used the retained
[lock](resolved-dependencies.lock); all three dependencies were force-compiled,
then 19 baseline modules and 20 repaired modules. [Baseline Encoding](baseline-beams.sha256)
and [repaired Encoding/Any](fixed-beams.sha256) fingerprints apply to that
pre-rebase comparison, not the final combined tree.
The [measured production patch](measured-repair.patch) and
[source hashes](fixed-source.sha256) preserve that exact intermediate source;
applying the patch to the stated baseline reconstructs it.

| Gate | Result |
| --- | --- |
| Corrected baseline regressions | 10 / 9 failures, rc 2 |
| Identical regressions after repair | 10 / 0, rc 0 |
| New API authoring, range and ordinary-value controls | 3 / 0, rc 0 |
| Existing encoding, malformed-input, map and array tests | 61 / 0, warnings as errors, rc 0 |
| Required Yjs 13.6.32 conformance | 11 / 0, rc 0 |
| Format and compilation with warnings as errors | rc 0 |

No full suite, server, consumer, browser or live document ran locally. All
owned BEAM/Node processes exited before the window release. Final combined
validation, single review and landing remain separately recorded gates.
