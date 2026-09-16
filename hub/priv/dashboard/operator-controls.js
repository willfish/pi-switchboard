import { canAct, makeOperation, newOperationId, plainLabel, outcomeTone } from './operator-actions.js';
import { isWorkSnapshot } from './operator-work.js';

const labels = { notice: "Send a message", work: "Ask agent to work", guidance: "Guide current work", label: "Rename agent", interrupt: "Stop current work" };
const explanations = {
  notice: "Leave a message for later. This won't start work, and we can't tell whether it has been read.",
  work: "Ask the agent to do something. It may start now or wait until its current work finishes.",
  guidance: "Send advice while the agent is working. It may not use it straight away, and you can't take it back.",
  label: "Change the name shown for this agent.",
  interrupt: "Ask the agent to stop its current work. Changes already made won't be undone, and messages already sent can't be taken back.",
};
const states = {
  queued: "Waiting for the agent", accepted: "Agent received the request; waiting for an update", received: "Message reached the agent; reading isn't confirmed",
  attempted: "Passed to the agent; not confirmed in use", observed: "Message appeared in the conversation; use isn't confirmed",
  context_reserved: "Prepared for a later conversation; not yet confirmed there", labelled: "Agent renamed; the list may take a moment to update",
  work_assigned: "Task details saved; work hasn't necessarily started",
  abort_requested: "Asked to stop; existing changes aren't undone", settled: "That work has finished or stopped", completed: "Conversation loaded",
  cancelled: "Cancelled", expired: "Timed out. Check what happened before sending again.", rejected: 'Rejected', unknown: "Couldn't confirm what happened", assembling: "Loading conversation",
};
const pending = new Set(['queued', 'received', 'accepted', 'assembling', 'attempted', 'abort_requested', 'context_reserved']);
const encoder = new TextEncoder();
function pin(view, kind) {
  if (!view) return '';
  const b = view.binding;
  return JSON.stringify([b.agentId, b.sessionId, b.bindingId, b.runtimeGeneration, b.sessionGeneration, b.branchId,
    view.work.workId, b.workRevision, kind === 'interrupt' ? b.activeRunId : null]);
}

export function mountOperatorControls(doc, operator, onAttention = () => {}) {
  const el = id => doc.getElementById(id);
  const node = (tag, text) => { const n = doc.createElement(tag); n.textContent = text; return n; };
  const drafts = new Map(), outcomes = new Map(), unknownGuard = new Set(), outcomeRows = new Map(), owned = new Set();
  let selected = null, generation = 0, busy = false, polling = false, timer = null, hidden = doc.hidden;
  let kind = 'notice', message = '', nextLeaf = null, sessionOperation = null, sessionPage = null, displayedPage = null, lastSubmitted = null;
  const assignmentFields = ['workId', 'objective', 'phase', 'owner', 'currentStep', 'nextStep', 'project', 'parentWorkId', 'delegatedWorkId'];
  let assignmentAgent = '', assignmentPin = '', assignmentBase = null;
  const assignmentKey = () => selected ? `${selected.target.agentId}:workAssign` : '';
  function loadAssignment(fresh = false, empty = false) {
    const view = selected?.workView; if (!view) return;
    const stored = !fresh && drafts.get(assignmentKey());
    assignmentBase = stored ? JSON.parse(stored.text) : structuredClone(view.work);
    if (empty) { for (const key of Object.keys(assignmentBase)) assignmentBase[key] = key === 'evidence' ? [] : null; }
    assignmentAgent = view.binding.agentId; assignmentPin = stored ? stored.pin : pin(view, 'workAssign');
    for (const key of assignmentFields) el(`assign-${key}`).value = assignmentBase[key] ?? '';
  }
  function assignmentValue() {
    if (!assignmentBase) return null;
    const work = structuredClone(assignmentBase);
    for (const key of assignmentFields) work[key] = el(`assign-${key}`).value.trim() || null;
    return work;
  }
  function rememberAssignment() {
    if (!selected || assignmentAgent !== selected.target.agentId) return;
    const work = assignmentValue(); if (!work) return;
    const key = assignmentKey(); if (!drafts.has(key) && drafts.size >= 16) return;
    const text = JSON.stringify(work); if (encoder.encode(text).length <= 16384) drafts.set(key, { text, pin: assignmentPin });
  }
  const key = () => selected ? `${selected.target.agentId}:${kind}` : '';
  const draft = () => drafts.get(key());
  function resetTimer() { if (timer !== null) clearTimeout(timer); timer = null; }
  function remember() {
    if (!selected) return;
    const id = key();
    if (!drafts.has(id) && drafts.size >= 16) { message = "Too many saved drafts. Clear one before starting another."; return; }
    const previous = drafts.get(id);
    drafts.set(id, { text: el('operation-text').value, pin: previous?.pin ?? pin(selected.workView, kind) });
  }
  function render() {
    const view = selected?.workView;
    if (view && assignmentAgent !== view.binding.agentId) loadAssignment();
    const assignment = assignmentValue();
    const assignmentChanged = !!view && assignmentPin !== pin(view, 'workAssign');
    el('assignment-send').disabled = busy || !selected || selected.contextChanged || selected.availability !== 'present'
      || unknownGuard.has(selected.target.agentId) || !canAct(view, 'workAssign') || assignmentChanged || !assignment || !isWorkSnapshot(assignment)
      || encoder.encode(JSON.stringify(assignment)).length > 16384;
    el('assignment-status').textContent = assignmentChanged ? "The task changed. Reload its details before saving."
      : canAct(view, 'workAssign') ? "Save task details without starting work." : "The agent must allow task changes first. In its terminal, run /bus operator manage on.";
    const value = draft(), changed = !!value && value.pin !== pin(view, kind);
    const text = el('operation-text').value;
    const validText = kind === 'interrupt' ? encoder.encode(text).length <= 512
      : kind === 'label' ? Array.from(text.trim()).length > 0 && Array.from(text.trim()).length <= 200 && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(text.trim())
        : text.length > 0 && encoder.encode(text).length <= 16384;
    const available = !!selected && selected.availability === 'present' && !selected.contextChanged && canAct(view, kind);
    el('operation-send').textContent = labels[kind]; el('operation-send').disabled = busy || !available || changed || !validText || unknownGuard.has(selected?.target.agentId);
    el('operation-new-intent').hidden = !unknownGuard.has(selected?.target.agentId);
    el('operation-confirm-target').hidden = !changed; el('operation-confirm-target').disabled = !view || busy;
    const command = kind === 'notice' ? '/bus operator notices on' : kind === 'label' || kind === 'interrupt' ? '/bus operator manage on' : '/bus control on';
    el('operation-text-label').textContent = kind === 'label' ? 'New name' : kind === 'interrupt' ? 'Reason for stopping (optional)' : 'Message';
    el('operation-help').textContent = `${explanations[kind]}${view?.permissions.history ? ' Message text may be saved temporarily in history.' : ''}${available ? '' : ` To allow this action, run ${command} in the agent's terminal.`}`;
    el('operation-status').dataset.tone = outcomeTone(outcomes.get(lastSubmitted)?.state);
    el('operation-target').textContent = view ? `Agent ${view.binding.agentId} · task ${view.work.workId ?? 'not provided'} · conversation ${view.binding.sessionId}${kind === 'interrupt' ? ` · current work ${view.binding.activeRunId ?? 'none'}` : ''}${changed ? " · DETAILS CHANGED: check the agent and task before sending." : ''}` : "Choose an available agent first.";
    el('operation-status').textContent = message;
    el('session-read').disabled = busy || !selected || selected.contextChanged || selected.availability !== 'present' || !canAct(view, 'sessionRead');
    el('session-earlier').disabled = busy || !nextLeaf || !canAct(view, 'sessionRead');
    el('session-status').textContent = sessionPage
      ? `Saved conversation, not a live terminal. ${sessionPage.omitted} items left out.${sessionPage.truncated ? " Some text was shortened or left out. Earlier summaries aren't expanded." : ''}`
      : canAct(view, 'sessionRead') ? "Conversation access is allowed. Private reasoning and other files aren't shown."
        : "The agent must allow conversation access. In its terminal, run /bus operator read on. Private reasoning and other files aren't shown.";
    if (displayedPage !== sessionPage) {
      displayedPage = sessionPage;
      el('session-records').replaceChildren(...(sessionPage?.records ?? []).map(record => {
        const article = doc.createElement('article'); article.className = 'session-record';
        article.append(node('h4', record.role), node('pre', record.text)); return article;
      }));
    }
    renderOutcomes();
    onAttention([...outcomes.values()].filter(op => ['unknown', 'expired', 'rejected'].includes(op.state)));
  }
  function renderOutcomes() {
    const id = selected?.target.agentId;
    const items = [...outcomes.values()].filter(item => item.agentId === id).slice(-32).reverse();
    const root = el('operation-list'), wanted = new Set(items.map(item => item.operationId));
    const focus = doc.activeElement, hadFocus = root.contains(focus);
    for (const [id, row] of outcomeRows) if (!wanted.has(id)) { row.root.remove(); outcomeRows.delete(id); }
    for (const [index, item] of items.entries()) {
      let row = outcomeRows.get(item.operationId);
      if (!row) {
        const article = doc.createElement('article'); article.className = 'operation-outcome';
        const title = node('p', ''), identity = node('small', item.operationId), warning = node('p', "Already passed to the agent. Cancelling can't undo it.");
        const cancel = node('button', 'Cancel request'); cancel.type = 'button';
        cancel.addEventListener('click', () => { void cancelOperation(item.operationId); });
        const preview = doc.createElement('details'), previewText = node('pre', '');
        preview.append(node('summary', "Text you sent from this page"), previewText);
        article.append(title, identity, warning, cancel, preview); row = { root: article, title, warning, cancel, preview, previewText }; outcomeRows.set(item.operationId, row);
      }
      row.root.dataset.tone = outcomeTone(item.state);
      row.title.textContent = `${plainLabel(item.kind)} · ${states[item.state] ?? plainLabel(item.state)}${item.watchComplete ? " · no later update received" : ''}`;
      row.warning.hidden = !item.unsupportedWithdrawal;
      row.preview.hidden = typeof item.preview !== 'string'; row.previewText.textContent = item.preview ?? '';
      row.cancel.hidden = !pending.has(item.state) || item.watchComplete || !owned.has(item.operationId);
      row.cancel.textContent = item.kind === 'sessionRead' ? 'Cancel loading' : 'Cancel request';
      const position = root.children[index]; if (position !== row.root) root.insertBefore(row.root, position ?? null);
    }
    if (hadFocus) {
      if (!root.contains(focus) || focus.hidden) el('operation-list-refresh').focus();
      else if (doc.activeElement !== focus) focus.focus({ preventScroll: true });
    }
  }
  function retain(status) {
    if (!outcomes.has(status.operationId) && outcomes.size >= 32) {
      const removable = [...outcomes].find(([, value]) => !pending.has(value.state) || value.watchComplete);
      if (!removable) throw new Error('operation view capacity');
      outcomes.delete(removable[0]); owned.delete(removable[0]);
    }
    if (['unknown', 'expired'].includes(status.state)) unknownGuard.add(status.agentId);
    const { payload: _payload, ...metadata } = status;
    const copy = { ...metadata, page: null, preview: status.preview ?? outcomes.get(status.operationId)?.preview }; outcomes.set(status.operationId, copy);
    if (status.kind === 'sessionRead' && status.state === 'completed' && status.operationId === sessionOperation && status.page) {
      sessionPage = status.page; nextLeaf = status.page.nextLeafId;
    }
  }
  async function cancelOperation(id) {
    if (!owned.has(id)) return;
    const epoch = generation;
    try {
      const result = await operator.cancelOperation(id);
      if (epoch !== generation) return;
      retain(result); message = result.unsupportedWithdrawal ? "Already passed to the agent. It can't be taken back." : "Cancellation requested.";
    } catch { if (epoch === generation) message = "Couldn't confirm cancellation. We haven't tried again."; }
    if (epoch === generation) render();
  }
  let push = false, invalidated = false;
  function schedule() {
    resetTimer();
    if (!hidden && [...outcomes.values()].some(op => owned.has(op.operationId) && pending.has(op.state) && !op.watchComplete)) timer = setTimeout(() => { timer = null; void poll(); }, invalidated ? 250 : push ? 5000 : 1000);
  }
  async function poll() {
    if (polling || hidden) return;
    polling = true; invalidated = false; const epoch = generation;
    try {
      for (const op of [...outcomes.values()]) {
        if (epoch !== generation || hidden) return;
        if (!pending.has(op.state) || op.watchComplete || !owned.has(op.operationId)) continue;
        try {
          const status = await operator.operationStatus(op.operationId);
          if (epoch === generation) {
            retain({ ...status, watchComplete: ['received', 'context_reserved'].includes(status.state) && Date.now() > Number(status.deadline) + 5000 });
            if (status.operationId === lastSubmitted && status.agentId === selected?.target.agentId) {
              message = states[status.state] ?? status.state;
              if (!['unknown', 'expired'].includes(status.state)
                && ![...outcomes.values()].some(other => other.agentId === status.agentId && other.operationId !== status.operationId && ['unknown', 'expired'].includes(other.state))) {
                unknownGuard.delete(status.agentId);
                if (kind === status.kind && el('operation-text').value === op.preview) { drafts.delete(key()); el('operation-text').value = ''; }
              }
            }
          }
        }
        catch (error) {
          if (epoch !== generation) continue;
          if (error?.code === 'forbidden') {
            owned.delete(op.operationId);
            message = "This page can no longer change that request. Checking its status instead.";
            try {
              const list = await operator.operations(op.agentId);
              if (epoch === generation) { const found = list.find(item => item.operationId === op.operationId); if (found) retain(found); }
            } catch { if (epoch === generation) retain({ ...op, state: 'unknown' }); }
          } else if (Date.now() > Number(op.deadline) + 5000) retain(['received', 'context_reserved'].includes(op.state)
            ? { ...op, watchComplete: true } : { ...op, state: 'unknown' });
        }
      }
    } finally { polling = false; if (epoch === generation) render(); schedule(); }
  }
  async function submit(action, payload) {
    const target = selected?.workView;
    if (!target || busy || selected.contextChanged || selected.availability !== 'present' || !canAct(target, action)) return;
    const epoch = generation, expected = pin(target, action); busy = true; message = "Checking the agent and task…"; render();
    let intent;
    try {
      const fresh = await operator.work(target.binding.agentId);
      if (epoch !== generation) return;
      if (pin(fresh, action) !== expected) { message = "The agent or task changed. Refresh the details and check them before sending."; return; }
      intent = makeOperation(fresh, action, payload); owned.add(intent.operationId); lastSubmitted = intent.operationId;
      retain({ ...intent, state: 'queued', page: null, preview: payload.text ?? payload.label });
      if (action === 'sessionRead') sessionOperation = intent.operationId;
      message = "Sending your request. We'll show what the agent reports back."; render();
      const result = await operator.createOperation(intent);
      if (epoch !== generation) return;
      retain(result); message = states[result.state];
      if (action === 'workAssign') { drafts.delete(assignmentKey()); message = "Task update sent. Refresh its details to check it was saved."; }
      else if (action !== 'sessionRead') { drafts.delete(key()); el('operation-text').value = ''; }
    } catch (error) {
      if (epoch !== generation) return;
      if (intent && ['limit', 'schema', 'disconnected'].includes(error?.code)) {
        outcomes.delete(intent.operationId); owned.delete(intent.operationId); message = "Couldn't send this request. Check its contents, length and connection.";
      } else if (intent && ['rejected', 'forbidden', 'unauthorized'].includes(error?.code)) {
        retain({ ...intent, state: 'rejected', page: null }); message = "Request refused. We haven't tried again.";
      } else {
        if (intent) unknownGuard.add(intent.agentId);
        message = intent ? `Couldn't confirm request ${intent.operationId}. We'll check its status without sending it again.` : "Couldn't confirm the agent is available. Nothing was sent.";
      }
    } finally { if (epoch === generation) { busy = false; render(); schedule(); } }
  }
  for (const key of assignmentFields) el(`assign-${key}`).addEventListener(key === 'phase' ? 'change' : 'input', () => { rememberAssignment(); render(); });
  el('assignment-load').addEventListener('click', () => { drafts.delete(assignmentKey()); loadAssignment(true); render(); });
  el('assignment-new').addEventListener('click', () => { drafts.delete(assignmentKey()); loadAssignment(true, true); el('assign-workId').value = newOperationId(); rememberAssignment(); render(); });
  el('assignment-send').addEventListener('click', () => { if (!el('assignment-send').disabled) void submit('workAssign', { work: assignmentValue() }); });
  el('operation-text').addEventListener('input', () => { remember(); render(); });
  el('operation-kind').addEventListener('change', () => {
    remember(); kind = el('operation-kind').value; el('operation-text').value = draft()?.text ?? ''; message = ''; render();
  });
  el('operation-confirm-target').addEventListener('click', () => {
    const value = draft(); if (value && selected?.workView) value.pin = pin(selected.workView, kind); message = "Updated agent and task details confirmed."; render();
  });
  el('operation-clear').addEventListener('click', () => { drafts.delete(key()); el('operation-text').value = ''; message = ''; render(); });
  el('operation-new-intent').addEventListener('click', () => {
    if (selected) unknownGuard.delete(selected.target.agentId); message = "You can send another request. Earlier actions aren't undone."; render();
  });
  el('operation-send').addEventListener('click', () => {
    if (el('operation-send').disabled) return;
    const text = el('operation-text').value;
    const payload = kind === 'label' ? { label: text.trim() } : kind === 'interrupt' ? { reason: text || null } : { text };
    void submit(kind, payload);
  });
  el('session-read').addEventListener('click', () => { void submit('sessionRead', { leafId: null, limit: '64' }); });
  el('session-earlier').addEventListener('click', () => { if (nextLeaf) void submit('sessionRead', { leafId: nextLeaf, limit: '64' }); });
  el('operation-list-refresh').addEventListener('click', async () => {
    const id = selected?.target.agentId, epoch = generation; if (!id) return;
    try { const values = await operator.operations(id); if (epoch !== generation) return; for (const value of values) retain(value); render(); schedule(); }
    catch { if (epoch === generation) { message = "Couldn't load other requests."; render(); } }
  });
  function update(state, tab) {
    const changed = selected?.target.agentId !== state?.target.agentId || selected?.target.sessionId !== state?.target.sessionId;
    if (changed) {
      remember(); rememberAssignment(); generation++; assignmentAgent = ''; assignmentBase = null;
      for (const key of assignmentFields) el(`assign-${key}`).value = '';
      if (sessionOperation && pending.has(outcomes.get(sessionOperation)?.state)) void operator.cancelOperation(sessionOperation).catch(() => {});
      sessionOperation = null; sessionPage = null; nextLeaf = null; busy = false; selected = state;
      el('operation-text').value = draft()?.text ?? ''; message = '';
    } else selected = state;
    el('operator-session-panel').hidden = tab !== 'session';
    el('operator-composer').hidden = !state || tab === 'session' || tab === 'changes';
    el('more-actions').hidden = el('operator-composer').hidden;
    render(); schedule();
  }
  function disconnect() {
    generation++; resetTimer(); selected = null; drafts.clear(); outcomes.clear(); unknownGuard.clear(); owned.clear(); sessionOperation = null; lastSubmitted = null;
    sessionPage = null; nextLeaf = null; busy = false; message = ''; assignmentAgent = ''; assignmentBase = null;
    for (const key of assignmentFields) el(`assign-${key}`).value = '';
    el('operation-text').value = ''; render();
  }
  doc.addEventListener('visibilitychange', () => { hidden = doc.hidden; schedule(); });
  render();
  return { update, disconnect,
    invalidate() { if (invalidated) return; invalidated = true; schedule(); },
    setPush(value) { if (push === value) return; push = value; schedule(); },
  };
}
