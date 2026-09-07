# Yelixer

An Elixir implementation of Yjs V1 document updates and shared data types.
Documents are immutable values; an optional `Yelixer.DocServer` owns a document
in a GenServer and broadcasts local changes to subscribers.

## Installation

Pin a reviewed Git revision in `mix.exs`:

```elixir
def deps do
  [
    {:yelixer, git: "https://github.com/commonplace-systems/yelixer.git", ref: "<commit>"}
  ]
end
```

## Plain text

```elixir
doc = Yelixer.Doc.new(client_id: 7)
{doc, _type} = Yelixer.Doc.get_or_create_type(doc, "content", :text)
doc = Yelixer.Types.Text.insert(doc, "content", 0, "hello")
update = Yelixer.Encoding.encode_update(doc)
{:ok, peer} = Yelixer.Encoding.apply_update(Yelixer.Doc.new(client_id: 8), update)
"hello" = Yelixer.Types.Text.to_string(peer, "content")
```

Positions count **UTF-16 code units**, not Elixir graphemes or UTF-8 bytes.
Local positions inside a surrogate pair clamp upward, including independent
delete endpoints. Incoming wire edits retain their exact identity clocks and
follow the pinned Yjs replacement behavior. Reusing a client ID requires restoring
its existing clock history before authoring new operations.

## Compatibility scope

The conformance oracles pin Yjs **13.6.32** and separately **14.0.0-16** preview.
These pins define tested behavior; they are not a guarantee for every type/API.

| Surface | Scope |
| --- | --- |
| Document encoding | V1 updates/state vectors, incremental apply/diff, delete sets and pending dependencies |
| Raw sync frames | y-protocols 1.0.7 length-delimited tags 0, 1 and 2; caller supplies transport/room envelopes |
| Plain Text / XMLText | Local UTF-16 positions and scalar-boundary normalization; rich-text formatting positions have known differences |
| General values | Primitive values and explicit Any buffer/undefined/signed-64-bit-bigint wrappers; ordinary binaries encode as strings |
| Content reads | `Array.to_list` and `YMap.get/to_map` resolve supported nested values; ContentBinary projects to `Any.buffer`; these are value projections, not nested CRDT insertion |
| Awareness / transport | Not supplied by this library |
| V2 / subdocuments | Not advertised as supported |
| Persistence | Caller responsibility; DocServer state is in memory |
| Reauthored snapshots | Not ordinary mergeable updates; overlay and derivation-map limitations are documented in the audit |

`SyncProtocol.handle_message/2` returns `{:step2, frame}`, `{:update, doc}`, or
`{:error, reason}`. `DocServer.apply_update/2` returns tagged codec errors while
retaining its document. Callers should handle these errors. An accepted update
can still contain unresolved dependencies: inspect `Doc.pending_info/1` when
deciding whether an application-level operation is complete.

Older Yelixer sync frames omitted the payload length. They are incompatible with
upstream framing and must not be mixed with the corrected protocol.

Use `Yelixer.Any.buffer(bytes)`, `Yelixer.Any.undefined()` and
`Yelixer.Any.bigint(integer)` when authoring these JavaScript value types.
Decoding their Any wire tags now returns these wrappers, including in nested
maps and lists. Ordinary binaries, `nil` and integers retain their string, null
and number meanings. Callers that previously treated decoded buffers as strings,
undefined as `nil`, or bigints as ordinary integers must handle the wrappers.
JSON projections need an explicit application representation for these types.

See the [ranked project audit](docs/audit-2026-09-07/README.md),
[Unicode policy](docs/unicode-compatibility.md), and
[incoming Unicode evidence](docs/unicode-inbound-repair.md) for measured limits.
The test suite keeps two unwrapped-binary authoring expectations separately
counted: ordinary binaries remain strings, while `Any.buffer/1` requests a byte
buffer. Formatted text length excludes format markers; local rich-text editing
positions and attribute behavior remain outside the plain-text authoring contract.
See the [second repair round](docs/audit-round-2-2026-09-07/README.md) for evidence.

## Development

```sh
mix deps.get
npm ci --prefix test/fixtures
mix test
```

CI separately requires stable/preview oracles, counts executed checks, and
verifies the expected divergence population. See `.github/workflows/ci.yml` for
the exact gates. Performance probes in the audit are finite synthetic experiments,
not production latency measurements.


## License

MIT — see [LICENSE](LICENSE).

Yelixer is an independent implementation of the [Yjs](https://github.com/yjs/yjs)
CRDT. Yjs and [y-crdt](https://github.com/y-crdt/y-crdt) are also MIT licensed.
