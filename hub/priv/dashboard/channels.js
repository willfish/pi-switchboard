export const OPERATOR_ID = '00000000-0000-4000-8000-000000000001';
const NAME = /^[a-z][a-z0-9-]{0,31}$/;
const SEQ = /^(0|[1-9][0-9]{0,19})$/;
const PAGE_KEYS = ['epoch', 'channel', 'window', 'fromSequence', 'toSequence', 'retainedFrom', 'retainedTo',
  'coverage', 'caughtUp', 'earlier', 'nextCursor', 'earlierCursor', 'messages'];

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

export function speaker(message) {
  return message?.from === OPERATOR_ID ? 'Operator' : message?.from ?? '';
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
  return date.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

/** Works on the plain HTTP console, where the secure-context UUID helper is absent. */
export function newChannelMessageId() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
  const hex = [...bytes].map(b => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function mergeHistory(current, page, placement) {
  const seen = new Set(current.map(message => message.seq));
  const fresh = page.messages.filter(message => !seen.has(message.seq));
  if (placement === 'prepend') return [...fresh, ...current];
  if (placement === 'append') return [...current, ...fresh];
  return page.messages;
}

export function mountChannels(doc, session) {
  const byId = id => doc.getElementById(id);
  const node = (tag, text) => { const item = doc.createElement(tag); item.textContent = text; return item; };
  let selected = 'general';
  let history = [];
  let page = null;
  let open = false;
  let generation = 0;
  let draftId = null;
  function status(text) { byId('channels-status').textContent = text; }
  async function loadList() {
    const own = generation;
    const list = await session.channelRead('/dashboard/api/v1/channels');
    if (own !== generation) return null;
    if (!isChannelList(list)) throw new Error('schema');
    const names = byId('channel-names');
    names.replaceChildren();
    for (const channel of orderChannels(list.channels)) {
      const button = node('button', `#${channel.name}`);
      button.type = 'button';
      button.setAttribute('role', 'listitem');
      button.dataset.topic = channel.topic || '';
      button.setAttribute('aria-pressed', String(channel.name === selected));
      button.addEventListener('click', () => {
        selected = channel.name;
        for (const item of names.children) item.setAttribute('aria-pressed', String(item === button));
        history = []; page = null; void loadPage();
      });
      names.append(button);
    }
    if (!list.channels.some(channel => channel.name === selected)) selected = 'general';
    return list;
  }
  async function loadPage(query, placement = 'replace') {
    const own = generation;
    const path = channelMessagesPath(selected, query);
    const next = await session.channelRead(path);
    if (own !== generation) return;
    if (!isMessagePage(next, selected)) throw new Error('schema');
    page = next;
    history = mergeHistory(placement === 'replace' ? [] : history, next, placement);
    render();
    try {
      const board = await session.channelRead(`/dashboard/api/v1/channels/${selected}/status`);
      if (isStatusBoard(board, selected)) renderBoard(board);
    } catch { /* Status is helpful context, not required to show history. */ }
  }
  function renderBoard(board) {
    const list = byId('channel-status');
    list.replaceChildren(...board.statuses.map(row => node('li', `${row.label || row.agentId}: ${row.summary}`)));
    if (!board.statuses.length) list.append(node('li', 'No check-ins yet.'));
  }
  function render() {
    const topic = byId('channel-topic');
    byId('channel-title').textContent = `#${selected}`;
    byId('channel-draft').placeholder = `Message #${selected}`;
    const chosen = [...byId('channel-names').children].find(button => button.textContent === `#${selected}`);
    if (topic) topic.textContent = chosen?.dataset.topic || (page?.coverage === 'empty' ? 'No messages yet.' : '');
    const note = page?.coverage === 'gap' ? 'Some earlier messages expired.' : '';
    status(note || `${history.length} messages in #${selected}`);
    byId('channel-earlier').disabled = !page?.earlier;
    byId('channel-later').disabled = !page || page.caughtUp;
    const log = byId('channel-log');
    log.replaceChildren(...history.map(message => {
      const who = speaker(message);
      const item = node('article', '');
      item.className = 'slack-message';
      item.dataset.kind = who === 'Operator' ? 'operator' : 'agent';
      const avatar = node('span', who.slice(0, 1).toUpperCase());
      avatar.className = 'slack-avatar';
      avatar.setAttribute('aria-hidden', 'true');
      const body = node('div', '');
      const meta = node('p', '');
      meta.className = 'slack-meta';
      meta.append(node('strong', who), node('span', messageTime(message.postedAt)));
      meta.lastChild.className = 'slack-time';
      const text = node('p', message.body);
      text.className = 'channel-note';
      body.append(meta, text);
      item.append(avatar, body);
      return item;
    }));
    log.scrollTop = log.scrollHeight;
  }
  function reset() {
    generation++;
    open = false; selected = 'general'; history = []; page = null;
    draftId = null;
    const draft = byId('channel-draft'); if (draft) draft.value = '';
    const postStatus = byId('channel-post-status'); if (postStatus) postStatus.textContent = '';
    byId('channel-log')?.replaceChildren();
    byId('channel-names')?.replaceChildren();
    byId('channel-status')?.replaceChildren();
    const title = byId('channel-title'); if (title) title.textContent = '#general';
    status('Disconnected. Channel history cleared.');
  }
  async function reload(keep = false) {
    if (!open || !session.channelRead) return;
    const own = generation;
    try {
      if (await loadList() === null || own !== generation) return;
      if (!keep || !page || page.caughtUp) await loadPage(undefined, 'replace');
      else status(`${byId('channels-status').textContent} Newer messages may be available.`);
    } catch (error) {
      status(error?.code === 'disconnected' ? 'Disconnected. Channel history cleared.' : "Couldn't load channels.");
    }
  }
  byId('channel-earlier')?.addEventListener('click', () => {
    if (page?.earlierCursor) void loadPage({ before: page.earlierCursor }, 'prepend').catch(() => status("Couldn't load earlier messages."));
  });
  byId('channel-later')?.addEventListener('click', () => {
    if (page?.nextCursor) void loadPage({ after: page.nextCursor }, 'append').catch(() => status("Couldn't load later messages."));
  });
  byId('channel-start')?.addEventListener('click', () => {
    void loadPage({ after: '0' }, 'replace').catch(() => status("Couldn't load history from the start."));
  });
  byId('channel-refresh')?.addEventListener('click', () => { void reload(); });
  const dialog = byId('channel-create');
  byId('channel-add')?.addEventListener('click', () => { byId('channel-create-status').textContent = ''; dialog?.showModal(); byId('channel-create-name')?.focus(); });
  byId('channel-create-cancel')?.addEventListener('click', () => dialog?.close());
  byId('channel-create-form')?.addEventListener('submit', event => {
    event.preventDefault();
    const name = channelSlug(byId('channel-create-name').value);
    const topicText = byId('channel-create-topic').value.trim();
    const note = byId('channel-create-status');
    if (!name) { note.textContent = 'Use a short name: letters, numbers, and hyphens.'; return; }
    if (!session.channelCreate) { note.textContent = 'This server cannot create channels yet.'; return; }
    note.textContent = 'Creating…';
    void session.channelCreate(name, topicText).then(async () => {
      selected = name; history = []; page = null; dialog?.close();
      byId('channel-create-name').value = ''; byId('channel-create-topic').value = '';
      await reload();
    }, () => { note.textContent = "Couldn't create that channel."; });
  });
  byId('channel-composer')?.addEventListener('submit', event => {
    event.preventDefault();
    const draft = byId('channel-draft');
    const note = byId('channel-post-status');
    const body = draft?.value.trim() ?? '';
    if (!body || !session.channelPost) { if (note) note.textContent = 'This server cannot share operator updates yet.'; return; }
    draftId ??= newChannelMessageId();
    const id = draftId;
    if (note) note.textContent = 'Sharing your update…';
    void session.channelPost(selected, id, body).then(async () => {
      if (draftId === id) { draftId = null; if (draft) draft.value = ''; }
      if (note) note.textContent = 'Shared as the operator.';
      await loadPage(undefined, 'replace');
    }, error => {
      if (note) note.textContent = error?.code === 'outcome_unknown'
        ? 'That update may already be shared. Check the channel before sending it again.'
        : "Couldn't share that update.";
    });
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
