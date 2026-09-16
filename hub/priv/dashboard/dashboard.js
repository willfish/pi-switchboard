import { createOperatorSession } from './operator-session.js';
import { mountConsole } from './console-view.js';

const ERRORS = Object.freeze({ reset: 'Presence changed during the read. Refresh to try a new snapshot.',
  schema: 'The hub returned invalid presence data.', limit: 'The read exceeded a presence size limit.',
  timeout: 'The presence read exceeded its time limit.', transport: 'Could not read presence from the hub.',
  disabled: 'Operator access is disabled on this hub.',
  forbidden: 'Operator access was denied for this request.',
  unauthorized: 'Operator access was rejected for this network path.',
  unavailable: 'Operator access is temporarily unavailable.',
  cancelled: 'The operator request was cancelled.',
  disconnected: 'This view is disconnected.' });

export function createController({ operator, fetch: fetcher, now = Date.now,
  setTimer = setTimeout, clearTimer = clearTimeout, render = () => {}, hidden = false } = {}) {
  const session = operator ?? createOperatorSession({ fetch: fetcher });
  let generation = 0, active = null, timer = null, failures = 0, userDisconnected = false, lastCode = '';
  let state = { connected: true, loading: true, auto: true, hidden, snapshot: null,
    lastSuccess: null, error: '', retryMs: 15000, invalidation: null,
    workSnapshot: null, workError: '', workLoading: false };
  const pollMode = () => userDisconnected ? 'disconnected' : lastCode === 'disabled' ? 'stopped'
    : state.hidden ? 'hidden' : state.auto ? 'scheduled' : 'paused';
  const emit = () => render({ ...state, poll: pollMode() });
  const unschedule = () => { if (timer !== null) clearTimer(timer); timer = null; };
  const schedule = () => {
    unschedule();
    if (!userDisconnected && state.auto && !state.hidden && !active && lastCode !== 'disabled') {
      timer = setTimer(() => { timer = null; void refresh(); }, state.retryMs);
    }
  };
  function disconnect() {
    const ownGeneration = ++generation; userDisconnected = true; unschedule();
    active = null; failures = 0; lastCode = '';
    state = { ...state, connected: false, loading: false, snapshot: null, lastSuccess: null,
      error: '', retryMs: 15000, invalidation: null, workSnapshot: null, workError: '', workLoading: false };
    emit();
    void Promise.resolve(session.disconnect()).then((result) => {
      if (generation !== ownGeneration || !userDisconnected) return;
      state = { ...state, invalidation: result ?? state.invalidation };
      emit();
    }, () => {
      if (generation !== ownGeneration || !userDisconnected) return;
      state = { ...state, invalidation: 'unknown' }; emit();
    });
  }
  async function run(kind) {
    if (userDisconnected || active) return;
    unschedule();
    const ownGeneration = generation;
    active = kind;
    state = { ...state, connected: true, loading: true, error: '', invalidation: null }; emit();
    try {
      if (kind === 'start') await session.connect();
      if (generation !== ownGeneration || userDisconnected) return;
      const snapshot = await session.presence();
      if (generation !== ownGeneration || userDisconnected || active !== kind) return;
      failures = 0; lastCode = '';
      state = { ...state, snapshot, lastSuccess: now(), retryMs: 15000, error: '',
        workError: '', workLoading: Boolean(session.fleet) }; emit();
      if (session.fleet) {
        try {
          const workSnapshot = await session.fleet();
          if (generation !== ownGeneration || userDisconnected) return;
          if (workSnapshot.epoch !== snapshot.epoch) throw new Error('work epoch changed');
          state = { ...state, workSnapshot, workLoading: false };
        } catch {
          if (generation !== ownGeneration || userDisconnected) return;
          state = { ...state, workSnapshot: null, workLoading: false, workError: 'Work reports unavailable. Runtime presence is shown separately.' };
        }
      }
    } catch (error) {
      if (generation !== ownGeneration || userDisconnected || active !== kind) return;
      lastCode = error?.code ?? 'transport';
      if (lastCode === 'disconnected') { disconnect(); return; }
      failures += 1;
      state = { ...state, snapshot: null, workSnapshot: null, workLoading: false, workError: '', error: ERRORS[lastCode] ?? ERRORS.transport,
        retryMs: lastCode === 'disabled' ? 15000 : failures === 1 ? 30000 : 60000 };
    } finally {
      if (generation === ownGeneration && userDisconnected === false && active === kind) {
        active = null; state = { ...state, loading: false }; emit(); schedule();
      }
    }
  }
  function refresh() { return run('refresh'); }
  function connect() { userDisconnected = false; lastCode = ''; return run('start'); }
  emit();
  void connect();
  return {
    connect, disconnect, refresh,
    setAuto(value) { state = { ...state, auto: Boolean(value) }; emit(); schedule(); },
    setHidden(value) {
      const returning = state.hidden && !value;
      state = { ...state, hidden: Boolean(value) }; emit(); unschedule();
      if (returning && state.auto && !userDisconnected && lastCode !== 'disabled') void refresh();
      else schedule();
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
  const operator = createOperatorSession(), watchlist = new Set(), operationAttention = new Map();
  const lastEvents = new Map(); let observedEpoch = null, observedAgents = new Map();
  const consoleView = mountConsole(doc, operator, {
    onObserved(events, caughtUp, epoch) {
      if (observedEpoch !== epoch) { observedEpoch = epoch; lastEvents.clear(); }
      for (const event of events) for (const id of new Set([event.agentId, event.payload.from, event.payload.to].filter(Boolean))) {
        const agent = observedAgents.get(id); if (!agent) continue;
        if (event.sessionId !== null && event.sessionId !== agent.sessionId) continue;
        const prior = lastEvents.get(id);
        if (!prior || BigInt(event.sequence) > BigInt(prior.sequence)) lastEvents.set(id,
          { sequence: event.sequence, observedAt: event.observedAt, kind: event.kind, source: event.source });
      }
      if (caughtUp && current?.snapshot) renderRows();
    },
    onAttention(operations) {
      const wanted = new Set(operations.map(op => op.operationId));
      for (const [id, row] of operationAttention) if (!wanted.has(id)) { row.remove(); operationAttention.delete(id); }
      for (const op of operations) {
        let row = operationAttention.get(op.operationId);
        if (!row) {
          row = element('button'); row.type = 'button';
          row.addEventListener('click', () => { const agent = current?.snapshot?.agents.find(a => a.agentId === op.agentId); if (agent) consoleView.selectRuntime(agent); });
          operationAttention.set(op.operationId, row); byId('attention-operations').append(row);
        }
        row.textContent = `${op.kind} · ${op.state} · ${op.agentId}`;
      }
    },
    isWatched: id => watchlist.has(id),
    resolveAgent: id => current?.snapshot?.agents.find(agent => agent.agentId === id),
    focusWork(id) {
      const select = byId('work-filter');
      if (![...select.children].some(option => option.value === id)) { const option = element('option', id); option.value = id; select.append(option); }
      select.value = id; page = 0; renderRows(); byId('runtimes').focus();
    },
    toggleWatch(id) { if (watchlist.has(id)) watchlist.delete(id); else watchlist.add(id); renderRows(); },
  });
  let current, page = 0, controller, wasConnected = true, hostOptions = null;
  const cards = new Map();
  let displayedSnapshot = null, shortIds = new Map(), workViews = new Map();
  const attentionRows = new Map();
  const filterIds = ['search', 'host', 'activity', 'receiving', 'control', 'sort', 'project', 'work-filter', 'model-filter', 'owner-filter', 'capability-filter'];
  const optionCache = new Map();
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
    const objective = element('p', '', 'work-objective peer'), phase = element('p', '', 'identity'), meaningful = element('p', '', 'identity');
    work.append(title, session, objective, phase, meaningful);
    const inspect = element('button', 'Inspect', 'inspect'); inspect.type = 'button';
    details.append(summary, list); root.append(work, identity, model, badges, details, inspect);
    const card = { root, title, identity, session, model, status, receiving, control, summary, fields, inspect, objective, phase, meaningful, agent: null };
    inspect.addEventListener('click', () => { if (card.agent) consoleView.selectRuntime(card.agent); });
    return card;
  }
  function renderRows() {
    const snapshot = current.snapshot;
    const agents = snapshot?.agents ?? [];
    const selected = filters();
    const matching = selectAgents(agents, selected).filter(agent => {
      const view = workViews.get(agent.agentId), work = view?.work;
      return (!selected.project || work?.project === selected.project)
        && (!selected['work-filter'] || work?.workId === selected['work-filter'])
        && (!selected['model-filter'] || modelText(agent) === selected['model-filter'])
        && (!selected['owner-filter'] || work?.owner === selected['owner-filter'])
        && (!selected['capability-filter'] || view?.binding.capabilities.includes(selected['capability-filter']))
        && (!byId('watched').checked || watchlist.has(agent.agentId));
    });
    if (selected.sort === 'work') matching.sort((a, b) => {
      const key = agent => { const work = workViews.get(agent.agentId)?.work;
        return work?.workId ? `${work.project ?? ''}\u0000${work.workId}` : '\uffff'; };
      return compare(key(a), key(b)) || compare(a.label, b.label) || compare(a.agentId, b.agentId);
    });
    page = Math.max(0, Math.min(page, Math.ceil(matching.length / 50) - 1));
    byId('matching').textContent = snapshot ? `${matching.length} matching of ${agents.length} registered` : 'Counts unavailable';
    byId('page').textContent = snapshot ? `Page ${page + 1} of ${Math.max(1, Math.ceil(matching.length / 50))}` : 'Page unavailable';
    byId('previous').disabled = !snapshot || page === 0;
    byId('next').disabled = !snapshot || (page + 1) * 50 >= matching.length;
    byId('empty').hidden = Boolean(snapshot && matching.length);
    byId('empty').textContent = !snapshot ? (current.loading ? 'Reading a complete snapshot…' : current.connected ? 'Presence unavailable. No records or counts are retained.' : 'Disconnected. This view is cleared.')
      : agents.length === 0 ? 'No runtimes registered in this complete snapshot.' : 'No runtimes match these filters. Summary counts still describe the complete snapshot.';
    const visible = matching.slice(page * 50, (page + 1) * 50);
    const ids = new Set(visible.map((a) => a.agentId));
    const focus = doc.activeElement;
    const hadCardFocus = byId('cards').contains(focus);
    for (const [id, card] of cards) if (!ids.has(id)) { card.root.remove(); cards.delete(id); }
    for (const [index, a] of visible.entries()) {
      let card = cards.get(a.agentId);
      if (!card) { card = makeCard(); cards.set(a.agentId, card); }
      card.agent = a;
      card.inspect.setAttribute('aria-label', `Inspect runtime ${shortIds.get(a.agentId)}`);
      card.title.textContent = a.label;
      card.summary.setAttribute('aria-label', `Runtime details for ${shortIds.get(a.agentId)}`);
      card.identity.textContent = `${a.host} · ${shortIds.get(a.agentId)}`;
      card.session.textContent = a.sessionName;
      const reported = workViews.get(a.agentId)?.work;
      card.objective.textContent = reported?.objective ?? 'Work not reported';
      card.phase.textContent = reported ? `${reported.project ?? 'Project not reported'} · ${reported.phase ?? 'phase unknown'}${reported.currentStep ? ` · ${reported.currentStep}` : ''}` : 'Presence-only context';
      const last = lastEvents.get(a.agentId);
      if (last) {
        const age = BigInt(Math.floor(Date.now() / 1000)) - BigInt(last.observedAt);
        const when = age < 0n ? 'clock difference' : age < 60n ? `${age}s ago` : age < 3600n ? `${age / 60n}m ago` : `${age / 3600n}h ago`;
        card.meaningful.textContent = `Last observed ${last.kind}: ${when} · ${last.source.replaceAll('_', ' ')}`;
      } else card.meaningful.textContent = 'Meaningful event history not observed.';
      card.model.textContent = modelText(a);
      card.status.textContent = a.status === 'busy' ? 'Busy' : 'Idle';
      card.receiving.textContent = a.receiving ? 'Receiving' : 'Not receiving';
      card.control.textContent = a.acceptsControl ? 'Peer control reported' : 'No peer control reported';
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
    observedAgents = new Map((state.snapshot?.agents ?? []).map(agent => [agent.agentId, agent]));
    for (const id of lastEvents.keys()) if (!observedAgents.has(id)) lastEvents.delete(id);
    consoleView.setConnected(state.connected);
    consoleView.enableObservation(Boolean(state.connected && state.snapshot));
    consoleView.updateAgents(state.snapshot?.agents ?? [], Boolean(state.snapshot));
    workViews = new Map((state.workSnapshot?.epoch === state.snapshot?.epoch ? state.workSnapshot?.views ?? [] : []).map(v => [v.binding.agentId, v]));
    for (const agent of state.snapshot?.agents ?? []) {
      if (workViews.get(agent.agentId)?.binding.sessionId !== agent.sessionId) workViews.delete(agent.agentId);
    }
    byId('attention-status').textContent = !state.connected ? 'Disconnected. Work reports cleared.'
      : state.workLoading ? 'Reading complete work reports. Any displayed work is from the previous snapshot.' : state.workError
        || (state.workSnapshot ? 'Explicit client reports, not inferred progress or verified completion.' : 'Work reports have not been read.');
    const needs = (state.snapshot?.agents ?? []).filter(a => {
      const w = workViews.get(a.agentId)?.work; return w?.blocker || w?.phase === 'failed';
    });
    const activeIds = new Set(needs.map(a => a.agentId));
    for (const [id, row] of attentionRows) if (!activeIds.has(id)) { row.remove(); attentionRows.delete(id); }
    for (const agent of needs) {
      let row = attentionRows.get(agent.agentId);
      if (!row) {
        row = element('button'); row.type = 'button';
        row.addEventListener('click', () => {
          const currentAgent = current.snapshot?.agents.find(a => a.agentId === agent.agentId);
          if (currentAgent) consoleView.selectRuntime(currentAgent);
        });
        attentionRows.set(agent.agentId, row); byId('attention-list').append(row);
      }
      const work = workViews.get(agent.agentId).work;
      row.textContent = `${agent.label} · ${work.blocker?.kind === 'decision' ? 'Decision requested' : work.blocker ? 'Reported blocker' : 'Reported failure'}: ${work.blocker?.reason ?? work.objective ?? 'Outcome evidence not supplied'}`;
    }
    byId('attention-empty').hidden = !state.workSnapshot || needs.length !== 0;
    byId('attention-empty').textContent = 'No explicit blockers or failures in these reports. This does not establish that unreported work is healthy.';
    if (displayedSnapshot !== state.snapshot) {
      displayedSnapshot = state.snapshot;
      shortIds = displayIds(state.snapshot?.agents ?? []);
    }
    byId('refresh').disabled = !state.connected || state.loading;
    byId('disconnect').hidden = !state.connected;
    byId('disconnect').disabled = !state.connected;
    byId('reconnect').hidden = state.connected;
    byId('reconnect').disabled = state.connected;
    byId('auto').checked = state.auto;
    const pause = state.poll === 'stopped' ? 'Automatic refresh is stopped until you Refresh or Reconnect.'
      : state.poll === 'hidden' ? 'Paused while this page is hidden.'
      : state.poll === 'paused' ? 'Automatic refresh paused.'
      : `Next automatic read ${state.retryMs / 1000}s after completion.`;
    const invalid = state.invalidation === 'unknown' ? ' Server session invalidation is uncertain.' : '';
    byId('status').textContent = !state.connected ? `Disconnected. This view is cleared. Reconnect is allowed while the network still admits this page; it is not a physical lock.${invalid}`
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
    for (const [id, title, values] of [
      ['project', 'All projects', [...workViews.values()].map(v => v.work.project)],
      ['work-filter', 'All work items', [...workViews.values()].map(v => v.work.workId)],
      ['model-filter', 'All models', (state.snapshot?.agents ?? []).map(modelText)],
      ['owner-filter', 'All owners', [...workViews.values()].map(v => v.work.owner)],
      ['capability-filter', 'Any capability', [...workViews.values()].flatMap(v => v.binding.capabilities)],
    ]) {
      const select = byId(id), selected = select.value;
      const options = [...new Set(values.filter(v => typeof v === 'string'))].sort(compare);
      if (selected && state.snapshot && !options.includes(selected)) options.push(selected);
      const key = JSON.stringify(options);
      if (optionCache.get(id) !== key) {
        const all = element('option', title); all.value = '';
        select.replaceChildren(all);
        for (const value of options) { const option = element('option', value); option.value = value; select.append(option); }
        select.value = state.snapshot ? selected : ''; optionCache.set(id, key);
      }
    }
    if (!state.connected) {
      watchlist.clear(); lastEvents.clear(); observedEpoch = null; byId('watched').checked = false;
      for (const id of filterIds) byId(id).value = id === 'sort' ? 'label' : '';
      page = 0;
    }
    renderRows();
    if (!state.connected && wasConnected) byId('reconnect').focus();
    wasConnected = state.connected;
  }
  controller = createController({ operator, render, hidden: doc.hidden });
  byId('refresh').addEventListener('click', () => { void controller.refresh(); });
  byId('disconnect').addEventListener('click', () => { controller.disconnect(); });
  byId('reconnect').addEventListener('click', () => { void controller.connect(); });
  byId('auto').addEventListener('change', () => controller.setAuto(byId('auto').checked));
  byId('theme').addEventListener('change', () => { doc.documentElement.dataset.theme = byId('theme').value; });
  for (const id of filterIds) byId(id).addEventListener(id === 'search' ? 'input' : 'change', () => {
    if (id === 'search') byId(id).value = byId(id).value.slice(0, 200);
    page = 0; renderRows();
  });
  byId('watched').addEventListener('change', () => { page = 0; renderRows(); });
  byId('clear-filters').addEventListener('click', () => {
    byId('watched').checked = false;
    for (const id of filterIds) byId(id).value = id === 'sort' ? 'label' : '';
    page = 0; renderRows(); byId('search').focus();
  });
  byId('previous').addEventListener('click', () => { page -= 1; renderRows(); });
  byId('next').addEventListener('click', () => { page += 1; renderRows(); });
  doc.addEventListener('visibilitychange', () => {
    controller.setHidden(doc.hidden); consoleView.setHidden(doc.hidden);
  });
  win.addEventListener('pagehide', () => { controller.disconnect(); });
  win.addEventListener('pageshow', (event) => { if (event.persisted) controller.disconnect(); });
  const network = () => { byId('network').hidden = win.navigator.onLine !== false; };
  win.addEventListener('online', network); win.addEventListener('offline', network); network();
  return controller;
}
if (typeof document !== 'undefined' && typeof window !== 'undefined') mountDashboard(document, window);
