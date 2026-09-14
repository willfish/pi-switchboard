import { discover } from './protocol.js';

const ERRORS = Object.freeze({ reset: 'Presence changed during the read. Refresh to try a new snapshot.',
  schema: 'The hub returned invalid presence data.', limit: 'The read exceeded a presence size limit.',
  timeout: 'The presence read exceeded its time limit.', transport: 'Could not read presence from the hub.' });

// Token and request ownership are closure-private, never part of render state.
export function createController({ load = discover, render = () => {}, now = Date.now,
  setTimer = setTimeout, clearTimer = clearTimeout, hidden = false } = {}) {
  let token = '', generation = 0, active = null, timer = null, failures = 0;
  let state = { unlocked: false, loading: false, auto: true, hidden, snapshot: null,
    lastSuccess: null, error: '', retryMs: 15000 };
  const emit = () => render({ ...state });
  const unschedule = () => { if (timer !== null) clearTimer(timer); timer = null; };
  const schedule = () => {
    unschedule();
    if (state.unlocked && state.auto && !state.hidden && !active) {
      timer = setTimer(() => { timer = null; void refresh(); }, state.retryMs);
    }
  };
  function lock(reason = '') {
    generation += 1; token = ''; unschedule();
    active?.abort(); active = null; failures = 0;
    state = { ...state, unlocked: false, loading: false, snapshot: null, lastSuccess: null,
      error: reason, retryMs: 15000 };
    emit();
  }
  async function refresh() {
    if (!token || active) return;
    unschedule();
    const ownGeneration = generation;
    const request = new AbortController(); active = request;
    state = { ...state, loading: true, error: '' }; emit();
    try {
      const snapshot = await load(token, { signal: request.signal });
      if (generation !== ownGeneration || active !== request || request.signal.aborted) return;
      failures = 0;
      state = { ...state, snapshot, lastSuccess: now(), retryMs: 15000 };
    } catch (error) {
      if (generation !== ownGeneration || active !== request || request.signal.aborted) return;
      if (error?.code === 'unauthorized') { lock('Token rejected. Unlock with a valid hub token.'); return; }
      failures += 1;
      state = { ...state, snapshot: null, error: ERRORS[error?.code] ?? ERRORS.transport,
        retryMs: failures === 1 ? 30000 : 60000 };
    } finally {
      if (generation === ownGeneration && active === request) {
        active = null; state = { ...state, loading: false }; emit(); schedule();
      }
    }
  }
  emit();
  return {
    unlock(value) { lock(); if (!value) return; token = value; state = { ...state, unlocked: true }; void refresh(); },
    lock, refresh,
    setAuto(value) { state = { ...state, auto: Boolean(value) }; emit(); schedule(); },
    setHidden(value) {
      const returning = state.hidden && !value;
      state = { ...state, hidden: Boolean(value) }; emit(); unschedule();
      if (returning && state.auto) void refresh(); else schedule();
    },
  };
}

export function counts(agents) {
  return { registered: agents.length, busy: agents.filter((a) => a.status === 'busy').length,
    receiving: agents.filter((a) => a.receiving).length, control: agents.filter((a) => a.acceptsControl).length };
}
const modelText = (a) => a.model ? `${a.model.provider} / ${a.model.id}` : 'Not reported';
const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;
export function selectAgents(agents, { search = '', host = '', activity = '', receiving = '', control = '', sort = 'label' } = {}) {
  const needle = search.slice(0, 200).toLowerCase();
  const key = (a) => sort === 'model' ? modelText(a) : sort === 'activity' ? a.status : sort === 'host' ? a.host : a.label;
  return agents.filter((a) => (!host || a.host === host) && (!activity || a.status === activity)
    && (!receiving || String(a.receiving) === receiving) && (!control || String(a.acceptsControl) === control)
    && [a.label, a.sessionName, a.host, modelText(a), a.agentId].some((v) => v.toLowerCase().includes(needle)))
    .sort((a, b) => compare(key(a).toLowerCase(), key(b).toLowerCase()) || compare(a.host, b.host) || compare(a.agentId, b.agentId));
}
export function displayIds(agents) {
  const groups = new Map(), result = new Map();
  for (const { agentId } of agents) {
    const prefix = agentId.slice(0, 8);
    if (!groups.has(prefix)) groups.set(prefix, []);
    groups.get(prefix).push(agentId);
  }
  for (const [prefix, ids] of groups) {
    if (ids.length === 1) { result.set(ids[0], prefix); continue; }
    let length = 4;
    while (length < 28 && new Set(ids.map((id) => id.slice(-length))).size !== ids.length) length += 1;
    for (const id of ids) result.set(id, length + 9 < id.length ? `${prefix}…${id.slice(-length)}` : id);
  }
  return result;
}

export function timestamp(value, seconds = false) {
  if (value === null || value === undefined) return 'unavailable';
  const date = new Date(seconds ? value * 1000 : value);
  return Number.isNaN(date.valueOf()) ? 'Outside browser date range' : date.toLocaleString();
}

export function mountDashboard(doc, win) {
  const byId = (id) => doc.getElementById(id);
  const element = (tag, text, className) => {
    const node = doc.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  };
  let current, page = 0, controller, wasUnlocked = false, hostOptions = null;
  const cards = new Map();
  let displayedSnapshot = null, shortIds = new Map();
  const filterIds = ['search', 'host', 'activity', 'receiving', 'control', 'sort'];
  const filters = () => Object.fromEntries(filterIds.map((id) => [id, byId(id).value]));
  function makeCard() {
    const root = element('article', undefined, 'card');
    const title = element('h3', '', 'peer');
    const identity = element('p', '', 'identity peer');
    const session = element('p', '', 'identity peer');
    const model = element('p', '', 'model peer');
    const badges = element('div', undefined, 'badges');
    const status = element('span', '', 'badge'), receiving = element('span', '', 'badge'), control = element('span', '', 'badge');
    badges.append(status, receiving, control);
    const details = element('details');
    const summary = element('summary', 'Runtime details');
    const list = element('dl');
    const fields = {};
    for (const [key, label] of Object.entries({ agentId: 'Runtime ID', sessionId: 'Saved session ID', host: 'Host', cwd: 'Working directory', pid: 'PID', updatedAt: 'Last registration' })) {
      const value = element('dd', '', 'peer'); fields[key] = value;
      list.append(element('dt', label), value);
    }
    const work = element('div', undefined, 'work');
    work.append(title, session);
    details.append(summary, list); root.append(work, identity, model, badges, details);
    return { root, title, identity, session, model, status, receiving, control, summary, fields };
  }
  function renderRows() {
    const snapshot = current.snapshot;
    const agents = snapshot?.agents ?? [];
    const matching = selectAgents(agents, filters());
    page = Math.max(0, Math.min(page, Math.ceil(matching.length / 50) - 1));
    byId('matching').textContent = snapshot ? `${matching.length} matching of ${agents.length} registered` : 'Counts unavailable';
    byId('page').textContent = snapshot ? `Page ${page + 1} of ${Math.max(1, Math.ceil(matching.length / 50))}` : 'Page unavailable';
    byId('previous').disabled = !snapshot || page === 0;
    byId('next').disabled = !snapshot || (page + 1) * 50 >= matching.length;
    byId('empty').hidden = Boolean(snapshot && matching.length);
    byId('empty').textContent = !snapshot ? (current.loading ? 'Reading a complete snapshot…' : current.unlocked ? 'Presence unavailable. No records or counts are retained.' : 'Unlock to read runtime presence.')
      : agents.length === 0 ? 'No runtimes registered in this complete snapshot.' : 'No runtimes match these filters. Summary counts still describe the complete snapshot.';
    const visible = matching.slice(page * 50, (page + 1) * 50);
    const ids = new Set(visible.map((a) => a.agentId));
    const focus = doc.activeElement;
    const hadCardFocus = byId('cards').contains(focus);
    for (const [id, card] of cards) if (!ids.has(id)) { card.root.remove(); cards.delete(id); }
    for (const [index, a] of visible.entries()) {
      let card = cards.get(a.agentId);
      if (!card) { card = makeCard(); cards.set(a.agentId, card); }
      card.title.textContent = a.label;
      card.summary.setAttribute('aria-label', `Runtime details for ${shortIds.get(a.agentId)}`);
      card.identity.textContent = `${a.host} · ${shortIds.get(a.agentId)}`;
      card.session.textContent = a.sessionName;
      card.model.textContent = modelText(a);
      card.status.textContent = a.status === 'busy' ? 'Busy' : 'Idle';
      card.receiving.textContent = a.receiving ? 'Receiving' : 'Not receiving';
      card.control.textContent = a.acceptsControl ? 'Control enabled' : 'Notice only';
      for (const [key, node] of Object.entries(card.fields)) node.textContent = key === 'updatedAt' ? timestamp(a[key], true) : String(a[key]);
      const position = byId('cards').children[index];
      if (position !== card.root) byId('cards').insertBefore(card.root, position ?? null);
    }
    // Reordering can detach the focused summary in browsers. Restore only existing user focus.
    if (hadCardFocus) {
      if (byId('cards').contains(focus)) {
        if (doc.activeElement !== focus) focus.focus({ preventScroll: true });
      } else byId('runtimes').focus({ preventScroll: true });
    }
  }
  function render(state) {
    current = state;
    if (displayedSnapshot !== state.snapshot) {
      displayedSnapshot = state.snapshot;
      shortIds = displayIds(state.snapshot?.agents ?? []);
    }
    byId('unlock-panel').hidden = state.unlocked;
    byId('refresh').disabled = !state.unlocked || state.loading;
    byId('lock').disabled = !state.unlocked;
    byId('auto').checked = state.auto;
    const pause = state.hidden ? 'Paused while this page is hidden.' : !state.auto ? 'Automatic refresh paused.' : `Next automatic read ${state.retryMs / 1000}s after completion.`;
    byId('status').textContent = !state.unlocked ? state.error || 'Locked. No presence loaded.'
      : state.loading ? (state.snapshot ? 'Refreshing. Showing a historical snapshot until the complete read succeeds.' : 'Reading presence. Counts unavailable until all pages validate.')
      : state.error ? `${state.error} No current snapshot. ${pause}`
      : `Snapshot read complete, not live. ${pause}`;
    byId('freshness').textContent = `Last successful read: ${state.lastSuccess === null ? 'none' : timestamp(state.lastSuccess)} · Server capture: ${timestamp(state.snapshot?.capturedAt, true)}`;
    const totals = state.snapshot ? counts(state.snapshot.agents) : null;
    for (const key of ['registered', 'busy', 'receiving', 'control']) byId(`${key}-count`).textContent = totals ? String(totals[key]) : '--';
    const selectedHost = byId('host').value;
    const hosts = [...new Set(state.snapshot?.agents.map((a) => a.host) ?? [])].sort(compare);
    if (selectedHost && !hosts.includes(selectedHost) && state.snapshot) hosts.push(selectedHost);
    hosts.sort(compare);
    if (hostOptions === null || hosts.length !== hostOptions.length || hosts.some((host, i) => host !== hostOptions[i])) {
      byId('host').replaceChildren(element('option', 'All hosts'));
      byId('host').firstChild.value = '';
      for (const host of hosts) { const option = element('option', host); option.value = host; byId('host').append(option); }
      byId('host').value = state.snapshot ? selectedHost : '';
      hostOptions = hosts;
    }
    if (!state.unlocked) {
      byId('token').value = '';
      for (const id of filterIds) byId(id).value = id === 'sort' ? 'label' : '';
      page = 0;
    }
    renderRows();
    if (!state.unlocked && wasUnlocked) byId('token').focus();
    wasUnlocked = state.unlocked;
  }
  controller = createController({ render, hidden: doc.hidden });
  byId('unlock-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const value = byId('token').value;
    byId('token').value = '';
    controller.unlock(value);
    if (value) byId('lock').focus();
  });
  byId('refresh').addEventListener('click', () => { void controller.refresh(); });
  byId('lock').addEventListener('click', () => { controller.lock(); byId('token').focus(); });
  byId('auto').addEventListener('change', () => controller.setAuto(byId('auto').checked));
  byId('theme').addEventListener('change', () => { doc.documentElement.dataset.theme = byId('theme').value; });
  for (const id of filterIds) byId(id).addEventListener(id === 'search' ? 'input' : 'change', () => {
    if (id === 'search') byId(id).value = byId(id).value.slice(0, 200);
    page = 0; renderRows();
  });
  byId('clear-filters').addEventListener('click', () => {
    for (const id of filterIds) byId(id).value = id === 'sort' ? 'label' : '';
    page = 0; renderRows(); byId('search').focus();
  });
  byId('previous').addEventListener('click', () => { page -= 1; renderRows(); });
  byId('next').addEventListener('click', () => { page += 1; renderRows(); });
  doc.addEventListener('visibilitychange', () => controller.setHidden(doc.hidden));
  win.addEventListener('pagehide', () => { controller.lock(); byId('token').value = ''; byId('token').focus(); });
  win.addEventListener('pageshow', (event) => { if (event.persisted) { controller.lock(); byId('token').focus(); } });
  const network = () => { byId('network').hidden = win.navigator.onLine !== false; };
  win.addEventListener('online', network); win.addEventListener('offline', network); network();
  return controller;
}
if (typeof document !== 'undefined' && typeof window !== 'undefined') mountDashboard(document, window);
