import type { ExtensionAPI, ExtensionContext, MessageStartEvent } from "@earendil-works/pi-coding-agent";
import { createHubClient, type FetchLike, type HubClient, type Timers } from "./client.ts";
import { subscribeOnce, type BusFrame } from "./sse.ts";
import { createPresenceState, reducePresence, type PresenceState } from "./presence.ts";
import { createInboxState, receive, takeNoticeBatch, consumeUserMessage, markRead, type InboxState } from "./inbox.ts";
import { DEFAULT_URL, parseHubUrl, decodeServerMessage, isPublicAgent, cwdBasename, resolveTarget, parseTell, type Agent, type SendKind, type SendOutcome } from "./protocol.ts";
import { describeOutcome, formatAgentList } from "./commands.ts";

export type Env = Record<string, string | undefined>;
export type AgentBusDeps = {
  pi?: ExtensionAPI; fetch?: FetchLike; env?: Env; uuid?: () => string;
  now?: () => number; wallNow?: () => number; random?: () => number;
  hostname?: () => string; cwd?: () => string; pid?: () => number;
  timers?: Timers; subscribe?: typeof subscribeOnce;
};
export const LABEL_ENTRY = "agent-bus-label";
export function projectName(text: string): string {
  const clean = Array.from(text).map(char => /^[\ud800-\udfff]$/.test(char) ? "\ufffd" : char).join("").replace(/[\x00-\x1f\x7f-\x9f\u2028\u2029]/g, " ").trim();
  return Array.from(clean).slice(0, 200).join("");
}
export function validateLabel(text: string): string | undefined {
  const value = text.trim();
  return value && !Array.from(value).some(char => /^[\ud800-\udfff]$/.test(char)) && !/[\x00-\x1f\x7f-\x9f\u2028\u2029]/.test(value) && Array.from(value).length <= 200 ? value : undefined;
}
export function restoreLabel(ctx: ExtensionContext): string | undefined {
  const entries = ctx.sessionManager.getBranch();
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry.type === "custom" && entry.customType === LABEL_ENTRY) {
      const data: unknown = entry.data;
      return data && typeof data === "object" && "label" in data && typeof data.label === "string" ? validateLabel(data.label) : undefined;
    }
  }
  return undefined;
}
export function normalizedUserText(message: MessageStartEvent["message"]): string | undefined {
  if (message.role !== "user") return;
  if (typeof message.content === "string") return message.content;
  if (message.content.every(block => block.type === "text")) return message.content.map(block => block.type === "text" ? block.text : "").join("\n");
}
export function retryDelay(attempt: number, random: number): number {
  const ceiling = Math.min(30000, 1000 * 2 ** Math.min(attempt, 5));
  const floor = Math.max(1000, ceiling / 2);
  return floor + Math.max(0, Math.min(1, random)) * (ceiling - floor);
}

function projectModel(model: ExtensionContext["model"]): Agent["model"] {
  return model == null ? null : { provider: model.provider, id: model.id };
}

type Run = {
  generation: number; ctx: ExtensionContext; id: string; sessionId: string; client: HubClient;
  baseUrl: string; token: string; abort: AbortController; lifetime: AbortController; stream?: AbortController;
  closed: boolean; unauthorized: boolean; busy: boolean; explicitLabel?: string;
  model: Agent["model"]; projectedName: string; label: string; invalidMetadata: boolean; putBusy: boolean; dirty: boolean;
  retry?: unknown; heartbeat?: unknown; lease?: unknown; burst?: unknown; arrivals: number; warnings: number;
  attempt: number; lastPut: number; healthySince?: number; presence: PresenceState;
  cached: Agent[]; inbox: InboxState; control: boolean; consentGeneration: number;
  confirmation?: AbortController; status: string; error?: string;
};

export function createRuntime(deps: AgentBusDeps) {
  const timers = deps.timers ?? { setTimeout: (cb: () => void, ms: number) => setTimeout(cb, ms), clearTimeout: (h: unknown) => clearTimeout(h as ReturnType<typeof setTimeout>) };
  const now = deps.now ?? (() => performance.now());
  const wallNow = deps.wallNow ?? Date.now;
  const uuid = deps.uuid ?? (() => crypto.randomUUID());
  const env = deps.env ?? {};
  let current: Run | undefined;
  let generation = 0;
  let warnedMissing = false;
  const active = (r: Run) => current === r && !r.closed && r.generation === generation;
  const online = (r: Run) => active(r) && !r.unauthorized;
  const notify = (r: Run, text: string, level: "info" | "warning" | "error" = "info") => { if (active(r)) r.ctx.ui.notify(`pi-switchboard: ${text}`, level); };
  function status(r: Run, next: string) {
    if (!active(r)) return;
    if (r.status !== next) {
      const previous = r.status;
      r.status = next;
      if ((next === "down" || next === "degraded") && previous !== "connecting") notify(r, `connection ${next}`, "warning");
    }
    r.ctx.ui.setStatus("agent-bus", `bus ${r.status} control ${r.control ? "on" : "off"}`);
  }
  function refreshHealth(r: Run) {
    if (!online(r)) return;
    if (r.invalidMetadata) { r.healthySince = undefined; status(r, "down"); return; }
    if (r.status === "connecting" && !r.error && r.lastPut === -Infinity) return;
    const recent = now() - r.lastPut < 15000;
    const synced = !!r.stream && r.presence.status === "current";
    if (recent && synced) {
      r.healthySince ??= now();
      if (now() - r.healthySince >= 10000) r.attempt = 0;
      status(r, "connected");
    } else {
      r.healthySince = undefined;
      status(r, recent ? "degraded" : "down");
    }
  }
  function cancelTimer(r: Run, key: "retry" | "heartbeat" | "lease" | "burst") {
    if (r[key] !== undefined) timers.clearTimeout(r[key]);
    r[key] = undefined;
  }
  function stopUnauthorized(r: Run) {
    if (!online(r)) return;
    r.unauthorized = true; r.error = "credentials must be refreshed locally";
    cancelTimer(r, "retry"); cancelTimer(r, "heartbeat"); cancelTimer(r, "lease");
    r.stream?.abort(); r.stream = undefined; r.abort.abort();
    r.healthySince = undefined;
    status(r, "down"); notify(r, r.error, "error");
  }
  function metadata(r: Run): Record<string, unknown> | undefined {
    r.projectedName = projectName(deps.pi?.getSessionName() ?? "") || projectName(cwdBasename(deps.cwd?.() ?? r.ctx.cwd)) || "Pi session";
    r.label = r.explicitLabel ?? r.projectedName;
    const doc = { agentId: r.id, sessionId: r.sessionId, host: deps.hostname?.() ?? "unknown",
      cwd: deps.cwd?.() ?? r.ctx.cwd, sessionName: r.projectedName, label: r.label,
      model: r.model,
      status: r.busy ? "busy" : "idle", pid: deps.pid?.() ?? 1, acceptsControl: r.control };
    if (!isPublicAgent({ ...doc, receiving: false, updatedAt: 0 }) || /[\u2028\u2029]/.test(doc.cwd)) {
      r.invalidMetadata = true;
      r.error = "invalid local presence metadata; correct it before publication";
      if (r.status !== "down") notify(r, r.error, "warning");
      r.stream?.abort(); r.stream = undefined; r.healthySince = undefined;
      status(r, "down"); return;
    }
    r.invalidMetadata = false;
    return doc;
  }
  function scheduleRetry(r: Run) {
    if (!online(r) || r.retry !== undefined) return;
    const delay = retryDelay(r.attempt++, (deps.random ?? Math.random)());
    r.retry = timers.setTimeout(() => { r.retry = undefined; if (online(r)) requestPut(r, true); }, delay);
  }
  function heartbeat(r: Run) {
    if (!online(r)) return;
    r.heartbeat = timers.setTimeout(() => {
      r.heartbeat = undefined;
      if (!online(r)) return;
      refreshHealth(r);
      if (r.retry === undefined) requestPut(r, true);
      heartbeat(r);
    }, 5000);
  }
  function requestPut(r: Run, refreshModel = false) {
    if (!online(r)) return;
    if (refreshModel) r.model = projectModel(r.ctx.model);
    if (r.putBusy) { r.dirty = true; return; }
    if (r.retry !== undefined) { r.dirty = true; return; }
    const doc = metadata(r);
    if (!doc) return;
    r.putBusy = true; r.dirty = false;
    void (async () => {
      try {
        const result = await r.client.putAgent(doc, r.abort.signal);
        if (!online(r)) return;
        if (r.client.isUnauthorized()) { stopUnauthorized(r); return; }
        if (result.status === "ok") {
          r.lastPut = now(); r.error = undefined;
          cancelTimer(r, "lease");
          r.lease = timers.setTimeout(() => { r.lease = undefined; if (online(r)) refreshHealth(r); }, 15000);
          if (!r.stream) openStream(r);
          refreshHealth(r);
        } else {
          r.error = "presence update failed";
          refreshHealth(r); scheduleRetry(r);
        }
      } catch {
        if (online(r)) { r.error = "presence update failed"; refreshHealth(r); scheduleRetry(r); }
      } finally {
        if (online(r)) {
          r.putBusy = false;
          if (r.dirty && r.retry === undefined) requestPut(r);
        }
      }
    })();
  }
  function openStream(r: Run) {
    if (!online(r) || r.stream) return;
    const stream = new AbortController(); r.stream = stream; r.presence = createPresenceState();
    const valid = () => online(r) && r.stream === stream && !stream.signal.aborted;
    void (async () => {
      try {
        const end = await (deps.subscribe ?? subscribeOnce)({ baseUrl: r.baseUrl, token: r.token,
          agentId: r.id, fetch: deps.fetch!, signal: stream.signal, now, timers,
          onActivity: () => { if (valid()) refreshHealth(r); },
          onFrame: (frame: BusFrame) => {
            if (!valid()) return false;
            if (frame.event === "message") {
              const mail = decodeServerMessage(frame.data, r.id);
              const before = r.inbox;
              const result = receive(before, mail, { monoMs: now(), wallMs: wallNow() }, r.control);
              r.inbox = result.state; // Reserve the slot before synchronous Pi effects/reentrant events.
              if (r.inbox.nextReceipt !== before.nextReceipt) r.arrivals++;
              r.warnings += result.warnings.reduce((count, warning) => count + warning.count, 0);
              scheduleBurst(r);
              if (result.control && valid() && r.control) {
                try { deps.pi?.sendUserMessage(result.control.text, { deliverAs: result.control.kind === "prompt" ? "followUp" : "steer", expandPromptTemplates: false }); }
                catch { r.error = "control injection attempted; awaiting exact user message, reload to recover"; notify(r, r.error, "warning"); }
              }
            } else {
              r.presence = reducePresence(r.presence, frame.event, frame.data, now());
              if (r.presence.reconnect) return false;
              if (r.presence.status === "current") r.cached = [...r.presence.agents];
              refreshHealth(r);
            }
          } });
        if (!valid()) return;
        if (end.reason === "unauthorized") { stopUnauthorized(r); return; }
      } catch { if (!valid()) return; }
      if (!valid()) return;
      refreshHealth(r);
      r.stream = undefined; stream.abort(); r.healthySince = undefined;
      r.error = "receive stream unavailable"; refreshHealth(r); scheduleRetry(r);
    })();
  }
  function scheduleBurst(r: Run) {
    if (r.burst !== undefined || (!r.arrivals && !r.warnings)) return;
    r.burst = timers.setTimeout(() => {
      r.burst = undefined;
      if (!active(r)) return;
      notify(r, `${r.arrivals} mail arrivals; ${unread(r)} unread${r.warnings ? `; ${r.warnings} discard/capacity warnings` : ""}`, r.warnings ? "warning" : "info");
      r.arrivals = 0; r.warnings = 0;
    }, 250);
  }
  const unread = (r: Run) => r.inbox.records.filter(record => !record.humanRead).length;
  function invalidateConsent(r: Run) {
    r.consentGeneration++; r.confirmation?.abort(); r.confirmation = undefined;
  }
  function close(r: Run) {
    if (r.closed) return;
    r.closed = true; generation++; r.control = false; invalidateConsent(r);
    cancelTimer(r, "retry"); cancelTimer(r, "heartbeat"); cancelTimer(r, "lease"); cancelTimer(r, "burst");
    r.lifetime.abort(); r.abort.abort(); r.stream?.abort(); r.stream = undefined;
    r.inbox = createInboxState(); r.cached = [];
    r.ctx.ui.setStatus("agent-bus", undefined);
  }
  async function cleanup(r: Run) {
    if (!deps.fetch) return;
    const controller = new AbortController();
    let timer: unknown;
    const deadline = new Promise<void>(resolve => { timer = timers.setTimeout(() => { controller.abort(); resolve(); }, 2000); });
    const fresh = createHubClient({ baseUrl: r.baseUrl, token: r.token, fetch: deps.fetch, now, timers, timeoutMs: 2000 });
    try { await Promise.race([fresh.deleteAgent(r.id, controller.signal).catch(() => {}), deadline]); }
    finally { timers.clearTimeout(timer); controller.abort(); }
  }
  const runtime = {
    sessionStart(_event: { reason?: string }, ctx: ExtensionContext): void {
      if (current) { const old = current; close(old); current = undefined; void cleanup(old); }
      const quiet = ctx.mode !== "tui" || env.PI_AGENT_BUS_ENABLED === "0" || /^(1|true|yes)$/i.test(env.PI_OFFLINE?.trim() ?? "");
      if (quiet) return;
      const parsed = parseHubUrl(env.PI_AGENT_BUS_URL || DEFAULT_URL);
      if (!env.PI_AGENT_BUS_TOKEN || !deps.fetch || "error" in parsed) {
        if (!warnedMissing) { warnedMissing = true; ctx.ui.notify("pi-switchboard: missing or invalid bus configuration", "warning"); }
        return;
      }
      const r: Run = { generation: ++generation, ctx, id: uuid(), sessionId: ctx.sessionManager.getSessionId(),
        client: createHubClient({ baseUrl: parsed.ok, token: env.PI_AGENT_BUS_TOKEN, fetch: deps.fetch, now, timers, onUnauthorized: () => stopUnauthorized(r) }),
        baseUrl: parsed.ok, token: env.PI_AGENT_BUS_TOKEN,
        abort: new AbortController(), lifetime: new AbortController(), closed: false, unauthorized: false, busy: !ctx.isIdle(), explicitLabel: restoreLabel(ctx),
        model: projectModel(ctx.model), projectedName: "", label: "", invalidMetadata: false, putBusy: false, dirty: false, arrivals: 0, warnings: 0,
        attempt: 0, lastPut: -Infinity, presence: createPresenceState(), cached: [], inbox: createInboxState(),
        control: false, consentGeneration: 0, status: "connecting" };
      current = r;
      status(r, "connecting"); requestPut(r); heartbeat(r);
    },
    async sessionShutdown(): Promise<void> {
      const r = current; if (!r) return;
      close(r); current = undefined; await cleanup(r);
    },
    modelSelect(model: ExtensionContext["model"], ctx: ExtensionContext) {
      const r = current; if (!r || !active(r)) return;
      r.ctx = ctx; r.model = projectModel(model); requestPut(r);
    },
    refresh(ctx: ExtensionContext, branch = false) {
      const r = current; if (!r || !active(r)) return;
      r.ctx = ctx; if (branch) r.explicitLabel = restoreLabel(ctx);
      requestPut(r, true);
    },
    setBusy(busy: boolean, ctx?: ExtensionContext) {
      const r = current; if (!r || !active(r)) return;
      if (ctx) r.ctx = ctx; r.busy = busy; requestPut(r);
    },
    beforeAgentStart() {
      const r = current; if (!r || !active(r)) return;
      const batch = takeNoticeBatch(r.inbox); r.inbox = batch.state;
      return batch.message ? { message: batch.message } : undefined;
    },
    messageStart(message: MessageStartEvent["message"]) {
      const r = current; if (!r || !active(r)) return;
      const text = normalizedUserText(message);
      if (text !== undefined) r.inbox = consumeUserMessage(r.inbox, text);
    },
    async list(signal?: AbortSignal) {
      const r = current;
      if (!r || !online(r)) return { status: "not_sent" as const, reason: "agent bus unavailable" };
      const result = await r.client.listAgents(signal ? AbortSignal.any([signal, r.abort.signal]) : r.abort.signal);
      if (!active(r)) return { status: "not_sent" as const, reason: "runtime closed" };
      if (r.unauthorized) return { status: "not_sent" as const, reason: "unauthorized" };
      if (signal?.aborted) return { status: "not_sent" as const, reason: "cancelled" };
      if (result.status === "ok" && online(r)) r.cached = result.agents;
      return result;
    },
    async send(to: string, body: string, kind: SendKind = "notice", signal?: AbortSignal): Promise<SendOutcome> {
      const r = current;
      if (!r || !online(r) || signal?.aborted) return { status: "not_sent", reason: "agent bus unavailable" };
      const listed = await runtime.list(signal);
      if (!active(r) || signal?.aborted) return { status: "not_sent", reason: "runtime closed or cancelled" };
      if (listed.status !== "ok") return listed;
      if (!online(r)) return { status: "not_sent", reason: "agent bus unavailable" };
      const resolved = resolveTarget(to, listed.agents, r.id);
      if ("error" in resolved) return { status: "not_sent", reason: `${resolved.error}${resolved.candidates.length ? `: ${resolved.candidates.map(a => a.agentId).join(", ")}` : ""}` };
      const result = await r.client.send({ id: uuid(), from: r.id, to: resolved.ok.agentId, body, kind }, signal ? AbortSignal.any([signal, r.abort.signal]) : r.abort.signal);
      // The one attempt remains uncertain/accepted even if its session was closed. No new effects follow.
      if (!active(r)) return result;
      return result;
    },
    setLabel(text: string, clear = false): string {
      const r = current; if (!r || !active(r)) throw new Error("agent bus unavailable");
      const label = clear ? undefined : validateLabel(text);
      if (!clear && !label) throw new Error("label must be nonempty, single-line and at most 200 code points");
      deps.pi?.appendEntry(LABEL_ENTRY, { label: label ?? "" });
      r.explicitLabel = label; metadata(r); requestPut(r); return r.label;
    },
    label: () => current?.label ?? "agent bus unavailable",
    async consent(enable: boolean, ctx: ExtensionContext): Promise<string> {
      const r = current; if (!r || !active(r) || ctx.mode !== "tui") return "agent bus unavailable";
      if (!enable) { invalidateConsent(r); r.control = false; requestPut(r); status(r, r.status); return "control off; already injected work is not recalled"; }
      if (r.control) return "control on";
      if (r.confirmation) return "control confirmation already pending";
      const confirmation = new AbortController(); r.confirmation = confirmation;
      const consentGeneration = ++r.consentGeneration;
      let confirmed = false;
      try { confirmed = await ctx.ui.confirm("Enable peer control?", "Trusted-token peers can inject user prompts and steer active work. Peer text grants no local approvals. Enable for this runtime only?", { signal: confirmation.signal }); }
      catch { /* A failed or cancelled dialog never grants consent. */ }
      if (!active(r) || r.consentGeneration !== consentGeneration || confirmation.signal.aborted) return "control unchanged";
      r.confirmation = undefined;
      if (confirmed) { r.control = true; requestPut(r); status(r, r.status); }
      return r.control ? "control on" : "control off";
    },
    markRead(key: string) { const r = current; if (r && active(r)) r.inbox = markRead(r.inbox, key); },
    signal: () => current?.lifetime.signal,
    inbox: () => current?.inbox ?? createInboxState(),
    listCached: () => [...(current?.cached ?? [])],
    runtimeId: () => current?.id,
    status: () => { if (current) refreshHealth(current); return current?.status ?? "disabled"; },
    acceptsControl: () => current?.control ?? false,
    version: () => generation,
    isCurrent: (id: string | undefined, version = generation) => !!current && active(current) && current.id === id && version === generation,
    statusText() {
      const r = current; if (!r) return "agent bus unavailable (disabled)";
      refreshHealth(r);
      return `status=${r.status} id=${r.id} session=${r.sessionId} unread=${unread(r)} control=${r.control ? "on" : "off"} pending-control=${r.inbox.pendingControl ? "occupied; /reload recovers unmatched submission" : "empty"}${r.error ? ` error=${r.error}` : ""}`;
    },
    async handleCommand(name: string, args: string, ctx: ExtensionContext): Promise<string> {
      if (name === "bus") {
        if (args.trim() === "control on") return runtime.consent(true, ctx);
        if (args.trim() === "control off") return runtime.consent(false, ctx);
        return runtime.statusText();
      }
      if (name === "label") return args.trim() ? runtime.setLabel(args, args.trim() === "--clear") : runtime.label();
      if (name === "agents") { const result = await runtime.list(); return result.status === "ok" ? formatAgentList(result.agents, runtime.runtimeId() ?? "") : describeOutcome(result); }
      if (name === "tell") {
        const parsed = parseTell(args); if ("error" in parsed) return parsed.error;
        return describeOutcome(await runtime.send(parsed.target, parsed.body, parsed.kind));
      }
      return "unknown command";
    },
  };
  return runtime;
}
export type AgentBusRuntime = ReturnType<typeof createRuntime>;
