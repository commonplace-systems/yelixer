import fs from 'node:fs';
import * as Y from 'yjs-stable';

const rows = [];
for (const [name, prefix] of [['ascii', 'a'], ['combining', 'e\u0301'], ['astral', '\u{1F600}'], ['zwj', '\u{1F469}\u200D\u{1F4BB}']]) {
  const doc = new Y.Doc(); doc.clientID = 100;
  const text = doc.getText('content');
  const updates = [], full = [], views = [];
  doc.on('update', u => updates.push(Buffer.from(u).toString('hex')));
  const operations = [['insert', 0, prefix + 'b'], ['insert', prefix.length + 1, '!'], ['insert', prefix.length, 'X'], ['delete', prefix.length + 1, 1]];
  for (const [op, pos, value] of operations) {
    text[op](pos, value);
    full.push(Buffer.from(Y.encodeStateAsUpdate(doc)).toString('hex'));
    views.push(text.toString());
  }
  rows.push({name, writer: 'Yjs 13.6.32', author: 100, coordinate_contract: 'UTF-16 scalar boundaries', operations,
    updates_hex: updates, full_updates_hex: full, old_views: views, intended_final: prefix + 'X!'});
  doc.destroy();
}
fs.writeFileSync(process.env.HISTORY_OUTPUT, JSON.stringify({schema: 1, histories: rows}, null, 2) + '\n');
