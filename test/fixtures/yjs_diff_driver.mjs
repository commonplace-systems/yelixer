// Differential testing driver for Node yjs (CX-xk6).
//
// Reads JSONL commands from stdin, maintains a Y.Doc, and writes JSONL
// results to stdout. Used by Yelixer.DiffYjsTest to compare yelixer's
// behavior against the canonical JS reference.
//
// Protocol:
//   stdin  — one command per line, JSON object:
//     {"cmd":"reset","client_id":1,"type":"text","name":"content"}
//     {"cmd":"insert_text","pos":0,"text":"hello"}
//     {"cmd":"delete_text","pos":0,"len":1}
//     {"cmd":"set_map","root":"root","key":"k","value":"v"}
//     {"cmd":"delete_map","root":"root","key":"k"}
//     {"cmd":"push_array","root":"items","items":[1,2,3]}
//     {"cmd":"insert_array","root":"items","pos":0,"items":[0]}
//     {"cmd":"delete_array","root":"items","pos":0,"len":1}
//     {"cmd":"encode"}
//     {"cmd":"reload"}          — roundtrip: encode, discard, decode into fresh doc
//     {"cmd":"text_content","name":"content"}
//     {"cmd":"map_content","name":"root"}
//     {"cmd":"array_content","name":"items"}
//     {"cmd":"quit"}
//
//   stdout — one result per command, JSON object:
//     {"ok":true,...}  or  {"ok":false,"error":"..."}
//
// Usage:  node yjs_diff_driver.mjs --oracle stable|preview

import readline from 'readline'

const oracleArg = process.argv.indexOf('--oracle')
const oracle = oracleArg === -1 ? 'stable' : process.argv[oracleArg + 1]
const oraclePackages = {
  stable: 'yjs-stable',
  preview: 'yjs-preview'
}
const oraclePackage = oraclePackages[oracle]

if (!oraclePackage) {
  throw new Error(`unknown Yjs oracle '${oracle}'; expected stable or preview`)
}

// Import the selected package in this module so --check-import exercises the
// exact oracle that the long-lived JSONL process will use.
const Y = await import(oraclePackage)

// Let the ExUnit setup guard execute this exact module, including its selected
// oracle import, without starting the long-lived JSONL process.
if (process.argv.includes('--check-import')) process.exit(0)

// yjs logs a warning to stdout via lib0/logging.print → console.log
// when it auto-changes client-id on apply_update collision. Our stdout
// is reserved for JSONL responses, so silence all console methods —
// errors we care about are thrown and get caught in handle(). JSONL
// responses go through process.stdout.write directly.
console.log = () => {}
console.warn = () => {}
console.error = () => {}
console.info = () => {}
console.debug = () => {}

let doc = null
let clientId = 1
// Defer registering types until asked; this matches yelixer's lazy
// type creation in envelope-style docs.
function ensureDoc() {
  if (!doc) {
    doc = new Y.Doc({ gc: false })
    doc.clientID = clientId
  }
  return doc
}

function getText(name) {
  return ensureDoc().getText(name)
}

function getMap(name) {
  return ensureDoc().getMap(name)
}

function getArray(name) {
  return ensureDoc().getArray(name)
}

function toHex(uint8) {
  return Array.from(uint8).map((b) => b.toString(16).padStart(2, '0')).join('')
}

function fromHex(hex) {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substr(i, 2), 16)
  }
  return bytes
}

function handle(msg) {
  try {
    switch (msg.cmd) {
      case 'reset':
        doc = new Y.Doc({ gc: msg.gc === true })
        clientId = msg.client_id || 1
        doc.clientID = clientId
        return { ok: true }

      case 'insert_text': {
        const t = getText(msg.name || 'content')
        doc.transact(() => {
          t.insert(msg.pos || 0, msg.text)
        })
        return { ok: true, length: t.length }
      }

      case 'delete_text': {
        const t = getText(msg.name || 'content')
        doc.transact(() => {
          t.delete(msg.pos || 0, msg.len || 0)
        })
        return { ok: true, length: t.length }
      }

      case 'set_map': {
        const m = getMap(msg.root || 'root')
        doc.transact(() => {
          m.set(msg.key, msg.value)
        })
        return { ok: true }
      }

      case 'delete_map': {
        const m = getMap(msg.root || 'root')
        doc.transact(() => {
          m.delete(msg.key)
        })
        return { ok: true }
      }

      case 'push_array': {
        const a = getArray(msg.root || 'items')
        doc.transact(() => {
          a.insert(a.length, msg.items)
        })
        return { ok: true, length: a.length }
      }

      case 'insert_array': {
        const a = getArray(msg.root || 'items')
        doc.transact(() => {
          a.insert(msg.pos || 0, msg.items)
        })
        return { ok: true, length: a.length }
      }

      case 'delete_array': {
        const a = getArray(msg.root || 'items')
        doc.transact(() => {
          a.delete(msg.pos || 0, msg.len || 0)
        })
        return { ok: true, length: a.length }
      }

      case 'encode': {
        const update = Y.encodeStateAsUpdate(ensureDoc())
        return { ok: true, update_hex: toHex(update) }
      }

      case 'apply_update': {
        const bytes = fromHex(msg.update_hex)
        Y.applyUpdate(ensureDoc(), bytes)
        return { ok: true }
      }

      case 'reload': {
        // Full round-trip: encode, discard, decode into a fresh doc with
        // the same client id.
        const update = Y.encodeStateAsUpdate(ensureDoc())
        doc = new Y.Doc({ gc: false })
        doc.clientID = clientId
        Y.applyUpdate(doc, update)
        return { ok: true, update_hex: toHex(update) }
      }

      case 'text_content': {
        const t = getText(msg.name || 'content')
        return { ok: true, text: t.toString() }
      }

      case 'map_content': {
        const m = getMap(msg.name || 'root')
        return { ok: true, map: m.toJSON() }
      }

      case 'array_content': {
        const a = getArray(msg.name || 'items')
        return { ok: true, array: a.toArray() }
      }

      case 'quit':
        process.exit(0)

      default:
        return { ok: false, error: `unknown cmd: ${msg.cmd}` }
    }
  } catch (e) {
    return { ok: false, error: e.message || String(e) }
  }
}

const rl = readline.createInterface({ input: process.stdin, terminal: false })
rl.on('line', (line) => {
  if (!line.trim()) return
  let msg
  try {
    msg = JSON.parse(line)
  } catch (e) {
    process.stdout.write(JSON.stringify({ ok: false, error: `parse: ${e.message}` }) + '\n')
    return
  }
  const res = handle(msg)
  process.stdout.write(JSON.stringify(res) + '\n')
})
