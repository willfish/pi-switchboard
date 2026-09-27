import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { isMessagePage, mergeHistory, channelMessagesPath, speaker, OPERATOR_ID, newChannelMessageId, channelSlug, orderChannels, mountChannels } from '../hub/priv/dashboard/channels.js';

test('operator posts are labeled without impersonating an agent', () => {
  assert.equal(speaker({ from: OPERATOR_ID }), 'Operator');
  assert.equal(speaker({ from: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }), 'aaaaaaaa');
  assert.equal(speaker({ from: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }, new Map([['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Ada']])), 'Ada');
  assert.equal(speaker({ from: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }, new Map([['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Can you resume this session: carry on']])), 'aaaaaaaa');
});

test('channel composer can mint an id without crypto.randomUUID', () => {
  const uuid = newChannelMessageId();
  assert.match(uuid, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.notEqual(uuid, newChannelMessageId());
  const source = readFileSync(new URL('../hub/priv/dashboard/channels.js', import.meta.url), 'utf8');
  assert.equal(source.includes('crypto.randomUUID('), false);
});

test('channel list keeps general first and slugs a new name', () => {
  assert.equal(channelSlug('Project Updates'), 'project-updates');
  assert.equal(channelSlug('***'), '');
  assert.deepEqual(orderChannels([{ name: 'zeta' }, { name: 'general' }, { name: 'alpha' }]).map(c => c.name),
    ['general', 'alpha', 'zeta']);
});

test('operator history can be walked without duplicating packets', () => {
  assert.equal(channelMessagesPath('general', { after: '0' }), '/dashboard/api/v1/channels/general/messages?after=0');
  const older = page(['1', '2']);
  const newer = page(['3', '4']);
  assert.equal(isMessagePage(older, 'general'), true);
  assert.deepEqual(mergeHistory(older.messages, newer, 'append').map(message => message.seq), ['1', '2', '3', '4']);
  assert.deepEqual(mergeHistory(newer.messages, older, 'prepend').map(message => message.seq), ['1', '2', '3', '4']);
  assert.equal(mergeHistory(older.messages, older, 'append').length, 2);
});

function page(seqs) {
  return {
    epoch: '11111111-1111-4111-8111-111111111111', channel: 'general', window: 'history',
    fromSequence: seqs[0], toSequence: seqs.at(-1), retainedFrom: '1', retainedTo: '4',
    coverage: 'complete', caughtUp: seqs.at(-1) === '4', earlier: seqs[0] !== '1',
    nextCursor: seqs.at(-1) === '4' ? null : seqs.at(-1), earlierCursor: seqs[0] === '1' ? null : seqs[0],
    messages: seqs.map(seq => ({ seq, id: '33333333-3333-4333-8333-333333333333', channel: 'general',
      from: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', kind: 'say', body: `note ${seq}`, postedAt: 10 })),
  };
}

const EPOCH = '11111111-1111-4111-8111-111111111111';
const AGENT = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

function meta(name, topic = '') {
  return { name, topic, retained: 1, lastSequence: '1', updatedAt: 1 };
}
function directory(channels, epoch = EPOCH) {
  return { epoch, channels };
}
function message(channel, seq, body, extra = {}) {
  return {
    seq, id: extra.id || '33333333-3333-4333-8333-333333333333', channel,
    from: extra.from || AGENT, kind: extra.kind || 'say', body, postedAt: extra.postedAt || 10,
  };
}
function messagePage(channel, messages, extra = {}) {
  const seqs = messages.map(item => item.seq);
  const from = seqs[0] || '0';
  const to = seqs.at(-1) || '0';
  return {
    epoch: extra.epoch || EPOCH, channel, window: 'history', fromSequence: from, toSequence: to,
    retainedFrom: extra.retainedFrom || from, retainedTo: extra.retainedTo || to,
    coverage: extra.coverage || (messages.length ? 'complete' : 'empty'),
    caughtUp: extra.caughtUp ?? true, earlier: extra.earlier ?? false,
    nextCursor: extra.nextCursor ?? null, earlierCursor: extra.earlierCursor ?? null, messages,
  };
}
function statusBoard(channel, statuses = []) {
  return { epoch: EPOCH, channel, statuses };
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}
function tick() { return new Promise(resolve => setImmediate(resolve)); }

function createHarness() {
  const listeners = new Map();
  class El {
    constructor(tag) {
      this.tagName = String(tag).toUpperCase();
      this.children = []; this.dataset = {}; this.attrs = new Map();
      this.hidden = false; this.disabled = false; this.value = ''; this.placeholder = '';
      this.scrollTop = 0; this.clientHeight = 40; this.className = ''; this.id = ''; this._text = '';
      this.parentNode = null;
    }
    get scrollHeight() { return this.children.length * 40; }
    get isConnected() {
      let node = this;
      const seen = new Set();
      while (node && !seen.has(node)) {
        seen.add(node);
        if (node.id && nodes.get(node.id) === node) return true;
        node = node.parentNode;
      }
      return false;
    }
    set textContent(value) {
      for (const child of this.children) child.parentNode = null;
      this._text = String(value); this.children = [];
    }
    get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
    set innerHTML(_) { throw new Error('untrusted HTML'); }
    append(...children) {
      for (const child of children) { child.parentNode = this; this.children.push(child); }
    }
    replaceChildren(...children) {
      for (const child of this.children) child.parentNode = null;
      this.children = []; this._text = '';
      if (this.id === 'channel-log') this.scrollTop = 0;
      this.append(...children);
    }
    get lastChild() { return this.children.at(-1); }
    setAttribute(name, value) { this.attrs.set(name, String(value)); }
    getAttribute(name) { return this.attrs.has(name) ? this.attrs.get(name) : null; }
    removeAttribute(name) { this.attrs.delete(name); }
    toggleAttribute(name, force) { if (force) this.setAttribute(name, ''); else this.removeAttribute(name); }
    addEventListener(type, fn) {
      const list = listeners.get(this) ?? [];
      list.push({ type, fn });
      listeners.set(this, list);
    }
    dispatch(type, event = {}) {
      for (const listener of listeners.get(this) ?? []) {
        if (listener.type === type) listener.fn({ preventDefault() {}, ...event });
      }
    }
    click() { this.dispatch('click'); }
    requestSubmit() { this.dispatch('submit'); }
    focus(options) { doc.activeElement = this; this.focusOptions = options || null; }
    get offsetHeight() { return 40; }
    get offsetTop() { return this.parentNode ? this.parentNode.children.indexOf(this) * 50 : 0; }
    getBoundingClientRect() {
      const scroll = this.parentNode?.scrollTop || 0;
      const top = this.offsetTop - scroll;
      return { top, height: this.offsetHeight, bottom: top + this.offsetHeight };
    }
  }
  let doc;
  const nodes = new Map();
  const el = (id, tag = 'div') => {
    if (!nodes.has(id)) { const node = new El(tag); node.id = id; nodes.set(id, node); }
    return nodes.get(id);
  };
  for (const [id, tag] of [['channel-draft', 'textarea'], ['channel-composer', 'form'], ['channel-send', 'button'],
    ['channel-check-outcome', 'button'], ['channel-new-intent', 'button'], ['channel-earlier', 'button'],
    ['channel-later', 'button'], ['channel-start', 'button'], ['channel-refresh', 'button']]) el(id, tag);
  el('channel-names'); el('channel-log'); el('channel-post-status'); el('channels-status');
  el('channel-title'); el('channel-topic'); el('channel-status');
  doc = { activeElement: null, createElement: tag => new El(tag), getElementById: el };
  return { doc, nodes, el };
}

function channelName(path) {
  return /^\/dashboard\/api\/v1\/channels\/([^/]+)\//.exec(path)?.[1];
}

function mountWorkspace(read, { post, options, channels = [meta('general', 'Workspace'), meta('alpha', 'Alpha topic')] } = {}) {
  const harness = createHarness();
  const posts = [];
  const session = {
    posts,
    channelRead: read,
    channelPost(channel, id, body) {
      posts.push({ channel, id, body });
      return post ? post(channel, id, body) : Promise.resolve({ id, channel, state: 'accepted', sequence: '1' });
    },
  };
  const controller = mountChannels(harness.doc, session, options);
  return { ...harness, session, controller, channels };
}

function liveRead(pages = new Map(), directoryFor = () => [meta('general', 'Workspace'), meta('alpha', 'Alpha topic')]) {
  return async path => {
    if (path === '/dashboard/api/v1/channels') return directory(directoryFor());
    const name = channelName(path);
    if (path.endsWith('/status')) return statusBoard(name);
    if (pages.has(path)) return pages.get(path);
    return messagePage(name, [message(name, '1', `${name} note`)]);
  };
}

function buttonFor(nodes, name) {
  return [...nodes.get('channel-names').children].find(button => button.dataset.name === name);
}
function logText(nodes) { return nodes.get('channel-log').textContent; }

test('mounted channels keep per-channel drafts and do not retarget an in-flight post', async () => {
  const pending = [];
  const ws = mountWorkspace(liveRead(), { post: () => { const box = deferred(); pending.push(box); return box.promise; } });
  await ws.controller.openView();
  const draft = ws.el('channel-draft');
  draft.value = 'hello general';
  draft.dispatch('input');
  ws.el('channel-composer').requestSubmit();
  assert.equal(ws.session.posts.length, 1);
  assert.equal(ws.session.posts[0].channel, 'general');
  assert.equal(ws.el('channel-send').disabled, true);
  ws.el('channel-composer').requestSubmit();
  assert.equal(ws.session.posts.length, 1);
  buttonFor(ws.nodes, 'alpha').click();
  draft.value = 'hello alpha';
  draft.dispatch('input');
  ws.el('channel-composer').requestSubmit();
  assert.equal(ws.session.posts.length, 2);
  assert.equal(ws.session.posts[1].channel, 'alpha');
  assert.notEqual(ws.session.posts[1].id, ws.session.posts[0].id);
  pending[0].resolve({ id: ws.session.posts[0].id, channel: 'general', state: 'accepted', sequence: '2' });
  await tick();
  assert.equal(draft.value, 'hello alpha');
  assert.equal(logText(ws.nodes).includes('hello general'), false);
  buttonFor(ws.nodes, 'general').click();
  await tick();
  assert.equal(draft.value, '');
  buttonFor(ws.nodes, 'alpha').click();
  assert.equal(draft.value, 'hello alpha');
});

test('edits made while a post is pending are kept and not sent under the completed id', async () => {
  const pending = deferred();
  const ws = mountWorkspace(liveRead(), { post: () => pending.promise });
  await ws.controller.openView();
  const draft = ws.el('channel-draft');
  draft.value = 'one';
  ws.el('channel-composer').requestSubmit();
  draft.value = 'one more';
  draft.dispatch('input');
  pending.resolve({ id: ws.session.posts[0].id, channel: 'general', state: 'accepted', sequence: '2' });
  await tick();
  assert.equal(draft.value, 'one more');
  const again = deferred();
  ws.session.channelPost = (channel, id, body) => {
    ws.session.posts.push({ channel, id, body });
    return again.promise;
  };
  ws.el('channel-composer').requestSubmit();
  assert.equal(ws.session.posts[1].body, 'one more');
  assert.notEqual(ws.session.posts[1].id, ws.session.posts[0].id);
  again.resolve({ id: ws.session.posts[1].id, channel: 'general', state: 'accepted', sequence: '3' });
  await tick();
});

test('unknown outcomes are not resent until a new intent, and absence is not non-delivery', async () => {
  let reads = 0;
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general'), meta('alpha')]);
    const name = channelName(path);
    if (path.endsWith('/status')) return statusBoard(name);
    reads += 1;
    if (reads > 2) return messagePage('general', [message('general', '1', 'other', { id: '44444444-4444-4444-8444-444444444444' })]);
    return messagePage(name, [message(name, '1', `${name} note`)]);
  }, { post: () => Promise.reject(Object.assign(new Error('lost'), { code: 'outcome_unknown' })) });
  await ws.controller.openView();
  const draft = ws.el('channel-draft');
  draft.value = 'maybe shared';
  ws.el('channel-composer').requestSubmit();
  await tick();
  assert.equal(ws.session.posts.length, 1);
  assert.equal(ws.el('channel-send').disabled, true);
  assert.equal(ws.el('channel-check-outcome').hidden, false);
  assert.equal(ws.el('channel-new-intent').hidden, false);
  assert.match(ws.el('channel-post-status').textContent, /unknown/i);
  draft.value = 'edited while unknown';
  draft.dispatch('input');
  ws.el('channel-composer').requestSubmit();
  draft.dispatch('keydown', { key: 'Enter', shiftKey: false });
  buttonFor(ws.nodes, 'alpha').click();
  await tick();
  buttonFor(ws.nodes, 'general').click();
  ws.el('channel-composer').requestSubmit();
  assert.equal(ws.session.posts.length, 1);
  assert.equal(draft.value, 'edited while unknown');
  const beforeCheck = ws.session.posts.length;
  ws.el('channel-check-outcome').click();
  await tick();
  assert.equal(ws.session.posts.length, beforeCheck);
  assert.match(ws.el('channel-post-status').textContent, /does not prove/i);
  assert.equal(ws.el('channel-send').disabled, true);
  ws.el('channel-new-intent').click();
  assert.equal(ws.session.posts.length, 1);
  assert.equal(ws.el('channel-send').disabled, false);
  assert.equal(ws.el('channel-check-outcome').hidden, true);
  assert.match(ws.el('channel-post-status').textContent, /will not be sent again/);
  ws.el('channel-composer').requestSubmit();
  assert.equal(ws.session.posts.length, 2);
  assert.equal(ws.session.posts[1].body, 'edited while unknown');
  assert.notEqual(ws.session.posts[1].id, ws.session.posts[0].id);
});

test('a matching retained message reconciles an unknown post without another send', async () => {
  const ws = mountWorkspace(liveRead(), { post: () => Promise.reject(Object.assign(new Error('lost'), { code: 'outcome_unknown' })) });
  await ws.controller.openView();
  ws.el('channel-draft').value = 'maybe shared';
  ws.el('channel-composer').requestSubmit();
  await tick();
  const id = ws.session.posts[0].id;
  ws.session.channelRead = async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general'), meta('alpha')]);
    const name = channelName(path);
    if (path.endsWith('/status')) return statusBoard(name);
    return messagePage('general', [message('general', '2', 'maybe shared', { id, from: OPERATOR_ID })]);
  };
  const top = ws.el('channel-log').scrollTop;
  ws.el('channel-check-outcome').click();
  await tick();
  assert.equal(ws.session.posts.length, 1);
  assert.equal(ws.el('channel-send').disabled, false);
  assert.equal(ws.el('channel-draft').value, '');
  assert.match(ws.el('channel-post-status').textContent, /shared/i);
  assert.equal(ws.el('channel-log').scrollTop, top);
});

test('unknown reconciliation requires the operator sender, channel, id, and body', async () => {
  const ws = mountWorkspace(liveRead(), { post: () => Promise.reject(Object.assign(new Error('lost'), { code: 'outcome_unknown' })) });
  await ws.controller.openView();
  ws.el('channel-draft').value = 'maybe shared';
  ws.el('channel-composer').requestSubmit();
  await tick();
  const id = ws.session.posts[0].id;
  const probes = [
    message('general', '2', 'maybe shared', { id, from: AGENT }),
    message('general', '3', 'different body', { id, from: OPERATOR_ID }),
    message('alpha', '4', 'maybe shared', { id, from: OPERATOR_ID }),
  ];
  for (const probe of probes) {
    ws.session.channelRead = async path => {
      if (path === '/dashboard/api/v1/channels') return directory([meta('general'), meta('alpha')]);
      const name = channelName(path);
      if (path.endsWith('/status')) return statusBoard(name);
      return messagePage(probe.channel === 'general' ? 'general' : name, probe.channel === 'general' ? [probe] : [message(name, '1', 'other')]);
    };
    ws.el('channel-check-outcome').click();
    await tick();
    assert.equal(ws.el('channel-send').disabled, true, probe.body);
    assert.equal(ws.session.posts.length, 1);
    assert.match(ws.el('channel-post-status').textContent, /does not prove/i);
  }
});

test('a transient directory miss keeps a populated draft until an explicit clear', async () => {
  let listed = [meta('general'), meta('alpha', 'Alpha')];
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory(listed);
    const name = channelName(path);
    if (path.endsWith('/status')) return statusBoard(name);
    return messagePage(name, [message(name, '1', name)]);
  });
  await ws.controller.openView();
  buttonFor(ws.nodes, 'alpha').click();
  await tick();
  ws.el('channel-draft').value = 'keep alpha';
  ws.el('channel-draft').dispatch('input');
  listed = [meta('general')];
  await ws.controller.refresh(false);
  assert.equal(buttonFor(ws.nodes, 'alpha'), undefined);
  assert.equal(ws.el('channel-draft').value, '');
  listed = [meta('general'), meta('alpha', 'Alpha')];
  await ws.controller.refresh(false);
  buttonFor(ws.nodes, 'alpha').click();
  assert.equal(ws.el('channel-draft').value, 'keep alpha');
  ws.controller.reset();
  assert.equal(ws.el('channel-draft').value, '');
  listed = [meta('general'), meta('alpha', 'Alpha')];
  await ws.controller.openView();
  buttonFor(ws.nodes, 'alpha').click();
  await tick();
  assert.equal(ws.el('channel-draft').value, '');
});

test('explicit disconnect clears drafts and ignores a late post result', async () => {
  const pending = deferred();
  const ws = mountWorkspace(liveRead(), { post: () => pending.promise });
  await ws.controller.openView();
  ws.el('channel-draft').value = 'keep me';
  ws.el('channel-composer').requestSubmit();
  ws.controller.reset();
  assert.equal(ws.el('channel-draft').value, '');
  assert.equal(ws.el('channel-names').children.length, 0);
  assert.equal(ws.el('channel-log').children.length, 0);
  assert.equal(ws.el('channels-status').textContent, 'Disconnected. Channel history cleared.');
  assert.equal(ws.el('channel-send').disabled, false);
  pending.resolve({ id: ws.session.posts[0].id, channel: 'general', state: 'accepted', sequence: '2' });
  await tick();
  await tick();
  assert.equal(ws.session.posts.length, 1);
  assert.equal(ws.el('channel-draft').value, '');
  assert.equal(ws.el('channels-status').textContent, 'Disconnected. Channel history cleared.');
});

test('older history keeps its anchor and refresh does not pull the reader to the bottom', async () => {
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general', 'Workspace')]);
    if (path.endsWith('/status')) return statusBoard('general');
    if (path.includes('before=3')) return messagePage('general', [message('general', '1', 'older'), message('general', '2', 'older still')], { earlier: false, caughtUp: false, retainedTo: '4' });
    if (path.includes('after=0')) return messagePage('general', [message('general', '1', 'oldest')], { earlier: false, caughtUp: false, nextCursor: '1', retainedTo: '4' });
    return messagePage('general', [message('general', '3', 'recent'), message('general', '4', 'newest')], { earlier: true, earlierCursor: '3', caughtUp: true, retainedFrom: '1', retainedTo: '4' });
  });
  await ws.controller.openView();
  const log = ws.el('channel-log');
  assert.equal(log.scrollTop, log.scrollHeight);
  log.scrollTop = 0;
  await ws.controller.refresh(true);
  assert.equal(log.scrollTop, 0);
  assert.notEqual(log.scrollTop, log.scrollHeight);
  ws.el('channel-refresh').click();
  await tick();
  assert.equal(log.scrollTop, log.scrollHeight);
  log.scrollTop = 0;
  const anchored = [...log.children].find(child => child.dataset.seq === '3');
  const seenAt = anchored.offsetTop - log.scrollTop;
  const heightSum = log.scrollHeight;
  ws.el('channel-earlier').click();
  await tick();
  const moved = [...log.children].find(child => child.dataset.seq === '3');
  assert.equal(moved.offsetTop - log.scrollTop, seenAt);
  assert.notEqual(log.scrollTop, log.scrollHeight - heightSum);
  assert.match(logText(ws.nodes), /older/);
  ws.el('channel-start').click();
  await tick();
  assert.equal(log.scrollTop, 0);
  assert.match(logText(ws.nodes), /oldest/);
});

test('late responses for another channel are ignored and do not reject unhandled', async () => {
  const held = [];
  let boot = true;
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general'), meta('alpha', 'Alpha topic')]);
    const name = channelName(path);
    if (path.endsWith('/status')) return statusBoard(name);
    if (boot) return messagePage('general', [message('general', '1', 'general-body')]);
    const box = deferred();
    held.push({ path, box });
    return box.promise;
  });
  await ws.controller.openView();
  boot = false;
  const refreshing = ws.controller.refresh(false);
  await tick();
  assert.equal(held.length, 1);
  buttonFor(ws.nodes, 'alpha').click();
  await tick();
  assert.equal(held.length, 1);
  held[0].box.reject(Object.assign(new Error('late'), { code: 'schema' }));
  await tick();
  assert.equal(held.length, 2);
  assert.equal(logText(ws.nodes).includes('stale-general'), false);
  assert.equal(ws.el('channel-title').textContent, '# alpha');
  assert.doesNotMatch(ws.el('channels-status').textContent, /Couldn't load/);
  held[1].box.resolve(messagePage('alpha', [message('alpha', '1', 'alpha-body')]));
  await refreshing;
  await tick();
  assert.match(logText(ws.nodes), /alpha-body/);
  assert.equal(logText(ws.nodes).includes('general-body'), false);
});

test('a held single-flight read does not fail the channel switched to, and only the latest selection loads', async () => {
  let flight = null;
  let hold = false;
  let busy = 0;
  const held = [];
  const messagePaths = [];
  const channels = [meta('general'), meta('alpha', 'Alpha'), meta('beta', 'Beta')];
  const read = path => {
    if (flight && flight.path !== path) {
      busy += 1;
      return Promise.reject(Object.assign(new Error('busy'), { code: 'busy' }));
    }
    const box = deferred();
    flight = { path, promise: box.promise };
    box.promise.finally(() => { if (flight?.promise === box.promise) flight = null; });
    const name = channelName(path);
    const settle = value => { box.resolve(value); return box.promise; };
    if (path === '/dashboard/api/v1/channels') return settle(directory(channels));
    if (path.endsWith('/status')) return settle(statusBoard(name));
    messagePaths.push(path);
    if (!hold) return settle(messagePage(name, [message(name, '1', `${name}-boot`)]));
    held.push({ path, box });
    return box.promise;
  };
  const ws = mountWorkspace(read);
  await ws.controller.openView();
  hold = true;
  const refreshing = ws.controller.refresh(false);
  await tick();
  assert.equal(held.length, 1);
  assert.match(held[0].path, /\/general\/messages$/);
  buttonFor(ws.nodes, 'alpha').click();
  buttonFor(ws.nodes, 'beta').click();
  await tick();
  assert.equal(held.length, 1);
  assert.equal(busy, 0);
  assert.equal(ws.el('channel-title').textContent, '# beta');
  held[0].box.resolve(messagePage('general', [message('general', '9', 'stale-general')]));
  await tick();
  assert.equal(busy, 0);
  assert.equal(messagePaths.some(path => path.includes('/alpha/')), false);
  assert.equal(held.length, 2);
  assert.match(held[1].path, /\/beta\/messages$/);
  assert.doesNotMatch(ws.el('channels-status').textContent, /Couldn't load/);
  held[1].box.resolve(messagePage('beta', [message('beta', '1', 'beta-body')]));
  await refreshing;
  await tick();
  assert.equal(busy, 0);
  assert.match(logText(ws.nodes), /beta-body/);
  assert.equal(logText(ws.nodes).includes('stale-general'), false);
  assert.equal(logText(ws.nodes).includes('alpha-boot'), false);
  assert.equal(ws.session.posts.length, 0);
});

test('a missing channel falls back to a pressed matching topic and placeholder', async () => {
  let duringRead;
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('alpha', 'Alpha topic')]);
    const name = channelName(path);
    if (path.endsWith('/status')) return statusBoard(name);
    duringRead = {
      pressed: [...ws.nodes.get('channel-names').children].map(button => [button.dataset.name, button.getAttribute('aria-pressed'), button.getAttribute('role')]),
      title: ws.el('channel-title').textContent,
      placeholder: ws.el('channel-draft').placeholder,
      topic: ws.el('channel-topic').textContent,
    };
    return messagePage('alpha', []);
  });
  await ws.controller.openView();
  assert.deepEqual(duringRead.pressed, [['alpha', 'true', null]]);
  assert.equal(duringRead.title, '# alpha');
  assert.equal(duringRead.placeholder, 'Message #alpha');
  assert.equal(duringRead.topic, 'Alpha topic');
  assert.equal(ws.el('channel-topic').textContent, 'Alpha topic');
  assert.equal(ws.el('channel-title').textContent, '# alpha');
  assert.equal(ws.el('channel-draft').placeholder, 'Message #alpha');
});

test('channel buttons stay buttons and inspection uses the exact agent id', async () => {
  const calls = [];
  const inspected = [];
  let allow = true;
  const stale = nodeRoleButton();
  const ws = createHarness();
  stale.dataset.name = 'general';
  stale.setAttribute('role', 'listitem');
  ws.nodes.get('channel-names').append(stale);
  const session = {
    async channelRead(path) {
      if (path === '/dashboard/api/v1/channels') return directory([meta('general', 'Workspace')]);
      if (path.endsWith('/status')) return statusBoard('general', [
        { agentId: AGENT, label: 'Ada', summary: 'reading' },
        { agentId: OPERATOR_ID, label: 'Operator', summary: 'posting' },
      ]);
      return messagePage('general', [
        message('general', '1', 'agent note', { from: AGENT }),
        message('general', '2', 'operator note', { from: OPERATOR_ID }),
      ]);
    },
  };
  const controller = mountChannels(ws.doc, session, {
    canInspectAgent(id) { calls.push(id); return allow && id === AGENT; },
    onInspectAgent(id, opener) { inspected.push({ id, opener }); },
  });
  assert.equal(stale.getAttribute('role'), null);
  await controller.openView();
  for (const button of ws.nodes.get('channel-names').children) assert.equal(button.getAttribute('role'), null);
  assert.equal(calls.includes(OPERATOR_ID), false);
  const buttons = walk(ws.el('channel-log'), node => node.tagName === 'BUTTON').concat(walk(ws.el('channel-status'), node => node.tagName === 'BUTTON'));
  assert.equal(buttons.length, 2);
  const log = ws.el('channel-log');
  log.scrollTop = 12;
  buttons[0].click();
  assert.equal(inspected.length, 1);
  assert.equal(inspected[0].id, AGENT);
  assert.equal(inspected[0].opener, buttons[0]);
  assert.equal(log.scrollTop, 12);
  assert.equal(ws.el('channel-title').textContent, '# general');
  allow = false;
  buttons[1].click();
  assert.equal(inspected.length, 1);
  controller.reset();
});

test('idle drafts stay inside the directory cap and uncertain attempts survive removal', async () => {
  const names = ['general', ...Array.from({ length: 129 }, (_, index) => `n${index + 1}`)];
  let listed = names;
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory(listed.map(name => meta(name, name)));
    const name = channelName(path);
    if (path.endsWith('/status')) return statusBoard(name);
    return messagePage(name, [message(name, '1', name)]);
  }, { post: () => Promise.reject(Object.assign(new Error('lost'), { code: 'outcome_unknown' })) });
  await ws.controller.openView();
  const draft = ws.el('channel-draft');
  const typed = [];
  for (const name of names) {
    if (name !== 'general') buttonFor(ws.nodes, name).click();
    draft.value = `text-${name}`;
    draft.dispatch('input');
    typed.push(name);
  }
  buttonFor(ws.nodes, typed[0]).click();
  assert.equal(draft.value, '');
  buttonFor(ws.nodes, typed[2]).click();
  assert.equal(draft.value, `text-${typed[2]}`);
  buttonFor(ws.nodes, 'n1').click();
  draft.value = 'uncertain';
  ws.el('channel-composer').requestSubmit();
  await tick();
  listed = ['general'];
  await ws.controller.refresh(false);
  assert.equal(buttonFor(ws.nodes, 'n1'), undefined);
  listed = names;
  await ws.controller.refresh(false);
  buttonFor(ws.nodes, 'n1').click();
  assert.equal(draft.value, 'uncertain');
  assert.equal(ws.el('channel-send').disabled, true);
  assert.equal(ws.session.posts.length, 1);
});

test('creating a channel or falling back does not retarget the previous draft', async () => {
  let listed = [meta('general', 'Workspace'), meta('alpha', 'Alpha')];
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory(listed);
    const name = channelName(path);
    if (path.endsWith('/status')) return statusBoard(name);
    return messagePage(name, [message(name, '1', name)]);
  }, { post: () => Promise.reject(Object.assign(new Error('lost'), { code: 'outcome_unknown' })) });
  ws.session.channelCreate = async (name, topic) => {
    listed = [...listed, meta(name, topic)];
    return { channel: name, state: 'ready', topic };
  };
  await ws.controller.openView();
  const draft = ws.el('channel-draft');
  draft.value = 'general only';
  draft.dispatch('input');
  ws.el('channel-composer').requestSubmit();
  await tick();
  ws.el('channel-create-name').value = 'project';
  ws.el('channel-create-topic').value = 'New';
  ws.el('channel-create-form').dispatch('submit');
  await tick();
  assert.equal(ws.el('channel-title').textContent, '# project');
  assert.equal(draft.value, '');
  assert.equal(ws.el('channel-send').disabled, false);
  ws.el('channel-composer').requestSubmit();
  assert.equal(ws.session.posts.length, 1);
  assert.equal(ws.session.posts[0].channel, 'general');
  buttonFor(ws.nodes, 'general').click();
  await tick();
  assert.equal(draft.value, 'general only');
  assert.equal(ws.el('channel-send').disabled, true);
  buttonFor(ws.nodes, 'alpha').click();
  await tick();
  draft.value = 'alpha only';
  draft.dispatch('input');
  listed = [meta('general', 'Workspace')];
  await ws.controller.refresh(false);
  assert.equal(ws.el('channel-title').textContent, '# general');
  assert.equal(draft.value, 'general only');
  listed = [meta('general', 'Workspace'), meta('alpha', 'Alpha')];
  await ws.controller.refresh(false);
  buttonFor(ws.nodes, 'alpha').click();
  assert.equal(draft.value, 'alpha only');
});

test('an older traversal is not merged with the latest tail, so the middle stays reachable', async () => {
  const reads = [];
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general')]);
    if (path.endsWith('/status')) return statusBoard('general');
    reads.push(path);
    if (path.includes('after=0')) return messagePage('general', [message('general', '1', 'oldest-1'), message('general', '2', 'oldest-2')], {
      retainedFrom: '1', retainedTo: '9', earlier: false, caughtUp: false, nextCursor: '2',
    });
    if (path.includes('after=2')) return messagePage('general', [message('general', '3', 'middle-3'), message('general', '4', 'middle-4')], {
      retainedFrom: '1', retainedTo: '9', earlier: true, earlierCursor: '3', caughtUp: false, nextCursor: '4',
    });
    return messagePage('general', [message('general', '8', 'tail-8'), message('general', '9', 'tail-9')], {
      retainedFrom: '1', retainedTo: '9', earlier: true, earlierCursor: '8', caughtUp: true,
    });
  });
  await ws.controller.openView();
  ws.el('channel-start').click();
  await tick();
  assert.match(logText(ws.nodes), /oldest-1/);
  assert.equal(logText(ws.nodes).includes('tail-9'), false);
  const beforePost = reads.length;
  ws.el('channel-draft').value = 'from older';
  ws.el('channel-composer').requestSubmit();
  await tick();
  assert.equal(reads.length, beforePost);
  assert.match(logText(ws.nodes), /oldest-1/);
  assert.equal(logText(ws.nodes).includes('tail-8'), false);
  assert.equal(ws.el('channel-later').disabled, false);
  assert.match(ws.el('channels-status').textContent, /Use Latest/);
  ws.el('channel-later').click();
  await tick();
  assert.match(logText(ws.nodes), /oldest-1/);
  assert.match(logText(ws.nodes), /middle-3/);
  assert.equal(logText(ws.nodes).includes('tail-9'), false);
  ws.el('channel-refresh').click();
  await tick();
  assert.match(logText(ws.nodes), /tail-9/);
  assert.equal(logText(ws.nodes).includes('oldest-1'), false);
  assert.equal(logText(ws.nodes).includes('middle-3'), false);
  assert.equal(ws.el('channel-earlier').disabled, false);
});

test('a directory refresh already in flight does not replace a newer history move', async () => {
  let holdList = false;
  let releaseList;
  const ws = mountWorkspace(path => {
    if (path === '/dashboard/api/v1/channels') {
      if (!holdList) return directory([meta('general')]);
      return new Promise(resolve => { releaseList = () => resolve(directory([meta('general')])); });
    }
    if (path.endsWith('/status')) return statusBoard('general');
    if (path.includes('after=0')) return messagePage('general', [message('general', '1', 'moved-oldest')], {
      retainedFrom: '1', retainedTo: '9', earlier: false, caughtUp: false, nextCursor: '1',
    });
    return messagePage('general', [message('general', '8', 'live-tail'), message('general', '9', 'live-end')], {
      retainedFrom: '1', retainedTo: '9', earlier: true, earlierCursor: '8', caughtUp: true,
    });
  });
  await ws.controller.openView();
  holdList = true;
  const refreshing = ws.controller.refresh(true);
  await tick();
  ws.el('channel-start').click();
  releaseList();
  await refreshing;
  await tick();
  assert.match(logText(ws.nodes), /moved-oldest/);
  assert.equal(logText(ws.nodes).includes('live-end'), false);
  assert.equal(ws.el('channel-later').disabled, false);
});

test('a failed check-in load clears the previous channel and says unavailable', async () => {
  let failAlpha = false;
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general'), meta('alpha')]);
    const name = channelName(path);
    if (path.endsWith('/status')) {
      if (failAlpha && name === 'alpha') throw new Error('status down');
      return statusBoard(name, name === 'general' ? [{ agentId: AGENT, label: 'Ada', summary: 'reading' }] : []);
    }
    return messagePage(name, [message(name, '1', name)]);
  }, { options: { canInspectAgent: id => id === AGENT, onInspectAgent() {} } });
  await ws.controller.openView();
  assert.match(ws.el('channel-status').textContent, /Ada/);
  failAlpha = true;
  buttonFor(ws.nodes, 'alpha').click();
  await tick();
  assert.equal(ws.el('channel-status').textContent.includes('Ada'), false);
  assert.match(ws.el('channel-status').textContent, /Check-ins unavailable/);
});

test('replacing channel and check-in controls restores focus to the equivalent control', async () => {
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general')]);
    if (path.endsWith('/status')) return statusBoard('general', [{ agentId: AGENT, label: 'Ada', summary: 'reading' }]);
    return messagePage('general', [message('general', '1', 'agent note', { from: AGENT })]);
  }, { options: { canInspectAgent: id => id === AGENT, onInspectAgent() {} } });
  await ws.controller.openView();
  const channelButton = buttonFor(ws.nodes, 'general');
  channelButton.focus();
  await ws.controller.refresh(false);
  const replacedChannel = buttonFor(ws.nodes, 'general');
  assert.notEqual(replacedChannel, channelButton);
  assert.equal(channelButton.parentNode, null);
  assert.equal(channelButton.isConnected, false);
  assert.equal(ws.doc.activeElement, replacedChannel);
  assert.equal(replacedChannel.focusOptions?.preventScroll, true);
  const inspect = walk(ws.el('channel-log'), node => node.tagName === 'BUTTON')[0];
  inspect.focus();
  await ws.controller.refresh(false);
  const nextInspect = walk(ws.el('channel-log'), node => node.tagName === 'BUTTON')[0];
  assert.notEqual(nextInspect, inspect);
  assert.equal(contains(ws.el('channel-log'), inspect), false);
  assert.equal(inspect.isConnected, false);
  assert.equal(nextInspect.isConnected, true);
  assert.equal(ws.doc.activeElement, nextInspect);
  assert.equal(nextInspect.dataset.inspect, AGENT);
  const checkIn = walk(ws.el('channel-status'), node => node.tagName === 'BUTTON')[0];
  checkIn.focus();
  await ws.controller.refresh(false);
  const nextCheckIn = walk(ws.el('channel-status'), node => node.tagName === 'BUTTON')[0];
  assert.equal(contains(ws.el('channel-status'), checkIn), false);
  assert.equal(checkIn.isConnected, false);
  assert.equal(nextCheckIn.isConnected, true);
  assert.equal(ws.doc.activeElement, nextCheckIn);
  assert.equal(nextCheckIn.dataset.inspect, AGENT);
  assert.equal(nextCheckIn.dataset.board, 'check-in');
});

test('a hub restart does not merge old sequence numbers into the current window', async () => {
  const nextEpoch = '22222222-2222-4222-8222-222222222222';
  const thirdEpoch = '33333333-3333-4333-8333-333333333333';
  let epoch = EPOCH;
  let pageKind = 'old';
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general')], epoch);
    if (path.endsWith('/status')) return statusBoard('general');
    if (path.includes('?')) return messagePage('general', [], {
      epoch, retainedFrom: '1', retainedTo: '1', earlier: false, caughtUp: true, coverage: 'empty',
    });
    if (epoch !== EPOCH && pageKind !== 'third') return messagePage('general', [message('general', '1', 'fresh-tail')], {
      epoch, retainedFrom: '1', retainedTo: '1', earlier: false, caughtUp: true,
    });
    if (pageKind === 'third') return messagePage('general', [message('general', '1', 'third-window')], {
      epoch, retainedFrom: '1', retainedTo: '1', earlier: false, caughtUp: false,
    });
    return messagePage('general', [message('general', '1', 'old-journal'), message('general', '2', 'old-tail')], {
      epoch, retainedFrom: '1', retainedTo: '4', earlier: true, earlierCursor: '1', caughtUp: false,
    });
  }, { post: () => Promise.reject(Object.assign(new Error('lost'), { code: 'outcome_unknown' })) });
  await ws.controller.openView();
  const draft = ws.el('channel-draft');
  draft.value = 'still drafting';
  draft.dispatch('input');
  ws.el('channel-composer').requestSubmit();
  await tick();
  epoch = nextEpoch;
  ws.el('channel-earlier').click();
  await tick();
  assert.match(logText(ws.nodes), /fresh-tail/);
  assert.equal(logText(ws.nodes).includes('old-journal'), false);
  assert.equal(logText(ws.nodes).includes('old-tail'), false);
  assert.match(ws.el('channels-status').textContent, /current retained window/);
  assert.match(ws.el('channels-status').textContent, /not the previous history/);
  assert.equal(draft.value, 'still drafting');
  assert.equal(ws.el('channel-send').disabled, true);
  assert.equal(ws.session.posts.length, 1);
  epoch = thirdEpoch;
  pageKind = 'third';
  await ws.controller.refresh(true);
  assert.match(logText(ws.nodes), /third-window/);
  assert.equal(logText(ws.nodes).includes('fresh-tail'), false);
  assert.equal(logText(ws.nodes).includes('old-journal'), false);
  assert.match(ws.el('channels-status').textContent, /not the previous history/);
  assert.equal(ws.session.posts.length, 1);
  assert.equal(ws.el('channel-send').disabled, true);
  pageKind = 'third';
  ws.el('channel-refresh').click();
  await tick();
  assert.equal(ws.el('channels-status').textContent.includes('not the previous history'), false);
  assert.match(logText(ws.nodes), /third-window/);
  assert.equal(logText(ws.nodes).includes('old-journal'), false);
});

test('an old cursor after a restart is discarded for one fresh tail, and a second epoch change waits for Latest', async () => {
  const restarted = '22222222-2222-4222-8222-222222222222';
  const churned = '33333333-3333-4333-8333-333333333333';
  let epoch = EPOCH;
  let tailEpoch = restarted;
  const messageReads = [];
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general')], epoch);
    if (path.endsWith('/status')) return statusBoard('general');
    messageReads.push(path);
    if (path.includes('after=100')) return messagePage('general', [], {
      epoch, retainedFrom: '1', retainedTo: '1', coverage: 'empty', caughtUp: true, earlier: false,
    });
    if (path.includes('?')) return messagePage('general', [message('general', '1', 'other-cursor')], { epoch });
    return messagePage('general', [message('general', '1', epoch === EPOCH ? 'before-restart' : 'fresh-seq1')], {
      epoch: epoch === EPOCH ? EPOCH : tailEpoch, retainedFrom: '1', retainedTo: '100', caughtUp: false,
      nextCursor: '100', earlier: false,
    });
  }, { post: () => Promise.reject(Object.assign(new Error('lost'), { code: 'outcome_unknown' })) });
  await ws.controller.openView();
  const draft = ws.el('channel-draft');
  draft.value = 'keep this';
  draft.dispatch('input');
  ws.el('channel-composer').requestSubmit();
  await tick();
  epoch = restarted;
  tailEpoch = restarted;
  const beforeLater = messageReads.length;
  ws.el('channel-later').click();
  await tick();
  assert.equal(messageReads.slice(beforeLater).filter(path => path.includes('after=100')).length, 1);
  assert.equal(messageReads.slice(beforeLater).filter(path => path.endsWith('/messages')).length, 1);
  assert.equal(messageReads.slice(beforeLater).length, 2);
  assert.match(logText(ws.nodes), /fresh-seq1/);
  assert.equal(logText(ws.nodes).includes('before-restart'), false);
  assert.match(ws.el('channels-status').textContent, /current retained window/);
  assert.equal(ws.el('channels-status').textContent.includes('0 messages'), false);
  assert.equal(draft.value, 'keep this');
  assert.equal(ws.el('channel-send').disabled, true);
  assert.equal(ws.session.posts.length, 1);
  epoch = churned;
  tailEpoch = '44444444-4444-4444-8444-444444444444';
  const beforeChurn = messageReads.length;
  ws.el('channel-later').click();
  await tick();
  assert.equal(messageReads.slice(beforeChurn).length, 2);
  assert.equal(logText(ws.nodes).includes('fresh-seq1'), true);
  assert.match(ws.el('channels-status').textContent, /Use Latest to retry/);
  assert.match(ws.el('channels-status').textContent, /not the current retained window/);
  assert.equal(ws.session.posts.length, 1);
  assert.equal(ws.el('channel-send').disabled, true);
  assert.equal(draft.value, 'keep this');
});

test('a followed refresh does not jump if the reader scrolls up while the page is loading', async () => {
  let hold = false;
  let release;
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general')]);
    if (path.endsWith('/status')) return statusBoard('general');
    if (hold) return new Promise(resolve => { release = () => resolve(messagePage('general', [message('general', '2', 'arrived-later')], { caughtUp: true, retainedTo: '2' })); });
    return messagePage('general', [message('general', '1', 'already-reading')], { caughtUp: true, retainedTo: '1' });
  });
  await ws.controller.openView();
  const log = ws.el('channel-log');
  assert.equal(log.scrollTop, log.scrollHeight);
  hold = true;
  const refreshing = ws.controller.refresh(true);
  await tick();
  log.scrollTop = 0;
  release();
  await refreshing;
  await tick();
  assert.equal(log.scrollTop, 0);
  assert.match(logText(ws.nodes), /already-reading/);
  assert.equal(logText(ws.nodes).includes('arrived-later'), false);
  assert.match(ws.el('channels-status').textContent, /Use Latest/);
});

test('an accepted post does not replace a history move started while the post was in flight', async () => {
  let releasePost;
  let releaseRead;
  const reads = [];
  const ws = mountWorkspace(path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general')]);
    if (path.endsWith('/status')) return statusBoard('general');
    reads.push(path);
    if (path.includes('after=0')) return new Promise(resolve => { releaseRead = () => resolve(messagePage('general', [message('general', '1', 'oldest-kept')], { caughtUp: false, nextCursor: '1', retainedTo: '9' })); });
    return messagePage('general', [message('general', '9', 'live-tail')], { caughtUp: true, retainedTo: '9', earlier: true, earlierCursor: '9' });
  }, { post: () => new Promise(resolve => { releasePost = () => resolve({ id: 'ignored', channel: 'general', state: 'accepted', sequence: '2' }); }) });
  await ws.controller.openView();
  ws.el('channel-draft').value = 'sent at bottom';
  ws.el('channel-composer').requestSubmit();
  await tick();
  const beforeMove = reads.length;
  ws.el('channel-start').click();
  await tick();
  releasePost();
  await tick();
  assert.equal(reads.slice(beforeMove).some(path => !path.includes('after=0') && path.includes('/messages')), false);
  releaseRead();
  await tick();
  assert.match(logText(ws.nodes), /oldest-kept/);
  assert.equal(logText(ws.nodes).includes('live-tail'), false);
  assert.equal(ws.session.posts.length, 1);
});

test('a successful outcome check keeps focus only if the check still owns it', async () => {
  let release;
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general')]);
    if (path.endsWith('/status')) return statusBoard('general');
    if (release) return new Promise(resolve => { const done = release; release = null; done(resolve); });
    return messagePage('general', [message('general', '1', 'note')]);
  }, { post: () => Promise.reject(Object.assign(new Error('lost'), { code: 'outcome_unknown' })) });
  await ws.controller.openView();
  ws.el('channel-draft').value = 'maybe shared';
  ws.el('channel-composer').requestSubmit();
  await tick();
  const id = ws.session.posts[0].id;
  ws.session.channelRead = path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general')]);
    if (path.endsWith('/status')) return statusBoard('general');
    return new Promise(resolve => { release = resolve; });
  };
  const check = ws.el('channel-check-outcome');
  const elsewhere = ws.el('channel-refresh');
  check.focus();
  check.click();
  await tick();
  elsewhere.focus();
  release(messagePage('general', [message('general', '2', 'maybe shared', { id, from: OPERATOR_ID })]));
  await tick();
  assert.equal(ws.doc.activeElement, elsewhere);
  assert.equal(check.hidden, true);
});

test('a successful outcome check moves focus to the composer when the check still owns it', async () => {
  let release;
  const ws = mountWorkspace(async path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general')]);
    if (path.endsWith('/status')) return statusBoard('general');
    return messagePage('general', [message('general', '1', 'note')]);
  }, { post: () => Promise.reject(Object.assign(new Error('lost'), { code: 'outcome_unknown' })) });
  await ws.controller.openView();
  ws.el('channel-draft').value = 'maybe shared';
  ws.el('channel-composer').requestSubmit();
  await tick();
  const id = ws.session.posts[0].id;
  ws.session.channelRead = path => {
    if (path === '/dashboard/api/v1/channels') return directory([meta('general')]);
    if (path.endsWith('/status')) return statusBoard('general');
    return new Promise(resolve => { release = resolve; });
  };
  const check = ws.el('channel-check-outcome');
  check.focus();
  check.click();
  await tick();
  release(messagePage('general', [message('general', '2', 'maybe shared', { id, from: OPERATOR_ID })]));
  await tick();
  assert.equal(ws.doc.activeElement, ws.el('channel-draft'));
  assert.equal(ws.el('channel-draft').focusOptions?.preventScroll, true);
  assert.equal(check.hidden, true);
});

test('the composer rejects multibyte text that fits the box but not the channel byte limit', async () => {
  const ws = mountWorkspace(liveRead());
  await ws.controller.openView();
  const draft = ws.el('channel-draft');
  const body = '😀'.repeat(1366);
  assert.ok(body.length < 4000);
  assert.ok(new TextEncoder().encode(body).length > 4096);
  draft.value = body;
  ws.el('channel-composer').requestSubmit();
  assert.equal(ws.session.posts.length, 0);
  assert.equal(draft.value, body);
  assert.match(ws.el('channel-post-status').textContent, /Shorten it, then post again/);
  const quotes = '"'.repeat(4096);
  assert.equal(new TextEncoder().encode(quotes).length, 4096);
  draft.value = quotes;
  ws.el('channel-composer').requestSubmit();
  assert.equal(ws.session.posts.length, 0);
  assert.equal(draft.value, quotes);
  assert.match(ws.el('channel-post-status').textContent, /too long to send/);
});

test('channel composer does not store drafts outside memory', () => {
  const source = readFileSync(new URL('../hub/priv/dashboard/channels.js', import.meta.url), 'utf8');
  assert.equal(source.includes('localStorage'), false);
  assert.equal(source.includes('sessionStorage'), false);
});

function nodeRoleButton() {
  const { doc } = createHarness();
  return doc.createElement('button');
}
function walk(node, pred, found = []) {
  if (pred(node)) found.push(node);
  for (const child of node.children ?? []) walk(child, pred, found);
  return found;
}
function contains(root, node) {
  if (!root || !node) return false;
  if (root === node) return true;
  return (root.children || []).some(child => contains(child, node));
}
