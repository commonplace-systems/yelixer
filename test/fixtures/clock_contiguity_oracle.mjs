// yelixer#9 clock-contiguity oracle: applies update bytes to Yjs 13.6.32 in
// phases and reports, after each phase, the state vector, whether Yjs holds
// pending structs, and the rendering of each named root.
//
// argv[2]: path of a JSON file {"roots": {"t": "text", "m": "map", "a": "array",
//            "x": "xmlelement", "f": "xmlfragment"},
//          "phases": [["<hex>", ...], ["<hex>", ...]]}
// stdout: {"yjs": "13.6.32",
//          "phases": [{"sv": {"<client>": clock}, "pending": bool, "roots": {...}}, ...]}
import * as Y from 'yjs-stable'
import fs from 'fs'
import { createRequire } from 'module'

const EXPECTED_YJS = '13.6.32'
const version = createRequire(import.meta.url)('yjs-stable/package.json').version
if (version !== EXPECTED_YJS) throw new Error(`oracle needs yjs ${EXPECTED_YJS}, found ${version}`)

const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const doc = new Y.Doc()
const roots = {}
for (const [name, kind] of Object.entries(input.roots)) {
  if (kind === 'text') roots[name] = doc.getText(name)
  else if (kind === 'map') roots[name] = doc.getMap(name)
  else if (kind === 'array') roots[name] = doc.getArray(name)
  else if (kind === 'xmlelement') roots[name] = doc.get(name, Y.XmlElement)
  else if (kind === 'xmlfragment') roots[name] = doc.getXmlFragment(name)
  else throw new Error(`unknown root kind ${kind}`)
}
const render = root => {
  if (root instanceof Y.Text) return root.toString()
  if (root instanceof Y.XmlElement) return { string: root.toString(), attrs: root.getAttributes() }
  if (root instanceof Y.XmlFragment) return root.toString()
  return root.toJSON()
}
const phases = []
for (const phase of input.phases) {
  for (const hex of phase) Y.applyUpdate(doc, Uint8Array.from(Buffer.from(hex, 'hex')))
  const sv = {}
  for (const [client, clock] of Y.decodeStateVector(Y.encodeStateVector(doc))) sv[client] = clock
  const json = {}
  for (const [name, root] of Object.entries(roots)) json[name] = render(root)
  phases.push({ sv, pending: doc.store.pendingStructs !== null, roots: json })
}
process.stdout.write(JSON.stringify({ yjs: version, phases }) + '\n')
