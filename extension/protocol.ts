export type Agent = {
  agentId: string;
  sessionId: string;
  host: string;
  cwd: string;
  sessionName: string;
  label: string;
  model: { provider: string; id: string } | null;
  status: "idle" | "busy";
  pid: number;
  acceptsControl: boolean;
  updatedAt?: number;
  receiving?: boolean;
};

export type SendKind = "notice" | "prompt" | "steer";

export type SendOutcome =
  | { status: "accepted"; id: string; to: string; receiving: boolean; expiresAt: number }
  | { status: "rejected"; reason: string }
  | { status: "outcome_unknown"; reason: string }
  | { status: "not_sent"; reason: string };

export const DEFAULT_URL = "http://terminus:7420";
export const MAX_BODY_BYTES = 16 * 1024;
export const MAX_ENVELOPE_BYTES = 32 * 1024;

export type ServerMessage = {
  id: string; from: string; to: string; kind: SendKind; body: string;
  sender: { host: string; label: string }; acceptedAt: number; expiresAt: number;
};

export function isServerMessage(value: unknown, recipient?: string): value is ServerMessage {
  return exactKeys(value, ["id", "from", "to", "kind", "body", "sender", "acceptedAt", "expiresAt"])
    && isMessageFields(value) && (recipient === undefined || value.to === recipient)
    && exactKeys(value.sender, ["host", "label"])
    && typeof value.sender.host === "string" && /^[\x20-\x7e]{1,255}$/.test(value.sender.host)
    && labelString(value.sender.label, 200)
    && isUnsignedInteger(value.acceptedAt) && isUnsignedInteger(value.expiresAt)
    && value.expiresAt === value.acceptedAt + 60
    && new TextEncoder().encode(JSON.stringify(value)).length <= MAX_ENVELOPE_BYTES;
}

export function isMessageFields(value: Record<string, unknown>): boolean {
  return [value.id, value.from, value.to].every((id) => typeof id === "string" && isUuid(id))
    && value.from !== value.to
    && ["notice", "prompt", "steer"].includes(value.kind as string)
    && typeof value.body === "string" && isUnicode(value.body) && value.body.length > 0
    && new TextEncoder().encode(value.body).length <= MAX_BODY_BYTES;
}

export function decodeServerMessage(data: Uint8Array, recipient?: string): ServerMessage {
  try {
    if (data.byteLength > MAX_ENVELOPE_BYTES) throw new Error("protocol");
    const value = decodeWireJson(data);
    if (!isServerMessage(value, recipient)) throw new Error("protocol");
    return value;
  } catch { throw new Error("protocol"); }
}
export const MAX_DISCOVERY_BYTES = 1024 * 1024;
export const MAX_STAGE_BYTES = 256 * 1024 * 1024;
export const MAX_AGENTS = 5000;
export const MAX_PAGE_RECORDS = 128;
export const DISCOVERY_LIFETIME_MS = 30_000;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: string): boolean {
  return UUID_RE.test(value);
}

export function parseHubUrl(raw: string): { ok: string } | { error: string } {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return { error: "invalid hub URL" };
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return { error: "hub URL must be http or https" };
  }
  if (url.username || url.password) {
    return { error: "hub URL must not include userinfo" };
  }
  if (url.search) {
    return { error: "hub URL must not include a query" };
  }
  if (url.hash) {
    return { error: "hub URL must not include a fragment" };
  }
  if (!url.hostname) {
    return { error: "hub URL host required" };
  }
  const path = url.pathname === "/" ? "" : url.pathname.replace(/\/+$/, "");
  return { ok: `${url.protocol}//${url.host}${path}` };
}

export function snapshotModel(
  model: { provider?: unknown; id?: unknown } | null | undefined,
): { provider: string; id: string } | null {
  if (!model || typeof model !== "object") {
    return null;
  }
  const provider = model.provider;
  const id = model.id;
  if (typeof provider !== "string" || typeof id !== "string") {
    return null;
  }
  if (!provider || !id) {
    return null;
  }
  return { provider, id };
}

export function cwdBasename(cwd: string): string {
  const parts = cwd.replace(/\/+$/, "").split("/");
  return parts[parts.length - 1] || cwd;
}

export function defaultLabel(sessionName: string | undefined, cwd: string): string {
  const name = sessionName?.trim();
  if (name) {
    return name;
  }
  return cwdBasename(cwd);
}

export function resolveTarget(
  query: string,
  agents: Agent[],
  selfId: string,
): { ok: Agent } | { error: string; candidates: Agent[] } {
  const q = query.trim();
  const pool = agents.filter((a) => a.agentId !== selfId);
  if (!q) {
    return { error: "empty target", candidates: [] };
  }
  // Removing self from shorthand candidates must not turn its explicit ID
  // into a lower-tier label match on a different peer.
  if (q.toLowerCase() === selfId.toLowerCase()) {
    return { error: "cannot send to self", candidates: [] };
  }

  const exactId = pool.filter((a) => a.agentId === q);
  if (exactId.length === 1) {
    return { ok: exactId[0] };
  }
  if (exactId.length > 1) {
    return { error: "ambiguous agent id", candidates: exactId };
  }

  if (q.length >= 8) {
    const prefix = pool.filter((a) =>
      a.agentId.toLowerCase().startsWith(q.toLowerCase()),
    );
    if (prefix.length === 1) {
      return { ok: prefix[0] };
    }
    if (prefix.length > 1) {
      return { error: "ambiguous id prefix", candidates: prefix };
    }
  }

  const hosts = pool.filter((a) => a.host === q);
  if (hosts.length === 1) {
    return { ok: hosts[0] };
  }
  if (hosts.length > 1) {
    return { error: "ambiguous host", candidates: hosts };
  }

  const needle = q.toLowerCase();
  const labels = pool.filter((a) => a.label.toLowerCase().includes(needle));
  if (labels.length === 1) {
    return { ok: labels[0] };
  }
  if (labels.length > 1) {
    return { error: "ambiguous label", candidates: labels };
  }
  return { error: "no matching agent", candidates: [] };
}

export function shortestUniquePrefix(agentId: string, agents: Agent[]): string {
  const id = agentId.toLowerCase();
  const others = agents
    .map((a) => a.agentId.toLowerCase())
    .filter((other) => other !== id);
  for (let n = 8; n <= id.length; n += 1) {
    const prefix = id.slice(0, n);
    if (!others.some((other) => other.startsWith(prefix))) {
      return agentId.slice(0, n);
    }
  }
  return agentId;
}

export function parseTell(
  input: string,
): { kind: SendKind; target: string; body: string } | { error: string } {
  let rest = input.trimStart();
  let kind: SendKind = "notice";
  while (rest.startsWith("--")) {
    const flag = rest.match(/^\S+/)![0];
    rest = rest.slice(flag.length).trimStart();
    if (flag === "--") break;
    if (flag !== "--prompt" && flag !== "--steer") {
      return { error: "unknown flag" };
    }
    if (kind !== "notice") return { error: "only one delivery flag allowed" };
    kind = flag === "--prompt" ? "prompt" : "steer";
  }
  let target: string;
  if (rest.startsWith('"')) {
    const end = rest.indexOf('"', 1);
    if (end < 0) return { error: "unclosed quote" };
    if (end + 1 < rest.length && !/\s/.test(rest[end + 1])) {
      return { error: "whitespace required after quoted target" };
    }
    target = rest.slice(1, end);
    rest = rest.slice(end + 1);
  } else {
    target = rest.match(/^\S+/)?.[0] ?? "";
    if (target.includes('"')) return { error: "invalid target quoting" };
    rest = rest.slice(target.length);
  }
  const body = rest.trimStart();
  if (!target) {
    return { error: "target required" };
  }
  if (!body.trim()) {
    return { error: "message body required" };
  }
  if (new TextEncoder().encode(body).length > MAX_BODY_BYTES) {
    return { error: "message too large" };
  }
  return { kind, target, body };
}

export type PublicAgent = Agent & { updatedAt: number; receiving: boolean };
export type SnapshotPart = {
  epoch: string; revision: string; snapshotId: string; capturedAt: number;
  total: number; agents: PublicAgent[];
};
export type DiscoveryPage = SnapshotPart & { page: number; nextCursor: string | null };

export function exactKeys(value: unknown, keys: string[]): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    && Object.keys(value).length === keys.length
    && keys.every((key) => Object.hasOwn(value, key));
}

export function isRevision(value: unknown): value is string {
  return typeof value === "string" && /^(0|[1-9][0-9]{0,19})$/.test(value)
    && BigInt(value) <= 18446744073709551615n;
}

export function isUnsignedInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

export function isUnicode(value: string): boolean {
  return !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value);
}

function labelString(value: unknown, max: number): value is string {
  return typeof value === "string" && isUnicode(value) && [...value].length > 0
    && [...value].length <= max && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u.test(value);
}

export function isPublicAgent(value: unknown): value is PublicAgent {
  if (!exactKeys(value, ["agentId", "sessionId", "host", "cwd", "sessionName", "label",
    "model", "status", "pid", "acceptsControl", "updatedAt", "receiving"])) return false;
  return typeof value.agentId === "string" && isUuid(value.agentId)
    && typeof value.sessionId === "string" && isUuid(value.sessionId)
    && typeof value.host === "string" && /^[\x20-\x7e]{1,255}$/.test(value.host)
    && typeof value.cwd === "string" && isUnicode(value.cwd) && value.cwd.length > 0
    && new TextEncoder().encode(value.cwd).length <= 4096
    && !/[\u0000-\u001f\u007f-\u009f]/u.test(value.cwd)
    && labelString(value.sessionName, 200) && labelString(value.label, 200)
    && (value.model === null || (exactKeys(value.model, ["provider", "id"])
      && labelString(value.model.provider, 200) && labelString(value.model.id, 512)))
    && (value.status === "idle" || value.status === "busy")
    && isUnsignedInteger(value.pid) && value.pid > 0
    && typeof value.acceptsControl === "boolean" && typeof value.receiving === "boolean"
    && isUnsignedInteger(value.updatedAt);
}

// JSON.parse accepts duplicate keys and escaped lone surrogates; the wire does not.
export function decodeWireJson(bytes: Uint8Array): unknown {
  const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  const value: unknown = JSON.parse(text);
  const containers: Array<Set<string> | null> = [];
  const tokens = /"(?:[^"\\]|\\.)*"|[{}\[\]]/g;
  for (const match of text.matchAll(tokens)) {
    const token = match[0];
    if (token === "{") containers.push(new Set());
    else if (token === "[") containers.push(null);
    else if (token === "}" || token === "]") containers.pop();
    else {
      const string: string = JSON.parse(token);
      if (!isUnicode(string)) throw new Error("invalid Unicode");
      if (/^\s*:/.test(text.slice(match.index! + token.length))) {
        const keys = containers.at(-1);
        if (!keys || keys.has(string)) throw new Error("duplicate key");
        keys.add(string);
      }
    }
  }
  return value;
}

export function isSnapshotPart(value: Record<string, unknown>): boolean {
  return typeof value.epoch === "string" && isUuid(value.epoch)
    && isRevision(value.revision) && typeof value.snapshotId === "string" && isUuid(value.snapshotId)
    && isUnsignedInteger(value.capturedAt) && isUnsignedInteger(value.total) && value.total <= MAX_AGENTS
    && Array.isArray(value.agents) && value.agents.length <= MAX_PAGE_RECORDS
    && value.agents.every(isPublicAgent)
    && value.agents.every((agent, i, agents) => i === 0 || agents[i - 1].agentId < agent.agentId);
}

export function sameSnapshot(a: SnapshotPart, b: SnapshotPart): boolean {
  return a.epoch === b.epoch && a.revision === b.revision && a.snapshotId === b.snapshotId
    && a.capturedAt === b.capturedAt && a.total === b.total;
}

export function isDiscoveryPage(value: unknown): value is DiscoveryPage {
  return exactKeys(value, ["epoch", "revision", "snapshotId", "capturedAt", "page", "total", "agents", "nextCursor"])
    && isSnapshotPart(value) && isUnsignedInteger(value.page)
    && (value.nextCursor === null || (typeof value.nextCursor === "string"
      && /^[A-Za-z0-9_-]{1,64}$/.test(value.nextCursor)
      && value.nextCursor === btoa(`${value.snapshotId}:${value.page + 1}`).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")));
}
