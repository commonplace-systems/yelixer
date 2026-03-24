// Oracle test vector generator: uses Yjs (v14) as ground truth for yelixer interop testing.
//
// Usage:   cd apps/yelixer && node test/fixtures/yjs_oracle.mjs
// Output:  test/fixtures/oracle_vectors.json
//
// Each vector records: name, hex-encoded update, types used, and expected output
// after applying the update to a fresh Yjs doc.  Yelixer tests decode the same
// update and compare against the expected values.
//
// NOTE: Yjs v14 has a unified YType model:
//   - Text:  doc.get('name').insert(0, 'string')  /  .toString()
//   - Map:   doc.get('name').setAttr(key, val)     /  .getAttrs()
//   - Array: doc.get('name').insert(0, [vals])     /  .toArray()
//
// Known interop gaps with yelixer (as of 2026-03):
//   - Integer ContentAny values: lib0 uses writeVarInt (sign-bit-in-6th-bit),
//     but yelixer uses zigzag (decode_sint).  Positive ints decode incorrectly.
//   - Booleans in ContentAny: lib0 uses 120=true / 121=false, yelixer has them
//     reversed.
//   - Nested sub-types: Yjs v14 unified YType encodes as typeref 4 (xml_fragment),
//     but yelixer's sub_type_to_json only handles :text/:array/:map.

import * as Y from '../../../../../yelixer/yjs/src/index.js'
import fs from 'fs'
import { fileURLToPath } from 'url'
import path from 'path'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

function toHex(uint8) {
  return Array.from(uint8).map(b => b.toString(16).padStart(2, '0')).join('')
}

const vectors = []

// ---------------------------------------------------------------------------
// 1. Simple text insert
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => { doc.get('text').insert(0, 'hello world') })
  vectors.push({
    name: 'text_simple_insert',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { text: 'text' },
    expected: { text: 'hello world' }
  })
}

// ---------------------------------------------------------------------------
// 2. Text insert + delete
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => { doc.get('text').insert(0, 'hello world') })
  doc.transact(() => { doc.get('text').delete(5, 6) })  // delete " world"
  vectors.push({
    name: 'text_insert_delete',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { text: 'text' },
    expected: { text: 'hello' }
  })
}

// ---------------------------------------------------------------------------
// 3. Two-client concurrent text inserts (merge)
// ---------------------------------------------------------------------------
{
  const docA = new Y.Doc({ gc: false }); docA.clientID = 10
  const docB = new Y.Doc({ gc: false }); docB.clientID = 20
  docA.transact(() => { docA.get('text').insert(0, 'abc') })
  docB.transact(() => { docB.get('text').insert(0, 'xyz') })
  // Merge into a fresh doc
  const merged = new Y.Doc({ gc: false }); merged.clientID = 99
  Y.applyUpdate(merged, Y.encodeStateAsUpdate(docA))
  Y.applyUpdate(merged, Y.encodeStateAsUpdate(docB))
  vectors.push({
    name: 'text_two_client_merge',
    update_hex: toHex(Y.encodeStateAsUpdate(merged)),
    types: { text: 'text' },
    expected: { text: merged.get('text').toString() }
  })
}

// ---------------------------------------------------------------------------
// 4. Map with string values
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => {
    doc.get('mymap').setAttr('name', 'Alice')
    doc.get('mymap').setAttr('city', 'Berlin')
  })
  vectors.push({
    name: 'map_string_values',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { mymap: 'map' },
    expected: { mymap: doc.get('mymap').getAttrs() }
  })
}

// ---------------------------------------------------------------------------
// 5. Map with overwrite (set same key twice)
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => {
    doc.get('mymap').setAttr('key', 'first')
    doc.get('mymap').setAttr('key', 'second')
  })
  vectors.push({
    name: 'map_overwrite',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { mymap: 'map' },
    expected: { mymap: { key: 'second' } }
  })
}

// ---------------------------------------------------------------------------
// 6. Map with nested map sub-type (KNOWN ISSUE: typeref mismatch)
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => {
    const outer = doc.get('mymap')
    const inner = new Y.Type()
    outer.setAttr('nested', inner)
    inner.setAttr('a', 'one')
    inner.setAttr('b', 'two')
  })
  vectors.push({
    name: 'map_nested_map',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { mymap: 'map' },
    expected: { mymap: doc.get('mymap').getAttrs() },
    xfail: 'Yjs v14 unified YType encodes nested types as typeref 4 (xml_fragment); yelixer sub_type_to_json only handles :text/:array/:map'
  })
}

// ---------------------------------------------------------------------------
// 7. Map with nested array sub-type (KNOWN ISSUE)
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => {
    const m = doc.get('mymap')
    const arr = new Y.Type()
    m.setAttr('list', arr)
    arr.insert(0, ['x', 'y', 'z'])
  })
  vectors.push({
    name: 'map_nested_array',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { mymap: 'map' },
    expected: { mymap: doc.get('mymap').getAttrs() },
    xfail: 'Yjs v14 unified YType encodes nested types as typeref 4 (xml_fragment); yelixer sub_type_to_json only handles :text/:array/:map'
  })
}

// ---------------------------------------------------------------------------
// 8. Array push (string values — integers have encoding mismatch)
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => { doc.get('arr').insert(0, ['a', 'b', 'c']) })
  vectors.push({
    name: 'array_push_strings',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { arr: 'array' },
    expected: { arr: ['a', 'b', 'c'] }
  })
}

// ---------------------------------------------------------------------------
// 9. Array insert at index (string values)
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => {
    doc.get('arr').insert(0, ['x', 'z'])
    doc.get('arr').insert(1, ['y'])  // insert 'y' at index 1
  })
  vectors.push({
    name: 'array_insert_at_index',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { arr: 'array' },
    expected: { arr: ['x', 'y', 'z'] }
  })
}

// ---------------------------------------------------------------------------
// 10. Mixed: text + map in same doc
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => {
    doc.get('text').insert(0, 'mixed')
    doc.get('mymap').setAttr('key', 'value')
  })
  vectors.push({
    name: 'mixed_text_and_map',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { text: 'text', mymap: 'map' },
    expected: { text: 'mixed', mymap: { key: 'value' } }
  })
}

// ---------------------------------------------------------------------------
// 11. Three-client concurrent text edits
// ---------------------------------------------------------------------------
{
  const docs = [1, 2, 3].map(id => {
    const d = new Y.Doc({ gc: false }); d.clientID = id * 10; return d
  })
  docs[0].transact(() => { docs[0].get('text').insert(0, 'aaa') })
  docs[1].transact(() => { docs[1].get('text').insert(0, 'bbb') })
  docs[2].transact(() => { docs[2].get('text').insert(0, 'ccc') })
  // Merge into fresh doc
  const merged = new Y.Doc({ gc: false }); merged.clientID = 99
  for (const d of docs) {
    Y.applyUpdate(merged, Y.encodeStateAsUpdate(d))
  }
  vectors.push({
    name: 'text_three_client_merge',
    update_hex: toHex(Y.encodeStateAsUpdate(merged)),
    types: { text: 'text' },
    expected: { text: merged.get('text').toString() }
  })
}

// ---------------------------------------------------------------------------
// 12. Text delete in the middle
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => { doc.get('text').insert(0, 'abcdef') })
  doc.transact(() => { doc.get('text').delete(2, 2) })  // "abcdef" -> "abef"
  vectors.push({
    name: 'text_delete_middle',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { text: 'text' },
    expected: { text: 'abef' }
  })
}

// ---------------------------------------------------------------------------
// 13. Map delete key
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => {
    doc.get('mymap').setAttr('keep', 'yes')
    doc.get('mymap').setAttr('remove', 'no')
  })
  doc.transact(() => {
    doc.get('mymap').deleteAttr('remove')
  })
  vectors.push({
    name: 'map_delete_key',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { mymap: 'map' },
    expected: { mymap: { keep: 'yes' } }
  })
}

// ---------------------------------------------------------------------------
// 14. Text with multiple sequential inserts
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => { doc.get('text').insert(0, 'hello') })
  doc.transact(() => { doc.get('text').insert(5, ' ') })
  doc.transact(() => { doc.get('text').insert(6, 'world') })
  vectors.push({
    name: 'text_sequential_inserts',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { text: 'text' },
    expected: { text: 'hello world' }
  })
}

// ---------------------------------------------------------------------------
// 15. Array with integer values (KNOWN ISSUE: writeVarInt vs zigzag)
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => { doc.get('arr').insert(0, [1, 2, 3]) })
  vectors.push({
    name: 'array_integer_values',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { arr: 'array' },
    expected: { arr: [1, 2, 3] },
    xfail: 'lib0 writeVarInt (sign-bit-in-6th-bit) vs yelixer decode_sint (zigzag) mismatch for integer ContentAny'
  })
}

// ---------------------------------------------------------------------------
// 16. Mixed text + map + array (strings only) in same doc
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => {
    doc.get('text').insert(0, 'hello')
    doc.get('mymap').setAttr('k', 'v')
    doc.get('arr').insert(0, ['one', 'two'])
  })
  vectors.push({
    name: 'mixed_all_types',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { text: 'text', mymap: 'map', arr: 'array' },
    expected: { text: 'hello', mymap: { k: 'v' }, arr: ['one', 'two'] }
  })
}

// ---------------------------------------------------------------------------
// 17. Text insert at beginning (prepend)
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => { doc.get('text').insert(0, 'world') })
  doc.transact(() => { doc.get('text').insert(0, 'hello ') })
  vectors.push({
    name: 'text_prepend',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { text: 'text' },
    expected: { text: 'hello world' }
  })
}

// ---------------------------------------------------------------------------
// 18. Text insert in middle
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => { doc.get('text').insert(0, 'hllo') })
  doc.transact(() => { doc.get('text').insert(1, 'e') })
  vectors.push({
    name: 'text_insert_middle',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { text: 'text' },
    expected: { text: 'hello' }
  })
}

// ---------------------------------------------------------------------------
// 19. Map with many keys
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => {
    const m = doc.get('mymap')
    m.setAttr('a', 'alpha')
    m.setAttr('b', 'beta')
    m.setAttr('c', 'gamma')
    m.setAttr('d', 'delta')
  })
  vectors.push({
    name: 'map_many_keys',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { mymap: 'map' },
    expected: { mymap: { a: 'alpha', b: 'beta', c: 'gamma', d: 'delta' } }
  })
}

// ---------------------------------------------------------------------------
// 20. Two-client map conflict (last-write-wins)
// ---------------------------------------------------------------------------
{
  const docA = new Y.Doc({ gc: false }); docA.clientID = 10
  const docB = new Y.Doc({ gc: false }); docB.clientID = 20
  docA.transact(() => { docA.get('mymap').setAttr('key', 'from_a') })
  docB.transact(() => { docB.get('mymap').setAttr('key', 'from_b') })
  // Merge
  const merged = new Y.Doc({ gc: false }); merged.clientID = 99
  Y.applyUpdate(merged, Y.encodeStateAsUpdate(docA))
  Y.applyUpdate(merged, Y.encodeStateAsUpdate(docB))
  vectors.push({
    name: 'map_two_client_conflict',
    update_hex: toHex(Y.encodeStateAsUpdate(merged)),
    types: { mymap: 'map' },
    expected: { mymap: merged.get('mymap').getAttrs() }
  })
}

// ---------------------------------------------------------------------------
// 21. Text delete all
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => { doc.get('text').insert(0, 'gone') })
  doc.transact(() => { doc.get('text').delete(0, 4) })
  vectors.push({
    name: 'text_delete_all',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { text: 'text' },
    expected: { text: '' }
  })
}

// ---------------------------------------------------------------------------
// 22. Array delete elements (strings)
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => { doc.get('arr').insert(0, ['a', 'b', 'c', 'd']) })
  doc.transact(() => { doc.get('arr').delete(1, 2) })  // remove 'b' and 'c'
  vectors.push({
    name: 'array_delete_elements',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { arr: 'array' },
    expected: { arr: ['a', 'd'] }
  })
}

// ---------------------------------------------------------------------------
// 23. Text with concurrent inserts then deletion
// ---------------------------------------------------------------------------
{
  const docA = new Y.Doc({ gc: false }); docA.clientID = 10
  const docB = new Y.Doc({ gc: false }); docB.clientID = 20
  docA.transact(() => { docA.get('text').insert(0, 'hello') })
  docB.transact(() => { docB.get('text').insert(0, 'world') })
  // Merge
  Y.applyUpdate(docA, Y.encodeStateAsUpdate(docB))
  Y.applyUpdate(docB, Y.encodeStateAsUpdate(docA))
  // Delete from merged state
  const mergedText = docA.get('text').toString()
  const worldIdx = mergedText.indexOf('world')
  if (worldIdx >= 0) {
    docA.transact(() => { docA.get('text').delete(worldIdx, 5) })
  }
  vectors.push({
    name: 'text_merge_then_delete',
    update_hex: toHex(Y.encodeStateAsUpdate(docA)),
    types: { text: 'text' },
    expected: { text: docA.get('text').toString() }
  })
}

// ---------------------------------------------------------------------------
// 24. Empty text (no operations)
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  // Get text type but don't insert anything
  doc.get('text')
  vectors.push({
    name: 'text_empty',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { text: 'text' },
    expected: { text: '' }
  })
}

// ---------------------------------------------------------------------------
// 25. Map with null value
// ---------------------------------------------------------------------------
{
  const doc = new Y.Doc({ gc: false }); doc.clientID = 1
  doc.transact(() => {
    doc.get('mymap').setAttr('present', 'yes')
    doc.get('mymap').setAttr('empty', null)
  })
  vectors.push({
    name: 'map_with_null_value',
    update_hex: toHex(Y.encodeStateAsUpdate(doc)),
    types: { mymap: 'map' },
    expected: { mymap: doc.get('mymap').getAttrs() }
  })
}

// ---------------------------------------------------------------------------
// Write output
// ---------------------------------------------------------------------------
const outPath = path.join(__dirname, 'oracle_vectors.json')
fs.writeFileSync(outPath, JSON.stringify(vectors, null, 2) + '\n')
console.log(`Generated ${vectors.length} oracle vectors -> ${outPath}`)
for (const v of vectors) {
  const status = v.xfail ? ' [XFAIL]' : ''
  console.log(`  ${v.name}: ${v.update_hex.length / 2} bytes${status}`)
}
