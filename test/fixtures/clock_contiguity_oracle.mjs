// yelixer#9 clock-contiguity oracle: applies update bytes to Yjs 13.6.32 in
// phases and reports, after each phase, the state vector, whether Yjs holds
// pending structs, and the JSON of each named root.
//
// argv[2]: path of a JSON file {"roots": {"t": "text", "m": "map", "a": "array"},
//          "phases": [["<hex>", ...], ["<hex>", ...]]}
// stdout: [{"sv": {"<client>": clock}, "pending": bool, "roots": {...}}, ...]
import * as Y from 'yjs-stable'
import fs from 'fs'

const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const doc = new Y.Doc()
const roots = {}
for (const [name, kind] of Object.entries(input.roots)) {
  if (kind === 'text') roots[name] = doc.getText(name)
  else if (kind === 'map') roots[name] = doc.getMap(name)
  else if (kind === 'array') roots[name] = doc.getArray(name)
  else throw new Error(`unknown root kind ${kind}`)
}
const out = []
for (const phase of input.phases) {
  for (const hex of phase) Y.applyUpdate(doc, Uint8Array.from(Buffer.from(hex, 'hex')))
  const sv = {}
  for (const [client, clock] of Y.decodeStateVector(Y.encodeStateVector(doc))) sv[client] = clock
  const json = {}
  for (const [name, root] of Object.entries(roots)) {
    json[name] = root instanceof Y.Text ? root.toString() : root.toJSON()
  }
  out.push({ sv, pending: doc.store.pendingStructs !== null, roots: json })
}
process.stdout.write(JSON.stringify(out) + '\n')
