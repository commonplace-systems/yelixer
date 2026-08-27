// Full roundtrip: Yelixer -> Yjs -> Yelixer
// 1. Read Yelixer update, apply to Yjs doc
// 2. Make an edit in Yjs
// 3. Encode and save for Yelixer to read back
// Was '../../yjs/src/index.js' -- an unpinned clone path.
// (yjs_oracle/yjs_verify's variant resolved to /yelixer/yjs, which never existed:
//  broken at HEAD before the clone was removed, and unreferenced by any test or CI.)
// Uses the version-pinned oracle instead (yjs-stable = npm:yjs@13.6.32).
// ⚠️ STATUS 2026-08-27: IMPORTS CLEANLY, DOES NOT RUN YET. This script was
// authored against the yjs v14 API (`doc.get(name).insert(...)`); the pinned
// stable oracle is 13.6.32, where that is `doc.getText(name)`. It needs an API
// update before it can be used. Left visibly broken rather than silently
// repointed at a v14 build: the parity target is STABLE, and a dev script that
// quietly regenerates fixtures from a non-target version is how the committed
// corpus lost its provenance in the first place.
import * as Y from 'yjs-stable'
import fs from 'fs'

// Step 1: Load Yelixer update
const yelixerUpdate = new Uint8Array(fs.readFileSync('test/fixtures/yelixer_text_update.bin'))
const doc = new Y.Doc({ gc: false })
doc.clientID = 200
Y.applyUpdate(doc, yelixerUpdate)

console.log('After Yelixer update:', doc.get('text').toString())

// Step 2: Make a Yjs edit
doc.transact(() => {
  const text = doc.get('text')
  text.insert(text.length, ' and yjs')
})

console.log('After Yjs edit:', doc.get('text').toString())

// Step 3: Encode full state and save
const fullUpdate = Y.encodeStateAsUpdate(doc)
fs.writeFileSync('test/fixtures/roundtrip_yjs_update.bin', Buffer.from(fullUpdate))
fs.writeFileSync('test/fixtures/roundtrip_expected.txt', doc.get('text').toString())

console.log('Saved roundtrip_yjs_update.bin:', fullUpdate.byteLength, 'bytes')
console.log('Expected text:', doc.get('text').toString())
