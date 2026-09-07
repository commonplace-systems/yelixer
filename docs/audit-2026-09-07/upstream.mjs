// One bounded upstream oracle invocation. Existing modules only; no network.
// Usage: node upstream.mjs /path/to/consumer/assets/node_modules
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const root = resolve(process.argv[2])
const pkg = name => JSON.parse(readFileSync(resolve(root, name, 'package.json'), 'utf8'))
const Y = await import(pathToFileURL(resolve(root, 'yjs/dist/yjs.mjs')))
const sync = await import(pathToFileURL(resolve(root, 'y-protocols/sync.js')))
const enc = await import(pathToFileURL(resolve(root, 'lib0/encoding.js')))
const dec = await import(pathToFileURL(resolve(root, 'lib0/decoding.js')))
const hex = bytes => Buffer.from(bytes).toString('hex')
const encode = fn => { const e = enc.createEncoder(); fn(e); return enc.toUint8Array(e) }

if (pkg('yjs').version !== '13.6.32' || pkg('y-protocols').version !== '1.0.7') {
  throw new Error('oracle version mismatch')
}

const empty = new Y.Doc()
const framing = {
  official_empty_step1: hex(encode(e => sync.writeSyncStep1(e, empty))),
  official_empty_step2: hex(encode(e => sync.writeSyncStep2(e, empty))),
  official_empty_update: hex(encode(e => sync.writeUpdate(e, Y.encodeStateAsUpdate(empty))))
}

const any = {}
for (const [name, value, yelixerBytes] of [
  ['buffer', new Uint8Array([65, 66]), [119, 2, 65, 66]],
  ['undefined', undefined, [126]],
  ['bigint', 42n, [125, 42]]
]) {
  const decoded = dec.readAny(dec.createDecoder(new Uint8Array(yelixerBytes)))
  any[name] = {
    upstream_hex: hex(encode(e => enc.writeAny(e, value))),
    original_type: value instanceof Uint8Array ? 'Uint8Array' : typeof value,
    yelixer_reencoded_type: decoded === null ? 'null' : typeof decoded
  }
}

empty.destroy()
console.log(JSON.stringify({ versions: {
  yjs: pkg('yjs').version, y_protocols: pkg('y-protocols').version, lib0: pkg('lib0').version
}, framing, any }))
