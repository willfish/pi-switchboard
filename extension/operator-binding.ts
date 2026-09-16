import { exactKeys, isUuid, MAX_ENVELOPE_BYTES } from './protocol.ts';
import { isWorkSnapshot, type WorkSnapshot } from './operator-protocol.ts';

export const OPERATOR_CAPABILITIES = [
  'work.report.v1', 'work.assign.v1', 'activity.report.v1', 'session.current.read.v1', 'notice.receive.v1', 'work.enqueue.v1',
  'guidance.attempt.v1', 'label.set.v1', 'run.interrupt.active.v1',
] as const;
export type OperatorCapability = typeof OPERATOR_CAPABILITIES[number];
export const PERMISSION_KEYS = ['notice', 'work', 'guidance', 'sessionRead', 'label', 'interrupt', 'content', 'workAssign', 'history'] as const;
export type OperatorPermissions = Record<typeof PERMISSION_KEYS[number], boolean>;
export type RegistrationIdentity = { epoch: string; generation: string };
export type OperatorAnnouncement = {
  schemaVersion: 1; agentId: string; sessionId: string;
  runtimeGeneration: string; sessionGeneration: string; branchId: string | null; activeRunId: string | null;
  registration: RegistrationIdentity | null; permissionRevision: string; reportRevision: string;
  capabilities: OperatorCapability[]; permissions: OperatorPermissions; work: WorkSnapshot;
};
export type OperatorBinding = Omit<OperatorAnnouncement, 'permissions' | 'work' | 'registration'> & {
  registration: RegistrationIdentity; bindingId: string; workRevision: string;
};
const encoder = new TextEncoder();
const uint = (v: unknown): v is string => typeof v === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(v)
  && BigInt(v) <= 18446744073709551615n;
const uuid = (v: unknown): v is string => typeof v === 'string' && isUuid(v);
const branch = (v: unknown): v is string | null => v === null || typeof v === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(v);
function registration(v: unknown): v is RegistrationIdentity {
  return exactKeys(v, ['epoch', 'generation']) && uuid(v.epoch) && uint(v.generation);
}
function capabilities(v: unknown): v is OperatorCapability[] {
  return Array.isArray(v) && v.length <= OPERATOR_CAPABILITIES.length && new Set(v).size === v.length
    && v.every(c => typeof c === 'string' && (OPERATOR_CAPABILITIES as readonly string[]).includes(c));
}
function permissions(v: unknown): v is OperatorPermissions {
  return exactKeys(v, [...PERMISSION_KEYS]) && PERMISSION_KEYS.every(key => typeof v[key] === 'boolean');
}
function context(v: Record<string, unknown>): boolean {
  return v.schemaVersion === 1 && uuid(v.agentId) && uuid(v.sessionId)
    && uint(v.runtimeGeneration) && uint(v.sessionGeneration) && uint(v.permissionRevision) && uint(v.reportRevision)
    && branch(v.branchId) && (v.activeRunId === null || uuid(v.activeRunId)) && capabilities(v.capabilities);
}
export function isAnnouncement(v: unknown): v is OperatorAnnouncement {
  return exactKeys(v, ['schemaVersion', 'agentId', 'sessionId', 'runtimeGeneration', 'sessionGeneration',
    'branchId', 'activeRunId', 'registration', 'permissionRevision', 'reportRevision', 'capabilities', 'permissions', 'work'])
    && context(v) && (v.registration === null || registration(v.registration))
    && permissions(v.permissions)
    && isWorkSnapshot(v.work) && encoder.encode(JSON.stringify(v)).length <= MAX_ENVELOPE_BYTES;
}
export function isBindingFor(v: unknown, request: OperatorAnnouncement): v is OperatorBinding {
  if (!exactKeys(v, ['schemaVersion', 'agentId', 'sessionId', 'runtimeGeneration', 'sessionGeneration',
    'branchId', 'activeRunId', 'registration', 'permissionRevision', 'reportRevision', 'capabilities', 'bindingId', 'workRevision'])
    || !context(v) || !registration(v.registration) || !uuid(v.bindingId) || !uint(v.workRevision)
    || !capabilities(v.capabilities)) return false;
  for (const key of ['agentId', 'sessionId', 'runtimeGeneration', 'sessionGeneration', 'branchId', 'activeRunId', 'permissionRevision', 'reportRevision'] as const)
    if (v[key] !== request[key]) return false;
  if (request.registration && (v.registration.epoch !== request.registration.epoch
    || v.registration.generation !== request.registration.generation)) return false;
  return v.capabilities.every(c => request.capabilities.includes(c));
}
export function encodeAnnouncement(value: unknown): Uint8Array {
  if (!isAnnouncement(value)) throw new Error('invalid operator announcement');
  return encoder.encode(JSON.stringify(value));
}
