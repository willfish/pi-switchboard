import assert from "node:assert/strict";
import { it } from "node:test";
import { createHubClient, type FetchLike, type Timers } from "../extension/client.ts";
import { decodeServerMessage, isServerMessage } from "../extension/protocol.ts";
const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", to = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const msg = { id, from: id, to, kind: "notice" as const, body: "hello 😀" };
const acceptance = { id, to, state: "accepted", receiving: false, expiresAt: 61 };
function response(status: number, doc?: unknown, length?: string): Awaited<ReturnType<FetchLike>> {
  const data = typeof doc === "string" ? new TextEncoder().encode(doc) : new TextEncoder().encode(doc === undefined ? "" : JSON.stringify(doc));
  let offset = 0;
  return { status, headers: { get: () => length ?? null }, text: async () => { throw Error("text forbidden"); },
    body: { getReader: () => ({ read: async () => offset < data.length
      ? { done: false, value: data.subarray(offset, offset += 17) } : { done: true } }) } };
}
function clock() {
  let time = 0; let sequence = 0;
  const jobs = new Map<number, { at: number; callback: () => void }>();
  const timers: Timers = { setTimeout(callback, delay) { const key = ++sequence; jobs.set(key, { at: time + delay, callback }); return key; }, clearTimeout(key) { jobs.delete(key as number); } };
  return { timers, now: () => time, jobs, advance(ms: number) { time += ms; for (const [key, job] of jobs) if (job.at <= time) { jobs.delete(key); job.callback(); } } };
}
const flush = async () => { for (let n = 0; n < 10; n++) await Promise.resolve(); };
it("validates complete exact acceptance and never retries malformed acceptances", async () => {
  for (const doc of [acceptance, ...["id", "to", "state", "receiving", "expiresAt"].map((key) => ({ ...acceptance, [key]: undefined })),
    { ...acceptance, extra: true }, { ...acceptance, state: "delivered" }, { ...acceptance, receiving: 1 },
    { ...acceptance, expiresAt: -1 }, { ...acceptance, expiresAt: 1.5 }, { ...acceptance, id: to }, { ...acceptance, to: id }]) {
    let calls = 0;
    const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", fetch: async (_url, init) => {
      calls++; assert.equal(init?.redirect, "manual"); assert.equal(init?.method, "POST"); return response(202, doc);
    } });
    const result = await client.send(msg);
    assert.equal(result.status, doc === acceptance ? "accepted" : "outcome_unknown");
    if (result.status === "accepted") assert.equal(result.expiresAt, 61);
    assert.equal(calls, 1);
  }
});
it("latches and notifies once at 401 headers on every protected route, without reading a body", async () => {
  let notifications = 0;
  const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", onUnauthorized() { notifications++; assert.equal(client.isUnauthorized(), true); }, fetch: async () => ({
    status: 401, headers: { get: () => null }, text: () => { throw Error("body accessed"); }, body: { getReader: () => { throw Error("reader accessed"); } },
  }) });
  assert.equal(client.isUnauthorized(), false);
  assert.deepEqual(await client.send(msg), { status: "rejected", reason: "unauthorized" });
  await client.putAgent({ agentId: id }); await client.deleteAgent(id); await client.listAgents();
  assert.equal(notifications, 1);
});
it("preserves a request's observed 401 when authentication shutdown aborts concurrent POSTs", async () => {
  const stop = new AbortController();
  let calls = 0;
  const client = createHubClient({ baseUrl: "http://hub", token: "synthetic",
    onUnauthorized() { stop.abort(); },
    fetch: async () => ++calls === 1 ? new Promise(() => {}) : response(401),
  });
  const uncertain = client.send(msg, stop.signal);
  const rejected = client.send({ ...msg, id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc" }, stop.signal);
  assert.deepEqual(await rejected, { status: "rejected", reason: "unauthorized" });
  assert.equal((await uncertain).status, "outcome_unknown", "another request's 401 cannot establish this POST's outcome");
  assert.equal(calls, 2);
});

it("bounds uncooperative fetch, reads and cancellation to five seconds using injected timers", async () => {
  for (const phase of ["fetch", "read"] as const) for (const method of ["send", "putAgent", "deleteAgent", "listAgents"] as const) {
    const c = clock(); let calls = 0; let signal: AbortSignal | undefined;
    const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", ...c, fetch: async (_url, init) => {
      calls++; signal = init?.signal;
      if (phase === "fetch") return new Promise(() => {});
      return { ...response(200), body: { getReader: () => ({ read: () => new Promise(() => {}), cancel: () => new Promise(() => {}) }) } };
    } });
    const pending = method === "send" ? client.send(msg) : method === "putAgent" ? client.putAgent({ agentId: id }) : method === "deleteAgent" ? client.deleteAgent(id) : client.listAgents();
    await flush(); c.advance(5000);
    const result = await pending;
    if (result) assert.equal(result.status, method === "listAgents" ? "not_sent" : "outcome_unknown");
    assert.equal(calls, 1); assert.equal(signal?.aborted, true); assert.equal(c.jobs.size, 0);
  }
});
it("cancels all operations and distinguishes pre-dispatch from post-dispatch POST failure", async () => {
  let calls = 0;
  const c = clock(); const abort = new AbortController();
  const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", ...c, fetch: async () => { calls++; return new Promise(() => {}); } });
  const pending = client.send(msg, abort.signal); abort.abort();
  assert.equal((await pending).status, "outcome_unknown");
  assert.equal((await client.send(msg, abort.signal)).status, "not_sent");
  assert.equal(calls, 1); assert.equal(c.jobs.size, 0);
  for (const method of ["putAgent", "deleteAgent", "listAgents"] as const) {
    const a = new AbortController();
    const pending = method === "putAgent" ? client.putAgent({ agentId: id }, a.signal) : method === "deleteAgent" ? client.deleteAgent(id, a.signal) : client.listAgents(a.signal);
    a.abort(); await pending; assert.equal(c.jobs.size, 0);
  }
  const broken = createHubClient({ baseUrl: "http://hub", token: "synthetic", fetch: () => { throw Error("private network details"); } });
  assert.equal((await broken.send(msg)).status, "outcome_unknown");
  assert.equal((await broken.send({ ...msg, body: "x".repeat(16385) })).status, "not_sent");
});
it("bounds all ordinary response bytes and ignores remote diagnostics", async () => {
  for (const status of [200, 202, 204, 400, 503]) for (const length of [undefined, "32769", "-1", "1"]) {
    const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", fetch: async () => response(status, "x".repeat(32769), length) });
    assert.equal((await client.send(msg)).status, "outcome_unknown");
    assert.equal((await client.putAgent({ agentId: id })).status, "outcome_unknown");
    await client.deleteAgent(id);
  }
  for (const doc of [{ error: { code: "control_disabled", message: "synthetic secret" } }, { error: { code: "synthetic secret", message: "synthetic secret" } }]) {
    const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", fetch: async () => response(403, doc) });
    const result = await client.send(msg); assert.equal(result.status, "rejected"); assert.ok(!JSON.stringify(result).includes("synthetic"));
  }
});
it("treats redirects, unexpected success, duplicate JSON and lost fetch as uncertain without POST replay", async () => {
  for (const [status, doc] of [[302, ""], [200, acceptance], [204, undefined], [500, {}], [202, JSON.stringify(acceptance).replace('"expiresAt":61', '"expiresAt":61,"expiresAt":61')]] as const) {
    let calls = 0;
    const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", fetch: async () => { calls++; return response(status, doc); } });
    assert.equal((await client.send(msg)).status, "outcome_unknown"); assert.equal(calls, 1);
  }
  let calls = 0;
  const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", fetch: async () => { calls++; return response(202, acceptance); } });
  assert.equal((await client.send({ ...msg, body: "\u0000".repeat(16384) })).status, "not_sent"); assert.equal(calls, 0);
});
it("checks monotonic deadlines at headers and completed reads, and caps cleanup independently", async () => {
  for (const phase of ["headers", "end"]) for (const elapsed of [4999, 5000]) {
    let now = 0;
    const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", now: () => now, fetch: async () => {
      if (phase === "headers") now = elapsed;
      const res = response(202, acceptance), reader = res.body!.getReader();
      return { ...res, body: { getReader: () => ({ read: async () => { const chunk = await reader.read(); if (phase === "end" && chunk.done) now = elapsed; return chunk; } }) } };
    } });
    assert.equal((await client.send(msg)).status, elapsed === 4999 ? "accepted" : "outcome_unknown");
  }
  for (const [timeoutMs, deadline] of [[2000, 2000], [60000, 5000]]) {
    const c = clock();
    const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", ...c, timeoutMs, fetch: () => new Promise(() => {}) });
    const pending = client.deleteAgent(id); c.advance(deadline); await pending; assert.equal(c.jobs.size, 0);
  }
});
it("validates exact server envelopes, recipient, UTF-8 and body bytes without receiver expiry", () => {
  const mail = { ...msg, sender: { host: "host", label: "peer" }, acceptedAt: 1, expiresAt: 61 };
  const encode = (value: unknown) => new TextEncoder().encode(JSON.stringify(value));
  assert.deepEqual(decodeServerMessage(encode(mail), to), mail);
  assert.throws(() => decodeServerMessage(encode(mail), id));
  for (const patch of [{ extra: true }, { sender: { host: "h", label: "l", extra: true } }, { acceptedAt: -1 }, { expiresAt: 62 },
    { body: "😀".repeat(4097) }, { body: "\ud800" }, { kind: "ask" }, { sender: { host: "é", label: "l" } }]) assert.equal(isServerMessage({ ...mail, ...patch }), false);
  assert.equal(isServerMessage({ ...mail, body: "😀".repeat(4096) }), true);
  assert.throws(() => decodeServerMessage(new Uint8Array([0xff])));
  assert.throws(() => decodeServerMessage(new TextEncoder().encode(JSON.stringify(mail).replace('"acceptedAt":1', '"acceptedAt":1,"acceptedAt":1'))));
  assert.throws(() => decodeServerMessage(new TextEncoder().encode(JSON.stringify(mail) + " ".repeat(32768))));
});
