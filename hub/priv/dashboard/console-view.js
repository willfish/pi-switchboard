import { eventCursor } from './operator-events.js';
import { mountOperatorControls } from './operator-controls.js';

export function historyTime(value) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?$/.test(value)) return null;
  const time = Date.parse(`${value}Z`);
  return Number.isFinite(time) && time >= 0 ? String(Math.floor(time / 1000)) : null;
}

export function eventTime(value) {
  if (value === null) return 'Unknown';
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,19})$/.test(value)) return 'Unknown';
  const seconds = BigInt(value);
  if (seconds > 8640000000000n) return 'Outside display range';
  // This bounded range is exactly representable, including milliseconds.
  return new Date(Number(seconds * 1000n)).toISOString().replace('T', ' ').replace('.000Z', ' UTC');
}

export function createCommunications({ operator, render = () => {}, onObserved = () => {}, setTimer = setTimeout, clearTimer = clearTimeout }) {
  let generation = 0, flight = null, timer = null, selected = false, hidden = false, cursor = 'first';
  let searchFilters = null, searchPage = null, queuedSearch = null, stream = null, streamFailures = 0, observeFleet = false, pendingEvents = [], pendingMeta = null;
  function bounded(events) {
    const kept = events.slice(-128); let bytes = kept.reduce((n, event) => n + new TextEncoder().encode(JSON.stringify(event)).length, 0);
    while (bytes > 1048576 && kept.length) bytes -= new TextEncoder().encode(JSON.stringify(kept.shift())).length;
    return kept;
  }
  let state = { connected: false, events: [], coverage: null, loading: false, following: false, error: '', hasPage: false, caughtUp: true, searchMode: false, updates: 0 };
  const emit = () => render({ ...state });
  const stop = () => { if (timer !== null) clearTimer(timer); timer = null; };
  function stopStream() { stream?.abort(); stream = null; }
  function schedule() {
    stop();
    if (hidden || !state.connected || !observeFleet && (!selected || !state.following)) { stopStream(); return; }
    if (flight || stream) return;
    if (operator.observe) {
      timer = setTimer(() => { timer = null; startStream(); }, streamFailures ? Math.min(60000, 1000 * 2 ** Math.min(streamFailures, 6)) : 0);
    } else if (selected && state.following) timer = setTimer(() => { timer = null; void load(); }, 15000);
  }
  function startStream() {
    if (stream || hidden || !state.connected || !observeFleet && (!selected || !state.following)) return;
    const own = new AbortController(); stream = own;
    let caught = false, staged = [];
    state = { ...state, loading: state.following, error: '' }; emit();
    void operator.observe({ signal: own.signal, onPage(page) {
      if (stream !== own) return;
      cursor = eventCursor(page.epoch, page.toSequence);
      onObserved(page.events, page.caughtUp, page.epoch);
      staged = bounded([...staged, ...page.events]);
      if (page.caughtUp) {
        pendingMeta = { coverage: page.coverage, caughtUp: true };
        if (state.following) {
          state = { ...state, events: caught ? bounded([...state.events, ...staged]) : staged,
            coverage: page.coverage, caughtUp: true, hasPage: true, loading: false, error: '', updates: 0 };
          pendingEvents = [];
        } else {
          pendingEvents = bounded([...pendingEvents, ...staged]);
          state = { ...state, updates: Math.min(100000, state.updates + staged.length), loading: flight ? state.loading : false, streamError: '' };
        }
        caught = true; staged = []; streamFailures = 0; emit();
      }
    } }).catch(error => {
      if (stream !== own || own.signal.aborted) return;
      streamFailures++;
      if (['forbidden', 'disabled'].includes(error?.code)) observeFleet = false;
      const explanation = error?.code === 'history' ? 'Observation coverage changed. Reconnecting to a fresh retained window.' : 'Live observation unavailable. Retrying without replaying operations.';
      state = state.following ? { ...state, events: [], hasPage: false, loading: false,
        following: !['forbidden', 'disabled'].includes(error?.code), error: explanation, streamError: explanation }
        : { ...state, streamError: explanation };
      emit();
    }).finally(() => { if (stream === own) { stream = null; schedule(); } });
  }
  async function read(gen, restart) {
    state = { ...state, loading: true, error: '' }; emit();
    try {
      const page = await operator.events(restart ? 'first' : cursor);
      if (gen !== generation) return;
      // Follow is opt-in. Keep the last nonempty page on an empty incremental read.
      const events = restart || page.events.length ? page.events : state.events;
      cursor = page.nextCursor ?? eventCursor(page.epoch, page.toSequence);
      state = { ...state, events, coverage: page.coverage, caughtUp: page.caughtUp, hasPage: true };
    } catch (error) {
      if (gen !== generation) return;
      cursor = 'first';
      state = { ...state, events: [], hasPage: false, following: false,
        error: error?.code === 'history' ? 'Observation history changed or expired. Read retained history to continue.'
          : 'Communications unavailable. No current records are retained. Try reading again.' };
    } finally {
      if (gen === generation) { state = { ...state, loading: false }; emit(); }
    }
  }
  function load(restart = false) {
    if (state.searchMode && !restart) return search(searchFilters, true);
    if (restart) { if (!observeFleet) stopStream(); searchFilters = null; searchPage = null; state = { ...state, searchMode: false }; }
    if (!state.connected || !selected || hidden) return Promise.resolve();
    if (flight) return flight;
    const own = read(generation, restart);
    flight = own;
    void own.finally(() => { if (flight === own) {
      flight = null;
      if (queuedSearch) { const filters = queuedSearch; queuedSearch = null; void search(filters); } else schedule();
    } }).catch(() => {});
    return own;
  }
  function search(filters = {}, more = false) {
    if (!state.connected || !selected || hidden) return Promise.resolve();
    if (flight) { if (!more) { queuedSearch = filters; generation++; } return flight; }
    stop(); if (!observeFleet) stopStream();
    if (!more) { searchFilters = { ...filters }; searchPage = null; generation++; }
    if (more && !searchPage?.nextCursor) return Promise.resolve();
    const gen = generation;
    state = { ...state, searchMode: true, following: false, loading: true, error: '' }; emit();
    const own = (async () => {
      try {
        const result = await operator.searchEvents(searchFilters, more ? searchPage.nextCursor : null, more ? searchPage : null);
        if (gen !== generation) return;
        searchPage = result;
        state = { ...state, events: result.events, coverage: result.coverage, caughtUp: result.nextCursor === null, hasPage: true };
      } catch {
        if (gen !== generation) return;
        state = { ...state, events: [], hasPage: false, error: 'Retained-history search unavailable or expired. Start a new search.' };
      } finally { if (gen === generation) { state = { ...state, loading: false }; emit(); } }
    })();
    flight = own;
    void own.finally(() => { if (flight === own) {
      flight = null;
      if (queuedSearch) { const next = queuedSearch; queuedSearch = null; void search(next); }
    } }).catch(() => {});
    return own;
  }
  function setConnected(connected) {
    if (connected === state.connected) return;
    state = { ...state, connected };
    if (!connected) {
      generation++; stop(); stopStream(); pendingEvents = []; pendingMeta = null; flight = null; cursor = 'first'; searchFilters = null; searchPage = null; queuedSearch = null;
      state = { ...state, events: [], coverage: null, loading: false, following: false, error: '', hasPage: false, searchMode: false, updates: 0 };
    }
    emit();
  }
  function select(value) { selected = value; schedule(); return value && !state.hasPage ? load() : Promise.resolve(); }
  function follow(value) {
    if (value && state.searchMode) {
      cursor = searchPage ? eventCursor(searchPage.epoch, searchPage.throughSequence) : 'first';
      searchFilters = null; searchPage = null; state = { ...state, searchMode: false, events: [] };
    }
    if (!value && !observeFleet) stopStream();
    if (value && pendingMeta) { state = { ...state, ...pendingMeta, events: pendingEvents, hasPage: true, updates: 0 }; pendingEvents = []; }
    state = { ...state, following: value, loading: value ? state.loading : false }; emit(); schedule();
  }
  function setHidden(value) { hidden = value; schedule(); }
  emit();
  function applyUpdates() { state = { ...state, ...pendingMeta, events: pendingEvents, hasPage: true, updates: 0, searchMode: false }; pendingEvents = []; emit(); }
  function enableObservation(value) { observeFleet = value; schedule(); }
  return { load, search, select, follow, setConnected, setHidden, applyUpdates, enableObservation };
}

export function createInspector(render = () => {}, loadWork) {
  let state = null, generation = 0, flight = null, queued = false;
  async function read(gen, target) {
    try {
      const workView = await loadWork(target.agentId);
      if (gen !== generation || !state) return;
      if (workView.binding.agentId !== target.agentId || workView.binding.sessionId !== target.sessionId) {
        state = { ...state, contextChanged: true, workView: null, workError: 'Reported session context changed.' };
      } else state = { ...state, workView, workError: '' };
    } catch (error) {
      if (gen !== generation || !state) return;
      state = { ...state, workView: null, workError: error?.code === 'not_found'
        ? 'No current work report is available for this runtime.' : 'Work report unavailable. Read again to retry.' };
    } finally {
      if (gen === generation && state) { state = { ...state, workLoading: false }; render(state); }
    }
  }
  function refresh() {
    if (!state || !loadWork || state.contextChanged || state.availability !== 'present') return Promise.resolve();
    if (flight) { queued = true; return flight; }
    state = { ...state, workLoading: true, workError: '' }; render(state);
    const own = read(generation, state.target); flight = own;
    void own.finally(() => {
      if (flight !== own) return;
      flight = null;
      if (queued) { queued = false; void refresh(); }
    }).catch(() => {});
    return own;
  }
  return {
    select(agent) {
      generation++;
      state = { agent, target: { agentId: agent.agentId, sessionId: agent.sessionId },
        availability: 'present', contextChanged: false, workView: null, workLoading: false, workError: '' };
      render(state); void refresh();
    },
    update(agents, available) {
      if (!state) return;
      const agent = agents.find(a => a.agentId === state.target.agentId);
      state = { ...state, agent: agent ?? state.agent,
        availability: !available ? 'unknown' : agent ? 'present' : 'missing',
        contextChanged: agent ? agent.sessionId !== state.target.sessionId : state.contextChanged };
      render(state);
    },
    refresh,
    clear() { generation++; queued = false; state = null; render(state); },
  };
}

export function mountConsole(doc, operator, { isWatched = () => false, toggleWatch = () => {}, resolveAgent = () => undefined, focusWork = () => {}, onAttention = () => {}, onObserved = () => {} } = {}) {
  const byId = id => doc.getElementById(id);
  const node = (tag, text) => { const n = doc.createElement(tag); n.textContent = text; return n; };
  function evidenceNode(evidence) {
    const row = node('p', `${evidence.kind}: `);
    try {
      const url = new URL(evidence.ref);
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new Error('non-web reference');
      const link = node('a', evidence.ref); link.href = url.href; link.rel = 'noopener noreferrer'; link.target = '_blank'; row.append(link);
    } catch { row.append(node('span', evidence.ref)); }
    return row;
  }
  let lastEvents = null, current, search = '', category = 'communications', selectedRuntime = null, detailTab = 'overview', detailKey = '';
  const history = [];
  const detailTabs = ['overview', 'conversation', 'session', 'changes', 'activity'];
  function detail(state) {
    selectedRuntime = state;
    controls.update(state, detailTab);
    byId('inspector-back').disabled = history.length === 0;
    byId('inspector').hidden = !state;
    if (!state) {
      detailKey = '';
      byId('inspector-target').textContent = ''; byId('inspector-body').replaceChildren();
      byId('inspector-status').textContent = ''; byId('inspector-title').textContent = 'Runtime detail';
      return;
    }
    const a = state.agent;
    byId('inspector-refresh').disabled = state.workLoading || state.contextChanged || state.availability !== 'present';
    byId('inspector-title').textContent = a.label;
    byId('inspector-watch').setAttribute('aria-pressed', String(isWatched(state.target.agentId)));
    byId('inspector-watch').textContent = isWatched(state.target.agentId) ? 'Unwatch runtime' : 'Watch runtime';
    byId('inspector-target').textContent = `Runtime ${state.target.agentId} · saved session ${state.target.sessionId}`;
    byId('inspector-status').textContent = state.contextChanged ? 'Session context changed. Select the runtime again before intervening.'
      : state.availability === 'missing' ? 'Historical detail. Runtime is absent from the current snapshot.'
        : state.availability === 'unknown' ? 'Current presence unavailable. Showing historical detail.' : 'Present in the latest complete snapshot.';
    for (const tab of detailTabs) byId(`inspector-${tab}`).setAttribute('aria-pressed', String(tab === detailTab));
    const key = JSON.stringify([state.target, detailTab, a.host, a.pid, a.cwd, a.sessionName, a.model,
      state.workView?.work, state.workView?.binding.capabilities, state.workView?.binding.activeRunId, !state.workView && state.workLoading, state.workError]);
    if (key === detailKey) return;
    detailKey = key;
    const body = byId('inspector-body');
    if (detailTab === 'overview') {
      body.replaceChildren();
      const metadata = doc.createElement('details');
      metadata.append(node('summary', 'Runtime metadata'), node('p', `${a.host} · PID ${a.pid}`),
        node('p', a.cwd), node('p', a.sessionName),
        node('p', a.model ? `${a.model.provider} / ${a.model.id}` : 'Model not reported'));
      if (state.workView) {
        const work = state.workView.work;
        body.append(node('h3', work.objective ?? 'Objective not reported'),
          node('p', `Client-reported phase: ${work.phase ?? 'Not reported'}`));
        if (work.blocker) body.append(node('p', `${work.blocker.kind === 'decision' ? 'Decision requested' : 'Reported blocker'}: ${work.blocker.reason}`));
        const fields = doc.createElement('dl');
        for (const [key, label] of Object.entries({ workId: 'Work ID', currentStep: 'Current step', nextStep: 'Next step',
          owner: 'Reported owner', project: 'Project', repository: 'Repository', branch: 'Branch', worktree: 'Worktree',
          parentWorkId: 'Parent work', delegatedWorkId: 'Delegated work' }))
          fields.append(node('dt', label), node('dd', work[key] ?? 'Not reported'));
        body.append(fields);
        for (const [id, label] of [[work.parentWorkId, 'Show parent work'], [work.delegatedWorkId, 'Show delegated work']]) if (id) {
          const link = node('button', label); link.type = 'button';
          link.addEventListener('click', () => { select(false); inspector.clear(); focusWork(id); }); body.append(link);
        }
        body.append(node('h3', 'Reported evidence'));
        if (!work.evidence.length) body.append(node('p', 'No evidence reported. A completion report is not independent verification.'));
        for (const evidence of work.evidence) body.append(evidenceNode(evidence));
        body.append(node('p', `Negotiated capabilities: ${state.workView.binding.capabilities.join(', ') || 'None'}`),
          node('p', state.workView.permissions.history ? 'This runtime is explicitly enrolled for bounded volatile message previews.' : 'Message preview history is not enrolled for this runtime.'));
      } else body.append(node('p', state.workLoading ? 'Reading the current work report…'
        : state.workError || 'Structured work has not been reported.'));
      body.append(metadata);
    } else {
      const unavailable = {
        conversation: 'Recorded relay communications are available below. Client receipt and model-use reports are not available for this runtime.',
        session: state.workView?.binding.capabilities.includes('session.current.read.v1')
          ? 'Inspect a bounded stored conversation projection. Hidden reasoning and raw tool output are excluded. Read permission and content enrollment must both be granted locally.'
          : 'Current-session inspection is unavailable: no read capability has been negotiated for this runtime.',
        changes: 'No client-reported changes are available. Shared-checkout changes are not automatically attributed to this runtime.',
        activity: 'Run and tool activity reporting is unavailable for this runtime. Relay message observations are separate from execution progress.',
      };
      if (detailTab === 'changes' && state.workView) {
        const evidence = state.workView.work.evidence.filter(e => ['file', 'commit', 'artifact'].includes(e.kind));
        body.replaceChildren(node('p', 'Client-reported references. Shared-checkout attribution and unreported diffs are unknown.'));
        for (const item of evidence) body.append(evidenceNode(item));
        if (!evidence.length) body.append(node('p', 'No change evidence reported.'));
      } else if (detailTab === 'activity' && state.workView) {
        body.replaceChildren(node('p', state.workView.binding.activeRunId
          ? `Client reports active run ${state.workView.binding.activeRunId}. Activity is not proof of progress.` : 'No active run reported.'),
          node('p', 'Operation outcomes below are distinct from work reports. Use Communications for retained relay history.'));
      } else body.replaceChildren(node('p', unavailable[detailTab]));
    }
  }
  const controls = mountOperatorControls(doc, operator, onAttention);
  const inspector = createInspector(detail, agentId => operator.work(agentId));
  function rows() {
    const records = current.events.filter(event => {
      const type = event.kind === 'observation_lost' ? 'diagnostics'
        : event.kind.startsWith('mail_') || event.kind.startsWith('operator_') ? 'communications' : 'activity';
      return (category === 'all' || category === type) && JSON.stringify(event).toLowerCase().includes(search);
    });
    const items = records.map(event => {
      const root = doc.createElement('article'); root.className = 'communication';
      const names = { mail_accepted: 'Accepted by relay', mail_dispatched: 'Dispatch attempted', observation_lost: 'Observation gap',
        work_reported: 'Work reported', work_snapshot: 'Work report updated', run_reported: 'Run state reported', tool_reported: 'Tool state reported',
        operator_requested: 'Operator request', operator_result: 'Operation outcome reported', blocker_reported: 'Blocker reported', outcome_reported: 'Outcome reported' };
      root.append(node('h3', names[event.kind]));
      const p = event.payload;
      if (p.from) root.append(node('p', `${p.from} → ${p.to} · ${p.kind}`));
      root.append(node('p', `${event.source === 'relay_observed' ? 'Relay observation' : event.source === 'operator_requested' ? 'Network-authorized operator request' : 'Client report'} · ${eventTime(event.occurredAt)} · observed ${eventTime(event.observedAt)}`));
      if (p.action) {
        root.append(node('p', `${p.action} · ${p.state}`));
        if (p.body) root.append(node('p', p.body));
      }
      if (Object.hasOwn(p, 'activeRunId')) root.append(node('p', p.activeRunId ? `Active run ${p.activeRunId}` : 'No active run reported'));
      if (p.toolName) root.append(node('p', `${p.toolName} · ${p.state}`));
      const participants = [...new Set([p.from, p.to, event.agentId].filter(Boolean))];
      for (const id of participants) {
        const link = node('button', `Inspect runtime ${id}`); link.type = 'button';
        link.disabled = !resolveAgent(id);
        link.addEventListener('click', () => { const agent = resolveAgent(id); if (agent) { select(false); showRuntime(agent); } });
        root.append(link);
      }
      if (p.count) root.append(node('p', `${p.count} observations were not retained.`));
      if (p.objective || p.reason || p.outcome) root.append(node('p', p.objective ?? p.reason ?? p.outcome));
      if (p.from) root.append(node('p', p.body ?? 'Content not collected. Acceptance or dispatch does not prove receipt or model use.'));
      const detail = doc.createElement('details'); detail.append(node('summary', 'Event details'));
      const pre = node('pre', JSON.stringify(event, null, 2)); detail.append(pre); root.append(detail);
      return root;
    });
    byId('communications-list').replaceChildren(...items);
    byId('communications-count').textContent = `${records.length} of ${current.events.length} events on this page`;
  }
  const view = createCommunications({ operator, onObserved, render(state) {
    current = state;
    if (!state.connected) {
      search = ''; category = 'communications'; byId('communications-category').value = category;
      byId('communications-search').value = '';
      for (const id of ['communications-query', 'communications-participant', 'communications-work', 'communications-thread', 'communications-outcome', 'communications-from', 'communications-to']) byId(id).value = '';
      inspector.clear(); controls.disconnect(); history.length = 0;
    }
    byId('communications-follow').disabled = !state.connected;
    byId('communications-status').textContent = !state.connected ? 'Disconnected. Communications cleared.'
      : state.loading ? 'Reading communications…' : state.error || (!state.hasPage ? 'Select Communications to read retained history.'
        : `${state.coverage === 'truncated' ? 'Earlier history has expired. ' : ''}${state.caughtUp ? 'Caught up at the last read.' : 'More retained events are available.'} ${state.following ? 'Following the independent observation stream.' : 'Paused for reading.'}`);
    byId('communications-more').disabled = !state.connected || state.loading || state.searchMode && state.caughtUp;
    byId('communications-more').textContent = state.searchMode ? 'Next search results' : 'Read next events';
    byId('communications-query-submit').disabled = !state.connected || state.loading;
    byId('communications-updates').hidden = !state.updates;
    byId('communications-updates').textContent = `Show latest updates (${state.updates} observed)`;
    if (state.streamError) byId('communications-status').textContent += ` ${state.streamError}`;
    if (state.events.some(event => event.kind === 'observation_lost')) byId('communications-status').textContent += ' Coverage warning: see Diagnostics for reported gaps.';
    byId('communications-reset').disabled = !state.connected || state.loading;
    byId('communications-follow').checked = state.following;
    if (lastEvents !== state.events) { lastEvents = state.events; rows(); }
  } });
  function select(communications) {
    byId('runtimes').hidden = communications;
    byId('communications').hidden = !communications;
    byId('view-fleet').setAttribute('aria-pressed', String(!communications));
    byId('view-communications').setAttribute('aria-pressed', String(communications));
    void view.select(communications);
  }
  byId('view-fleet').addEventListener('click', () => select(false));
  byId('view-communications').addEventListener('click', () => select(true));
  byId('communications-query-submit').addEventListener('click', () => {
    const filters = {};
    for (const [field, key] of [['communications-query', 'q'], ['communications-participant', 'participant'],
      ['communications-work', 'workId'], ['communications-thread', 'threadId'], ['communications-outcome', 'outcome']]) {
      const value = byId(field).value.trim(); if (value) filters[key] = value;
    }
    for (const [field, key] of [['communications-from', 'from'], ['communications-to', 'to']]) {
      const value = byId(field).value;
      if (value) { const time = historyTime(value); if (time !== null) filters[key] = time; }
    }
    category = 'all'; byId('communications-category').value = category;
    void view.search(filters);
  });
  byId('communications-more').addEventListener('click', () => { void view.load(); });
  byId('communications-reset').addEventListener('click', () => { void view.load(true); });
  byId('communications-follow').addEventListener('change', () => view.follow(byId('communications-follow').checked));
  byId('communications-updates').addEventListener('click', () => view.applyUpdates());
  byId('communications-category').addEventListener('change', () => { category = byId('communications-category').value; rows(); });
  byId('communications-search').addEventListener('input', () => {
    search = byId('communications-search').value.slice(0, 200).toLowerCase(); rows();
  });
  for (const tab of detailTabs) byId(`inspector-${tab}`).addEventListener('click', () => {
    detailTab = tab; detail(selectedRuntime);
  });
  byId('inspector-watch').addEventListener('click', () => {
    if (!selectedRuntime) return;
    toggleWatch(selectedRuntime.target.agentId); detail(selectedRuntime);
  });
  byId('inspector-refresh').addEventListener('click', () => { void inspector.refresh(); });
  function showRuntime(agent, remember = true) {
    if (remember && selectedRuntime && selectedRuntime.target.agentId !== agent.agentId) {
      if (history.length >= 32) history.shift(); history.push(selectedRuntime.agent);
    }
    detailTab = 'overview'; inspector.select(agent); byId('inspector-title').focus();
  }
  byId('inspector-back').addEventListener('click', () => {
    const prior = history.pop(); if (!prior) return;
    const live = resolveAgent(prior.agentId); showRuntime(live ?? prior, false);
    if (!live) inspector.update([], true);
  });
  byId('inspector-close').addEventListener('click', () => { inspector.clear(); byId('view-fleet').focus(); });
  byId('inspector-communications').addEventListener('click', () => {
    if (!selectedRuntime) return;
    search = selectedRuntime.target.agentId.toLowerCase();
    byId('communications-search').value = selectedRuntime.target.agentId;
    rows(); select(true);
  });
  return { ...view,
    selectRuntime: showRuntime,
    updateAgents(agents, available) { inspector.update(agents, available); },
  };
}
