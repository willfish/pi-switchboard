import test from 'node:test';
import assert from 'node:assert/strict';
import { decodeEventPage, eventCursor } from '../hub/priv/dashboard/operator-events.js';

const epoch = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const encode = value => new TextEncoder().encode(JSON.stringify(value));
function event() {
  return { schemaVersion: 1, epoch, sequence: '1', eventId: id, observedAt: '100',
    occurredAt: null, source: 'relay_observed', kind: 'mail_accepted', agentId: null,
    sessionId: null, workId: null, threadId: null, operationId: null,
    payload: { id, from: epoch, to: id, kind: 'notice', acceptedAt: '99', receiving: true, bodyBytes: 5 } };
}
function page() {
  return { epoch, fromSequence: '0', toSequence: '1', retainedFrom: '1', coverage: 'live',
    caughtUp: true, nextCursor: null, events: [event()] };
}
test('accepts metadata without inventing receipt or body', () => {
  assert.deepEqual(decodeEventPage(encode(page())), page());
  assert.equal(Object.hasOwn(decodeEventPage(encode(page())).events[0].payload, 'body'), false);
});
test('preserves uint64 cursor precision', () => {
  const seq = '18446744073709551615';
  assert.equal(Buffer.from(eventCursor(epoch, seq), 'base64url').toString(), `${epoch}:${seq}`);
});
test('accepts retained-floor bootstrap and empty expired history', () => {
  const p = page(); p.fromSequence = '9'; p.toSequence = '10'; p.retainedFrom = '10';
  p.coverage = 'truncated'; p.events[0].sequence = '10';
  assert.deepEqual(decodeEventPage(encode(p)), p);
  p.events = []; p.fromSequence = '10'; p.coverage = 'empty';
  assert.deepEqual(decodeEventPage(encode(p)), p);
});
for (const [name, mutate] of [
  ['unknown envelope field', p => { p.secret = 'no'; }],
  ['noncanonical sequence', p => { p.toSequence = '01'; }],
  ['unsafe sequence number', p => { p.toSequence = 18446744073709551615; }],
  ['sequence overflow', p => { p.toSequence = '18446744073709551616'; }],
  ['event sequence gap', p => { p.events[0].sequence = '2'; }],
  ['mixed epoch', p => { p.events[0].epoch = id; }],
  ['false provenance', p => { p.events[0].source = 'client_reported'; }],
  ['arbitrary payload', p => { p.events[0].payload.password = 'no'; }],
  ['nested payload', p => { p.events[0].payload.bodyBytes = {}; }],
  ['unknown event', p => { p.events[0].kind = 'heartbeat'; }],
  ['numeric timestamp', p => { p.events[0].observedAt = 100; }],
  ['invalid boolean', p => { p.events[0].payload.receiving = 'true'; }],
  ['missing payload field', p => { delete p.events[0].payload.to; }],
  ['inconsistent end', p => { p.toSequence = '2'; }],
  ['false caught-up cursor', p => { p.nextCursor = eventCursor(epoch, '1'); }],
  ['wrong continuation cursor', p => { p.caughtUp = false; p.nextCursor = eventCursor(id, '1'); }],
  ['impossible floor', p => { p.retainedFrom = '3'; }],
  ['empty coverage with records', p => { p.coverage = 'empty'; }],
]) test(`rejects ${name}`, () => {
  const p = page(); mutate(p); assert.throws(() => decodeEventPage(encode(p)));
});
test('binds a response to the requested epoch and position', () => {
  assert.deepEqual(decodeEventPage(encode(page()), eventCursor(epoch, '0')), page());
  assert.throws(() => decodeEventPage(encode(page()), eventCursor(epoch, '8')));
  assert.throws(() => decodeEventPage(encode(page()), eventCursor(id, '0')));
});

test('accepts canonical continuation cursor', () => {
  const p = page(); p.caughtUp = false; p.nextCursor = eventCursor(epoch, '1');
  assert.deepEqual(decodeEventPage(encode(p)), p);
});
test('rejects oversized bytes, excessive records and duplicate decoded keys', () => {
  assert.throws(() => decodeEventPage(new Uint8Array(1048577)));
  const p = page(); p.events = Array.from({ length: 129 }, event);
  assert.throws(() => decodeEventPage(encode(p)));
  const raw = JSON.stringify(page()).replace('"bodyBytes":5', '"bodyBytes":5,"body\\u0042ytes":5');
  assert.throws(() => decodeEventPage(new TextEncoder().encode(raw)));
});
test('enrolled literal text remains data and bounded', () => {
  const p = page(); p.events[0].payload.body = '<img src=x onerror=alert(1)>';
  assert.equal(decodeEventPage(encode(p)).events[0].payload.body, p.events[0].payload.body);
  p.events[0].payload.body = 'x'.repeat(16385);
  assert.throws(() => decodeEventPage(encode(p)));
});
