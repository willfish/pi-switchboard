import { exactKeys, isUuid } from './protocol.ts';
import type { OperatorBinding } from './operator-binding.ts';

export type ToolActivity = { id: string; toolCallId: string; toolName: string; state: 'started' | 'ended' | 'failed'; occurredAt: string };
export const OPERATION_KINDS = ['notice', 'work', 'guidance', 'label', 'interrupt', 'sessionRead', 'workAssign'] as const;
export type OperationKind = typeof OPERATION_KINDS[number];
export type OperationDescriptor = {
  schemaVersion: 1; operationId: string; kind: OperationKind; agentId: string; sessionId: string;
  bindingId: string; runtimeGeneration: string; sessionGeneration: string; branchId: string | null;
  runId: string | null; workId: string | null; deadline: string;
  content: { encoding: 'handle'; contentId: string; bytes: string };
};
export type OperationReport = {
  schemaVersion: 1; operationId: string; agentId: string; bindingId: string;
  runtimeGeneration: string; sessionGeneration: string;
} & ({ kind: 'receipt'; status: 'received' | 'rejected' }
  | { kind: 'result'; status: 'attempted' | 'observed' | 'labelled' | 'abort_requested' | 'settled' | 'unknown' | 'context_reserved' | 'work_assigned' }
  | { kind: 'fragment'; index: number; count: number; data: string; digest?: string });
export const operationStates = ['queued', 'accepted', 'received', 'rejected', 'assembling', 'attempted', 'observed',
  'labelled', 'work_assigned', 'abort_requested', 'settled', 'context_reserved', 'completed', 'cancelled', 'expired', 'unknown'] as const;
const uint = (v: unknown): v is string => typeof v === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(v)
  && BigInt(v) <= 18446744073709551615n;
const uuid = (v: unknown): v is string => typeof v === 'string' && isUuid(v);
export function isDescriptor(v: unknown): v is OperationDescriptor {
  return exactKeys(v, ['schemaVersion', 'operationId', 'kind', 'agentId', 'sessionId', 'bindingId',
    'runtimeGeneration', 'sessionGeneration', 'branchId', 'runId', 'workId', 'deadline', 'content'])
    && v.schemaVersion === 1 && [v.operationId, v.agentId, v.sessionId, v.bindingId].every(uuid)
    && typeof v.kind === 'string' && (OPERATION_KINDS as readonly string[]).includes(v.kind)
    && uint(v.runtimeGeneration) && uint(v.sessionGeneration) && uint(v.deadline)
    && (v.branchId === null || typeof v.branchId === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(v.branchId))
    && (v.runId === null || uuid(v.runId)) && (v.workId === null || uuid(v.workId))
    && exactKeys(v.content, ['encoding', 'contentId', 'bytes']) && v.content.encoding === 'handle'
    && uuid(v.content.contentId) && uint(v.content.bytes) && BigInt(v.content.bytes) <= 16384n
    && new TextEncoder().encode(JSON.stringify(v)).length <= 2048;
}
export function descriptorMatches(d: OperationDescriptor, binding: OperatorBinding): boolean {
  return d.agentId === binding.agentId && d.sessionId === binding.sessionId && d.bindingId === binding.bindingId
    && d.runtimeGeneration === binding.runtimeGeneration && d.sessionGeneration === binding.sessionGeneration
    && d.branchId === binding.branchId && (d.kind !== 'interrupt' || d.runId !== null && d.runId === binding.activeRunId);
}
export function reportBase(d: OperationDescriptor) {
  return { schemaVersion: 1 as const, operationId: d.operationId, agentId: d.agentId, bindingId: d.bindingId,
    runtimeGeneration: d.runtimeGeneration, sessionGeneration: d.sessionGeneration };
}
export function isRequests(v: unknown, agentId: string): v is { schemaVersion: 1; requests: OperationDescriptor[] } {
  if (!exactKeys(v, ['schemaVersion', 'requests']) || v.schemaVersion !== 1 || !Array.isArray(v.requests)
      || v.requests.length > 8 || !v.requests.every(isDescriptor)) return false;
  return v.requests.every(d => d.agentId === agentId) && new Set(v.requests.map(d => d.operationId)).size === v.requests.length
    && new TextEncoder().encode(JSON.stringify(v)).length <= 16384;
}
export function isOperationAck(v: unknown, operationId: string): v is { schemaVersion: 1; operationId: string; state: string } {
  return exactKeys(v, ['schemaVersion', 'operationId', 'state']) && v.schemaVersion === 1 && v.operationId === operationId
    && typeof v.state === 'string' && (operationStates as readonly string[]).includes(v.state);
}
