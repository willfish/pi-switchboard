import { canAct, makeOperation, newOperationId } from './operator-actions.js';
import { isWorkSnapshot } from './operator-work.js';

const labels = { notice: 'Send notice', work: 'Ask to work', guidance: 'Send guidance', label: 'Set label', interrupt: 'Interrupt selected run' };
const explanations = {
  notice: 'Passive notice. It does not start a run. Receipt, context reservation and matching observation are separate.',
  work: 'A request that may start or queue work. SDK attempt is not proof of run start or model use.',
  guidance: 'Best-effort guidance. It cannot guarantee consumption by the selected run or withdraw an individual queued message.',
  label: 'Applied by the owning client, so heartbeat cannot overwrite a hub-only change.',
  interrupt: 'Requests cancellation of the selected run. It does not kill the process, undo edits or withdraw queued messages.',
};
const states = {
  queued: 'Accepted by hub; awaiting receiver', accepted: 'Received by client; effect not confirmed', received: 'Notice received, not a read receipt',
  attempted: 'SDK effect attempted, not proof of consumption', observed: 'Matching content observed, not proof of model use',
  context_reserved: 'Reserved for a later context, not proof of inclusion', labelled: 'Label applied by client; presence is separate',
  work_assigned: 'Work metadata applied by client, not proof of execution',
  abort_requested: 'Abort requested, not rollback', settled: 'Selected run settled', completed: 'Session projection complete',
  cancelled: 'Cancelled before completion', expired: 'Expired; do not resend automatically', rejected: 'Rejected', unknown: 'Outcome unknown', assembling: 'Collecting bounded session page',
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
    if (!drafts.has(id) && drafts.size >= 16) { message = 'Draft capacity reached. Clear an existing draft first.'; return; }
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
    el('assignment-status').textContent = assignmentChanged ? 'Assignment target changed. Load current assignment before applying.'
      : canAct(view, 'workAssign') ? 'Typed metadata update only. It does not start a run or prove completion.' : 'Requires local operator management permission: /bus operator manage on.';
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
    el('operation-help').textContent = `${explanations[kind]} ${view?.permissions.history ? 'Receiver is enrolled for volatile message previews; submitted text may be retained in operator history.' : 'Receiver is not enrolled for message preview history.'}${available ? '' : ` Receiver permission/capability is unavailable. Local permission command: ${command}. The browser cannot enable it.`}`;
    el('operation-target').textContent = view ? `Target ${view.binding.agentId} · work ${view.work.workId ?? 'not reported'} · session ${view.binding.sessionId}${kind === 'interrupt' ? ` · run ${view.binding.activeRunId ?? 'none'}` : ''}${changed ? ' · CONTEXT CHANGED: review and confirm before sending.' : ''}` : 'No current negotiated target.';
    el('operation-status').textContent = message;
    el('session-read').disabled = busy || !selected || selected.contextChanged || selected.availability !== 'present' || !canAct(view, 'sessionRead');
    el('session-earlier').disabled = busy || !nextLeaf || !canAct(view, 'sessionRead');
    el('session-status').textContent = sessionPage
      ? `Stored conversation projection, not a terminal mirror. ${sessionPage.omitted} omitted items.${sessionPage.truncated ? ' Content was truncated or omitted; compaction is not reconstructed.' : ''}`
      : 'Read access and explicit content enrollment are required. Enable locally with /bus operator read on. No arbitrary files or hidden reasoning are exported.';
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
        const title = node('p', ''), identity = node('small', item.operationId), warning = node('p', 'Already dispatched; cancellation cannot withdraw the SDK effect.');
        const cancel = node('button', 'Request cancellation'); cancel.type = 'button';
        cancel.addEventListener('click', () => { void cancelOperation(item.operationId); });
        const preview = doc.createElement('details'), previewText = node('pre', '');
        preview.append(node('summary', 'Text submitted from this page (not a receipt)'), previewText);
        article.append(title, identity, warning, cancel, preview); row = { root: article, title, warning, cancel, preview, previewText }; outcomeRows.set(item.operationId, row);
      }
      row.title.textContent = `${item.kind} · ${states[item.state] ?? item.state}${item.watchComplete ? ' · no later context report observed within the watch window' : ''}`;
      row.warning.hidden = !item.unsupportedWithdrawal;
      row.preview.hidden = typeof item.preview !== 'string'; row.previewText.textContent = item.preview ?? '';
      row.cancel.hidden = !pending.has(item.state) || item.watchComplete || !owned.has(item.operationId);
      row.cancel.textContent = item.kind === 'sessionRead' ? 'Cancel inspection' : 'Request cancellation';
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
      retain(result); message = result.unsupportedWithdrawal ? 'Already dispatched; the effect cannot be withdrawn.' : 'Cancellation recorded.';
    } catch { if (epoch === generation) message = 'Cancellation outcome unknown. It was not resent.'; }
    if (epoch === generation) render();
  }
  function schedule() {
    resetTimer();
    if (!hidden && [...outcomes.values()].some(op => owned.has(op.operationId) && pending.has(op.state) && !op.watchComplete)) timer = setTimeout(() => { timer = null; void poll(); }, 1000);
  }
  async function poll() {
    if (polling || hidden) return;
    polling = true; const epoch = generation;
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
            message = 'Original page-session ownership is unavailable; reconciling metadata only.';
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
    const epoch = generation, expected = pin(target, action); busy = true; message = 'Checking exact current target…'; render();
    let intent;
    try {
      const fresh = await operator.work(target.binding.agentId);
      if (epoch !== generation) return;
      if (pin(fresh, action) !== expected) { message = 'Target changed. Refresh work report, review the target and confirm again.'; return; }
      intent = makeOperation(fresh, action, payload); owned.add(intent.operationId); lastSubmitted = intent.operationId;
      retain({ ...intent, state: 'queued', page: null, preview: payload.text ?? payload.label });
      if (action === 'sessionRead') sessionOperation = intent.operationId;
      message = 'Submitting one operation. Acceptance is separate from its effect.'; render();
      const result = await operator.createOperation(intent);
      if (epoch !== generation) return;
      retain(result); message = states[result.state];
      if (action === 'workAssign') { drafts.delete(assignmentKey()); message = 'Assignment submitted; refresh work report for client acknowledgement.'; }
      else if (action !== 'sessionRead') { drafts.delete(key()); el('operation-text').value = ''; }
    } catch (error) {
      if (epoch !== generation) return;
      if (intent && ['limit', 'schema', 'disconnected'].includes(error?.code)) {
        outcomes.delete(intent.operationId); owned.delete(intent.operationId); message = 'Operation was not submitted: invalid, oversized or disconnected request.';
      } else if (intent && ['rejected', 'forbidden', 'unauthorized'].includes(error?.code)) {
        retain({ ...intent, state: 'rejected', page: null }); message = 'Operation rejected; no automatic retry.';
      } else {
        if (intent) unknownGuard.add(intent.agentId);
        message = intent ? `Outcome unknown for ${intent.operationId}. Only status reads will be retried, never the operation.` : 'Could not establish a current target. Nothing submitted.';
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
    const value = draft(); if (value && selected?.workView) value.pin = pin(selected.workView, kind); message = 'Current target confirmed.'; render();
  });
  el('operation-clear').addEventListener('click', () => { drafts.delete(key()); el('operation-text').value = ''; message = ''; render(); });
  el('operation-new-intent').addEventListener('click', () => {
    if (selected) unknownGuard.delete(selected.target.agentId); message = 'A new intent is allowed. Prior effects are not undone.'; render();
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
    catch { if (epoch === generation) { message = 'Shared activity unavailable.'; render(); } }
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
  return { update, disconnect };
}
