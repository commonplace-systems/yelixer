// Exact stable-Yjs value oracle. Descriptor objects preserve distinctions
// JSON itself cannot carry (undefined, bigint, and Uint8Array).
import readline from 'node:readline'
import { createRequire } from 'node:module'
import * as Y from 'yjs-stable'

const version = createRequire(import.meta.url)('yjs-stable/package.json').version
if (version !== '13.6.32') throw new Error(`Wrong Yjs version: ${version}`)

const oracleAt = process.argv.indexOf('--oracle')
if (oracleAt !== -1 && process.argv[oracleAt + 1] !== 'stable') {
  throw new Error('This fixture requires stable Yjs 13.6.32')
}
if (process.argv.includes('--check-import')) process.exit(0)

const values = {
  buffer: new Uint8Array([0, 65, 255, 128]),
  undefined: undefined,
  bigint: 42n,
  bigint_min: -(1n << 63n),
  bigint_max: (1n << 63n) - 1n,
  nested: { list: [new Uint8Array([]), undefined, 42n], child: { bytes: new Uint8Array([255]) } },
  ordinary: { text: 'hello', number: 42, null: null, bool: false, list: [1, 'a'] }
}

function describe(value) {
  if (value === undefined) return { type: 'undefined' }
  if (value instanceof Uint8Array) return { type: 'buffer', hex: Buffer.from(value).toString('hex') }
  if (typeof value === 'bigint') return { type: 'bigint', decimal: value.toString() }
  if (value === null) return { type: 'null' }
  if (Array.isArray(value)) return { type: 'array', values: value.map(describe) }
  if (typeof value === 'object') {
    return { type: 'object', entries: Object.fromEntries(Object.keys(value).sort().map(k => [k, describe(value[k])])) }
  }
  return { type: typeof value, value }
}

function view(doc) {
  return {
    ok: true,
    map: describe(doc.getMap('values').get('value')),
    array: describe(doc.getArray('items').toArray()),
    sv: Buffer.from(Y.encodeStateVector(doc)).toString('hex')
  }
}

for await (const line of readline.createInterface({ input: process.stdin })) {
  let doc
  try {
    const msg = JSON.parse(line)
    doc = new Y.Doc({ gc: false })
    if (msg.cmd === 'seed') {
      if (!Object.hasOwn(values, msg.case)) throw new Error('unknown fixture case')
      doc.clientID = 7
      // The object wrapper forces Any content even for a buffer: top-level
      // Yjs buffers use the distinct ContentBinary struct, already supported.
      const value = { payload: values[msg.case] }
      doc.getMap('values').set('value', value)
      doc.getArray('items').insert(0, [value])
      console.log(JSON.stringify({ ...view(doc), version, update: Buffer.from(Y.encodeStateAsUpdate(doc)).toString('hex') }))
    } else if (msg.cmd === 'inspect') {
      Y.applyUpdate(doc, Buffer.from(msg.update, 'hex'))
      console.log(JSON.stringify(view(doc)))
    } else {
      throw new Error('unknown command')
    }
  } catch (error) {
    console.log(JSON.stringify({ ok: false, error: String(error.message) }))
  } finally {
    doc?.destroy()
  }
}
