import { decodeExactJson, DiscoveryError } from './protocol.js';

// Display names only. Wire values and permission checks stay unchanged.
export function plainLabel(value) {
  return ({ notice: 'Message', work: 'Work request', guidance: 'Guidance', label: 'Rename', interrupt: 'Stop request',
    sessionRead: 'Conversation', workAssign: 'Task update', queued: 'Waiting', accepted: 'Request received',
    received: 'Message received', attempted: 'Passed to agent', observed: 'Seen in conversation', context_reserved: 'Prepared for later',
    labelled: 'Renamed', work_assigned: 'Task saved', abort_requested: 'Asked to stop', settled: 'Finished or stopped',
    completed: 'Completed', cancelled: 'Cancelled', expired: 'Timed out', rejected: 'Refused', unknown: 'Not confirmed', assembling: 'Loading',
    planning: 'Planning', implementing: 'Working', verifying: 'Checking', waiting: 'Waiting', failed: 'Failed',
    mail_accepted: 'Message accepted', mail_dispatched: 'Delivery attempt', observation_lost: 'Missing history',
    work_reported: 'Task update', work_snapshot: 'Task update', run_reported: 'Work status', tool_reported: 'Tool activity',
    operator_requested: 'Dashboard request', operator_result: 'Request update', blocker_reported: 'Help needed', outcome_reported: 'Result shared',
    relay_observed: 'Server update', client_reported: 'Agent update',
    'work.report.v1': 'Task updates', 'work.assign.v1': 'Assign tasks', 'activity.report.v1': 'Activity updates',
    'session.current.read.v1': 'View conversation', 'notice.receive.v1': 'Receive messages', 'work.enqueue.v1': 'Accept work requests',
    'guidance.attempt.v1': 'Receive guidance', 'label.set.v1': 'Rename agent', 'run.interrupt.active.v1': 'Stop work' })[value] ?? value;
}

export const ACTION_CAPS = Object.freeze({ notice: 'notice.receive.v1', work: 'work.enqueue.v1', guidance: 'guidance.attempt.v1',
  label: 'label.set.v1', interrupt: 'run.interrupt.active.v1', sessionRead: 'session.current.read.v1', workAssign: 'work.assign.v1' });
export const ACTION_PERMISSIONS = Object.freeze({ notice: 'notice', work: 'work', guidance: 'guidance', label: 'label', interrupt: 'interrupt', sessionRead: 'sessionRead', workAssign: 'workAssign' });
export const OP_STATES = ['queued', 'accepted', 'received', 'rejected', 'assembling', 'attempted', 'observed', 'context_reserved',
  'labelled', 'work_assigned', 'abort_requested', 'settled', 'completed', 'cancelled', 'expired', 'unknown'];
const exact = (v, keys) => v !== null && typeof v === 'object' && !Array.isArray(v)
  && Object.keys(v).length === keys.length && keys.every(k => Object.hasOwn(v, k));
const uuid = v => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const uint = v => typeof v === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(v) && BigInt(v) <= 18446744073709551615n;
const handle = v => v === null || typeof v === 'string' && /^[A-Za-z0-9._-]{1,128}$/.test(v);
const encoder = new TextEncoder();
export function isProjection(p, sessionId) {
  return exact(p, ['schemaVersion', 'sessionId', 'leafId', 'nextLeafId', 'records', 'omitted', 'truncated'])
    && p.schemaVersion === 1 && p.sessionId === sessionId && handle(p.leafId) && handle(p.nextLeafId)
    && Number.isSafeInteger(p.omitted) && p.omitted >= 0 && typeof p.truncated === 'boolean'
    && Array.isArray(p.records) && p.records.length <= 64
    && p.records.every(r => exact(r, ['entryId', 'role', 'text']) && typeof r.entryId === 'string' && handle(r.entryId)
      && ['user', 'assistant', 'custom', 'tool-summary'].includes(r.role) && typeof r.text === 'string'
      && encoder.encode(r.text).length <= 16384)
    && encoder.encode(JSON.stringify(p)).length <= 524288;
}
function status(v) {
  return exact(v, ['schemaVersion', 'operationId', 'kind', 'agentId', 'sessionId', 'bindingId', 'runtimeGeneration',
    'sessionGeneration', 'branchId', 'runId', 'workId', 'state', 'createdAt', 'deadline', 'expiresAt', 'unsupportedWithdrawal', 'unsupported', 'page'])
    && v.schemaVersion === 1 && [v.operationId, v.agentId, v.sessionId, v.bindingId].every(uuid)
    && Object.hasOwn(ACTION_CAPS, v.kind) && OP_STATES.includes(v.state)
    && [v.runtimeGeneration, v.sessionGeneration, v.createdAt, v.deadline, v.expiresAt].every(uint)
    && handle(v.branchId) && (v.runId === null || uuid(v.runId)) && (v.workId === null || uuid(v.workId)) && typeof v.unsupportedWithdrawal === 'boolean'
    && Array.isArray(v.unsupported) && v.unsupported.length <= 32
    && v.unsupported.every(s => typeof s === 'string' && /^[a-z0-9_]{1,128}$/.test(s))
    && (v.page === null || v.kind === 'sessionRead' && v.state === 'completed' && isProjection(v.page, v.sessionId));
}
export function decodeOperation(bytes, operationId) {
  if (bytes.byteLength > 1048576) throw new DiscoveryError('limit');
  const v = decodeExactJson(bytes);
  if (!status(v) || v.operationId !== operationId) throw new DiscoveryError('schema');
  return v;
}
export function decodeOperations(bytes, agentId) {
  if (bytes.byteLength > 1048576) throw new DiscoveryError('limit');
  const v = decodeExactJson(bytes);
  if (!exact(v, ['schemaVersion', 'operations']) || v.schemaVersion !== 1 || !Array.isArray(v.operations)
    || v.operations.length > 128 || !v.operations.every(op => status(op) && op.agentId === agentId && op.page === null))
    throw new DiscoveryError('schema');
  return v.operations;
}
export function canAct(view, kind) {
  return !!view && view.binding.capabilities.includes(ACTION_CAPS[kind]) && view.permissions[ACTION_PERMISSIONS[kind]]
    && (kind !== 'sessionRead' || view.permissions.content) && (!['interrupt', 'guidance'].includes(kind) || view.binding.activeRunId !== null);
}
export function newOperationId() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
  const hex = [...bytes].map(b => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
export function makeOperation(view, kind, payload, operationId = newOperationId()) {
  if (!canAct(view, kind)) throw new DiscoveryError('forbidden');
  const b = view.binding;
  return { schemaVersion: 1, operationId, kind, agentId: b.agentId, bindingId: b.bindingId,
    runtimeGeneration: b.runtimeGeneration, sessionGeneration: b.sessionGeneration, branchId: b.branchId,
    runId: kind === 'interrupt' ? b.activeRunId : null, workId: view.work.workId, deadline: String(Date.now() + 25000), payload };
}
