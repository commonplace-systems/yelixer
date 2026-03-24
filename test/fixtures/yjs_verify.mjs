// Reverse oracle: verify that Yjs can decode yelixer-generated update binaries.
//
// Usage:  cd apps/yelixer && node test/fixtures/yjs_verify.mjs
//
// Reads yelixer_*.bin files from test/fixtures/, applies each to a fresh Yjs
// doc, and prints the result.  Exit code 1 if any file fails to decode.

import * as Y from '../../../../../yelixer/yjs/src/index.js'
import fs from 'fs'
import { fileURLToPath } from 'url'
import path from 'path'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

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

console.log('Yjs decoding yelixer-generated updates:')
console.log()

// Scan for yelixer_*.bin files
const files = fs.readdirSync(__dirname)
  .filter(f => f.startsWith('yelixer_') && f.endsWith('.bin'))
  .sort()

if (files.length === 0) {
  console.log('  No yelixer_*.bin files found.  Generate them by running oracle_test.exs first.')
  console.log('  Example: cd apps/yelixer && mix test test/yelixer/oracle_test.exs')
  process.exit(0)
}

for (const file of files) {
  test(`decode ${file}`, () => {
    const update = new Uint8Array(fs.readFileSync(path.join(__dirname, file)))
    assert(update.byteLength > 0, 'File is empty')

    const doc = new Y.Doc({ gc: false })
    Y.applyUpdate(doc, update)

    // Verify state vector is non-empty (doc has content)
    const sv = Y.encodeStateVector(doc)
    assert(sv.byteLength > 0, 'State vector should not be empty after applying update')

    // Print what we got
    const shared = {}
    doc.share.forEach((type, key) => {
      const text = type.toString()
      const attrs = type.getAttrs()
      const arr = type.toArray()
      const parts = []
      if (text && text.length > 0 && !text.startsWith('<')) parts.push(`text="${text}"`)
      if (Object.keys(attrs).length > 0) parts.push(`attrs=${JSON.stringify(attrs)}`)
      if (arr.length > 0) parts.push(`array=${JSON.stringify(arr)}`)
      if (parts.length > 0) shared[key] = parts.join(', ')
    })
    if (Object.keys(shared).length > 0) {
      for (const [key, desc] of Object.entries(shared)) {
        console.log(`         ${key}: ${desc}`)
      }
    }
  })
}

// Also verify the reverse: read oracle_vectors.json and ensure Yjs can
// re-decode its own vectors (sanity check)
const vectorsPath = path.join(__dirname, 'oracle_vectors.json')
if (fs.existsSync(vectorsPath)) {
  console.log()
  console.log('Oracle vectors self-check:')
  const vectors = JSON.parse(fs.readFileSync(vectorsPath, 'utf-8'))
  for (const v of vectors) {
    test(`oracle ${v.name}`, () => {
      const update = new Uint8Array(Buffer.from(v.update_hex, 'hex'))
      const doc = new Y.Doc({ gc: false })
      Y.applyUpdate(doc, update)

      // Verify expected values match
      for (const [typeName, typeKind] of Object.entries(v.types)) {
        const ytype = doc.get(typeName)
        const expected = v.expected[typeName]

        if (typeKind === 'text') {
          const actual = ytype.toString()
          assert(actual === expected,
            `${typeName}: expected "${expected}", got "${actual}"`)
        } else if (typeKind === 'map') {
          const actual = ytype.getAttrs()
          const actualJson = JSON.stringify(actual, Object.keys(actual).sort())
          const expectedJson = JSON.stringify(expected, Object.keys(expected).sort())
          assert(actualJson === expectedJson,
            `${typeName}: expected ${expectedJson}, got ${actualJson}`)
        } else if (typeKind === 'array') {
          const actual = ytype.toArray()
          assert(JSON.stringify(actual) === JSON.stringify(expected),
            `${typeName}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
        }
      }
    })
  }
}

console.log()
console.log(`Results: ${passed} passed, ${failed} failed`)
process.exit(failed > 0 ? 1 : 0)
