// Generate test fixtures from Yjs v14 for interop testing
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

// 1. Simple text: "hello" inserted at position 0
const doc1 = new Y.Doc({ gc: false })
doc1.clientID = 1
const text1 = doc1.get('text')
doc1.transact(() => { text1.insert(0, 'hello') })
const update1 = Y.encodeStateAsUpdate(doc1)
const sv1 = Y.encodeStateVector(doc1)
fs.writeFileSync('test/fixtures/hello_update_v1.bin', Buffer.from(update1))
fs.writeFileSync('test/fixtures/hello_sv.bin', Buffer.from(sv1))

// 2. Two-peer sync scenario
const docA = new Y.Doc({ gc: false })
docA.clientID = 10
const textA = docA.get('text')
docA.transact(() => { textA.insert(0, 'abc') })

const docB = new Y.Doc({ gc: false })
docB.clientID = 20
const textB = docB.get('text')
docB.transact(() => { textB.insert(0, 'xyz') })

const updateA = Y.encodeStateAsUpdate(docA)
const updateB = Y.encodeStateAsUpdate(docB)

// Apply both to get merged state
Y.applyUpdate(docA, updateB)
const mergedText = docA.get('text').toString()

fs.writeFileSync('test/fixtures/peer_a_update.bin', Buffer.from(updateA))
fs.writeFileSync('test/fixtures/peer_b_update.bin', Buffer.from(updateB))
fs.writeFileSync('test/fixtures/merged_text.txt', mergedText)

// 3. Array
const doc3 = new Y.Doc({ gc: false })
doc3.clientID = 1
const arr = doc3.get('arr')
doc3.transact(() => { arr.insert(0, [1, 2, 3]) })
const updateArr = Y.encodeStateAsUpdate(doc3)
fs.writeFileSync('test/fixtures/array_123_update.bin', Buffer.from(updateArr))

console.log('Generated fixtures:')
console.log('  hello_update_v1.bin:', update1.byteLength, 'bytes')
console.log('  hello_sv.bin:', sv1.byteLength, 'bytes')
console.log('  peer_a_update.bin:', updateA.byteLength, 'bytes')
console.log('  peer_b_update.bin:', updateB.byteLength, 'bytes')
console.log('  merged_text.txt:', JSON.stringify(mergedText))
console.log('  array_123_update.bin:', updateArr.byteLength, 'bytes')
console.log('')
console.log('Update bytes (hello):', Array.from(update1).map(b => b.toString(16).padStart(2,'0')).join(' '))
console.log('SV bytes (hello):', Array.from(sv1).map(b => b.toString(16).padStart(2,'0')).join(' '))
