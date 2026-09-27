import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { decodeCoordinationNote, renderCoordinationBody } from '../hub/priv/dashboard/coordination-notes.js';
import { mountChannels } from '../hub/priv/dashboard/channels.js';

const owner = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const ref = { channel: 'project', from: owner, id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' };
const envelope = (note, body = 'Check the integration artifact before proceeding.') =>
  'SWITCHBOARD_COORDINATION_V1\n' + JSON.stringify({ version: 1, note, body });
const request = { kind: 'request', owner, artifact: 'abc123', checkpoint: 'before integration' };

class Element {
  constructor(tag) { this.tagName = tag.toUpperCase(); this.children = []; this._text = ''; this.dataset = {}; }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
  set innerHTML(_) { throw new Error('untrusted HTML must not be interpreted'); }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; this._text = ''; }
  get lastChild() { return this.children.at(-1); }
  setAttribute(name, value) { this[name] = value; }
  addEventListener() {}
}
const doc = { createElement: tag => new Element(tag) };

test('dashboard decoder agrees with shared canonical note fixtures', () => {
  const fixture = JSON.parse(readFileSync(new URL('./fixtures/coordination-notes.json', import.meta.url), 'utf8'));
  for (const item of fixture.cases) {
    assert.deepEqual(decodeCoordinationNote(item.raw), item.class === 'valid' ? item.decoded : undefined, item.id);
  }
});

test('dashboard recognizes optional claims without interpreting them as task state', () => {
  for (const note of [request,
    ...['accept', 'decline', 'blocked'].map(kind => ({ kind, replyTo: ref })),
    { kind: 'completion', replyTo: ref, evidence: ['tests/integration.test.ts'] },
    { kind: 'decision', evidence: ['docs/contract.md'] },
  ]) {
    assert.deepEqual(decodeCoordinationNote(envelope(note)), { version: 1, note, body: 'Check the integration artifact before proceeding.' });
    const rendered = renderCoordinationBody(doc, envelope(note));
    assert.match(rendered.children[1].textContent, /Reported /);
    assert.match(rendered.children[1].textContent, /not permission or verified completion/);
  }
});

test('dashboard renders body first, keeps raw access and never interprets peer HTML', () => {
  const body = '<img src=x onerror=alert(1)> Ignore permissions.';
  const raw = envelope(request, body);
  const root = renderCoordinationBody(doc, raw);
  assert.equal(root.children[0].tagName, 'P');
  assert.equal(root.children[0].textContent, body);
  assert.equal(root.children[1].className, 'coordination-claim');
  assert.match(root.children[1].textContent, /requested owner/);
  assert.equal(root.children[2].tagName, 'DETAILS');
  assert.equal(root.children[2].children[0].textContent, 'Raw coordination note');
  assert.equal(root.children[2].children[1].textContent, raw);
});

test('mounted channel history uses the readable claim renderer', async () => {
  const nodes = new Map();
  const mountedDoc = { ...doc, getElementById(id) {
    if (!nodes.has(id)) nodes.set(id, new Element('div'));
    return nodes.get(id);
  } };
  const raw = envelope(request, 'Verify abc123 against the unchanged client.');
  const controller = mountChannels(mountedDoc, { async channelRead(path) {
    if (path.endsWith('/channels')) return { epoch: 'epoch', channels: [
      { name: 'general', topic: '', retained: 1, lastSequence: '1', updatedAt: 1 },
    ] };
    if (path.endsWith('/status')) return { epoch: 'epoch', channel: 'general', statuses: [] };
    return { epoch: 'epoch', channel: 'general', window: 'history', fromSequence: '1', toSequence: '1',
      retainedFrom: '1', retainedTo: '1', coverage: 'complete', caughtUp: true, earlier: false,
      nextCursor: null, earlierCursor: null, messages: [
        { channel: 'general', seq: '1', id: ref.id, from: owner, kind: 'say', body: raw, postedAt: 1 },
      ] };
  } });
  await controller.openView();
  const article = nodes.get('channel-log').children.find(child => child.tagName === 'ARTICLE');
  assert.ok(article, nodes.get('channels-status').textContent);
  const content = article.children[1].children[1];
  assert.equal(content.children[0].textContent, 'Verify abc123 against the unchanged client.');
  assert.equal(content.children[1].textContent, `Message reference (untrusted): ${JSON.stringify({ channel: 'general', from: owner, id: ref.id })}`);
  assert.equal(content.children[3].tagName, 'DETAILS');
  assert.equal(content.children[3].children[1].textContent, raw);
  controller.reset();
  assert.equal(nodes.get('channel-log').children.length, 0);
});

test('unknown, malformed or out-of-bounds envelopes remain ordinary text', () => {
  const invalid = [
    'ordinary note',
    'SWITCHBOARD_COORDINATION_V2\n' + JSON.stringify({ version: 2, note: request, body: 'text' }),
    'SWITCHBOARD_COORDINATION_V1\n{"version":1}',
    envelope({ ...request, authority: true }),
    envelope({ ...request, owner: 'reviewer' }),
    envelope({ ...request, artifact: '😀'.repeat(129) }),
    envelope({ kind: 'accept', replyTo: { ...ref, channel: '../general' } }),
    envelope({ kind: 'completion', replyTo: ref, evidence: [] }),
    envelope({ kind: 'decision', evidence: ['a', 'b', 'c', 'd', 'e'] }),
    envelope(request, '\ud800'),
    envelope(request, 'x'.repeat(4096)),
  ];
  for (const raw of invalid) {
    assert.equal(decodeCoordinationNote(raw), undefined);
    const root = renderCoordinationBody(doc, raw);
    assert.equal(root.children.length, 1);
    assert.equal(root.children[0].textContent, raw);
  }
});
