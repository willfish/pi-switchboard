import test from 'node:test';
import assert from 'node:assert/strict';
import { createObservationParser } from '../hub/priv/dashboard/operator-stream.js';
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const page = { epoch: id, fromSequence: '0', toSequence: '0', retainedFrom: '0', coverage: 'empty', caughtUp: true, nextCursor: null, events: [] };
const bytes = text => new TextEncoder().encode(text);
test('stream parses every byte split and all supported newline conventions', () => {
  for (const newline of ['\n', '\r', '\r\n']) {
    const wire = bytes(`: keepalive${newline}${newline}event: observation${newline}data: ${JSON.stringify(page)}${newline}${newline}`);
    for (let split = 0; split <= wire.length; split++) {
      const pages = []; let activity = 0;
      const parser = createObservationParser(p => pages.push(p), () => activity++);
      parser.push(wire.subarray(0, split)); parser.push(wire.subarray(split)); parser.end();
      assert.deepEqual(pages, [page]); assert.equal(activity, 2);
    }
  }
});
test('raw cap includes optional LF after a final CR before publishing', () => {
  const exact = bytes(':' + 'x'.repeat(524285) + '\r\r');
  let delivered = 0;
  const parser = createObservationParser(() => {}, () => delivered++);
  parser.push(exact); assert.equal(delivered, 0);
  assert.throws(() => parser.push(bytes('\n')), { code: 'limit' }); assert.equal(delivered, 0);
  const accepted = createObservationParser(() => {}, () => delivered++); accepted.push(exact); accepted.end(); assert.equal(delivered, 1);
});
test('reset, unknown events, malformed UTF8, duplicate keys and truncated frames fail closed', () => {
  for (const text of [
    `event: reset\ndata: {"reason":"history_lost"}\n\n`,
    `event: message\ndata: ${JSON.stringify(page)}\n\n`,
    `event: observation\ndata: ${JSON.stringify(page)}\n`,
    `event: observation\ndata: ${JSON.stringify(page).replace('"events":[]', '"events":[],"events":[]')}\n\n`,
  ]) {
    let shown = 0; const parser = createObservationParser(() => shown++);
    assert.throws(() => { parser.push(bytes(text)); parser.end(); }); assert.equal(shown, 0);
  }
  const parser = createObservationParser(() => { throw new Error('must not deliver'); });
  assert.throws(() => parser.push(new Uint8Array([58, 255, 10, 10])));
});
