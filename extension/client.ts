import type { Agent, SendKind, SendOutcome } from "./protocol.ts";
import { isUuid, decodeWireJson, isDiscoveryPage, sameSnapshot, MAX_DISCOVERY_BYTES,
  MAX_STAGE_BYTES, MAX_AGENTS, DISCOVERY_LIFETIME_MS, exactKeys, isUnsignedInteger,
  isMessageFields, MAX_ENVELOPE_BYTES, type DiscoveryPage } from "./protocol.ts";

export type FetchLike = (
  input: string,
  init?: {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
    signal?: AbortSignal;
    redirect?: "manual" | "follow" | "error";
  },
) => Promise<{
  status: number;
  headers: { get(name: string): string | null };
  text(): Promise<string>;
  body?: { getReader(): {
    read(): Promise<{ done: boolean; value?: Uint8Array }>;
    cancel?(): Promise<void>;
    releaseLock?(): void;
  } } | null;
}>;

export type Timers = {
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(handle: unknown): void;
};
export const defaultTimers: Timers = {
  setTimeout: (callback, delay) => setTimeout(callback, delay),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};
export type HubClient = {
  isUnauthorized(): boolean;
  putAgent(agent: Record<string, unknown>, signal?: AbortSignal): Promise<SendOutcome | { status: "ok" }>;
  deleteAgent(agentId: string, signal?: AbortSignal): Promise<void>;
  listAgents(signal?: AbortSignal): Promise<{ status: "ok"; agents: Agent[] } | SendOutcome>;
  send(msg: {
    id: string;
    from: string;
    to: string;
    kind: SendKind;
    body: string;
  }, signal?: AbortSignal): Promise<SendOutcome>;
};

export function createHubClient(opts: {
  baseUrl: string;
  token: string;
  fetch: FetchLike;
  now?: () => number;
  timeoutMs?: number;
  timers?: Timers;
  onUnauthorized?: () => void;
}): HubClient {
  const timers = opts.timers ?? defaultTimers;
  let unauthorized = false;
  function latchUnauthorized() {
    if (unauthorized) return;
    unauthorized = true;
    try { opts.onUnauthorized?.(); } catch { /* observer cannot alter transport outcome */ }
  }
  const timeoutMs = Math.min(5000, Math.max(1, opts.timeoutMs ?? 5000));
  const now = opts.now ?? (() => performance.now());
  const headers = {
    authorization: `Bearer ${opts.token}`,
    accept: "application/json",
  };

  async function request(method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<
    | { kind: "http"; status: number; json: unknown }
    | { kind: "unknown"; reason: string }
    | { kind: "local"; reason: string }
  > {
    if (signal?.aborted) return { kind: "local", reason: "aborted" };
    let encoded: string | undefined;
    try {
      encoded = body === undefined ? undefined : JSON.stringify(body);
      if (encoded !== undefined && new TextEncoder().encode(encoded).length > MAX_ENVELOPE_BYTES) throw Error();
    } catch { return { kind: "local", reason: "invalid request" }; }
    const controller = new AbortController();
    const deadline = now() + timeoutMs;
    let reader: ReturnType<NonNullable<Awaited<ReturnType<FetchLike>>["body"]>["getReader"]> | undefined;
    let dispatched = false;
    let observedUnauthorized = false;
    let rejectEnd!: (error: Error) => void;
    const ended = new Promise<never>((_, reject) => { rejectEnd = reject; });
    const abort = () => { controller.abort(); rejectEnd(Error("aborted")); };
    const timer = timers.setTimeout(() => { controller.abort(); rejectEnd(Error("timeout")); }, timeoutMs);
    signal?.addEventListener("abort", abort, { once: true });
    function check() {
      if (controller.signal.aborted || signal?.aborted || now() >= deadline) throw Error("timeout");
    }
    async function perform() {
      check();
      dispatched = true;
      const res = await opts.fetch(`${opts.baseUrl}${path}`, {
        method, headers: encoded === undefined ? headers : { ...headers, "content-type": "application/json" },
        body: encoded, signal: controller.signal, redirect: "manual",
      });
      if (res.status === 401) {
        // Record this response before the notification can synchronously abort
        // every request. A different request's global latch proves nothing here.
        observedUnauthorized = true;
        latchUnauthorized();
        return { kind: "http" as const, status: 401, json: null };
      }
      check();
      if (res.status >= 300 && res.status < 400) throw Error("redirect refused");
      const length = res.headers.get("content-length");
      if (length !== null && (!/^(0|[1-9][0-9]*)$/.test(length) || Number(length) > MAX_ENVELOPE_BYTES)) throw Error("invalid response");
      let bytes = 0;
      const buffer = new Uint8Array(MAX_ENVELOPE_BYTES);
      if (res.body) {
        reader = res.body.getReader();
        while (true) {
          const chunk = await reader.read();
          check();
          if (chunk.done) break;
          if (!(chunk.value instanceof Uint8Array) || bytes + chunk.value.length > buffer.length) throw Error("invalid response");
          buffer.set(chunk.value, bytes); bytes += chunk.value.length;
        }
      } else if (res.status !== 204 && length !== "0") throw Error("invalid response");
      if (length !== null && Number(length) !== bytes) throw Error("invalid response");
      let json: unknown = null;
      if (bytes) { try { json = decodeWireJson(buffer.subarray(0, bytes)); } catch { /* sanitized invalid response */ } }
      check();
      return { kind: "http" as const, status: res.status, json };
    }
    try { return await Promise.race([perform(), ended]); }
    catch (error) {
      if (observedUnauthorized) return { kind: "http", status: 401, json: null };
      const reason = error instanceof Error && ["timeout", "aborted", "redirect refused", "invalid response"].includes(error.message)
        ? error.message : "network error";
      return { kind: dispatched ? "unknown" : "local", reason };
    } finally {
      timers.clearTimeout(timer); signal?.removeEventListener("abort", abort); controller.abort();
      try { void reader?.cancel?.().catch(() => {}); } catch { /* best effort, never await */ }
      try { reader?.releaseLock?.(); } catch { /* pending abandoned read */ }
    }
  }

  async function discoveryRequest(cursor: string | null, overallDeadline: number, remainingBytes: number, signal?: AbortSignal) {
    if (signal?.aborted) throw Error("aborted");
    const controller = new AbortController();
    const deadline = Math.min(overallDeadline, now() + timeoutMs);
    let timer: unknown;
    let abort = () => {};
    let reader: ReturnType<NonNullable<Awaited<ReturnType<FetchLike>>["body"]>["getReader"]> | undefined;
    const expired = new Promise<never>((_, reject) => {
      abort = () => { controller.abort(); reject(Error("aborted")); };
      signal?.addEventListener("abort", abort, { once: true });
      timer = timers.setTimeout(() => { controller.abort(); reject(new Error("timeout")); }, Math.max(0, deadline - now()));
    });
    function checkDeadline() {
      if (now() >= deadline || controller.signal.aborted) throw new Error("timeout");
    }
    async function readPage() {
      const path = cursor === null ? "/v1/agents" : `/v1/agents?cursor=${encodeURIComponent(cursor)}`;
      const res = await opts.fetch(`${opts.baseUrl}${path}`, {
        method: "GET", headers, signal: controller.signal, redirect: "manual",
      });
      if (res.status === 401) { latchUnauthorized(); throw new Error("unauthorized"); }
      checkDeadline();
      if (res.status >= 300 && res.status < 400) throw new Error("redirect refused");
      if (res.status === 409) throw new Error("discovery reset");
      if (res.status !== 200 || !res.body) throw new Error("invalid discovery");
      const limit = Math.min(MAX_DISCOVERY_BYTES, remainingBytes);
      const length = res.headers.get("content-length");
      if (length !== null && (!/^(0|[1-9][0-9]*)$/.test(length) || Number(length) > limit)) throw new Error("discovery limit");
      reader = res.body.getReader();
      // Fixed byte storage avoids an unbounded array of tiny network fragments.
      const buffer = new Uint8Array(limit);
      let bytes = 0;
      while (true) {
        const chunk = await reader.read();
        checkDeadline();
        if (chunk.done) break;
        if (!(chunk.value instanceof Uint8Array) || bytes + chunk.value.byteLength > limit) throw new Error("discovery limit");
        buffer.set(chunk.value, bytes);
        bytes += chunk.value.byteLength;
      }
      if (length !== null && Number(length) !== bytes) throw new Error("invalid discovery");
      const page = decodeWireJson(buffer.subarray(0, bytes));
      if (!isDiscoveryPage(page)) throw new Error("invalid discovery");
      checkDeadline();
      return { page, bytes };
    }
    try {
      // One race per request, not per fragment: pending deadline reactions must
      // not accumulate when a server sends a page one byte at a time.
      return await Promise.race([readPage(), expired]);
    } finally {
      timers.clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      controller.abort();
      try { void reader?.cancel?.().catch(() => {}); } catch { /* cleanup is best effort */ }
      try { reader?.releaseLock?.(); } catch { /* a timed-out read may still be pending */ }
    }
  }

  return {
    isUnauthorized: () => unauthorized,
    async putAgent(agent, signal) {
      const id = String(agent.agentId ?? "");
      if (!isUuid(id)) {
        return { status: "not_sent", reason: "invalid agent id" };
      }
      const result = await request("PUT", `/v1/agents/${id}`, agent, signal);
      if (result.kind === "unknown") {
        return { status: "outcome_unknown", reason: result.reason };
      }
      if (result.kind === "local") {
        return { status: "not_sent", reason: result.reason };
      }
      if (result.status === 204 || result.status === 200) {
        return { status: "ok" };
      }
      if (result.status === 401) {
        return { status: "rejected", reason: "unauthorized" };
      }
      return {
        status: "rejected",
        reason: errorMessage(result.json, `http ${result.status}`),
      };
    },

    async deleteAgent(agentId, signal) {
      if (isUuid(agentId)) await request("DELETE", `/v1/agents/${agentId}`, undefined, signal);
    },

    async listAgents(signal) {
      const deadline = now() + DISCOVERY_LIFETIME_MS;
      const agents: Agent[] = [];
      let first: DiscoveryPage | undefined;
      let cursor: string | null = null;
      const cursors = new Set<string>();
      let bytes = 0;
      let pageIndex = 0;
      try {
        do {
          if (now() >= deadline) throw new Error("timeout");
          const result = await discoveryRequest(cursor, deadline, MAX_STAGE_BYTES - bytes, signal);
          bytes += result.bytes;
          const page = result.page;
          if (page.page !== pageIndex++ || (first && !sameSnapshot(first, page))) throw new Error("invalid discovery");
          first ??= page;
          if (agents.length && page.agents.length && agents.at(-1)!.agentId >= page.agents[0].agentId) throw new Error("invalid discovery");
          if (agents.length + page.agents.length > page.total || agents.length + page.agents.length > MAX_AGENTS) throw new Error("invalid discovery");
          agents.push(...page.agents);
          cursor = page.nextCursor;
          if (cursor !== null) {
            if (!page.agents.length || agents.length >= page.total || cursors.has(cursor)) throw new Error("invalid discovery");
            cursors.add(cursor);
          } else if (agents.length !== page.total || (pageIndex > 1 && !page.agents.length)) throw new Error("invalid discovery");
          if (now() >= deadline) throw new Error("timeout");
        } while (cursor !== null);
        return { status: "ok", agents };
      } catch (error) {
        const reason = error instanceof Error && ["timeout", "aborted", "unauthorized", "redirect refused", "discovery reset"].includes(error.message)
          ? error.message : "discovery failed";
        return { status: "not_sent", reason };
      }
    },

    async send(msg, signal) {
      if (!exactKeys(msg, ["id", "from", "to", "kind", "body"]) || !isMessageFields(msg)) return { status: "not_sent", reason: "invalid message" };
      const result = await request("POST", "/v1/messages", msg, signal);
      if (result.kind === "unknown") {
        return {
          status: "outcome_unknown",
          reason:
            "The hub response was lost; this may already have run. Check the peer before resending.",
        };
      }
      if (result.kind === "local") {
        return { status: "not_sent", reason: result.reason };
      }
      if (result.status === 202 && exactKeys(result.json, ["id", "to", "state", "expiresAt", "receiving"])) {
        const doc = result.json;
        if (doc.id === msg.id && doc.to === msg.to && doc.state === "accepted"
          && isUnsignedInteger(doc.expiresAt) && typeof doc.receiving === "boolean") {
          return {
            status: "accepted",
            id: doc.id,
            to: doc.to,
            receiving: doc.receiving,
            expiresAt: doc.expiresAt,
          };
        }
      }
      if (result.status !== 401 && ![400, 403, 404, 409, 413, 429, 503].includes(result.status)) {
        return { status: "outcome_unknown", reason: "The hub response was invalid; this may already have run. Check the peer before resending." };
      }
      if (result.status === 401) {
        return { status: "rejected", reason: "unauthorized" };
      }
      return {
        status: "rejected",
        reason: errorMessage(result.json, `http ${result.status}`),
      };
    },
  };
}

function errorMessage(json: unknown, fallback: string): string {
  const messages: Record<string, string> = {
    invalid_schema: "invalid request", self_send: "cannot send to self", control_disabled: "recipient does not accept control",
    not_found: "unknown runtime", conflict: "message id reused with different payload", payload_too_large: "message too large",
    mailbox_full: "recipient mailbox full", dedup_full: "deduplication cache full", capacity: "hub unavailable",
    invalid_cursor: "invalid discovery cursor", discovery_reset: "discovery changed", method_not_allowed: "method not allowed",
  };
  if (exactKeys(json, ["error"]) && exactKeys(json.error, ["code", "message"])
    && typeof json.error.code === "string" && Object.hasOwn(messages, json.error.code)) return messages[json.error.code];
  return fallback;
}
