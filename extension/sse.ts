import { defaultTimers, type FetchLike, type Timers } from "./client.ts";
import { decodeServerMessage, decodeWireJson, isUuid, MAX_DISCOVERY_BYTES } from "./protocol.ts";
import { isPresenceData } from "./presence.ts";

export type BusFrame = { event: "message" | "presence_snapshot" | "presence_delta" | "presence_reset"; data: Uint8Array };
export type StreamEnd = { reason: "aborted" | "unauthorized" | "not_found" | "unavailable" | "timeout" | "protocol" | "closed" };
type Callbacks = { onFrame(frame: BusFrame): void | false; onActivity?(): void };

// Fixed buffers bound retention even with one-byte chunks. Only the current
// frame is assembled; callbacks run synchronously before parsing further input.
export function createSseParser(opts: Callbacks) {
  const line = new Uint8Array(MAX_DISCOVERY_BYTES);
  const data = new Uint8Array(MAX_DISCOVERY_BYTES);
  const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
  const encoder = new TextEncoder();
  let lineBytes = 0, rawBytes = 0, dataBytes = 0;
  let event = "", hasData = false, leading = true, stopped = false;
  let pendingCR: { completed: boolean; endedFrame: boolean } | null = null;
  const fail = (): never => { stopped = true; throw Error("protocol"); };
  function invoke(callback: () => unknown) {
    const result = callback();
    if (result === false || (result !== null && typeof result === "object" && "then" in result)) {
      // Observe rejected promises from unsupported async callbacks, without a queue.
      if (result && typeof result === "object" && "then" in result) void Promise.resolve(result).catch(() => {});
      fail();
    }
  }
  function completeLine() {
    let text = decoder.decode(line.subarray(0, lineBytes));
    lineBytes = 0;
    if (leading) { leading = false; if (text.startsWith("\uFEFF")) text = text.slice(1); }
    if (text === "") {
      if (hasData) {
        event ||= "message";
        if (!["message", "presence_snapshot", "presence_delta", "presence_reset"].includes(event)) fail();
        const bytes = data.slice(0, dataBytes - 1);
        if (event === "message") decodeServerMessage(bytes);
        else if (!isPresenceData(event, decodeWireJson(bytes))) fail();
        invoke(() => opts.onFrame({ event: event as BusFrame["event"], data: bytes }));
        invoke(() => opts.onActivity?.());
      } else if (event) fail();
      event = ""; hasData = false; dataBytes = 0;
      return true;
    }
    if (text.startsWith(":")) { invoke(() => opts.onActivity?.()); return false; }
    const colon = text.indexOf(":");
    const field = colon < 0 ? text : text.slice(0, colon);
    let value = colon < 0 ? "" : text.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") event = value;
    if (field === "data") {
      const bytes = encoder.encode(value);
      if (dataBytes + bytes.length + 1 > data.length) fail();
      data.set(bytes, dataBytes); dataBytes += bytes.length; data[dataBytes++] = 10; hasData = true;
    }
    return false;
  }
  function resolveCR() {
    const cr = pendingCR!;
    pendingCR = null;
    if (!cr.completed) cr.endedFrame = completeLine();
    if (cr.endedFrame) rawBytes = 0;
  }
  function guard(work: () => void) {
    if (stopped) fail();
    try { work(); } catch { fail(); }
  }
  return {
    push(chunk: Uint8Array) {
      guard(() => {
        if (!(chunk instanceof Uint8Array)) fail();
        for (const byte of chunk) {
          // Optional LF belongs to the CR's raw frame, even after dispatch.
          if (pendingCR) {
            if (byte === 10) {
              if (++rawBytes > MAX_DISCOVERY_BYTES) fail();
              resolveCR(); continue;
            }
            resolveCR();
          }
          if (++rawBytes > MAX_DISCOVERY_BYTES) fail();
          if (byte === 13) {
            // With LF headroom, semantic completion need not wait for input.
            const completed = rawBytes < MAX_DISCOVERY_BYTES;
            pendingCR = { completed, endedFrame: completed ? completeLine() : false };
          }
          else if (byte === 10) { if (completeLine()) rawBytes = 0; }
          else line[lineBytes++] = byte;
        }
      });
    },
    finish() {
      guard(() => {
        if (pendingCR) resolveCR();
        if (lineBytes || hasData || event) fail();
        stopped = true;
      });
    },
  };
}

export async function subscribeOnce(opts: Callbacks & {
  baseUrl: string; token: string; agentId: string; fetch: FetchLike;
  signal?: AbortSignal; now?: () => number; timers?: Timers;
}): Promise<StreamEnd> {
  if (opts.signal?.aborted) return { reason: "aborted" };
  if (!isUuid(opts.agentId)) return { reason: "protocol" };
  const now = opts.now ?? (() => performance.now());
  const timers = opts.timers ?? defaultTimers;
  const controller = new AbortController();
  let reader: ReturnType<NonNullable<Awaited<ReturnType<FetchLike>>["body"]>["getReader"]> | undefined;
  let timer: unknown, finished = false, deadline = now() + 5000;
  let resolveEnd!: (end: StreamEnd) => void;
  const ended = new Promise<StreamEnd>((resolve) => { resolveEnd = resolve; });
  function end(reason: StreamEnd["reason"]) {
    if (finished) return;
    finished = true; controller.abort(); resolveEnd({ reason });
  }
  const abort = () => end("aborted");
  function arm(delay: number) {
    timers.clearTimeout(timer);
    deadline = now() + delay;
    timer = timers.setTimeout(() => end("timeout"), delay);
  }
  function check() {
    if (finished || opts.signal?.aborted) throw Error("aborted");
    if (now() >= deadline) { end("timeout"); throw Error("timeout"); }
  }
  opts.signal?.addEventListener("abort", abort, { once: true });
  arm(5000);
  const parser = createSseParser({
    onFrame(frame) {
      check();
      if (frame.event === "message") decodeServerMessage(frame.data, opts.agentId);
      return opts.onFrame(frame);
    },
    onActivity() { check(); const result = opts.onActivity?.(); arm(30000); return result; }
  });
  async function run(): Promise<StreamEnd> {
    try {
      const res = await opts.fetch(`${opts.baseUrl}/v1/events?agentId=${encodeURIComponent(opts.agentId)}`, {
        method: "GET", headers: { authorization: `Bearer ${opts.token}`, accept: "text/event-stream" },
        signal: controller.signal, redirect: "manual",
      });
      check();
      if (res.status === 401) return { reason: "unauthorized" };
      if (res.status === 404) return { reason: "not_found" };
      if (res.status !== 200) return { reason: "unavailable" };
      if (!/^text\/event-stream(?:\s*;[^\r\n]*)?$/i.test(res.headers.get("content-type") ?? "") || !res.body) return { reason: "protocol" };
      arm(30000);
      reader = res.body.getReader();
      while (true) {
        const chunk = await reader.read();
        check();
        try {
          if (chunk.done) { parser.finish(); return { reason: "closed" }; }
          parser.push(chunk.value!);
        } catch { return { reason: "protocol" }; }
      }
    } catch { return { reason: finished ? "aborted" : "unavailable" }; }
  }
  try { return await Promise.race([run(), ended]); }
  finally {
    finished = true; timers.clearTimeout(timer); opts.signal?.removeEventListener("abort", abort); controller.abort();
    try { void reader?.cancel?.().catch(() => {}); } catch { /* cleanup never blocks return */ }
    try { reader?.releaseLock?.(); } catch { /* abandoned read may retain lock until settlement */ }
  }
}
