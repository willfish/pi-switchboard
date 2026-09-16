import { decodeExactJson, DiscoveryError } from './protocol.js';

export const WORK_VIEW_BYTES = 65536;
const encoder = new TextEncoder();
const exact = (v, keys) => v !== null && typeof v === 'object' && !Array.isArray(v)
  && Object.keys(v).length === keys.length && keys.every(k => Object.hasOwn(v, k));
const uuid = v => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const uint = v => typeof v === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(v) && BigInt(v) <= 18446744073709551615n;
const text = (v, cap = 2048) => typeof v === 'string' && v.length > 0 && encoder.encode(v).length <= cap;
const caps = ['work.report.v1', 'work.assign.v1', 'activity.report.v1', 'session.current.read.v1', 'notice.receive.v1', 'work.enqueue.v1',
  'guidance.attempt.v1', 'label.set.v1', 'run.interrupt.active.v1'];
const permissionKeys = ['notice', 'work', 'guidance', 'sessionRead', 'label', 'interrupt', 'content', 'workAssign', 'history'];
const workKeys = ['workId', 'objective', 'phase', 'currentStep', 'nextStep', 'owner', 'blocker', 'project',
  'repository', 'branch', 'worktree', 'parentWorkId', 'delegatedWorkId', 'evidence'];
export function isWorkSnapshot(v) {
  return exact(v, workKeys)
    && ['workId', 'parentWorkId', 'delegatedWorkId'].every(k => v[k] === null || uuid(v[k]))
    && ['objective', 'currentStep', 'nextStep', 'project', 'repository', 'branch', 'worktree'].every(k => v[k] === null || text(v[k]))
    && (v.owner === null || text(v.owner, 200))
    && (v.phase === null || ['planning', 'implementing', 'verifying', 'waiting', 'completed', 'failed'].includes(v.phase))
    && (v.blocker === null || exact(v.blocker, ['kind', 'reason'])
      && ['blocked', 'decision'].includes(v.blocker.kind) && text(v.blocker.reason))
    && Array.isArray(v.evidence) && v.evidence.length <= 8
    && v.evidence.every(e => exact(e, ['kind', 'ref']) && ['file', 'test', 'commit', 'artifact'].includes(e.kind) && text(e.ref, 512))
    && encoder.encode(JSON.stringify(v)).length <= 32768;
}
function binding(v, agentId) {
  return exact(v, ['schemaVersion', 'agentId', 'sessionId', 'runtimeGeneration', 'sessionGeneration',
    'branchId', 'activeRunId', 'registration', 'permissionRevision', 'reportRevision', 'capabilities', 'bindingId', 'workRevision'])
    && v.schemaVersion === 1 && v.agentId === agentId && uuid(v.agentId) && uuid(v.sessionId) && uuid(v.bindingId) && (v.activeRunId === null || uuid(v.activeRunId))
    && ['runtimeGeneration', 'sessionGeneration', 'permissionRevision', 'reportRevision', 'workRevision'].every(k => uint(v[k]))
    && (v.branchId === null || typeof v.branchId === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(v.branchId))
    && exact(v.registration, ['epoch', 'generation']) && uuid(v.registration.epoch) && uint(v.registration.generation)
    && Array.isArray(v.capabilities) && v.capabilities.length <= caps.length && new Set(v.capabilities).size === v.capabilities.length
    && v.capabilities.every(c => caps.includes(c));
}
export function workCursor(snapshotId, page) {
  return btoa(`${snapshotId}:${page}`).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}
export function decodeWorkPage(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.byteLength > 1048576) throw new DiscoveryError('limit');
  const p = decodeExactJson(bytes);
  if (!exact(p, ['epoch', 'snapshotId', 'revision', 'capturedAt', 'page', 'total', 'snapshots', 'nextCursor'])
      || !uuid(p.epoch) || !uuid(p.snapshotId) || !uint(p.revision)
      || !Number.isSafeInteger(p.capturedAt) || p.capturedAt < 0
      || !Number.isSafeInteger(p.page) || p.page < 0 || p.page >= 5000
      || !Number.isSafeInteger(p.total) || p.total < 0 || p.total > 5000
      || !Array.isArray(p.snapshots) || p.snapshots.length > 128
      || (p.nextCursor !== null && p.nextCursor !== workCursor(p.snapshotId, p.page + 1)))
    throw new DiscoveryError('schema');
  let previous = '';
  for (const item of p.snapshots) {
    const id = item?.binding?.agentId;
    decodeWorkView(encoder.encode(JSON.stringify(item)), id);
    if (id <= previous) throw new DiscoveryError('schema');
    previous = id;
  }
  return p;
}

export function decodeWorkView(bytes, agentId) {
  if (!(bytes instanceof Uint8Array) || bytes.byteLength > WORK_VIEW_BYTES) throw new DiscoveryError('limit');
  const v = decodeExactJson(bytes);
  if (!exact(v, ['binding', 'work', 'permissions']) || !binding(v.binding, agentId) || !isWorkSnapshot(v.work)
      || !exact(v.permissions, permissionKeys) || !permissionKeys.every(k => typeof v.permissions[k] === 'boolean'))
    throw new DiscoveryError('schema');
  return v;
}
