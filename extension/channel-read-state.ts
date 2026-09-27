import { CHANNEL_NAME, type ChannelMessage, type ChannelPage } from "./channels.ts";

export const SCOPE_ENTRY = "agent-bus-scope";
export const MAX_CHECKPOINTS = 128;
export const MAX_TRACKED_READS = 128;
export const CACHE_MESSAGE_LIMIT = 24;
export const CACHE_RETENTION_SECONDS = 86400;
export const CACHE_BYTE_LIMIT = 32 * 1024 * 1024;

export type ChannelReadMode = "recent" | "new";
export type ReturnedCheckpoint = { epoch: string; after: string };
export type ReadTicket = { channel: string; context: number; request: number };
export type MessageReference = { channel: string; from: string; id: string };

const SEQ = /^(0|[1-9][0-9]{0,19})$/;

/** Decimal order only. Global sequence numbers are not per-channel or contiguous. */
export function compareSequence(left: string, right: string): number {
  if (!SEQ.test(left) || !SEQ.test(right)) return Number.NaN;
  if (left.length !== right.length) return left.length < right.length ? -1 : 1;
  return left < right ? -1 : left > right ? 1 : 0;
}

export function messagesOrdered(messages: readonly { seq: string }[]): boolean {
  for (let index = 1; index < messages.length; index += 1) {
    if (!(compareSequence(messages[index - 1].seq, messages[index].seq) < 0)) return false;
  }
  return messages.every(message => SEQ.test(message.seq));
}

type BusyRead = { ticket: ReadTicket; mode: ChannelReadMode; epoch?: string; sequences: readonly string[] };

export type ChannelReadState = {
  context: number;
  nextRequest: number;
  checkpoints: Map<string, ReturnedCheckpoint>;
  busy: Map<string, BusyRead>;
};

/** Pure. The runtime must pass a context nonce that never restarts across run replacement. */
export function emptyChannelReadState(context = 1): ChannelReadState {
  return { context, nextRequest: 0, checkpoints: new Map(), busy: new Map() };
}

/** Drops returned-context checkpoints and in-flight tokens. Does not touch registration generation. */
export function invalidateChannelReads(state: ChannelReadState, context = state.context + 1): ChannelReadState {
  return { context, nextRequest: state.nextRequest, checkpoints: new Map(), busy: new Map() };
}

export function coordinationScopeFromBranch(entries: readonly { type?: string; customType?: string; data?: unknown }[]): string | null {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry?.type !== "custom" || entry.customType !== SCOPE_ENTRY) continue;
    const data = entry.data;
    if (!data || typeof data !== "object" || !("channel" in data)) return null;
    const channel = (data as { channel: unknown }).channel;
    return typeof channel === "string" && CHANNEL_NAME.test(channel) ? channel : null;
  }
  return null;
}

/** Explicit scope replaces the cwd default. General is always included. Null keeps the cwd default. */
export function backgroundChannelNames(area: string, scope: string | null): string[] {
  if (scope && CHANNEL_NAME.test(scope)) return scope === "general" ? ["general"] : ["general", scope];
  return area === "general" ? ["general"] : ["general", area];
}

export function attemptReference(channel: string, from: string, id: string): MessageReference {
  return { channel, from, id };
}

export function beginTrackedRead(state: ChannelReadState, channel: string, mode: ChannelReadMode = "recent"):
  | { ok: true; state: ChannelReadState; ticket: ReadTicket }
  | { ok: false; reason: "channel read in progress" | "channel read limit" } {
  if (state.busy.has(channel)) return { ok: false, reason: "channel read in progress" };
  if (state.busy.size >= MAX_TRACKED_READS || state.nextRequest >= Number.MAX_SAFE_INTEGER) return { ok: false, reason: "channel read limit" };
  const request = state.nextRequest + 1;
  const ticket: ReadTicket = { channel, context: state.context, request };
  const busy = new Map(state.busy);
  busy.set(channel, { ticket, mode, sequences: [] });
  return { ok: true, ticket, state: { ...state, nextRequest: request, busy } };
}

export function releaseChannelRead(state: ChannelReadState, ticket: ReadTicket): ChannelReadState {
  const current = state.busy.get(ticket.channel);
  if (!current || current.ticket.context !== ticket.context || current.ticket.request !== ticket.request) return state;
  const busy = new Map(state.busy);
  busy.delete(ticket.channel);
  return { ...state, busy };
}

export function readAfter(state: ChannelReadState, channel: string, mode: ChannelReadMode, track: boolean): string {
  if (!track || mode !== "new") return "0";
  return state.checkpoints.get(channel)?.after ?? "0";
}

export type ReadAssessment =
  | { kind: "deliver"; reset: boolean }
  | { kind: "refetch" }
  | { kind: "fail"; reason: "malformed channel page" | "channel epoch changed" | "channel read invalidated" };

function ticketCurrent(state: ChannelReadState, ticket: ReadTicket | undefined): boolean {
  if (!ticket || ticket.context !== state.context) return false;
  const busy = state.busy.get(ticket.channel);
  return !!busy && busy.ticket.context === ticket.context && busy.ticket.request === ticket.request;
}

export function assessRead(state: ChannelReadState, ticket: ReadTicket | undefined, mode: ChannelReadMode, page: ChannelPage, phase: "primary" | "tail"): ReadAssessment {
  if (ticket && !ticketCurrent(state, ticket)) return { kind: "fail", reason: "channel read invalidated" };
  if (!messagesOrdered(page.messages)) return { kind: "fail", reason: "malformed channel page" };
  if (!ticket) return { kind: "deliver", reset: false };
  const checkpoint = state.checkpoints.get(ticket.channel);
  if (phase === "primary" && mode === "new" && checkpoint && checkpoint.after !== "0" && page.epoch !== checkpoint.epoch) return { kind: "refetch" };
  return { kind: "deliver", reset: phase === "tail" || (!!checkpoint && page.epoch !== checkpoint.epoch) };
}

export function assessTail(state: ChannelReadState, ticket: ReadTicket, page: ChannelPage, observedEpoch: string): ReadAssessment {
  if (!ticketCurrent(state, ticket)) return { kind: "fail", reason: "channel read invalidated" };
  if (!messagesOrdered(page.messages)) return { kind: "fail", reason: "malformed channel page" };
  if (page.epoch !== observedEpoch) return { kind: "fail", reason: "channel epoch changed" };
  return { kind: "deliver", reset: true };
}

export function noteDelivery(state: ChannelReadState, ticket: ReadTicket, page: ChannelPage): ChannelReadState {
  const current = state.busy.get(ticket.channel);
  if (!current || !ticketCurrent(state, ticket)) return state;
  const busy = new Map(state.busy);
  busy.set(ticket.channel, { ticket, mode: current.mode, epoch: page.epoch, sequences: page.messages.map(message => message.seq) });
  return { ...state, busy };
}

function storeCheckpoint(state: ChannelReadState, channel: string, checkpoint: ReturnedCheckpoint): ChannelReadState {
  const checkpoints = new Map(state.checkpoints);
  checkpoints.delete(channel);
  checkpoints.set(channel, checkpoint);
  while (checkpoints.size > MAX_CHECKPOINTS) {
    const oldest = checkpoints.keys().next().value;
    if (oldest === undefined) break;
    checkpoints.delete(oldest);
  }
  return { ...state, checkpoints };
}

/**
 * A string advances only a canonical nonzero sequence from the delivered page.
 * null completes a confirmed empty page only: same epoch retains the prior boundary;
 * a different epoch stores { epoch, after: "0" } and does not invent a message sequence.
 * null on a nonempty page, "", "0", a foreign epoch, or a stale ticket does not advance.
 * new mode rejects a same-epoch boundary behind the checkpoint. recent mode may reset that boundary to its emitted prefix.
 * A matching ticket is released even when rejected. A stale ticket does not release a newer read.
 */
export function commitChannelRead(state: ChannelReadState, ticket: ReadTicket, epoch: string, returnedThrough: string | null): { state: ChannelReadState; accepted: boolean } {
  if (!ticketCurrent(state, ticket)) return { state, accepted: false };
  const delivered = state.busy.get(ticket.channel);
  const released = releaseChannelRead(state, ticket);
  if (!delivered || delivered.epoch !== epoch) return { state: released, accepted: false };
  const previous = released.checkpoints.get(ticket.channel);
  if (returnedThrough === null) {
    if (delivered.sequences.length !== 0) return { state: released, accepted: false };
    if (previous && previous.epoch === epoch) return { state: released, accepted: true };
    return { state: storeCheckpoint(released, ticket.channel, { epoch, after: "0" }), accepted: true };
  }
  const canonical = SEQ.test(returnedThrough) && returnedThrough !== "0" && delivered.sequences.includes(returnedThrough);
  const behind = !!previous && previous.epoch === epoch && compareSequence(returnedThrough, previous.after) < 0;
  if (!canonical || (behind && delivered.mode !== "recent")) {
    return { state: released, accepted: false };
  }
  if (previous && previous.epoch === epoch && returnedThrough === previous.after) return { state: released, accepted: true };
  return { state: storeCheckpoint(released, ticket.channel, { epoch, after: returnedThrough }), accepted: true };
}

export type OperatorCache = { epoch?: string; pages: Record<string, ChannelPage>; after: Record<string, string> };

function nameRecord<T>(): Record<string, T> {
  return Object.create(null) as Record<string, T>;
}

function copyNameRecord<T>(source: Record<string, T>): Record<string, T> {
  const copy = nameRecord<T>();
  for (const key of Object.keys(source)) copy[key] = source[key];
  return copy;
}

export function emptyOperatorCache(): OperatorCache {
  return { pages: nameRecord(), after: nameRecord() };
}

/** Missing names, including constructor, are absent. Inherited properties are not cursors. */
export function cachedAfter(cache: OperatorCache, name: string): string {
  return Object.hasOwn(cache.after, name) ? cache.after[name] : "0";
}

/** Drop operator pages and cursors outside the selected background names. Epoch is unchanged. */
export function pruneOperatorCache(cache: OperatorCache, names: readonly string[]): OperatorCache {
  const allowed = new Set(names);
  const pages = nameRecord<ChannelPage>();
  const after = nameRecord<string>();
  for (const name of Object.keys(cache.pages)) if (allowed.has(name)) pages[name] = cache.pages[name];
  for (const name of Object.keys(cache.after)) if (allowed.has(name)) after[name] = cache.after[name];
  return { epoch: cache.epoch, pages, after };
}

export type CacheLimits = { messages: number; bytes: number };

function bodyBytes(message: ChannelMessage): number {
  return new TextEncoder().encode(message.body).length;
}

function pruneMessages(messages: readonly ChannelMessage[], page: ChannelPage, nowSeconds: number, limits: CacheLimits): ChannelMessage[] {
  const incoming = new Set(page.messages.map(message => message.seq));
  const retained = messages.filter(message => {
    if (incoming.has(message.seq)) return false;
    if (page.retainedFrom !== "0" && compareSequence(message.seq, page.retainedFrom) < 0) return false;
    if (page.retainedTo !== "0" && compareSequence(page.retainedTo, message.seq) < 0) return false;
    if (message.postedAt + CACHE_RETENTION_SECONDS <= nowSeconds) return false;
    return SEQ.test(message.seq);
  });
  const ordered = [...retained, ...page.messages].sort((left, right) => compareSequence(left.seq, right.seq));
  const unique: ChannelMessage[] = [];
  for (const message of ordered) {
    if (unique.at(-1)?.seq === message.seq) unique[unique.length - 1] = message;
    else unique.push(message);
  }
  let bytes = unique.reduce((sum, message) => sum + bodyBytes(message), 0);
  while (unique.length > limits.messages || (unique.length > 1 && bytes > limits.bytes)) {
    const dropped = unique.shift();
    if (!dropped) break;
    bytes -= bodyBytes(dropped);
  }
  if (unique.length === 1 && bytes > limits.bytes) unique.shift();
  return unique;
}

function cachedPage(page: ChannelPage, messages: ChannelMessage[], coverage: ChannelPage["coverage"]): ChannelPage {
  const fromSequence = messages[0]?.seq ?? "0";
  const toSequence = messages.at(-1)?.seq ?? "0";
  const earlier = fromSequence !== "0" && page.retainedFrom !== "0" && compareSequence(page.retainedFrom, fromSequence) < 0;
  const caughtUp = messages.length === 0 ? page.messages.length === 0 && page.caughtUp : page.retainedTo === "0" || compareSequence(toSequence, page.retainedTo) >= 0;
  return {
    ...page,
    fromSequence,
    toSequence,
    coverage,
    earlier,
    caughtUp,
    nextCursor: caughtUp ? null : toSequence,
    earlierCursor: earlier ? fromSequence : null,
    messages,
  };
}

/** Background/operator cache only. Explicit reads must not call this. */
export function applyOperatorCache(cache: OperatorCache, name: string, page: ChannelPage, nowSeconds: number, limits: CacheLimits = { messages: CACHE_MESSAGE_LIMIT, bytes: CACHE_BYTE_LIMIT }): { cache: OperatorCache; applied: boolean } {
  if (!messagesOrdered(page.messages) || page.channel !== name) return { cache, applied: false };
  const base: OperatorCache = cache.epoch && cache.epoch !== page.epoch
    ? { epoch: page.epoch, pages: nameRecord(), after: nameRecord() }
    : { epoch: page.epoch, pages: copyNameRecord(cache.pages), after: copyNameRecord(cache.after) };
  const previous = Object.hasOwn(base.pages, name) ? base.pages[name] : undefined;
  const emptyJournal = page.messages.length === 0 && page.retainedFrom === "0" && page.retainedTo === "0";
  const retainedHistory = page.retainedFrom !== "0" || page.retainedTo !== "0";
  let messages: ChannelMessage[];
  let coverage: ChannelPage["coverage"];
  if (emptyJournal || page.coverage === "gap" || !previous) {
    messages = pruneMessages(page.coverage === "gap" || emptyJournal ? [] : page.messages, page, nowSeconds, limits);
    coverage = page.coverage === "gap" ? "gap" : messages.length === 0 ? "empty" : "complete";
  } else if (page.messages.length === 0) {
    messages = pruneMessages(previous.messages, page, nowSeconds, limits);
    if (messages.length === 0 && retainedHistory) coverage = "gap";
    else if (messages.length === 0) coverage = "empty";
    else coverage = previous.coverage === "gap" ? "gap" : "complete";
  } else {
    messages = pruneMessages(previous.messages, page, nowSeconds, limits);
    coverage = previous.coverage === "gap" ? "gap"
      : messages.length === 0 && retainedHistory ? "gap"
      : messages.length === 0 ? "empty" : "complete";
  }
  const stored = cachedPage(page, messages, coverage);
  base.pages[name] = stored;
  if (emptyJournal) delete base.after[name];
  else if (stored.toSequence !== "0") base.after[name] = stored.toSequence;
  return { cache: base, applied: true };
}
