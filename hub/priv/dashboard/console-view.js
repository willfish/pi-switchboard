import { eventCursor } from './operator-events.js';
import { mountOperatorControls } from './operator-controls.js';
import { plainLabel } from './operator-actions.js';

export function historyTime(value) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?$/.test(value)) return null;
  const time = Date.parse(`${value}Z`);
  return Number.isFinite(time) && time >= 0 ? String(Math.floor(time / 1000)) : null;
}

export function eventTime(value) {
  if (value === null) return 'Unknown';
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,19})$/.test(value)) return 'Unknown';
  const seconds = BigInt(value);
  if (seconds > 8640000000000n) return "Date unavailable";
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
      const explanation = error?.code === 'history' ? "Some history is no longer available. Reconnecting for the latest updates." : "Live updates stopped. Reconnecting without sending any requests again.";
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
        error: error?.code === 'history' ? "Some history has expired. Open history again to continue."
          : "Couldn't load messages. Old details have been cleared. Try again." };
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
        state = { ...state, events: [], hasPage: false, error: "The history search failed or expired. Search again." };
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
        state = { ...state, contextChanged: true, workView: null, workError: "The agent switched conversations." };
      } else state = { ...state, workView, workError: '' };
    } catch (error) {
      if (gen !== generation || !state) return;
      state = { ...state, workView: null, workError: error?.code === 'not_found'
        ? "This agent hasn't shared task details yet." : "Couldn't load task details. Refresh to try again." };
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
      byId('inspector-status').textContent = ''; byId('inspector-title').textContent = "Agent details";
      return;
    }
    const a = state.agent;
    byId('inspector-refresh').disabled = state.workLoading || state.contextChanged || state.availability !== 'present';
    byId('inspector-title').textContent = a.label;
    byId('inspector-watch').setAttribute('aria-pressed', String(isWatched(state.target.agentId)));
    byId('inspector-watch').textContent = isWatched(state.target.agentId) ? "Stop watching agent" : "Watch agent";
    byId('inspector-target').textContent = `Agent ${state.target.agentId} · saved conversation ${state.target.sessionId}`;
    byId('inspector-status').textContent = state.contextChanged ? "The agent switched conversations. Select it again before sending a request."
      : state.availability === 'missing' ? "This agent is no longer in the list. These are its last known details."
        : state.availability === 'unknown' ? "Couldn't check the agent. Showing its last known details." : "Agent was available at the last update.";
    for (const tab of detailTabs) byId(`inspector-${tab}`).setAttribute('aria-pressed', String(tab === detailTab));
    const key = JSON.stringify([state.target, detailTab, a.host, a.pid, a.cwd, a.sessionName, a.model,
      state.workView?.work, state.workView?.binding.capabilities, state.workView?.binding.activeRunId, !state.workView && state.workLoading, state.workError]);
    if (key === detailKey) return;
    detailKey = key;
    const body = byId('inspector-body');
    if (detailTab === 'overview') {
      body.replaceChildren();
      const metadata = doc.createElement('details');
      metadata.append(node('summary', "Technical details"), node('p', `${a.host} · Process ID ${a.pid}`),
        node('p', a.cwd), node('p', a.sessionName),
        node('p', a.model ? `${a.model.provider} / ${a.model.id}` : 'Model not reported'));
      if (state.workView) {
        const work = state.workView.work;
        body.append(node('h3', work.objective ?? "No task shared yet"),
          node('p', `Agent's status: ${plainLabel(work.phase) ?? "Not provided"}`));
        if (work.blocker) body.append(node('p', `${work.blocker.kind === 'decision' ? "Needs your decision" : "Needs help"}: ${work.blocker.reason}`));
        const fields = doc.createElement('dl');
        for (const [key, label] of Object.entries({ workId: "Task ID", currentStep: 'Current step', nextStep: 'Next step',
          owner: "Owner", project: 'Project', repository: 'Repository', branch: 'Branch', worktree: 'Worktree',
          parentWorkId: "Parent task", delegatedWorkId: "Related task" }))
          fields.append(node('dt', label), node('dd', work[key] ?? "Not provided"));
        body.append(fields);
        for (const [id, label] of [[work.parentWorkId, "Show parent task"], [work.delegatedWorkId, "Show related task"]]) if (id) {
          const link = node('button', label); link.type = 'button';
          link.addEventListener('click', () => { select(false); inspector.clear(); focusWork(id); }); body.append(link);
        }
        body.append(node('h3', "Supporting details"));
        if (!work.evidence.length) body.append(node('p', "No supporting details shared yet. Finished work still needs checking."));
        for (const evidence of work.evidence) body.append(evidenceNode(evidence));
        body.append(node('p', `Available actions: ${state.workView.binding.capabilities.map(plainLabel).join(', ') || 'None'}`),
          node('p', state.workView.permissions.history ? "This agent allows message text to be saved temporarily in history." : "This agent hasn't allowed message text to be saved in history."));
      } else body.append(node('p', state.workLoading ? "Loading task details…"
        : state.workError || "No task details shared yet."));
      body.append(metadata);
    } else {
      const unavailable = {
        conversation: "See messages and request updates below. A message reaching an agent doesn't mean it has used it.",
        session: state.workView?.binding.capabilities.includes('session.current.read.v1')
          ? "Read the saved conversation, with the agent's permission. Private reasoning and detailed tool output aren't included."
          : "This agent doesn't support viewing its conversation here yet.",
        changes: "No changes shared yet. We don't assume this agent made every change in a shared folder.",
        activity: "This agent hasn't shared work activity. Message updates alone don't show its progress.",
      };
      if (detailTab === 'changes' && state.workView) {
        const evidence = state.workView.work.evidence.filter(e => ['file', 'commit', 'artifact'].includes(e.kind));
        body.replaceChildren(node('p', "Files and links shared by the agent. Other people or agents may also have changed these files."));
        for (const item of evidence) body.append(evidenceNode(item));
        if (!evidence.length) body.append(node('p', "No changes shared yet."));
      } else if (detailTab === 'activity' && state.workView) {
        body.replaceChildren(node('p', state.workView.binding.activeRunId
          ? `Agent reports work in progress: ${state.workView.binding.activeRunId}. Being active doesn't guarantee progress.` : "No work currently reported in progress."),
          node('p', "Request updates are shown below. Open Messages for earlier history."));
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
      const names = { mail_accepted: "Message accepted by server", mail_dispatched: "Server tried to deliver message", observation_lost: "Some history is missing",
        work_reported: "Task update", work_snapshot: "Task updated", run_reported: "Work status updated", tool_reported: "Tool activity updated",
        operator_requested: "Dashboard request", operator_result: "Request update", blocker_reported: "Help needed", outcome_reported: "Result shared" };
      root.append(node('h3', names[event.kind]));
      const p = event.payload;
      if (p.from) root.append(node('p', `${p.from} → ${p.to} · ${plainLabel(p.kind)}`));
      root.append(node('p', `${event.source === 'relay_observed' ? "Server update" : event.source === 'operator_requested' ? "Dashboard request" : "Agent update"} · ${eventTime(event.occurredAt)} · recorded ${eventTime(event.observedAt)}`));
      if (p.action) {
        root.append(node('p', `${plainLabel(p.action)} · ${plainLabel(p.state)}`));
        if (p.body) root.append(node('p', p.body));
      }
      if (Object.hasOwn(p, 'activeRunId')) root.append(node('p', p.activeRunId ? `Work in progress: ${p.activeRunId}` : 'No active run reported'));
      if (p.toolName) root.append(node('p', `${p.toolName} · ${plainLabel(p.state)}`));
      const participants = [...new Set([p.from, p.to, event.agentId].filter(Boolean))];
      for (const id of participants) {
        const link = node('button', `Open details agent ${id}`); link.type = 'button';
        link.disabled = !resolveAgent(id);
        link.addEventListener('click', () => { const agent = resolveAgent(id); if (agent) { select(false); showRuntime(agent); } });
        root.append(link);
      }
      if (p.count) root.append(node('p', `${p.count} updates were lost or couldn't be confirmed.`));
      if (p.objective || p.reason || p.outcome) root.append(node('p', p.objective ?? p.reason ?? p.outcome));
      if (p.from) root.append(node('p', p.body ?? "Message text wasn't saved. We can't tell whether the agent read or used it."));
      const detail = doc.createElement('details'); detail.append(node('summary', "Technical details"));
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
    byId('communications-status').textContent = !state.connected ? "Disconnected. Messages cleared."
      : state.loading ? "Loading messages…" : state.error || (!state.hasPage ? "Open Messages to see the history."
        : `${state.coverage === 'truncated' ? "Older history is no longer available. " : ''}${state.caughtUp ? "Up to date at the last check." : "More history is available."} ${state.following ? "New updates appear automatically." : "Paused so you can read."}`);
    byId('communications-more').disabled = !state.connected || state.loading || state.searchMode && state.caughtUp;
    byId('communications-more').textContent = state.searchMode ? "More results" : "Show more";
    byId('communications-query-submit').disabled = !state.connected || state.loading;
    byId('communications-updates').hidden = !state.updates;
    byId('communications-updates').textContent = `Show latest updates (${state.updates} recorded)`;
    if (state.streamError) byId('communications-status').textContent += ` ${state.streamError}`;
    if (state.events.some(event => event.kind === 'observation_lost')) byId('communications-status').textContent += " Some history may be missing. See Connection problems.";
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
