import { createHash } from 'node:crypto';
import type { ExtensionAPI, ExtensionContext, MessageStartEvent } from '@earendil-works/pi-coding-agent';
import type { HubClient } from './client.ts';
import type { OperatorBinding, OperatorPermissions, OperatorCapability } from './operator-binding.ts';
import { descriptorMatches, reportBase, type OperationDescriptor, type OperationReport, type ToolActivity } from './operator-operations.ts';
import { createSessionProjection } from './operator-session-projection.ts';
import { isWorkSnapshot, type WorkSnapshot } from './operator-protocol.ts';

export type OperatorContext = {
  binding?: OperatorBinding; ctx: ExtensionContext; permissions: OperatorPermissions;
  sessionGeneration: string; branchId: string | null; runId: string | null; workId: string | null; active: boolean;
};
const encoder = new TextEncoder();
const permission = { notice: 'notice', work: 'work', guidance: 'guidance', label: 'label', interrupt: 'interrupt', sessionRead: 'sessionRead', workAssign: 'workAssign' } as const;
export const bridgeCapabilities: OperatorCapability[] = ['work.report.v1', 'work.assign.v1', 'activity.report.v1', 'notice.receive.v1', 'work.enqueue.v1',
  'guidance.attempt.v1', 'label.set.v1', 'run.interrupt.active.v1', 'session.current.read.v1'];

export function createOperatorBridge(options: {
  client: HubClient; pi: ExtensionAPI; current(): OperatorContext;
  setLabel(label: string): string; assignWork(work: WorkSnapshot): boolean; now?: () => number; wall?: () => number; uuid?: () => string;
}) {
  const now = options.now ?? (() => performance.now()), wall = options.wall ?? Date.now;
  const lifetime = new AbortController();
  const projection = createSessionProjection({ now, uuid: options.uuid });
  const seen = new Map<string, number>();
  const pendingInputs = new Map<string, { descriptor: OperationDescriptor; text: string }>();
  const pendingInterrupts = new Map<string, OperationDescriptor>();
  const noticeBatches = new Map<string, OperationDescriptor[]>();
  const resultFlights = new Map<string, Promise<unknown>>();
  const notices: { descriptor: OperationDescriptor; text: string }[] = [];
  const activityQueue: { event: ToolActivity; context: string }[] = [];
  const toolContexts = new Map<string, string>(); let droppedActivity = 0n;
  const contextKey = () => { const c = options.current(); return JSON.stringify([c.ctx.sessionManager.getSessionId(), c.sessionGeneration, c.branchId]); };
  let stopped = false, flight: Promise<void> | null = null;
  function alive(d: OperationDescriptor): boolean {
    const c = options.current();
    return !stopped && c.active && !!c.binding && descriptorMatches(d, c.binding)
      && c.ctx.sessionManager.getSessionId() === d.sessionId && c.sessionGeneration === d.sessionGeneration
      && c.branchId === d.branchId && c.workId === d.workId && c.permissions[permission[d.kind]]
      && (d.kind !== 'sessionRead' || c.permissions.content)
      && (d.kind !== 'interrupt' || d.runId !== null && c.runId === d.runId && !c.ctx.isIdle())
      && (d.kind !== 'guidance' || !c.ctx.isIdle()) && BigInt(d.deadline) > BigInt(Math.floor(wall()));
  }
  function report(d: OperationDescriptor, status: Extract<OperationReport, { kind: 'result' }>['status']) {
    if (stopped || resultFlights.size >= 32 && !resultFlights.has(d.operationId)) return;
    const prior = resultFlights.get(d.operationId) ?? Promise.resolve();
    const own = prior.catch(() => {}).then(() => stopped ? undefined
      : options.client.operatorReport!({ ...reportBase(d), kind: 'result', status }, lifetime.signal));
    resultFlights.set(d.operationId, own);
    void own.finally(() => { if (resultFlights.get(d.operationId) === own) resultFlights.delete(d.operationId); }).catch(() => {});
  }
  async function reject(d: OperationDescriptor) {
    await options.client.operatorReport!({ ...reportBase(d), kind: 'receipt', status: 'rejected' }, lifetime.signal);
  }
  async function execute(d: OperationDescriptor) {
    if (seen.has(d.operationId)) return;
    if (!alive(d) || seen.size >= 4096 || (d.kind === 'notice' && notices.length >= 32)
      || ((d.kind === 'work' || d.kind === 'guidance') && pendingInputs.size >= 1)) { await reject(d); return; }
    // Reserve before any asynchronous work or synchronous SDK reentrancy.
    seen.set(d.operationId, now() + 120000);
    const result = await options.client.operatorContent!(d, lifetime.signal);
    if (result.status !== 'ok' || !alive(d)) { await reject(d); return; }
    const received = await options.client.operatorReport!({ ...reportBase(d), kind: 'receipt', status: 'received' }, lifetime.signal);
    if (received.status !== 'ok' || !['received', 'accepted', 'assembling'].includes(received.state)) return;
    if (!alive(d)) { report(d, 'unknown'); return; }
    const c = options.current();
    try {
      if (d.kind === 'notice') {
        notices.push({ descriptor: d, text: `[Network-authorized operator notice ${d.operationId}]\n${result.body}` });
        c.ctx.ui.notify('Switchboard: operator notice received. It will be reserved for a later run.', 'info');
      } else if (d.kind === 'work' || d.kind === 'guidance') {
        const text = `[Network-authorized operator ${d.kind} ${d.operationId}]\n${result.body}`;
        pendingInputs.set(d.operationId, { descriptor: d, text });
        // Queue the result before SDK callbacks can synchronously observe input;
        // the actual HTTP dispatch is a later microtask, after the SDK attempt.
        report(d, 'attempted');
        options.pi.sendUserMessage(text, { deliverAs: d.kind === 'guidance' ? 'steer' : 'followUp', expandPromptTemplates: false });
      } else if (d.kind === 'label') {
        const label = options.setLabel(result.body);
        report(d, label === result.body.trim() ? 'labelled' : 'unknown');
      } else if (d.kind === 'workAssign') {
        const work = JSON.parse(result.body);
        if (!isWorkSnapshot(work)) throw new Error('invalid work assignment');
        report(d, options.assignWork(work) ? 'work_assigned' : 'unknown');
      } else if (d.kind === 'interrupt') {
        pendingInterrupts.set(d.operationId, d);
        report(d, 'abort_requested');
        c.ctx.abort();
      } else {
        const args = JSON.parse(result.body) as { leafId: string | null; limit: string };
        if ((args.leafId !== null && (typeof args.leafId !== 'string' || args.leafId.length > 128))
          || !/^(?:[1-9]|[1-5][0-9]|6[0-4])$/.test(args.limit)) throw new Error('invalid session request');
        const page = projection.read(c.ctx, c.sessionGeneration, args.leafId, Number(args.limit));
        const bytes = encoder.encode(JSON.stringify(page));
        const digest = createHash('sha256').update(bytes).digest('hex');
        const count = Math.ceil(bytes.length / 16384);
        for (let index = 0; index < count; index++) {
          if (!alive(d)) { report(d, 'unknown'); return; }
          const data = Buffer.from(bytes.subarray(index * 16384, (index + 1) * 16384)).toString('base64');
          const uploaded = await options.client.operatorReport!({ ...reportBase(d), kind: 'fragment', index, count, data,
            ...(index === count - 1 ? { digest } : {}) }, lifetime.signal);
          if (uploaded.status !== 'ok') return;
        }
      }
    } catch { report(d, 'unknown'); }
  }
  async function poll() {
    const at = now();
    for (const [id, expires] of seen) if (expires <= at) { seen.delete(id); pendingInputs.delete(id); pendingInterrupts.delete(id); }
    const c = options.current();
    if (stopped || !c.active || !c.binding) return;
    if (c.binding.capabilities.some(cap => cap !== 'work.report.v1' && cap !== 'activity.report.v1')) {
      const response = await options.client.operatorRequests!(c.binding.agentId, lifetime.signal);
      if (stopped) return;
      if (response.status === 'ok') for (const descriptor of response.requests) {
        if (stopped) return;
        try { await execute(descriptor); } catch { /* Never replay an uncertain effect. */ }
      }
    }
    const observed = options.current();
    if (!stopped && observed.active && observed.binding?.capabilities.includes('activity.report.v1') && (activityQueue.length || droppedActivity)) {
      const captured = activityQueue.splice(0, 32), key = contextKey();
      const events = captured.filter(item => item.context === key).map(item => item.event);
      droppedActivity += BigInt(captured.length - events.length);
      const dropped = droppedActivity; droppedActivity = 0n;
      const result = await options.client.operatorActivity!(observed.binding, events, String(dropped), lifetime.signal);
      if (result.status !== 'ok') droppedActivity += dropped + BigInt(events.length);
    }
  }
  function tick(): Promise<void> {
    if (stopped) return Promise.resolve();
    if (flight) return flight;
    const own = poll(); flight = own;
    void own.finally(() => { if (flight === own) flight = null; }).catch(() => {});
    return own;
  }
  function takeNotices(maxBytes = 32768) {
    if (!options.current().permissions.notice) { notices.length = 0; return ''; }
    const selected: typeof notices = []; let text = '';
    while (notices.length) {
      const next = notices[0];
      const joined = text ? `${text}\n\n${next.text}` : next.text;
      if (encoder.encode(joined).length > maxBytes) break;
      notices.shift(); selected.push(next); text = joined;
    }
    if (text) {
      if (noticeBatches.size >= 32) noticeBatches.delete(noticeBatches.keys().next().value!);
      noticeBatches.set(text, selected.map(v => v.descriptor));
      for (const item of selected) report(item.descriptor, 'context_reserved');
    }
    return text;
  }
  function message(message: MessageStartEvent['message']) {
    let text: string | undefined;
    if (message.role === 'user' || message.role === 'custom') text = typeof message.content === 'string' ? message.content
      : message.content.every(v => v.type === 'text') ? message.content.map(v => v.type === 'text' ? v.text : '').join('') : undefined;
    if (text === undefined) return;
    if (message.role === 'user') for (const [id, item] of pendingInputs) if (item.text === text) {
      report(item.descriptor, 'observed'); pendingInputs.delete(id);
    }
    if (message.role === 'custom' && message.customType === 'agent-bus-mail') {
      const batch = noticeBatches.get(text);
      if (batch) { for (const d of batch) report(d, 'observed'); noticeBatches.delete(text); }
    }
  }
  function settled(runId: string | null) {
    if (!runId) return;
    for (const [id, d] of pendingInterrupts) if (d.runId === runId) { report(d, 'settled'); pendingInterrupts.delete(id); }
  }
  function activity(toolCallId: string, toolName: string, state: ToolActivity['state']) {
    if (stopped || !options.current().active) return;
    const context = contextKey();
    if (typeof toolCallId !== 'string' || typeof toolName !== 'string' || !toolCallId || !toolName
      || encoder.encode(toolCallId).length > 256 || encoder.encode(toolName).length > 128) { droppedActivity++; return; }
    if (state === 'started') {
      if (toolContexts.size >= 32) { droppedActivity++; return; }
      toolContexts.set(toolCallId, context);
    } else {
      const original = toolContexts.get(toolCallId); toolContexts.delete(toolCallId);
      if (original !== context) { droppedActivity++; return; }
    }
    if (activityQueue.length >= 32) { droppedActivity++; return; }
    activityQueue.push({ context, event: { id: (options.uuid ?? (() => crypto.randomUUID()))(), toolCallId, toolName,
      state, occurredAt: String(Math.floor(wall())) } });
  }
  function stop() {
    stopped = true; lifetime.abort(); projection.clear(); notices.length = 0;
    pendingInputs.clear(); pendingInterrupts.clear(); noticeBatches.clear(); resultFlights.clear(); seen.clear();
    activityQueue.length = 0; toolContexts.clear();
  }
  return { tick, takeNotices, message, settled, activity, stop, revoke: () => projection.clear() };
}
