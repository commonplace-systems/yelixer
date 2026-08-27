// Verify that Yjs can decode Yelixer-generated binary updates
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

let passed = 0
let failed = 0

function test(name, fn) {
  try {
    fn()
    console.log(`  PASS: ${name}`)
    passed++
  } catch (e) {
    console.log(`  FAIL: ${name}: ${e.message}`)
    failed++
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'Assertion failed')
}

console.log('Yjs decoding Yelixer updates:')

test('decode Yelixer text update', () => {
  const update = new Uint8Array(fs.readFileSync('test/fixtures/yelixer_text_update.bin'))
  const doc = new Y.Doc({ gc: false })
  Y.applyUpdate(doc, update)
  const text = doc.get('text').toString()
  assert(text === 'from elixir', `Expected "from elixir", got "${text}"`)
})

test('Yelixer state vector is valid', () => {
  const update = new Uint8Array(fs.readFileSync('test/fixtures/yelixer_text_update.bin'))
  const doc = new Y.Doc({ gc: false })
  Y.applyUpdate(doc, update)
  const sv = Y.encodeStateVector(doc)
  assert(sv.byteLength > 0, 'State vector should not be empty')
})

console.log(`\nResults: ${passed} passed, ${failed} failed`)
process.exit(failed > 0 ? 1 : 0)
