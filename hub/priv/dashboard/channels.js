import { renderCoordinationBody } from './coordination-notes.js';

export const OPERATOR_ID = '00000000-0000-4000-8000-000000000001';
const NAME = /^[a-z][a-z0-9-]{0,31}$/;
const SEQ = /^(0|[1-9][0-9]{0,19})$/;
const AGENT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PAGE_KEYS = ['epoch', 'channel', 'window', 'fromSequence', 'toSequence', 'retainedFrom', 'retainedTo',
  'coverage', 'caughtUp', 'earlier', 'nextCursor', 'earlierCursor', 'messages'];
/** Idle composer memory stays within the hub directory cap. A directory miss is not a clear. Uncertain attempts are not discarded to make room. */
const DRAFT_LIMIT = 128;
const CHANNEL_BODY_BYTES = 4096;
const CHANNEL_ENVELOPE_BYTES = 8192;
const READ_SKIPPED = Symbol('read-skipped');

export function channelMessagesPath(name, query = {}) {
  if (!NAME.test(name)) throw new Error('schema');
  const params = new URLSearchParams();
  if (query.after !== undefined) params.set('after', query.after);
  if (query.before !== undefined) params.set('before', query.before);
  if (query.limit !== undefined) params.set('limit', String(query.limit));
  const qs = params.toString();
  return `/dashboard/api/v1/channels/${name}/messages${qs ? `?${qs}` : ''}`;
}

export function isChannelList(value) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === 2 && typeof value.epoch === 'string' && Array.isArray(value.channels)
    && value.channels.every(channel => channel && typeof channel.name === 'string' && NAME.test(channel.name)
      && typeof channel.topic === 'string' && Number.isSafeInteger(channel.retained)
      && typeof channel.lastSequence === 'string' && SEQ.test(channel.lastSequence)
      && Number.isSafeInteger(channel.updatedAt));
}

export function isMessagePage(value, name) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== PAGE_KEYS.length) return false;
  if (!PAGE_KEYS.every(key => Object.hasOwn(value, key))) return false;
  if (value.channel !== name || !['recent', 'history'].includes(value.window)) return false;
  if (!['complete', 'gap', 'empty'].includes(value.coverage)) return false;
  if (typeof value.caughtUp !== 'boolean' || typeof value.earlier !== 'boolean') return false;
  if (![value.fromSequence, value.toSequence, value.retainedFrom, value.retainedTo].every(seq => typeof seq === 'string' && SEQ.test(seq))) return false;
  if (!(value.nextCursor === null || (typeof value.nextCursor === 'string' && SEQ.test(value.nextCursor)))) return false;
  if (!(value.earlierCursor === null || (typeof value.earlierCursor === 'string' && SEQ.test(value.earlierCursor)))) return false;
  return Array.isArray(value.messages) && value.messages.every(message => message && message.channel === name
    && typeof message.body === 'string' && typeof message.seq === 'string' && ['say', 'status'].includes(message.kind));
}

export function isStatusBoard(value, name) {
  return value && value.channel === name && Array.isArray(value.statuses)
    && value.statuses.every(row => typeof row.agentId === 'string' && typeof row.summary === 'string');
}

export function speaker(message, names = new Map()) {
  if (message?.from === OPERATOR_ID) return 'Operator';
  const label = names.get(message?.from);
  if (typeof label === 'string' && label.length > 0 && label.length <= 32 && !/[:·]/.test(label)) return label;
  const id = String(message?.from || '');
  return id ? id.slice(0, 8) : '';
}

export function channelSlug(raw) {
  const slug = String(raw ?? '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 32);
  return NAME.test(slug) ? slug : '';
}

export function orderChannels(channels) {
  return [...channels].sort((a, b) => {
    if (a.name === b.name) return 0;
    if (a.name === 'general') return -1;
    if (b.name === 'general') return 1;
    return a.name.localeCompare(b.name);
  });
}

export function messageTime(seconds) {
  const date = new Date(Number(seconds) * 1000);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

export function dayLabel(seconds) {
  const date = new Date(Number(seconds) * 1000);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });
}

/** Works on the plain HTTP console, where the secure-context UUID helper is absent. */
export function newChannelMessageId() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
  const hex = [...bytes].map(b => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function utf8Size(value) {
  return new TextEncoder().encode(value).length;
}
function postTooLong(id, body) {
  if (utf8Size(body) > CHANNEL_BODY_BYTES) return 'That message is longer than the channel allows. Shorten it, then post again.';
  if (utf8Size(JSON.stringify({ id, body })) > CHANNEL_ENVELOPE_BYTES) return 'That message is too long to send. Shorten it, then post again.';
  return '';
}
export function mergeHistory(current, page, placement) {
  const seen = new Set(current.map(message => message.seq));
  const fresh = page.messages.filter(message => !seen.has(message.seq));
  if (placement === 'prepend') return [...fresh, ...current];
  if (placement === 'append') return [...current, ...fresh];
  return page.messages;
}

export function mountChannels(doc, session, options = {}) {
  const hooks = options || {};
  const byId = id => doc.getElementById(id);
  const node = (tag, text) => { const item = doc.createElement(tag); item.textContent = text; return item; };
  let selected = 'general';
  let history = [];
  let page = null;
  let open = false;
  let generation = 0;
  let journalEpoch = null;
  let restarted = false;
  let needsRetry = false;
  let listToken = 0;
  let pageToken = 0;
  let navToken = 0;
  const drafts = new Map();
  const labels = new Map();
  function status(text) { byId('channels-status').textContent = text; }
  function blankDraft() {
    return { text: '', id: null, phase: 'idle', status: '', snapshot: null, attemptBody: null };
  }
  function storeDraft(name, record) {
    drafts.delete(name);
    drafts.set(name, record);
    evictIdle();
  }
  function evictIdle(directory) {
    if (directory) {
      for (const [name, record] of [...drafts]) {
        if (directory.has(name) || name === selected || record.phase === 'inflight' || record.phase === 'unknown') continue;
        if (String(record.text || '').trim()) continue;
        drafts.delete(name);
      }
    }
    for (const [name, record] of [...drafts]) {
      if (drafts.size <= DRAFT_LIMIT) break;
      if (name === selected || record.phase === 'inflight' || record.phase === 'unknown') continue;
      drafts.delete(name);
    }
  }
  function rememberDraft() {
    const draft = byId('channel-draft');
    if (!draft) return;
    const text = String(draft.value ?? '');
    const existing = drafts.get(selected);
    if (!text && !existing) return;
    const record = existing ?? blankDraft();
    record.text = text;
    storeDraft(selected, record);
  }
  function setHidden(el, hidden) {
    if (!el) return;
    el.hidden = hidden;
    if (typeof el.toggleAttribute === 'function') el.toggleAttribute('hidden', hidden);
    else if (hidden) el.setAttribute?.('hidden', '');
    else el.removeAttribute?.('hidden');
  }
  function syncComposer() {
    const record = drafts.get(selected);
    const phase = record?.phase ?? 'idle';
    const uncertain = phase === 'unknown';
    const send = byId('channel-send');
    if (send) send.disabled = phase === 'inflight' || uncertain;
    const check = byId('channel-check-outcome');
    const fresh = byId('channel-new-intent');
    const owned = doc.activeElement === check || doc.activeElement === fresh;
    setHidden(check, !uncertain);
    setHidden(fresh, !uncertain);
    if (owned && !uncertain) {
      const active = doc.activeElement;
      const stillThere = !active || active === check || active === fresh || active === doc.body || active.isConnected === false;
      if (stillThere) byId('channel-draft')?.focus?.({ preventScroll: true });
    }
    const note = byId('channel-post-status');
    if (note) note.textContent = record?.status ?? '';
  }
  function showDraft() {
    const draft = byId('channel-draft');
    if (draft) draft.value = drafts.get(selected)?.text ?? '';
    syncComposer();
  }
  function setPostStatus(channel, text) {
    const record = drafts.get(channel) ?? blankDraft();
    record.status = text;
    storeDraft(channel, record);
    if (selected === channel) syncComposer();
  }
  function runnableAgent(id) {
    return typeof id === 'string' && id !== OPERATOR_ID && AGENT_ID.test(id);
  }
  function inspectable(id) {
    if (!runnableAgent(id) || typeof hooks.canInspectAgent !== 'function') return false;
    try { return hooks.canInspectAgent(id) === true; } catch { return false; }
  }
  function inspectControl(id, label, marker = {}) {
    if (!inspectable(id)) return node('strong', label);
    const opener = node('button', label);
    opener.type = 'button';
    opener.dataset.inspect = id;
    if (marker.seq) opener.dataset.seq = marker.seq;
    if (marker.board) opener.dataset.board = marker.board;
    opener.setAttribute('aria-label', `Inspect agent ${label}`);
    opener.addEventListener('click', () => {
      if (!inspectable(id) || typeof hooks.onInspectAgent !== 'function') return;
      hooks.onInspectAgent(id, opener);
    });
    return opener;
  }
  function normalizeList(names) {
    if (!names) return;
    for (const item of names.children) {
      if (item.getAttribute?.('role') === 'listitem') item.removeAttribute?.('role');
    }
  }
  function paintSelection() {
    const names = byId('channel-names');
    const buttons = names ? [...names.children] : [];
    for (const button of buttons) button.setAttribute('aria-pressed', String(button.dataset.name === selected));
    const chosen = buttons.find(button => button.dataset.name === selected);
    const title = byId('channel-title');
    if (title) title.textContent = `# ${selected}`;
    const draft = byId('channel-draft');
    if (draft) draft.placeholder = `Message #${selected}`;
    const topic = byId('channel-topic');
    if (topic) topic.textContent = chosen?.dataset.topic || (page?.coverage === 'empty' ? 'No messages yet.' : '');
    syncComposer();
  }
  function scrollMode(placement, scroll) {
    if (scroll.mode) return scroll.mode;
    if (placement === 'prepend') return 'anchor';
    return atBottom(byId('channel-log')) ? 'bottom' : 'preserve';
  }
  function chooseSelected() {
    const names = [...(byId('channel-names')?.children ?? [])].map(button => button.dataset.name);
    if (names.includes(selected)) return;
    const next = names.includes('general') ? 'general' : (names[0] || 'general');
    if (next === selected) return;
    activateChannel(next, { navigate: false });
  }
  function clearBoard() {
    labels.clear();
    byId('channel-status')?.replaceChildren();
  }
  function showBoardUnavailable() {
    labels.clear();
    const list = byId('channel-status');
    list?.replaceChildren(node('li', 'Check-ins unavailable.'));
  }
  function controlKey(el) {
    if (!el || el.tagName !== 'BUTTON') return '';
    if (el.dataset?.name) return `channel:${el.dataset.name}`;
    if (el.dataset?.inspect) return `inspect:${el.dataset.inspect}:${el.dataset.seq || ''}:${el.dataset.board || ''}`;
    return '';
  }
  function findControl(key) {
    if (!key) return null;
    const walk = node => {
      if (!node) return null;
      if (controlKey(node) === key) return node;
      for (const child of node.children || []) {
        const found = walk(child);
        if (found) return found;
      }
      return null;
    };
    for (const id of ['channel-names', 'channel-log', 'channel-status']) {
      const found = walk(byId(id));
      if (found) return found;
    }
    return null;
  }
  function savedFocus() {
    const el = doc.activeElement;
    const key = controlKey(el);
    return key ? { key, el } : null;
  }
  function restoreFocus(saved) {
    if (!saved?.el || saved.el.isConnected !== false) return;
    const next = findControl(saved.key);
    if (next && next !== saved.el) next.focus({ preventScroll: true });
  }
  function noteNav() { navToken++; }
  function followingLatest() {
    return Boolean(page?.caughtUp) && atBottom(byId('channel-log'));
  }
  function indicateLatest() {
    const node = byId('channels-status');
    if (!node || node.textContent.includes('Use Latest')) return;
    node.textContent = `${node.textContent} Newer messages may be available. Use Latest.`.trim();
  }
  function activateChannel(name, { load = false, mode = 'bottom', navigate = true } = {}) {
    if (!NAME.test(name) || name === selected) return false;
    if (navigate) noteNav();
    rememberDraft();
    selected = name;
    pageToken++;
    history = [];
    page = null;
    clearBoard();
    byId('channel-log')?.replaceChildren();
    showDraft();
    paintSelection();
    if (load) void loadPage(undefined, 'replace', { mode, explicit: true });
    return true;
  }
  function atBottom(log) {
    if (!log || typeof log.scrollTop !== 'number' || typeof log.scrollHeight !== 'number') return true;
    const view = typeof log.clientHeight === 'number' ? log.clientHeight : 0;
    return log.scrollTop + view >= log.scrollHeight - 4;
  }
  function applyScroll(log, mode, beforeTop, beforeHeight) {
    if (!log || typeof log.scrollTop !== 'number' || typeof log.scrollHeight !== 'number') return;
    if (mode === 'anchor') {
      const delta = log.scrollHeight - beforeHeight;
      log.scrollTop = beforeTop + (delta > 0 ? delta : 0);
      return;
    }
    if (mode === 'top') { log.scrollTop = 0; return; }
    if (mode === 'bottom') { log.scrollTop = log.scrollHeight; return; }
    log.scrollTop = beforeTop;
  }
  let readTail = Promise.resolve();
  function exclusiveRead(path, current = () => true) {
    const run = readTail.then(async () => {
      if (!current()) return READ_SKIPPED;
      return session.channelRead(path);
    });
    readTail = run.then(() => {}, () => {});
    return run;
  }
  async function loadList() {
    const epoch = generation;
    const token = ++listToken;
    const list = await exclusiveRead('/dashboard/api/v1/channels', () => epoch === generation && token === listToken && open);
    if (list === READ_SKIPPED) return null;
    if (epoch !== generation || token !== listToken || !open) return null;
    if (!isChannelList(list)) throw new Error('schema');
    const names = byId('channel-names');
    const focused = savedFocus();
    names.replaceChildren();
    for (const channel of orderChannels(list.channels)) {
      const button = node('button', `# ${channel.name}`);
      button.type = 'button';
      button.dataset.name = channel.name;
      button.dataset.topic = channel.topic || '';
      button.addEventListener('click', () => selectChannel(channel.name));
      names.append(button);
    }
    restoreFocus(focused);
    if (adoptJournal(list.epoch)) {
      clearBoard();
      status('The hub restarted. This is the current retained window, not the previous history.');
    }
    chooseSelected();
    evictIdle(new Set(list.channels.map(channel => channel.name)));
    paintSelection();
    return list;
  }
  async function loadPage(query, placement = 'replace', scroll = {}) {
    const epoch = generation;
    const token = ++pageToken;
    const channel = selected;
    try {
      const current = () => epoch === generation && token === pageToken && selected === channel && open;
      const readMessages = async pathQuery => {
        const value = await exclusiveRead(channelMessagesPath(channel, pathQuery), current);
        if (value === READ_SKIPPED || !current()) return READ_SKIPPED;
        if (!isMessagePage(value, channel)) throw new Error('schema');
        return value;
      };
      let next = await readMessages(query);
      if (next === READ_SKIPPED) return;
      const cursor = query?.after !== undefined || query?.before !== undefined;
      const cursorRestart = cursor && journalEpoch !== null && next.epoch !== journalEpoch;
      if (cursorRestart) {
        const tail = await readMessages();
        if (tail === READ_SKIPPED) return;
        if (tail.epoch !== next.epoch) {
          needsRetry = true;
          status('The hub restarted again before the current window could be loaded. Use Latest to retry. What is on screen is not the current retained window.');
          return;
        }
        next = tail;
      }
      const journalChanged = adoptJournal(next.epoch, false);
      if (scroll.explicit && !journalChanged) { restarted = false; needsRetry = false; }
      else needsRetry = false;
      if (!scroll.explicit && !journalChanged && placement === 'replace' && page && !followingLatest()) {
        indicateLatest();
        return;
      }
      if (journalChanged || placement === 'replace') {
        page = next;
        history = next.messages.slice();
        render(journalChanged || scroll.explicit ? (scroll.mode || 'bottom') : scrollMode(placement, scroll));
      } else {
        page = next;
        history = mergeHistory(history, next, placement);
        render(scroll.mode || scrollMode(placement, scroll));
      }
      try {
        const board = await exclusiveRead(`/dashboard/api/v1/channels/${channel}/status`, () => epoch === generation && token === pageToken && selected === channel && open);
        if (board === READ_SKIPPED || epoch !== generation || token !== pageToken || selected !== channel || !open) return;
        if (isStatusBoard(board, channel)) renderBoard(board);
        else showBoardUnavailable();
      } catch {
        if (epoch !== generation || token !== pageToken || selected !== channel || !open) return;
        showBoardUnavailable();
      }
    } catch (error) {
      if (epoch !== generation || token !== pageToken || selected !== channel || !open) return;
      if (error?.code === 'disconnected') { status('Disconnected. Channel history cleared.'); return; }
      status(placement === 'prepend' ? "Couldn't load earlier messages."
        : placement === 'append' ? "Couldn't load later messages."
        : query?.after === '0' ? "Couldn't load history from the start."
        : "Couldn't load channels.");
    }
  }
  function adoptJournal(nextEpoch, invalidate = true) {
    if (typeof nextEpoch !== 'string' || !nextEpoch) return false;
    const changed = journalEpoch !== null && journalEpoch !== nextEpoch;
    journalEpoch = nextEpoch;
    if (!changed) return false;
    restarted = true;
    history = [];
    page = null;
    if (invalidate) pageToken++;
    byId('channel-log')?.replaceChildren();
    return true;
  }
  function renderBoard(board) {
    labels.clear();
    for (const row of board.statuses) if (row.label) labels.set(row.agentId, row.label);
    const list = byId('channel-status');
    const focused = savedFocus();
    list.replaceChildren(...board.statuses.map(row => {
      const item = node('li', '');
      item.append(inspectControl(row.agentId, speaker({ from: row.agentId }, labels), { board: 'check-in' }), node('span', `: ${row.summary}`));
      return item;
    }));
    if (!board.statuses.length) list.append(node('li', 'No check-ins yet.'));
    restoreFocus(focused);
    render('keep');
  }
  function render(mode = 'bottom') {
    const names = byId('channel-names');
    const chosen = names ? [...names.children].find(button => button.dataset.name === selected) : undefined;
    paintSelection();
    const base = page?.coverage === 'gap' ? 'Some earlier messages expired.' : `${history.length} messages in #${selected}`;
    status(needsRetry ? 'The hub restarted again before the current window could be loaded. Use Latest to retry. What is on screen is not the current retained window.'
      : restarted ? `The hub restarted. This is the current retained window, not the previous history. ${base}` : base);
    const earlier = byId('channel-earlier');
    const later = byId('channel-later');
    if (earlier) earlier.disabled = !page?.earlier;
    if (later) later.disabled = !page || page.caughtUp;
    const log = byId('channel-log');
    if (!log) return;
    const beforeTop = typeof log.scrollTop === 'number' ? log.scrollTop : 0;
    const beforeHeight = typeof log.scrollHeight === 'number' ? log.scrollHeight : 0;
    const anchor = captureAnchor(log);
    const focused = savedFocus();
    const empty = history.length ? [] : [(() => {
      const start = node('div', '');
      start.className = 'slack-empty';
      const blurb = chosen?.dataset.topic || `This is the very beginning of the #${selected} channel.`;
      start.append(node('h3', `# ${selected}`), node('p', blurb));
      return start;
    })()];
    let lastDay = '';
    const rows = [];
    for (const message of history) {
      const day = dayLabel(message.postedAt);
      if (day && day !== lastDay) {
        lastDay = day;
        rows.push(node('p', day));
        rows.at(-1).className = 'slack-day';
      }
      rows.push(messageRow(message));
    }
    log.replaceChildren(...empty, ...rows);
    if ((mode === 'seq' || mode === 'keep' || mode === 'anchor') && restoreAnchor(log, anchor)) {
      /* geometry restore includes gaps */
    } else applyScroll(log, mode === 'seq' || mode === 'keep' ? 'preserve' : mode, beforeTop, beforeHeight);
    restoreFocus(focused);
  }
  function contentTop(log, child) {
    if (typeof child?.getBoundingClientRect === 'function' && typeof log?.getBoundingClientRect === 'function') {
      const childRect = child.getBoundingClientRect();
      const logRect = log.getBoundingClientRect();
      if (childRect && logRect && Number.isFinite(childRect.top) && Number.isFinite(logRect.top)) {
        return childRect.top - logRect.top + (Number(log.scrollTop) || 0);
      }
    }
    if (child?.offsetParent === log && typeof child.offsetTop === 'number') return child.offsetTop;
    return null;
  }
  function captureAnchor(log) {
    const top = typeof log?.scrollTop === 'number' ? log.scrollTop : 0;
    for (const child of log?.children || []) {
      if (!child.dataset?.seq) continue;
      const y = contentTop(log, child);
      if (y === null) continue;
      const height = typeof child.getBoundingClientRect === 'function' ? Number(child.getBoundingClientRect().height) : Number(child.offsetHeight);
      if (y + (Number.isFinite(height) ? height : 0) > top) return { seq: child.dataset.seq, delta: top - y };
    }
    return null;
  }
  function restoreAnchor(log, anchor) {
    if (!log || !anchor) return false;
    for (const child of log.children || []) {
      if (child.dataset?.seq !== anchor.seq) continue;
      const y = contentTop(log, child);
      if (y === null) return false;
      log.scrollTop = Math.max(0, y + anchor.delta);
      return true;
    }
    return false;
  }
  function messageRow(message) {
    const who = speaker(message, labels);
    const agentId = message?.from;
    if (message.kind === 'status') {
      const line = node('p', '');
      line.className = 'slack-system';
      line.dataset.seq = message.seq;
      line.append(inspectControl(agentId, who, { seq: message.seq }), node('span', ` checked in: ${message.body}`), node('span', messageTime(message.postedAt)));
      line.lastChild.className = 'slack-time';
      return line;
    }
    const item = node('article', '');
    item.className = 'slack-message';
    item.dataset.kind = who === 'Operator' ? 'operator' : 'agent';
    item.dataset.seq = message.seq;
    const marker = { seq: message.seq };
    const avatar = node('span', who.slice(0, 1).toUpperCase());
    avatar.className = 'slack-avatar';
    avatar.setAttribute('aria-hidden', 'true');
    const body = node('div', '');
    const meta = node('p', '');
    meta.className = 'slack-meta';
    meta.append(inspectControl(agentId, who, marker), node('span', messageTime(message.postedAt)));
    meta.lastChild.className = 'slack-time';
    body.append(meta, renderCoordinationBody(doc, message.body, { channel: message.channel, from: message.from, id: message.id }));
    item.append(avatar, body);
    return item;
  }
  function selectChannel(name) {
    activateChannel(name, { load: true, mode: 'bottom' });
  }
  function reset() {
    generation++;
    listToken++;
    pageToken++;
    open = false;
    selected = 'general';
    history = [];
    page = null;
    drafts.clear();
    labels.clear();
    journalEpoch = null;
    restarted = false;
    needsRetry = false;
    const draft = byId('channel-draft');
    if (draft) draft.value = '';
    byId('channel-log')?.replaceChildren();
    byId('channel-names')?.replaceChildren();
    byId('channel-status')?.replaceChildren();
    const title = byId('channel-title');
    if (title) title.textContent = '# general';
    const topic = byId('channel-topic');
    if (topic) topic.textContent = '';
    syncComposer();
    status('Disconnected. Channel history cleared.');
  }
  async function reload(keep = false, scroll = {}) {
    if (!open || !session.channelRead) return;
    const epoch = generation;
    const nav = navToken;
    const journalBefore = journalEpoch;
    try {
      const list = await loadList();
      if (list === null || epoch !== generation) return;
      const restartedDuringList = journalBefore !== null && list.epoch !== journalBefore;
      if (nav !== navToken && !restartedDuringList) return;
      if (scroll.explicit || !page || followingLatest()) await loadPage(undefined, 'replace', scroll.explicit ? { ...scroll, explicit: true, mode: scroll.mode || 'bottom' } : { mode: 'bottom' });
      else indicateLatest();
    } catch (error) {
      if (epoch !== generation) return;
      status(error?.code === 'disconnected' ? 'Disconnected. Channel history cleared.' : "Couldn't load channels.");
    }
  }
  function reconcile(channel, id) {
    const record = drafts.get(channel);
    if (!record || record.phase !== 'unknown' || record.snapshot?.id !== id) return;
    const delivered = record.snapshot.body;
    record.phase = 'idle';
    record.snapshot = null;
    record.id = null;
    record.attemptBody = null;
    if (record.text.trim() === delivered) record.text = '';
    if (selected === channel) {
      const draft = byId('channel-draft');
      if (draft && draft.value.trim() === delivered) draft.value = '';
      else if (draft) record.text = draft.value;
    }
    storeDraft(channel, record);
    setPostStatus(channel, 'Found this post in the channel. It was shared.');
  }
  async function checkOutcome() {
    const epoch = generation;
    const channel = selected;
    const record = drafts.get(channel);
    if (!record || record.phase !== 'unknown' || !record.snapshot) {
      if (epoch === generation && selected === channel) setPostStatus(channel, 'Nothing uncertain to check on this channel.');
      return;
    }
    const id = record.snapshot.id;
    try {
      const next = await exclusiveRead(channelMessagesPath(channel), () => epoch === generation && drafts.get(channel)?.snapshot?.id === id);
      if (next === READ_SKIPPED || epoch !== generation) return;
      const current = drafts.get(channel);
      if (!current || current.phase !== 'unknown' || current.snapshot?.id !== id) return;
      if (!isMessagePage(next, channel)) throw new Error('schema');
      const snapshot = current.snapshot;
      const pool = selected === channel ? history : [];
      const found = [...next.messages, ...pool].some(message => message?.id === snapshot.id && message.channel === channel
        && message.from === OPERATOR_ID && message.body === snapshot.body);
      if (found) reconcile(channel, id);
      else setPostStatus(channel, 'Not seen in the retained history from this check. That does not prove it was not shared.');
    } catch {
      if (epoch !== generation) return;
      const current = drafts.get(channel);
      if (!current || current.phase !== 'unknown' || current.snapshot?.id !== id) return;
      setPostStatus(channel, "Couldn't check the channel. The outcome is still unknown.");
    }
  }
  function acknowledgeNewIntent() {
    const record = drafts.get(selected);
    if (!record || record.phase !== 'unknown') return;
    record.phase = 'idle';
    record.id = newChannelMessageId();
    record.attemptBody = null;
    record.snapshot = null;
    storeDraft(selected, record);
    setPostStatus(selected, 'Starting a new post. The earlier attempt stays unknown and will not be sent again.');
  }
  function publish(channel, id, body, epoch) {
    const record = drafts.get(channel) ?? blankDraft();
    record.phase = 'inflight';
    record.id = id;
    record.attemptBody = body;
    record.text = selected === channel ? String(byId('channel-draft')?.value ?? body) : (record.text || body);
    record.snapshot = { id, body };
    storeDraft(channel, record);
    setPostStatus(channel, 'Posting as Operator. This does not wake agents.');
    const nav = navToken;
    void session.channelPost(channel, id, body).then(async () => {
      if (epoch !== generation) return;
      const current = drafts.get(channel);
      if (!current || current.phase !== 'inflight' || current.snapshot?.id !== id) return;
      const visible = selected === channel ? String(byId('channel-draft')?.value ?? current.text) : current.text;
      current.phase = 'idle';
      current.snapshot = null;
      current.id = null;
      current.attemptBody = null;
      if (visible.trim() === body) {
        current.text = '';
        if (selected === channel) {
          const draft = byId('channel-draft');
          if (draft) draft.value = '';
        }
      } else current.text = visible;
      storeDraft(channel, current);
      setPostStatus(channel, 'Shared as Operator. This does not wake agents.');
      if (nav !== navToken) {
        if (selected === channel && open) indicateLatest();
        return;
      }
      if (selected === channel && open && followingLatest()) await loadPage(undefined, 'replace', { mode: 'bottom' });
      else if (selected === channel && open) indicateLatest();
    }, error => {
      if (epoch !== generation) return;
      const current = drafts.get(channel);
      if (!current || current.phase !== 'inflight' || current.snapshot?.id !== id) return;
      if (error?.code === 'outcome_unknown') {
        current.phase = 'unknown';
        storeDraft(channel, current);
        setPostStatus(channel, 'Outcome unknown. It may already be shared. Check the channel, or start a new post. Absence is not proof it was not shared.');
        return;
      }
      current.phase = 'idle';
      current.snapshot = null;
      storeDraft(channel, current);
      setPostStatus(channel, "Couldn't share that update. You can try this post again.");
    });
  }
  normalizeList(byId('channel-names'));
  byId('channel-earlier')?.addEventListener('click', () => {
    if (!page?.earlierCursor) return;
    noteNav();
    void loadPage({ before: page.earlierCursor }, 'prepend', { mode: 'anchor', explicit: true });
  });
  byId('channel-later')?.addEventListener('click', () => {
    if (!page?.nextCursor) return;
    noteNav();
    void loadPage({ after: page.nextCursor }, 'append', { explicit: true });
  });
  byId('channel-start')?.addEventListener('click', () => {
    noteNav();
    void loadPage({ after: '0' }, 'replace', { mode: 'top', explicit: true });
  });
  byId('channel-refresh')?.addEventListener('click', () => {
    noteNav();
    void reload(false, { mode: 'bottom', explicit: true });
  });
  const dialog = byId('channel-create');
  byId('channel-add')?.addEventListener('click', () => {
    const note = byId('channel-create-status');
    if (note) note.textContent = '';
    dialog?.showModal?.();
    byId('channel-create-name')?.focus?.();
  });
  byId('channel-create-cancel')?.addEventListener('click', () => dialog?.close?.());
  byId('channel-create-form')?.addEventListener('submit', event => {
    event.preventDefault();
    const name = channelSlug(byId('channel-create-name').value);
    const topicText = byId('channel-create-topic').value.trim();
    const note = byId('channel-create-status');
    if (!name) { note.textContent = 'Use a short name: letters, numbers, and hyphens.'; return; }
    if (!session.channelCreate) { note.textContent = 'This server cannot create channels yet.'; return; }
    note.textContent = 'Creating…';
    const epoch = generation;
    void session.channelCreate(name, topicText).then(async () => {
      if (epoch !== generation) return;
      dialog?.close?.();
      byId('channel-create-name').value = '';
      byId('channel-create-topic').value = '';
      activateChannel(name);
      await reload();
    }, () => { if (note) note.textContent = "Couldn't create that channel."; });
  });
  byId('channel-draft')?.addEventListener('input', rememberDraft);
  byId('channel-draft')?.addEventListener('keydown', event => {
    if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); byId('channel-composer')?.requestSubmit?.(); }
  });
  byId('channel-check-outcome')?.addEventListener('click', () => { void checkOutcome(); });
  byId('channel-new-intent')?.addEventListener('click', () => { acknowledgeNewIntent(); });
  byId('channel-composer')?.addEventListener('submit', event => {
    event.preventDefault();
    rememberDraft();
    const body = String(byId('channel-draft')?.value ?? '').trim();
    const record = drafts.get(selected);
    if (record?.phase === 'inflight' || record?.phase === 'unknown') return;
    if (!session.channelPost) { setPostStatus(selected, 'This server cannot share operator updates yet.'); return; }
    if (!body) { setPostStatus(selected, 'Write a message before posting.'); return; }
    let id = record?.id ?? null;
    if (!id || (record?.attemptBody && record.attemptBody !== body)) id = newChannelMessageId();
    const tooLong = postTooLong(id, body);
    if (tooLong) { setPostStatus(selected, tooLong); return; }
    publish(selected, id, body, generation);
  });
  return {
    async openView() {
      open = true;
      if (!session.channelRead) { status('This server does not have channel history.'); return; }
      await reload();
    },
    closeView() { open = false; },
    refresh(keep = false) { return reload(keep); },
    reset,
  };
}
