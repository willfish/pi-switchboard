import assert from "node:assert/strict";
import { it } from "node:test";
import { createHubClient } from "../extension/client.ts";

const epoch = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const snapshotId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
function agent(n: number) {
  return { agentId: `${n.toString(16).padStart(8, "0")}-0000-4000-8000-000000000000`,
    sessionId: epoch, host: "host", cwd: "/tmp", sessionName: "session", label: "peer 😀",
    model: null, status: "idle", pid: 1, acceptsControl: false, receiving: true, updatedAt: 1 };
}
function page(overrides = {}) {
  return { epoch, revision: "18446744073709551615", snapshotId, capturedAt: 1,
    page: 0, total: 1, agents: [agent(1)], nextCursor: null, ...overrides };
}
function response(doc: unknown, fragment = 7) {
  const bytes = doc instanceof Uint8Array ? doc : typeof doc === "string" ? new TextEncoder().encode(doc) : new TextEncoder().encode(JSON.stringify(doc));
  let offset = 0;
  return { status: 200, headers: { get: () => null },
    text: async () => { throw new Error("unbounded text forbidden"); },
    body: { getReader: () => ({ read: async () => {
      if (offset >= bytes.length) return { done: true };
      const value = bytes.slice(offset, offset += fragment);
      return { done: false, value };
    } }) } };
}
const nextCursor = (index: number) => Buffer.from(`${snapshotId}:${index}`).toString("base64url");
const cursor = nextCursor(1);
it("streams fragmented UTF-8 pages and publishes only the complete traversal", async () => {
  const urls: string[] = [];
  const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async (url, init) => {
    urls.push(url); assert.equal(init?.redirect, "manual");
    return response(page(urls.length === 1 ? { total: 2, nextCursor: cursor } : { total: 2, page: 1, agents: [agent(2)] }), 1);
  } });
  assert.deepEqual(await client.listAgents(), { status: "ok", agents: [agent(1), agent(2)] });
  assert.deepEqual(urls, ["http://hub/v1/agents", `http://hub/v1/agents?cursor=${cursor}`]);
});
it("rejects incomplete, mismatched, unordered, overfull and invalid exact wire pages without retry", async () => {
  for (const invalid of [ { total: 2 }, { revision: "01" }, { revision: "18446744073709551616" },
    { extra: true }, { agents: [{ ...agent(1), receiving: undefined }] }, { total: 5001 },
    { agents: [agent(2), agent(1)], total: 2 }, { agents: [{ ...agent(1), label: "\ud800" }] } ]) {
    let calls = 0;
    const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => { calls++; return response(page(invalid)); } });
    assert.equal((await client.listAgents()).status, "not_sent", JSON.stringify(invalid));
    assert.equal(calls, 1);
  }
});
it("validates every public record field and its bounds", async () => {
  for (const invalid of [{ agentId: "bad" }, { sessionId: "bad" }, { host: "é" }, { host: "h".repeat(256) },
    { cwd: "" }, { cwd: "😀".repeat(1025) }, { cwd: "/bad\u0000" }, { sessionName: "" },
    { label: "😀".repeat(201) }, { label: "bad\u0080" }, { label: "bad\u2028" },
    { model: { provider: "p".repeat(201), id: "m" } }, { model: { provider: "p", id: "m".repeat(513) } },
    { model: { provider: "p", id: "m", extra: 1 } }, { status: "unknown" }, { pid: 0 }, { pid: 1.5 },
    { acceptsControl: 0 }, { receiving: "true" }, { updatedAt: -1 }, { updatedAt: 0.5 }, { extra: true }]) {
    const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => response(page({ agents: [{ ...agent(1), ...invalid }] }), 65536) });
    assert.equal((await client.listAgents()).status, "not_sent", JSON.stringify(invalid));
  }
  const boundary = { ...agent(1), host: "h".repeat(255), cwd: "😀".repeat(1024), label: "😀".repeat(200), model: { provider: "p".repeat(200), id: "m".repeat(512) } };
  const valid = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => response(page({ agents: [boundary] }), 1) });
  assert.deepEqual(await valid.listAgents(), { status: "ok", agents: [boundary] });
});
it("rejects cross-page generation changes, skipped pages, duplicates and cursor loops", async () => {
  for (const invalid of [{ epoch: snapshotId }, { snapshotId: epoch }, { revision: "1" }, { capturedAt: 2 },
    { total: 3 }, { page: 2 }, { agents: [agent(1)] }, { nextCursor: cursor }, { agents: [] }]) {
    let calls = 0;
    const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => {
      calls++; return response(page(calls === 1 ? { total: 2, nextCursor: cursor }
        : { total: 2, page: 1, agents: [agent(2)], ...invalid }));
    } });
    assert.equal((await client.listAgents()).status, "not_sent", JSON.stringify(invalid));
    assert.equal(calls, 2);
  }
});
it("requires canonical continuation cursors for the same snapshot and next page", async () => {
  for (const bad of ["a", cursor + "=", nextCursor(2), Buffer.from(`${epoch}:1`).toString("base64url"),
    Buffer.from(`${snapshotId}:01`).toString("base64url")]) {
    let calls = 0;
    const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => {
      calls++; return response(page(calls === 1 ? { total: 2, nextCursor: bad } : { total: 2, page: 1, agents: [agent(2)] }));
    } });
    assert.equal((await client.listAgents()).status, "not_sent"); assert.equal(calls, 1);
  }
});
it("accepts empty and 5000-agent snapshots, refuses a 129-record page", async () => {
  const empty = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => response(page({ agents: [], total: 0 })) });
  assert.deepEqual(await empty.listAgents(), { status: "ok", agents: [] });
  let index = 0;
  const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => {
    const start = index * 128;
    return response(page({ total: 5000, page: index++, agents: Array.from({ length: Math.min(128, 5000 - start) }, (_, n) => agent(start + n)),
      nextCursor: start + 128 < 5000 ? nextCursor(index) : null }), 65536);
  } });
  const result = await client.listAgents();
  assert.equal(result.status, "ok"); if (result.status === "ok") assert.equal(result.agents.length, 5000);
  const large = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => response(page({ total: 129, agents: Array.from({ length: 129 }, (_, n) => agent(n)) }), 65536) });
  assert.equal((await large.listAgents()).status, "not_sent");
});
it("bounds raw page bytes, validates fatal UTF-8, duplicate keys and escaped surrogates", async () => {
  const valid = JSON.stringify(page());
  for (const doc of [new Uint8Array([0xc0, 0xaf]), new Uint8Array([0xf0, 0x9f, 0x98]),
    valid.replace('"total":1', '"total":1,"total":1'), valid.replace('peer 😀', 'peer \\ud800'), valid + " ".repeat(1048576)]) {
    const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => response(doc, 1048576) });
    assert.equal((await client.listAgents()).status, "not_sent");
  }
  const exact = valid + " ".repeat(1048576 - Buffer.byteLength(valid));
  const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => response(exact, 1048576) });
  assert.equal((await client.listAgents()).status, "ok");
});
it("enforces the 256MiB aggregate budget at the exact boundary", async () => {
  for (const total of [256, 257]) {
    let index = 0;
    const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => {
      const doc = JSON.stringify(page({ total, page: index, agents: [agent(index)], nextCursor: ++index < total ? nextCursor(index) : null }));
      return response(doc + " ".repeat(1048576 - Buffer.byteLength(doc)), 1048576);
    } });
    assert.equal((await client.listAgents()).status, total === 256 ? "ok" : "not_sent");
    assert.equal(index, total);
  }
});
it("enforces exact 5s request and 30s traversal deadlines including streaming and decoding", async () => {
  for (const elapsed of [4999, 5000]) {
    let time = 0;
    const client = createHubClient({ baseUrl: "http://hub", token: "secret", now: () => time, fetch: async () => { time = elapsed; return response(page(), 65536); } });
    assert.equal((await client.listAgents()).status, elapsed === 4999 ? "ok" : "not_sent");
  }
  let time = 0; let calls = 0;
  const client = createHubClient({ baseUrl: "http://hub", token: "secret", now: () => time, fetch: async () => {
    time += 4000;
    return response(page({ total: 8, page: calls, agents: [agent(calls)], nextCursor: ++calls < 8 ? nextCursor(calls) : null }), 65536);
  } });
  assert.equal((await client.listAgents()).status, "not_sent"); assert.equal(calls, 8);
  let aborted = false;
  const stalled = createHubClient({ baseUrl: "http://hub", token: "secret", timeoutMs: 5, fetch: async (_url, init) => {
    init?.signal?.addEventListener("abort", () => { aborted = true; });
    return { ...response(page()), body: { getReader: () => ({ read: () => new Promise(() => {}) }) } };
  } });
  assert.equal((await stalled.listAgents()).status, "not_sent"); assert.equal(aborted, true);
});
it("times out and aborts a fetch stalled before headers without retry", { timeout: 1000 }, async () => {
  let calls = 0;
  let aborts = 0;
  let signal: AbortSignal | undefined;
  const client = createHubClient({ baseUrl: "http://hub", token: "secret", timeoutMs: 5, fetch: async (_url, init) => {
    calls++;
    assert.equal(init?.method, "GET");
    assert.equal(init?.redirect, "manual");
    signal = init?.signal;
    signal?.addEventListener("abort", () => { aborts++; });
    return new Promise<never>(() => {});
  } });
  assert.deepEqual(await client.listAgents(), { status: "not_sent", reason: "timeout" });
  assert.equal(calls, 1);
  assert.equal(signal?.aborted, true);
  assert.equal(aborts, 1);
});
it("rejects continuation 401 from headers without touching its stalled body", { timeout: 1000 }, async () => {
  const urls: string[] = [];
  const signals: Array<AbortSignal | undefined> = [];
  let readers = 0;
  let reads = 0;
  let texts = 0;
  const client = createHubClient({ baseUrl: "http://hub", token: "secret", timeoutMs: 20, fetch: async (url, init) => {
    urls.push(url);
    signals.push(init?.signal);
    if (urls.length === 1) return response(page({ total: 2, nextCursor: cursor }), 65536);
    return {
      status: 401, headers: { get: () => null },
      text: () => { texts++; return new Promise<string>(() => {}); },
      body: { getReader: () => {
        readers++;
        return { read: () => { reads++; return new Promise<never>(() => {}); } };
      } },
    };
  } });
  assert.deepEqual(await client.listAgents(), { status: "not_sent", reason: "unauthorized" });
  assert.deepEqual(urls, ["http://hub/v1/agents", `http://hub/v1/agents?cursor=${cursor}`]);
  assert.equal(readers, 0);
  assert.equal(reads, 0);
  assert.equal(texts, 0);
  assert.ok(signals.every((signal) => signal?.aborted));
});
for (const failure of ["overflow", "malformed JSON"] as const) {
  it(`aborts and cancels its reader on ${failure} without reading further or retrying`, async () => {
    const valid = JSON.stringify(page());
    const chunks = failure === "overflow"
      ? [new TextEncoder().encode(valid + " ".repeat(1048576 - Buffer.byteLength(valid))), new Uint8Array([0x20])]
      : [new TextEncoder().encode("{")];
    let calls = 0;
    let reads = 0;
    let texts = 0;
    const cleanup: string[] = [];
    let signal: AbortSignal | undefined;
    const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async (_url, init) => {
      calls++;
      signal = init?.signal;
      signal?.addEventListener("abort", () => { cleanup.push("abort"); });
      return {
        status: 200, headers: { get: () => null },
        text: async () => { texts++; throw Error("unbounded text forbidden"); },
        body: { getReader: () => ({
          read: async () => {
            const value = chunks[reads++];
            return value === undefined ? { done: true } : { done: false, value };
          },
          cancel: async () => { cleanup.push("cancel"); },
          releaseLock: () => { cleanup.push("release"); },
        }) },
      };
    } });
    assert.deepEqual(await client.listAgents(), { status: "not_sent", reason: "discovery failed" });
    assert.equal(calls, 1);
    assert.equal(reads, 2, "overflow must stop before requesting end-of-stream");
    assert.equal(texts, 0);
    assert.equal(signal?.aborted, true);
    assert.deepEqual(cleanup, ["abort", "cancel", "release"]);
  });
}
it("bounds preflight length, cancels readers and never falls back to text", async () => {
  for (const length of ["1048577", "-1", "garbage", "1"]) {
    let read = false;
    let cancelled = false;
    const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => ({
      ...response(page()), headers: { get: (name) => name === "content-length" ? length : null },
      body: { getReader: () => ({ read: async () => { read = true; return { done: true }; }, cancel: async () => { cancelled = true; } }) },
    }) });
    assert.equal((await client.listAgents()).status, "not_sent");
    assert.equal(read, length === "1"); assert.equal(cancelled, length === "1");
  }
  let textCalls = 0;
  const noReader = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => ({
    status: 200, headers: { get: () => null }, text: async () => { textCalls++; return JSON.stringify(page()); },
  }) });
  assert.equal((await noReader.listAgents()).status, "not_sent"); assert.equal(textCalls, 0);
});
it("discards staged pages on a continuation reset with no retry or cached fallback", async () => {
  let calls = 0;
  const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => {
    calls++;
    if (calls === 1) return response(page());
    if (calls === 2) return response(page({ total: 2, nextCursor: cursor }));
    return { ...response({ error: { message: "secret" } }), status: 409 };
  } });
  assert.equal((await client.listAgents()).status, "ok");
  assert.deepEqual(await client.listAgents(), { status: "not_sent", reason: "discovery reset" });
  assert.equal(calls, 3);
});
it("checks the request deadline after the final streamed byte and the exact overall deadline", async () => {
  let time = 0;
  const late = createHubClient({ baseUrl: "http://hub", token: "secret", now: () => time, fetch: async () => {
    const res = response(page(), 65536);
    const reader = res.body.getReader();
    return { ...res, body: { getReader: () => ({ read: async () => { const chunk = await reader.read(); if (chunk.done) time = 5000; return chunk; } }) } };
  } });
  assert.equal((await late.listAgents()).status, "not_sent");
  for (const finalElapsed of [1999, 2000]) {
    time = 0; let calls = 0;
    const client = createHubClient({ baseUrl: "http://hub", token: "secret", now: () => time, fetch: async () => {
      time += calls === 7 ? finalElapsed : 4000;
      return response(page({ total: 8, page: calls, agents: [agent(calls)], nextCursor: ++calls < 8 ? nextCursor(calls) : null }), 65536);
    } });
    assert.equal((await client.listAgents()).status, finalElapsed === 1999 ? "ok" : "not_sent");
  }
});
it("read-only errors are not_sent with no token diagnostics", async () => {
  for (const status of [401, 409, 503, 302]) {
    const client = createHubClient({ baseUrl: "http://hub", token: "secret", fetch: async () => ({ ...response({ error: { message: "secret" } }), status }) });
    const result = await client.listAgents();
    assert.equal(result.status, "not_sent"); assert.ok(!JSON.stringify(result).includes("secret"));
  }
});
