import { decodeExactJson, DiscoveryError } from './protocol.js';
import { isWorkSnapshot } from './operator-work.js';
import { ACTION_CAPS, OP_STATES } from './operator-actions.js';

export const EVENT_LIMITS = Object.freeze({ pageBytes: 1048576, pageRecords: 128, bodyBytes: 16384 });
const encoder = new TextEncoder();
const uuid = v => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const uint = v => typeof v === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(v)
  && BigInt(v) <= 18446744073709551615n;
const exact = (v, required, optional = []) => v !== null && typeof v === 'object' && !Array.isArray(v)
  && required.every(k => Object.hasOwn(v, k)) && Object.keys(v).every(k => required.includes(k) || optional.includes(k));
const text = (v, max) => typeof v === 'string' && v.length > 0 && encoder.encode(v).length <= max;
const fail = (code = 'schema') => { throw new DiscoveryError(code); };
const ids = ['agentId', 'sessionId', 'workId', 'threadId', 'operationId'];

export function eventCursor(epoch, sequence) {
  if (!uuid(epoch) || !uint(sequence)) fail();
  return btoa(`${epoch}:${sequence}`).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function payload(event) {
  const p = event.payload;
  switch (event.kind) {
    case 'mail_accepted':
    case 'mail_dispatched': {
      const accepted = event.kind === 'mail_accepted';
      const fields = ['id', 'from', 'to', 'kind'];
      if (accepted) fields.push('acceptedAt', 'receiving', 'bodyBytes');
      return event.source === 'relay_observed'
        && exact(p, fields, accepted ? ['body'] : ['bodyBytes', 'body'])
        && ['id', 'from', 'to'].every(k => uuid(p[k]))
        && ['notice', 'prompt', 'steer'].includes(p.kind)
        && (!accepted || ((p.acceptedAt === null || uint(p.acceptedAt)) && typeof p.receiving === 'boolean'))
        && (!Object.hasOwn(p, 'bodyBytes') || (Number.isSafeInteger(p.bodyBytes) && p.bodyBytes >= 0 && p.bodyBytes <= 32768))
        && (!Object.hasOwn(p, 'body') || text(p.body, EVENT_LIMITS.bodyBytes));
    }
    case 'observation_lost':
      return event.source === 'relay_observed' && exact(p, ['count']) && uint(p.count);
    case 'work_snapshot':
      return event.source === 'client_reported' && isWorkSnapshot(p) && event.workId === p.workId;
    case 'run_reported':
      return event.source === 'client_reported' && exact(p, ['activeRunId']) && (p.activeRunId === null || uuid(p.activeRunId));
    case 'tool_reported':
      return event.source === 'client_reported' && exact(p, ['toolCallId', 'toolName', 'state'])
        && text(p.toolCallId, 256) && text(p.toolName, 128) && ['started', 'ended', 'failed'].includes(p.state);
    case 'operator_requested':
    case 'operator_result':
      return (event.kind === 'operator_requested' ? event.source === 'operator_requested' : ['client_reported', 'relay_observed'].includes(event.source))
        && exact(p, ['action', 'state'], event.kind === 'operator_requested' ? ['body'] : [])
        && (!Object.hasOwn(p, 'body') || text(p.body, EVENT_LIMITS.bodyBytes))
        && Object.hasOwn(ACTION_CAPS, p.action) && OP_STATES.includes(p.state)
        && uuid(event.operationId) && uuid(event.agentId);
    case 'work_reported':
      return event.source === 'client_reported' && uuid(event.workId) && exact(p, ['objective', 'phase'])
        && text(p.objective, 2048) && ['planning', 'implementing', 'verifying', 'waiting', 'completed', 'failed'].includes(p.phase);
    case 'blocker_reported':
      return event.source === 'client_reported' && uuid(event.workId) && exact(p, ['reason']) && text(p.reason, 2048);
    case 'outcome_reported':
      return event.source === 'client_reported' && uuid(event.workId) && exact(p, ['outcome'])
        && ['completed', 'failed'].includes(p.outcome);
    default: return false;
  }
}

export function isOperatorEvent(event) {
  return exact(event, ['schemaVersion', 'epoch', 'sequence', 'eventId', 'observedAt', 'occurredAt',
    'source', 'kind', ...ids, 'payload']) && event.schemaVersion === 1
    && uuid(event.epoch) && uuid(event.eventId) && uint(event.sequence) && uint(event.observedAt)
    && (event.occurredAt === null || uint(event.occurredAt))
    && ids.every(k => event[k] === null || uuid(event[k])) && payload(event);
}

// Validate the complete page before exposing any records to the view. No
// conversion of uint64 counters/timestamps to lossy JavaScript Numbers.
export function decodeSearchPage(bytes, prior = null) {
  if (!(bytes instanceof Uint8Array) || bytes.byteLength > EVENT_LIMITS.pageBytes) fail('limit');
  const p = decodeExactJson(bytes);
  if (!exact(p, ['epoch', 'events', 'nextCursor', 'scannedThrough', 'throughSequence', 'coverage'])
      || !uuid(p.epoch) || !uint(p.scannedThrough) || !uint(p.throughSequence)
      || BigInt(p.scannedThrough) > BigInt(p.throughSequence)
      || !['empty', 'live', 'truncated'].includes(p.coverage)
      || !Array.isArray(p.events) || p.events.length > 128
      || (p.nextCursor !== null && (typeof p.nextCursor !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(p.nextCursor)))) fail();
  if ((p.nextCursor === null) !== (p.scannedThrough === p.throughSequence)) fail();
  if (prior && (p.epoch !== prior.epoch || p.throughSequence !== prior.throughSequence
      || BigInt(p.scannedThrough) <= BigInt(prior.scannedThrough))) fail('history');
  let previous = prior ? BigInt(prior.scannedThrough) : -1n;
  for (const event of p.events) {
    if (!isOperatorEvent(event) || event.epoch !== p.epoch || BigInt(event.sequence) <= previous
      || BigInt(event.sequence) > BigInt(p.scannedThrough)) fail();
    previous = BigInt(event.sequence);
  }
  return p;
}

export function decodeEventPage(bytes, requestedCursor = 'first') {
  if (!(bytes instanceof Uint8Array)) fail();
  if (bytes.byteLength > EVENT_LIMITS.pageBytes) fail('limit');
  const p = decodeExactJson(bytes);
  if (!exact(p, ['epoch', 'fromSequence', 'toSequence', 'retainedFrom', 'coverage', 'caughtUp', 'nextCursor', 'events'])
      || !uuid(p.epoch) || ![p.fromSequence, p.toSequence, p.retainedFrom].every(uint)
      || !['live', 'truncated', 'empty'].includes(p.coverage) || typeof p.caughtUp !== 'boolean'
      || !Array.isArray(p.events) || p.events.length > EVENT_LIMITS.pageRecords) fail();
  if (requestedCursor !== 'first' && eventCursor(p.epoch, p.fromSequence) !== requestedCursor) fail();
  const from = BigInt(p.fromSequence), to = BigInt(p.toSequence), floor = BigInt(p.retainedFrom);
  if (to < from || to - from !== BigInt(p.events.length) || floor > from + 1n) fail();
  if (p.coverage === 'empty' && (p.events.length !== 0 || floor !== to || !p.caughtUp)) fail();
  if (p.coverage === 'live' && floor !== 1n) fail();
  if (p.coverage === 'truncated' && floor <= 1n) fail();
  if (p.caughtUp ? p.nextCursor !== null
    : p.events.length === 0 || p.nextCursor !== eventCursor(p.epoch, p.toSequence)) fail();
  const seen = new Set();
  for (const [index, event] of p.events.entries()) {
    if (!isOperatorEvent(event) || event.epoch !== p.epoch || BigInt(event.sequence) !== from + BigInt(index) + 1n
        || seen.has(event.eventId)) fail();
    seen.add(event.eventId);
  }
  return p;
}
