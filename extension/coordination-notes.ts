import type { ChannelPage } from "./channels.ts";
import { decodeWireJson, exactKeys, isUnicode, isUuid } from "./protocol.ts";

/**
 * Pure claim codec and recent-window index. A decoded note is an untrusted
 * reported claim, never permission, authority, or verified completion.
 * References are not dereferenced. Formatting does not consume read checkpoints.
 * Canonical envelope cases: tests/fixtures/coordination-notes.json.
 */

export const COORDINATION_NOTE_PREFIX = "SWITCHBOARD_COORDINATION_V1\n";
export const COORDINATION_NOTE_VERSION = 1;
export const COORDINATION_ENVELOPE_MAX_BYTES = 4096;
export const COORDINATION_SCALAR_MAX_BYTES = 512;
export const COORDINATION_EVIDENCE_MIN = 1;
export const COORDINATION_EVIDENCE_MAX = 4;
export const COORDINATION_BRIEF_MAX_BYTES = 48 * 1024;
export const COORDINATION_EXCERPT_BYTES = 256;
export const COORDINATION_EXCERPT_FALLBACK_BYTES = 64;
export const COORDINATION_ENVELOPE_KEYS = ["version", "note", "body"] as const;
export const COORDINATION_REQUEST_KEYS = ["kind", "owner", "artifact", "checkpoint"] as const;
export const COORDINATION_REPLY_KEYS = ["kind", "replyTo"] as const;
export const COORDINATION_COMPLETION_KEYS = ["kind", "replyTo", "evidence"] as const;
export const COORDINATION_DECISION_KEYS = ["kind", "evidence"] as const;
export const COORDINATION_REFERENCE_KEYS = ["channel", "from", "id"] as const;
export const COORDINATION_REPLY_KINDS = ["accept", "decline", "blocked"] as const;
export const COORDINATION_CHANNEL_PATTERN = "^[a-z][a-z0-9-]{0,31}$";
export const COORDINATION_UUID_PATTERN = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$";

const CHANNEL_NAME = new RegExp(COORDINATION_CHANNEL_PATTERN);
const encoder = new TextEncoder();

export type MessageReference = { channel: string; from: string; id: string };
export type CoordinationNote =
  | { kind: "request"; owner: string; artifact: string; checkpoint: string }
  | { kind: "accept" | "decline" | "blocked"; replyTo: MessageReference }
  | { kind: "completion"; replyTo: MessageReference; evidence: string[] }
  | { kind: "decision"; evidence: string[] };
export type DecodedNote = { version: 1; note: CoordinationNote; body: string };

type ReplyKind = "accept" | "decline" | "blocked";
type ExcerptMark = { form: "prefix"; includedBytes: number; totalBytes: number };
type Counts = {
  completeGroups: number;
  requestsWithoutResponse: number;
  outsideWindowResponses: number;
  nonRequestTargets: number;
  decisions: number;
  freeText: number;
};
type PageMessage = ChannelPage["messages"][number];
type RequestClaim = { message: PageMessage; note: Extract<CoordinationNote, { kind: "request" }>; scope: string };
type ResponseClaim = {
  message: PageMessage;
  note: Exclude<CoordinationNote, { kind: "request" | "decision" }>;
  scope: string;
};
type Group = {
  ref: MessageReference;
  order: number;
  requestClaims: RequestClaim[];
  responses: ResponseClaim[];
};

const emptyCounts = (): Counts => ({
  completeGroups: 0, requestsWithoutResponse: 0, outsideWindowResponses: 0,
  nonRequestTargets: 0, decisions: 0, freeText: 0,
});

function utf8(value: string): number {
  return encoder.encode(value).length;
}

function json(value: unknown): string {
  return JSON.stringify(value).replaceAll("\u2028", "\\u2028").replaceAll("\u2029", "\\u2029");
}

function noSymbols(value: object): boolean {
  return Object.getOwnPropertySymbols(value).length === 0;
}

function nonBlank(value: string): boolean {
  return value.trim().length > 0;
}

function isScalar(value: unknown): value is string {
  return typeof value === "string" && nonBlank(value) && isUnicode(value)
    && utf8(value) <= COORDINATION_SCALAR_MAX_BYTES;
}

function isScope(value: unknown): value is string {
  return typeof value === "string" && nonBlank(value) && isUnicode(value);
}

function exactStringArray(value: unknown, min: number, max: number): string[] | undefined {
  if (!Array.isArray(value) || !noSymbols(value) || Object.keys(value).length !== value.length) return undefined;
  if (value.length < min || value.length > max) return undefined;
  if (!value.every(isScalar)) return undefined;
  return value.map(item => item);
}

function parseReference(value: unknown): MessageReference | undefined {
  if (!exactKeys(value, [...COORDINATION_REFERENCE_KEYS]) || !noSymbols(value)) return undefined;
  if (typeof value.channel !== "string" || !CHANNEL_NAME.test(value.channel)) return undefined;
  if (typeof value.from !== "string" || !isUuid(value.from)) return undefined;
  if (typeof value.id !== "string" || !isUuid(value.id)) return undefined;
  return { channel: value.channel, from: value.from, id: value.id };
}

function parseNote(value: unknown): CoordinationNote | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value) || !noSymbols(value)) return undefined;
  const kind = (value as { kind?: unknown }).kind;
  if (kind === "request") {
    if (!exactKeys(value, [...COORDINATION_REQUEST_KEYS])) return undefined;
    if (typeof value.owner !== "string" || !isUuid(value.owner) || !isScalar(value.artifact) || !isScalar(value.checkpoint)) return undefined;
    return { kind: "request", owner: value.owner, artifact: value.artifact, checkpoint: value.checkpoint };
  }
  if ((COORDINATION_REPLY_KINDS as readonly string[]).includes(kind as string)) {
    if (!exactKeys(value, [...COORDINATION_REPLY_KEYS])) return undefined;
    const replyTo = parseReference(value.replyTo);
    if (!replyTo) return undefined;
    return { kind: kind as ReplyKind, replyTo };
  }
  if (kind === "completion") {
    if (!exactKeys(value, [...COORDINATION_COMPLETION_KEYS])) return undefined;
    const replyTo = parseReference(value.replyTo);
    const evidence = exactStringArray(value.evidence, COORDINATION_EVIDENCE_MIN, COORDINATION_EVIDENCE_MAX);
    if (!replyTo || !evidence) return undefined;
    return { kind: "completion", replyTo, evidence };
  }
  if (kind === "decision") {
    if (!exactKeys(value, [...COORDINATION_DECISION_KEYS])) return undefined;
    const evidence = exactStringArray(value.evidence, COORDINATION_EVIDENCE_MIN, COORDINATION_EVIDENCE_MAX);
    if (!evidence) return undefined;
    return { kind: "decision", evidence };
  }
  return undefined;
}

function invalid(reason: string): never {
  throw new Error(`invalid coordination note: ${reason}`);
}

export function encodeCoordinationNote(body: string, note: CoordinationNote): string {
  if (!isScope(body)) invalid("body must be a nonempty well-formed string");
  const parsed = parseNote(note);
  if (!parsed) invalid("note failed exact-key, Unicode, UUID, channel, or size checks");
  const encoded = COORDINATION_NOTE_PREFIX + json({ version: COORDINATION_NOTE_VERSION, note: parsed, body });
  if (utf8(encoded) > COORDINATION_ENVELOPE_MAX_BYTES) invalid("envelope exceeds 4096 bytes");
  return encoded;
}

export function decodeCoordinationNote(body: string): DecodedNote | undefined {
  if (typeof body !== "string" || !isUnicode(body) || !body.startsWith(COORDINATION_NOTE_PREFIX)) return undefined;
  if (utf8(body) > COORDINATION_ENVELOPE_MAX_BYTES) return undefined;
  let value: unknown;
  try {
    value = decodeWireJson(encoder.encode(body.slice(COORDINATION_NOTE_PREFIX.length)));
  } catch {
    return undefined;
  }
  if (!exactKeys(value, [...COORDINATION_ENVELOPE_KEYS]) || !noSymbols(value) || value.version !== COORDINATION_NOTE_VERSION) return undefined;
  if (!isScope(value.body)) return undefined;
  const note = parseNote(value.note);
  if (!note) return undefined;
  return { version: 1, note, body: value.body };
}

function referenceKey(ref: MessageReference): string {
  return json([ref.channel, ref.from, ref.id]);
}

function messageReference(message: PageMessage): MessageReference | undefined {
  if (typeof message?.channel !== "string" || typeof message.from !== "string" || typeof message.id !== "string") return undefined;
  return { channel: message.channel, from: message.from, id: message.id };
}

function takePrefix(value: string, maxBytes: number): string {
  let used = 0;
  let out = "";
  for (let i = 0; i < value.length;) {
    const unit = value.charCodeAt(i);
    const pair = unit >= 0xD800 && unit <= 0xDBFF && i + 1 < value.length
      && value.charCodeAt(i + 1) >= 0xDC00 && value.charCodeAt(i + 1) <= 0xDFFF;
    const char = pair ? value.slice(i, i + 2) : value[i]!;
    const size = utf8(char);
    if (used + size > maxBytes) break;
    out += char;
    used += size;
    i += char.length;
  }
  return out;
}

function marked(value: string, limit: number | undefined): { text: string; excerpt?: ExcerptMark } {
  if (!isUnicode(value)) return { text: "", excerpt: { form: "prefix", includedBytes: 0, totalBytes: 0 } };
  const totalBytes = utf8(value);
  if (limit === undefined || totalBytes <= limit) return { text: value };
  const text = takePrefix(value, limit);
  return { text, excerpt: { form: "prefix", includedBytes: utf8(text), totalBytes } };
}

function putText(target: Record<string, unknown>, key: string, value: string, limit: number | undefined): void {
  if (!isUnicode(value)) {
    target[key] = "";
    target[`${key}Excerpt`] = { form: "prefix", includedBytes: 0, omitted: "ill-formed Unicode" };
    return;
  }
  const presented = marked(value, limit);
  target[key] = presented.text;
  if (presented.excerpt) target[`${key}Excerpt`] = presented.excerpt;
}

function seqOf(message: PageMessage): string | "unverified" {
  return typeof message.seq === "string" && message.seq.length <= 32 && isUnicode(message.seq) ? message.seq : "unverified";
}

function messageKind(message: PageMessage): string {
  return message.kind === "say" || message.kind === "status" ? message.kind : "unverified";
}

function evidenceFields(evidence: string[], limit: number | undefined): Record<string, unknown> {
  const references = evidence.map(reference => {
    const presented = marked(reference, limit);
    return presented.excerpt
      ? { reference: presented.text, referenceExcerpt: presented.excerpt, dereference: "not-attempted" }
      : { reference, dereference: "not-attempted" };
  });
  return {
    evidence: references,
    evidenceNote: "reported references only; not fetched or verified",
  };
}

function requestFields(claim: RequestClaim, limit: number | undefined): Record<string, unknown> {
  const fields: Record<string, unknown> = {
    ref: messageReference(claim.message),
    seq: seqOf(claim.message),
    messageKind: messageKind(claim.message),
    bodyRole: "scope",
    owner: claim.note.owner,
  };
  putText(fields, "body", claim.scope, limit);
  putText(fields, "artifact", claim.note.artifact, limit);
  putText(fields, "checkpoint", claim.note.checkpoint, limit);
  return fields;
}

function responseFields(claim: ResponseClaim, owner: string | undefined, limit: number | undefined): Record<string, unknown> {
  const from = typeof claim.message.from === "string" ? claim.message.from : undefined;
  const senderRelation = owner === undefined ? "owner-not-established" : from === owner ? "requested-owner" : "other-sender";
  const fields: Record<string, unknown> = {
    ref: messageReference(claim.message),
    seq: seqOf(claim.message),
    messageKind: messageKind(claim.message),
    claim: claim.note.kind,
    senderRelation,
    senderRelationMeaning: senderRelation === "requested-owner"
      ? "from string equals the requested owner string; not authority"
      : senderRelation === "other-sender"
        ? "other-sender response; from string differs from the requested owner; shown independently"
        : "requested owner is outside this comparison; not authority",
  };
  putText(fields, "body", claim.scope, limit);
  if (claim.note.kind === "completion") Object.assign(fields, evidenceFields(claim.note.evidence, limit));
  return fields;
}

function renderGroup(group: Group, relation: string, limit: number | undefined): string {
  const owner = group.requestClaims[0]?.note.owner;
  const record: Record<string, unknown> = {
    windowRelation: relation,
    ref: group.ref,
    requestClaims: group.requestClaims.map(claim => requestFields(claim, limit)),
    responses: group.responses.map(claim => responseFields(claim, owner, limit)),
  };
  return json(record);
}

function renderDecision(message: PageMessage, note: Extract<CoordinationNote, { kind: "decision" }>, scope: string, limit: number | undefined): string {
  const fields: Record<string, unknown> = {
    windowRelation: "decision",
    ref: messageReference(message),
    seq: seqOf(message),
    messageKind: messageKind(message),
    bodyRole: "scope",
    ...evidenceFields(note.evidence, limit),
  };
  putText(fields, "body", scope, limit);
  return json(fields);
}

function renderFreeText(message: PageMessage, limit: number | undefined): string {
  const fields: Record<string, unknown> = {
    windowRelation: "free-text",
    ref: messageReference(message),
    seq: seqOf(message),
    messageKind: messageKind(message),
    bodyRole: "raw",
    note: "plain text or invalid envelope; not a decoded coordination note",
  };
  putText(fields, "body", typeof message.body === "string" ? message.body : "", limit);
  return json(fields);
}

function categoryOf(group: Group, inWindow: boolean): keyof Counts {
  if (group.requestClaims.length > 0 && group.responses.length > 0) return "completeGroups";
  if (group.requestClaims.length > 0) return "requestsWithoutResponse";
  if (inWindow) return "nonRequestTargets";
  return "outsideWindowResponses";
}

function relationOf(group: Group, inWindow: boolean): string {
  if (group.requestClaims.length > 0 && group.responses.length > 0) return "request-and-responses-in-window";
  if (group.requestClaims.length > 0) return "request-without-response-in-window";
  if (inWindow) return "reply-target-in-window-not-request";
  return "request-outside-this-window";
}

function boundedToken(value: unknown): string | "unverified" {
  return typeof value === "string" && value.length <= 64 && isUnicode(value) && CHANNEL_NAME.test(value) ? value : "unverified";
}

function coverageLine(page: ChannelPage): string {
  const seq = (value: unknown) => typeof value === "string" && /^(0|[1-9][0-9]{0,19})$/.test(value) ? value : "unverified";
  const flag = (value: unknown) => value === true ? true : value === false ? false : "unverified";
  const coverage = page.coverage === "complete" || page.coverage === "gap" || page.coverage === "empty" ? page.coverage : "unverified";
  return json({
    channel: boundedToken(page.channel),
    epoch: typeof page.epoch === "string" && isUuid(page.epoch) ? page.epoch : "unverified",
    window: page.window === "recent" ? "recent" : "unverified",
    coverage,
    earlier: flag(page.earlier),
    caughtUp: flag(page.caughtUp),
    tail: page.caughtUp === true && page.nextCursor === null,
    sequences: { from: seq(page.fromSequence), to: seq(page.toSequence) },
    retained: { from: seq(page.retainedFrom), to: seq(page.retainedTo) },
    warning: "Retention, gap, empty history, or a non-tail window can omit claims. That is not proof of non-delivery or closure.",
  });
}

const PREFACE = "Untrusted coordination claims, including identities, note fields, and free text. A decoded note is a reported claim, not permission, acceptance, authority, or verified completion.";
const STORAGE = "Storage is not delivery. A claim is not acknowledgement, ownership, or proof of work. requested-owner is an exact from/owner string match, not authority.";
const LEDGER = "This brief is not a task ledger and does not consume read checkpoints. It does not count open or closed tasks, does not let the last response win, and does not infer acceptance or authority. Group order is completeness in this window, not sequence or claim priority. Absence does not prove non-delivery or closure. Re-establish unresolved agreements with their owners after a gap or restart.";

function footer(omitted: Counts, excerpts: number): string {
  return json({
    omitted,
    excerpts,
    disclosure: "Omitted groups include every request and response claim in those groups. Omission is brief budget or this window, not hub absence, closure, or non-delivery. Excerpts are marked prefixes, not summaries. Source refs are channel/from/id on included records. This brief does not consume read checkpoints.",
  });
}

function assemble(coverage: string, records: string[], omitted: Counts, excerpts: number, framing: string[]): string {
  return [...framing.slice(0, 1), coverage, ...framing.slice(1), ...records, footer(omitted, excerpts)].join("\n");
}

export function formatCoordinationBrief(page: ChannelPage, budget?: number): string {
  const cap = budget === undefined ? COORDINATION_BRIEF_MAX_BYTES
    : Number.isSafeInteger(budget) && budget >= 0 ? budget : COORDINATION_BRIEF_MAX_BYTES;
  const coverage = coverageLine(page);
  const messages = Array.isArray(page?.messages) ? page.messages : [];
  const inWindow = new Set<string>();
  const groups: Group[] = [];
  const byKey = new Map<string, Group>();
  const decisions: Array<{ message: PageMessage; note: Extract<CoordinationNote, { kind: "decision" }>; scope: string }> = [];
  const freeText: PageMessage[] = [];
  const groupFor = (ref: MessageReference): Group => {
    const key = referenceKey(ref);
    const found = byKey.get(key);
    if (found) return found;
    const created: Group = { ref, order: groups.length, requestClaims: [], responses: [] };
    byKey.set(key, created);
    groups.push(created);
    return created;
  };

  for (const message of messages) {
    const ref = messageReference(message);
    if (ref) inWindow.add(referenceKey(ref));
    const decoded = typeof message?.body === "string" ? decodeCoordinationNote(message.body) : undefined;
    if (!decoded || !ref) {
      freeText.push(message);
      continue;
    }
    if (decoded.note.kind === "request") groupFor(ref).requestClaims.push({ message, note: decoded.note, scope: decoded.body });
    else if (decoded.note.kind === "decision") decisions.push({ message, note: decoded.note, scope: decoded.body });
    else groupFor(decoded.note.replyTo).responses.push({ message, note: decoded.note, scope: decoded.body });
  }

  const items: Array<{ category: keyof Counts; render: (limit: number | undefined) => string }> = [];
  const ranked = [...groups].sort((a, b) => {
    const rank = (group: Group) => group.requestClaims.length > 0 && group.responses.length > 0 ? 0
      : group.requestClaims.length > 0 ? 1 : 2;
    return rank(a) - rank(b) || a.order - b.order;
  });
  for (const group of ranked) {
    const inPage = inWindow.has(referenceKey(group.ref));
    const category = categoryOf(group, inPage);
    const relation = relationOf(group, inPage);
    items.push({ category, render: limit => renderGroup(group, relation, limit) });
  }
  for (const decision of decisions) items.push({ category: "decisions", render: limit => renderDecision(decision.message, decision.note, decision.scope, limit) });
  for (const message of freeText) items.push({ category: "freeText", render: limit => renderFreeText(message, limit) });

  const omitted = emptyCounts();
  for (const item of items) omitted[item.category] += 1;
  const framing = [PREFACE, STORAGE, LEDGER];
  const fit = (records: string[], next: Counts, excerpts: number) => utf8(assemble(coverage, records, next, excerpts, framing)) <= cap;
  if (!fit([], omitted, 0)) {
    const minimal = [PREFACE, coverage, footer(omitted, 0)].join("\n");
    if (utf8(minimal) <= cap) return minimal;
    if (utf8(PREFACE) <= cap) return PREFACE;
    if (utf8(coverage) <= cap) return coverage;
    return "";
  }

  const selected: string[] = [];
  let excerpts = 0;
  for (const item of items) {
    const attempt = (limit: number | undefined) => {
      const line = item.render(limit);
      const next = { ...omitted, [item.category]: omitted[item.category] - 1 };
      const markedExcerpt = limit !== undefined && line !== item.render(undefined);
      if (!fit([...selected, line], next, excerpts + (markedExcerpt ? 1 : 0))) return false;
      selected.push(line);
      omitted[item.category] -= 1;
      if (markedExcerpt) excerpts += 1;
      return true;
    };
    if (attempt(undefined) || attempt(COORDINATION_EXCERPT_BYTES) || attempt(COORDINATION_EXCERPT_FALLBACK_BYTES)) continue;
  }
  return assemble(coverage, selected, omitted, excerpts, framing);
}
