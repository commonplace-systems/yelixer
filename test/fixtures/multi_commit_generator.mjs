// Multi-commit fixture generator (CX-2cq).
//
// Generates a JSON file of fixture scenarios where each scenario is a
// sequence of hex-encoded yjs updates representing successive commits
// to the same doc. The yelixer test loads these as a commit chain and
// reconstructs the doc, asserting the final content matches.
//
// The point is static regression coverage: unlike the differential
// tests in diff_yjs_test.exs, these fixtures do not require Node at
// test time. CI runs them against committed binary.
//
// Usage:   node multi_commit_generator.mjs
// Output:  multi_commit_fixtures.json

import * as Y from '/home/jes/yelixer/yjs/src/index.js'
import fs from 'fs'
import { fileURLToPath } from 'url'
import path from 'path'

// Silence yjs client-id warnings (they go to console.log via lib0).
console.log = () => {}

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

function toHex(uint8) {
  return Array.from(uint8).map((b) => b.toString(16).padStart(2, '0')).join('')
}

// Take a sequence of op functions and produce a list of updates.
// Each op is applied in a fresh Y.Doc that has all prior updates
// applied — mirroring how commonplace's sync agent / MCP write path
// creates each new commit from a rehydrated snapshot.
function generateCommitChain(opSequence) {
  const updates = []
  let priorUpdates = []

  for (const op of opSequence) {
    // Fresh doc, replay prior updates, then apply the new op.
    const doc = new Y.Doc({ gc: false })
    for (const u of priorUpdates) {
      Y.applyUpdate(doc, u)
    }
    op(doc)
    const update = Y.encodeStateAsUpdate(doc)
    updates.push(update)
    priorUpdates.push(update)
  }

  return updates
}

// Read a doc's current text content (for expected values).
function readText(doc, name = 'content') {
  return doc.get(name).toString()
}

function readMap(doc, name = 'root') {
  return doc.get(name).getAttrs()
}

function readArray(doc, name = 'items') {
  return doc.get(name).toArray()
}

// Replay all updates from a chain and return the final doc state.
function replayAndRead(updates) {
  const doc = new Y.Doc({ gc: false })
  for (const u of updates) {
    Y.applyUpdate(doc, u)
  }
  return doc
}

const fixtures = []

// ---------------------------------------------------------------------------
// text_simple_chain: 3 commits of plain text inserts
// ---------------------------------------------------------------------------
{
  const updates = generateCommitChain([
    (d) => d.get('content').insert(0, 'hello '),
    (d) => d.get('content').insert(6, 'world'),
    (d) => d.get('content').insert(11, '!'),
  ])

  const final = replayAndRead(updates)
  fixtures.push({
    name: 'text_simple_chain',
    description: '3 commits of plain text inserts',
    update_hexes: updates.map(toHex),
    expected_text: readText(final),
  })
}

// ---------------------------------------------------------------------------
// text_delete_from_start_chain: insert, rehydrate-style delete-from-start
// ---------------------------------------------------------------------------
{
  const updates = generateCommitChain([
    (d) => d.get('content').insert(0, 'hello world'),
    (d) => d.get('content').delete(0, 1),
    (d) => d.get('content').delete(0, 1),
  ])

  const final = replayAndRead(updates)
  fixtures.push({
    name: 'text_delete_from_start_chain',
    description: 'insert + two delete-from-start commits (exercises Item.split left half)',
    update_hexes: updates.map(toHex),
    expected_text: readText(final),
  })
}

// ---------------------------------------------------------------------------
// text_replace_all_chain: insert, delete all, insert new — the MCP pattern
// ---------------------------------------------------------------------------
{
  const updates = generateCommitChain([
    (d) => d.get('content').insert(0, 'original content here'),
    (d) => {
      d.get('content').delete(0, 21)
      d.get('content').insert(0, 'replaced text')
    },
    (d) => {
      d.get('content').delete(0, 13)
      d.get('content').insert(0, 'third version')
    },
  ])

  const final = replayAndRead(updates)
  fixtures.push({
    name: 'text_replace_all_chain',
    description: 'MCP write tool pattern: delete-all + insert-new across 3 commits',
    update_hexes: updates.map(toHex),
    expected_text: readText(final),
  })
}

// ---------------------------------------------------------------------------
// text_envelope_chain: root map + content text, 5 commits of mutations
// ---------------------------------------------------------------------------
{
  const updates = generateCommitChain([
    (d) => {
      d.get('root').setAttr('_type', 'text')
      d.get('root').setAttr('_name', 'test.txt')
      d.get('content').insert(0, 'starting content')
    },
    (d) => {
      d.get('content').delete(0, 16)
      d.get('content').insert(0, 'second version')
    },
    (d) => {
      d.get('content').delete(0, 14)
      d.get('content').insert(0, 'third version content that is longer')
    },
    (d) => {
      d.get('root').setAttr('edited_by', 'fixture')
    },
    (d) => {
      d.get('content').delete(36, 0) // no-op
      d.get('content').insert(5, ' [inserted]')
    },
  ])

  const final = replayAndRead(updates)
  fixtures.push({
    name: 'text_envelope_chain',
    description: '5-commit envelope doc (root map + content text) — CX-2sv pattern',
    update_hexes: updates.map(toHex),
    expected_text: readText(final, 'content'),
    expected_map: readMap(final, 'root'),
  })
}

// ---------------------------------------------------------------------------
// text_long_chain: 20 successive append commits
// ---------------------------------------------------------------------------
{
  const ops = []
  for (let i = 1; i <= 20; i++) {
    ops.push((d) => {
      const t = d.get('content')
      t.insert(t.length, ` word${i}`)
    })
  }

  const updates = generateCommitChain([
    (d) => d.get('content').insert(0, 'start'),
    ...ops,
  ])

  const final = replayAndRead(updates)
  fixtures.push({
    name: 'text_long_chain',
    description: '21-commit chain of successive text appends',
    update_hexes: updates.map(toHex),
    expected_text: readText(final),
  })
}

// ---------------------------------------------------------------------------
// map_chain: set, overwrite, delete
// ---------------------------------------------------------------------------
{
  const updates = generateCommitChain([
    (d) => {
      d.get('root').setAttr('a', '1')
      d.get('root').setAttr('b', '2')
    },
    (d) => {
      d.get('root').setAttr('a', 'updated')
      d.get('root').setAttr('c', '3')
    },
    (d) => {
      d.get('root').deleteAttr('b')
    },
  ])

  const final = replayAndRead(updates)
  fixtures.push({
    name: 'map_chain',
    description: '3-commit map chain: set, overwrite, delete',
    update_hexes: updates.map(toHex),
    expected_map: readMap(final),
  })
}

// ---------------------------------------------------------------------------
// array_chain: push, insert at middle, delete
// ---------------------------------------------------------------------------
{
  const updates = generateCommitChain([
    (d) => d.get('items').insert(0, [1, 2, 3, 4, 5]),
    (d) => d.get('items').insert(2, [100]),
    (d) => d.get('items').delete(0, 1),
  ])

  const final = replayAndRead(updates)
  fixtures.push({
    name: 'array_chain',
    description: '3-commit array chain: push, insert middle, delete first',
    update_hexes: updates.map(toHex),
    expected_array: readArray(final),
  })
}

// ---------------------------------------------------------------------------
// text_interleaved_edits_chain: several mid-doc edits across commits
// ---------------------------------------------------------------------------
{
  const updates = generateCommitChain([
    (d) => d.get('content').insert(0, 'the quick brown fox jumps over the lazy dog'),
    (d) => {
      d.get('content').delete(4, 5)
      d.get('content').insert(4, 'slow')
    },
    (d) => {
      d.get('content').delete(9, 5)
      d.get('content').insert(9, 'red')
    },
    (d) => {
      d.get('content').delete(13, 3)
      d.get('content').insert(13, 'cat')
    },
  ])

  const final = replayAndRead(updates)
  fixtures.push({
    name: 'text_interleaved_edits_chain',
    description: 'mid-doc edits across 4 commits',
    update_hexes: updates.map(toHex),
    expected_text: readText(final),
  })
}

const output = path.join(__dirname, 'multi_commit_fixtures.json')
fs.writeFileSync(output, JSON.stringify(fixtures, null, 2))

process.stderr.write(`Generated ${fixtures.length} multi-commit fixtures → ${output}\n`)
for (const f of fixtures) {
  process.stderr.write(`  ${f.name} (${f.update_hexes.length} commits)\n`)
}
