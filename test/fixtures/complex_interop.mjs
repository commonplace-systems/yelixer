// Complex interop: multi-client, multi-edit, with deletions
// Was '../../yjs/src/index.js' -- an untracked, unpinned clone, now removed.
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

// Scenario: 3 peers make concurrent edits with deletions
const doc1 = new Y.Doc({ gc: false })
const doc2 = new Y.Doc({ gc: false })
const doc3 = new Y.Doc({ gc: false })
doc1.clientID = 10
doc2.clientID = 20
doc3.clientID = 30

// Peer 1: types "hello"
doc1.transact(() => { doc1.get('text').insert(0, 'hello') })

// Peer 2: types "world"
doc2.transact(() => { doc2.get('text').insert(0, 'world') })

// Peer 3: types "!!!"
doc3.transact(() => { doc3.get('text').insert(0, '!!!') })

// Sync all
const u1 = Y.encodeStateAsUpdate(doc1)
const u2 = Y.encodeStateAsUpdate(doc2)
const u3 = Y.encodeStateAsUpdate(doc3)

Y.applyUpdate(doc1, u2)
Y.applyUpdate(doc1, u3)
Y.applyUpdate(doc2, u1)
Y.applyUpdate(doc2, u3)
Y.applyUpdate(doc3, u1)
Y.applyUpdate(doc3, u2)

console.log('After sync (all should match):')
console.log('  doc1:', doc1.get('text').toString())
console.log('  doc2:', doc2.get('text').toString())
console.log('  doc3:', doc3.get('text').toString())

// Verify convergence
const text = doc1.get('text').toString()
if (doc1.get('text').toString() !== doc2.get('text').toString() ||
    doc2.get('text').toString() !== doc3.get('text').toString()) {
  console.error('CONVERGENCE FAILURE')
  process.exit(1)
}

// Now peer 1 deletes "world" from the merged text
const worldIdx = text.indexOf('world')
if (worldIdx >= 0) {
  doc1.transact(() => { doc1.get('text').delete(worldIdx, 5) })
}

// Sync deletion
const u1after = Y.encodeStateAsUpdate(doc1)
Y.applyUpdate(doc2, u1after)

console.log('After deletion:')
console.log('  doc1:', doc1.get('text').toString())
console.log('  doc2:', doc2.get('text').toString())

// Save full state for Yelixer to decode
const fullUpdate = Y.encodeStateAsUpdate(doc1)
fs.writeFileSync('test/fixtures/complex_update.bin', Buffer.from(fullUpdate))
fs.writeFileSync('test/fixtures/complex_expected.txt', doc1.get('text').toString())

console.log('Saved complex_update.bin:', fullUpdate.byteLength, 'bytes')
console.log('Expected text:', JSON.stringify(doc1.get('text').toString()))
