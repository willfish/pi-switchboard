import assert from "node:assert/strict";
import { it } from "node:test";
import { createSseParser, subscribeOnce, type BusFrame } from "../extension/sse.ts";
import type { FetchLike, Timers } from "../extension/client.ts";
import { createPresenceState, reducePresence } from "../extension/presence.ts";
const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", to = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const mail = { id, from: id, to, kind: "notice", body: "hello 😀", sender: { host: "h", label: "peer" }, acceptedAt: 1, expiresAt: 61 };
const encoder = new TextEncoder();
const wire = (event = "message", data: unknown = mail) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
function clock() {
  let time = 0, serial = 0;
  const jobs = new Map<number, { at: number; callback: () => void }>();
  const timers: Timers = { setTimeout(callback, delay) { const key = ++serial; jobs.set(key, { at: time + delay, callback }); return key; }, clearTimeout(key) { jobs.delete(key as number); } };
  return { now: () => time, timers, jobs, advance(ms: number) { time += ms; for (const [key, job] of jobs) if (job.at <= time) { jobs.delete(key); job.callback(); } } };
}
const flush = async () => { for (let n = 0; n < 10; n++) await Promise.resolve(); };
function stream(chunks: Uint8Array[], status = 200, type = "text/event-stream"): Awaited<ReturnType<FetchLike>> {
  let index = 0;
  return { status, headers: { get: () => type }, text: async () => { throw Error("text forbidden"); },
    body: { getReader: () => ({ read: async () => index < chunks.length ? { done: false, value: chunks[index++] } : { done: true } }) } };
}
const base = { baseUrl: "http://hub", token: "synthetic", agentId: to, onFrame: () => {} };
it("cold parser handles every fragmentation, BOM, newline convention, multiline data and ignored replay fields", () => {
  for (const newline of ["\n", "\r\n", "\r"]) {
    const text = "\uFEFF:keepalive\nid: never-replay\nretry: 1\nignored: x\n" + wire().replace(',"from"', ',\ndata: "from"');
    const bytes = encoder.encode(text.replaceAll("\n", newline));
    for (const size of [1, 2, 7, bytes.length]) {
      const frames: BusFrame[] = []; let activities = 0;
      const parser = createSseParser({ onFrame: (frame) => { frames.push(frame); }, onActivity: () => { activities++; } });
      assert.equal(activities, 0); assert.equal(frames.length, 0);
      for (let n = 0; n < bytes.length; n += size) parser.push(bytes.subarray(n, n + size));
      parser.finish();
      assert.equal(frames.length, 1); assert.deepEqual(JSON.parse(new TextDecoder().decode(frames[0].data)), mail); assert.equal(activities, 2);
    }
  }
});
it("raw frame limit includes all comments, ignored fields, BOM and CRLF framing at the exact boundary", () => {
  for (const newline of ["\n", "\r\n", "\r"]) for (const extra of [-1, 0, 1]) {
    const suffix = wire().replaceAll("\n", newline);
    const prefix = "\uFEFFignored: ";
    const pad = 1048576 - Buffer.byteLength(prefix + newline + suffix) + extra;
    const bytes = encoder.encode(prefix + "x".repeat(pad) + newline + suffix);
    for (const size of [1, bytes.length - newline.length, bytes.length]) {
      let count = 0; const parser = createSseParser({ onFrame: () => { count++; } });
      const parse = () => {
        for (let n = 0; n < bytes.length; n += size) parser.push(bytes.subarray(n, n + size));
        parser.finish();
      };
      if (extra > 0) { assert.throws(parse, /^Error: protocol$/); assert.equal(count, 0); }
      else { parse(); assert.equal(count, 1); }
    }
  }
});
it("defaults absent and empty event names to message with last-field-wins and case-sensitive validation", () => {
  for (const fields of ["", "event:\n", "event: unknown\nevent:\n", "event: unknown\nevent: message\n"]) {
    let calls = 0;
    const parser = createSseParser({ onFrame: (frame) => { calls++; assert.equal(frame.event, "message"); } });
    parser.push(encoder.encode(fields + `data:${JSON.stringify(mail)}\n\n`));
    assert.equal(calls, 1); parser.finish();
  }
  for (const fields of ["event: Message\n", "event: message\nevent: unknown\n"]) {
    const parser = createSseParser({ onFrame: () => { assert.fail("unknown event delivered"); } });
    assert.throws(() => parser.push(encoder.encode(fields + `data:${JSON.stringify(mail)}\n\n`)), /^Error: protocol$/);
  }
  // An ignored case-mismatched field still defaults to message, whose payload must validate.
  const parser = createSseParser({ onFrame: () => { assert.fail("invalid message delivered"); } });
  assert.throws(() => parser.push(encoder.encode("Event: message\ndata:{}\n\n")), /^Error: protocol$/);
});
it("CR events dispatch during push and optional LF never duplicates callbacks or activity", () => {
  for (const kind of ["notice", "prompt", "steer"]) {
    let calls = 0, activity = 0;
    const parser = createSseParser({ onFrame: () => { calls++; }, onActivity: () => { activity++; } });
    parser.push(encoder.encode(wire("message", { ...mail, kind }).replaceAll("\n", "\r")));
    assert.equal(calls, 1); assert.equal(activity, 1);
    parser.push(encoder.encode("\n"));
    assert.equal(calls, 1); assert.equal(activity, 1);
    parser.push(encoder.encode(wire().replaceAll("\n", "\r")));
    assert.equal(calls, 2); assert.equal(activity, 2);
    parser.finish(); assert.equal(calls, 2); assert.equal(activity, 2);
  }
});
it("exact-cap final CR defers control until non-LF or EOF and rejects optional LF before delivery", () => {
  for (const kind of ["prompt", "steer"]) for (const extra of [-1, 0, 1]) {
    const suffix = wire("message", { ...mail, kind }).replaceAll("\n", "\r");
    const bytes = encoder.encode(":" + "x".repeat(1048576 + extra - Buffer.byteLength(":\r" + suffix)) + "\r" + suffix);
    for (const resolution of ["lf", "non-lf", "eof"]) for (const size of [1, bytes.length - 1, bytes.length]) {
      let calls = 0;
      const parser = createSseParser({ onFrame: () => { calls++; } });
      const push = () => { for (let n = 0; n < bytes.length; n += size) parser.push(bytes.subarray(n, n + size)); };
      if (extra > 0) { assert.throws(push, /^Error: protocol$/); assert.equal(calls, 0); continue; }
      push(); assert.equal(calls, extra < 0 ? 1 : 0);
      if (resolution === "lf" && extra === 0) {
        assert.throws(() => parser.push(encoder.encode("\n")), /^Error: protocol$/); assert.equal(calls, 0);
      } else {
        if (resolution === "lf") parser.push(encoder.encode("\n"));
        if (resolution === "non-lf") parser.push(encoder.encode(wire()));
        parser.finish(); assert.equal(calls, resolution === "non-lf" ? 2 : 1);
      }
    }
  }
});
it("subscription accepts an exact 1MiB no-space presence frame and rejects one extra byte without callbacks", async () => {
  const doc = JSON.stringify({ epoch: id, revision: "1", snapshotId: to, capturedAt: 1, chunk: 0, total: 0, agents: [], final: true });
  const prefix = "event:presence_snapshot\ndata:";
  for (const extra of [-1, 0, 1]) {
    const bytes = encoder.encode(prefix + doc + " ".repeat(1048576 + extra - Buffer.byteLength(prefix + doc + "\n\n")) + "\n\n");
    assert.equal(bytes.length, 1048576 + extra);
    let calls = 0, publications = 0, activity = 0;
    let presence = createPresenceState();
    const end = await subscribeOnce({ ...base, onFrame: (frame) => {
      calls++;
      presence = reducePresence(presence, frame.event, frame.data, 0);
      if (presence.reconnect) return false;
      publications++;
    }, onActivity: () => { activity++; }, fetch: async () => stream([bytes]) });
    assert.equal(end.reason, extra > 0 ? "protocol" : "closed"); assert.equal(calls, extra > 0 ? 0 : 1);
    assert.equal(publications, extra > 0 ? 0 : 1); assert.equal(activity, publications);
    assert.equal(presence.revision, extra > 0 ? null : "1");
    assert.equal(presence.awaitingSnapshot, extra > 0);
  }
});
it("fails closed on unknown events, malformed wire, UTF-8, duplicate keys and truncated events", () => {
  for (const bytes of [encoder.encode(wire("unknown")), encoder.encode("data: {}\n\n"), encoder.encode("event: message\n\n"),
    encoder.encode(wire().slice(0, -1)), encoder.encode(":unfinished"), new Uint8Array([0xff, 10]),
    encoder.encode(wire().replace('"acceptedAt":1', '"acceptedAt":1,"acceptedAt":1')),
    encoder.encode(wire("message", { ...mail, sender: { host: "h", label: "bad\u2028" } })),
    encoder.encode(wire("presence_delta", {})), encoder.encode(wire("presence_snapshot", {})), encoder.encode(wire("presence_reset", {}))]) {
    const parser = createSseParser({ onFrame: () => { assert.fail("invalid callback"); } });
    assert.throws(() => { parser.push(bytes); parser.finish(); }, /^Error: protocol$/);
    assert.throws(() => parser.push(encoder.encode(wire())), /^Error: protocol$/);
  }
});
it("synchronous callback rejection or throw stops within a chunk without delivering later frames", () => {
  for (const callback of [() => false as const, () => { throw Error("synthetic private error"); }, () => Promise.reject(Error("synthetic"))]) {
    let calls = 0;
    const parser = createSseParser({ onFrame: (() => { calls++; return callback(); }) as () => false });
    assert.throws(() => parser.push(encoder.encode(wire() + wire())), /^Error: protocol$/); assert.equal(calls, 1);
  }
});
it("subscribes once with bearer headers, no replay or redirects, validates recipient and sanitizes ends", async () => {
  for (const [res, reason] of [[stream([encoder.encode(wire())]), "closed"], [stream([], 401), "unauthorized"], [stream([], 404), "not_found"],
    [stream([], 503), "unavailable"], [stream([], 302), "unavailable"], [stream([], 200, "application/json"), "protocol"],
    [stream([encoder.encode(wire("message", { ...mail, to: id, from: to }))]), "protocol"], [stream([encoder.encode(wire().slice(0, -1))]), "protocol"]] as const) {
    let calls = 0;
    const result = await subscribeOnce({ ...base, fetch: async (url, init) => {
      calls++; assert.equal(url, `http://hub/v1/events?agentId=${to}`); assert.equal(init?.redirect, "manual");
      assert.deepEqual(init?.headers, { authorization: "Bearer synthetic", accept: "text/event-stream" }); return res;
    } });
    assert.deepEqual(result, { reason }); assert.equal(calls, 1);
  }
});
it("enforces five-second handshake and thirty-second inactivity despite uncooperative fetch/read/cancel", async () => {
  for (const phase of ["fetch", "read"]) {
    const c = clock(); let signal: AbortSignal | undefined; let cancelled = false;
    const pending = subscribeOnce({ ...base, ...c, fetch: async (_url, init) => {
      signal = init?.signal;
      if (phase === "fetch") return new Promise(() => {});
      return { ...stream([]), body: { getReader: () => ({ read: () => new Promise(() => {}), cancel: () => { cancelled = true; return new Promise(() => {}); } }) } };
    } });
    await flush(); c.advance(phase === "fetch" ? 5000 : 30000);
    assert.deepEqual(await pending, { reason: "timeout" }); assert.equal(signal?.aborted, true); assert.equal(c.jobs.size, 0); assert.equal(cancelled, phase === "read");
  }
});
it("only complete valid comments or frames refresh inactivity, not drip bytes", async () => {
  for (const keepalive of [":valid\n", ":valid\r", ":drip"]) {
    const c = clock(); let next!: (chunk: { done: boolean; value?: Uint8Array }) => void; let activity = 0;
    const pending = subscribeOnce({ ...base, ...c, onActivity: () => { activity++; }, fetch: async () => ({ ...stream([]),
      body: { getReader: () => ({ read: () => new Promise((resolve) => { next = resolve; }) }) } }) });
    await flush(); c.advance(29000); next({ done: false, value: encoder.encode(keepalive) }); await flush();
    if (/[\r\n]$/.test(keepalive)) assert.deepEqual([...c.jobs.values()].map((job) => job.at), [59000]);
    c.advance(500);
    if (keepalive.endsWith("\r")) {
      next({ done: false, value: encoder.encode("\n") }); await flush();
      assert.equal(activity, 1); assert.deepEqual([...c.jobs.values()].map((job) => job.at), [59000]);
    }
    c.advance(500); await flush();
    assert.equal(activity, /[\r\n]$/.test(keepalive) ? 1 : 0);
    if (activity) { assert.equal(c.jobs.size, 1); c.advance(29000); }
    assert.deepEqual(await pending, { reason: "timeout" }); assert.equal(c.jobs.size, 0);
  }
});
it("caller abort settles immediately, fences late readers and never waits for cancellation", async () => {
  const c = clock(), abort = new AbortController(); let next!: (chunk: { done: boolean; value?: Uint8Array }) => void; let calls = 0;
  const pending = subscribeOnce({ ...base, ...c, signal: abort.signal, onFrame: () => { calls++; }, fetch: async () => ({ ...stream([]),
    body: { getReader: () => ({ read: () => new Promise((resolve) => { next = resolve; }), cancel: () => new Promise(() => {}) }) } }) });
  await flush(); abort.abort(); assert.deepEqual(await pending, { reason: "aborted" });
  next({ done: false, value: encoder.encode(wire()) }); await flush(); assert.equal(calls, 0); assert.equal(c.jobs.size, 0);
  assert.deepEqual(await subscribeOnce({ ...base, signal: abort.signal, fetch: () => { throw Error("must not fetch"); } }), { reason: "aborted" });
});
it("leaves sequencing to the callback's real reducer and stops rejected gaps before health or later frames", async () => {
  const snapshot = { epoch: id, revision: "1", snapshotId: to, capturedAt: 1, chunk: 0, total: 0, agents: [], final: true };
  const delta = { epoch: id, fromRevision: "1", toRevision: "1", changes: [], caughtUp: true };
  for (const gap of [false, true]) for (const rejection of ["false", "throw"]) {
    let frames = 0, publications = 0, activity = 0, healthy = 0;
    let presence = createPresenceState();
    const result = await subscribeOnce({ ...base, onFrame: (frame) => {
      frames++;
      if (frame.event === "message") return;
      presence = reducePresence(presence, frame.event, frame.data, 0);
      if (presence.reconnect) {
        if (rejection === "throw") throw Error("rejected sequence");
        return false;
      }
      publications++;
      if (presence.status === "current") healthy++;
    }, onActivity: () => { activity++; }, fetch: async () => stream([encoder.encode(
      wire("presence_snapshot", snapshot) + wire("presence_delta", { ...delta, fromRevision: gap ? "0" : "1", toRevision: gap ? "0" : "1" }) + wire())]) });
    assert.equal(result.reason, gap ? "protocol" : "closed");
    // The gap reaches the sole reducer, but cannot publish or refresh activity.
    assert.equal(frames, gap ? 2 : 3); assert.equal(publications, gap ? 1 : 2);
    assert.equal(activity, gap ? 1 : 3); assert.equal(healthy, gap ? 0 : 1);
    assert.equal(presence.reconnect, gap);
  }
  for (const rejection of ["false", "throw"]) {
    let frames = 0, activity = 0;
    const result = await subscribeOnce({ ...base, onFrame: () => {
      frames++;
      if (rejection === "throw") throw Error("callback rejected");
      return false;
    }, onActivity: () => { activity++; }, fetch: async () => stream([encoder.encode(wire() + wire())]) });
    assert.equal(result.reason, "protocol"); assert.equal(frames, 1); assert.equal(activity, 0);
  }
});
