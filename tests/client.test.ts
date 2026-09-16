import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { readFile } from "node:fs/promises";
import { createHubClient } from "../extension/client.ts";
import { createAgentBusExtension as createExtension, type AgentBusDeps } from "../extension/index.ts";
import { context, dormantSubscribe, flush } from "./client-test-helpers.ts";

// Supply complete SDK contexts and an independently controlled stream. HTTP assertions remain one-attempt.
function createAgentBusExtension(deps: AgentBusDeps = {}) {
  const runtime = createExtension({ hostname: () => "fixture", pid: () => 9, subscribe: dormantSubscribe, ...deps });
  return { ...runtime,
    async sessionStart(event: { reason?: string }, ctx: Record<string, any>) { runtime.sessionStart(event, context(ctx)); await flush(); },
    async handleCommand(name: string, args: string, ctx: Record<string, any>) { const result = await runtime.handleCommand(name, args, context(ctx)); await flush(); return result; },
  };
}

const token = "test-token";
const baseUrl = "http://127.0.0.1:7420";
const agentA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const agentB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

function jsonResponse(status: number, body: unknown, extra: { location?: string } = {}) {
  return {
    status,
    headers: {
      get(name: string) {
        if (name.toLowerCase() === "location") {
          return extra.location ?? null;
        }
        return name.toLowerCase() === "content-type" ? "application/json" : null;
      },
    },
    async text() {
      return JSON.stringify(body);
    },
    body: { getReader() {
      let done = false;
      return { async read() {
        if (done) return { done: true };
        done = true;
        return { done: false, value: new TextEncoder().encode(JSON.stringify(body)) };
      } };
    } },
  };
}

describe("shared wire fixtures", () => {
  it("sends the same registration fixture validated by Erlang", async () => {
    const agent = JSON.parse(await readFile(new URL("./fixtures/register-valid.json", import.meta.url), "utf8"));
    let calls = 0;
    const client = createHubClient({ baseUrl, token, fetch: async (url, init) => {
      calls += 1;
      assert.equal(url, `${baseUrl}/v1/agents/${agent.agentId}`);
      assert.equal(init?.method, "PUT");
      assert.deepEqual(JSON.parse(init?.body ?? "null"), agent);
      return jsonResponse(204, null);
    } });
    assert.deepEqual(await client.putAgent(agent), { status: "ok" });
    assert.equal(calls, 1);
  });

  it("sends the same notice fixture validated by Erlang", async () => {
    const message = JSON.parse(await readFile(new URL("./fixtures/message-notice.json", import.meta.url), "utf8"));
    let calls = 0;
    const client = createHubClient({ baseUrl, token, fetch: async (url, init) => {
      calls += 1;
      assert.equal(url, `${baseUrl}/v1/messages`);
      assert.equal(init?.method, "POST");
      assert.deepEqual(JSON.parse(init?.body ?? "null"), message);
      return jsonResponse(202, {
        id: message.id, to: message.to, state: "accepted", expiresAt: 1770000060, receiving: false,
      });
    } });
    assert.equal((await client.send(message)).status, "accepted");
    assert.equal(calls, 1);
  });
});

describe("hub client", () => {
  it("accepts 202 as accepted and does not retry", async () => {
    let posts = 0;
    const client = createHubClient({
      baseUrl,
      token,
      fetch: async (url, init) => {
        assert.equal(init?.redirect, "manual");
        if (init?.method === "POST") {
          posts += 1;
          return jsonResponse(202, {
            id: "33333333-3333-4333-8333-333333333333",
            to: agentB,
            state: "accepted",
            expiresAt: 1,
            receiving: true,
          });
        }
        throw new Error(`unexpected ${url}`);
      },
    });
    const once = await client.send({
      id: "33333333-3333-4333-8333-333333333333",
      from: agentA,
      to: agentB,
      kind: "notice",
      body: "hi",
    });
    assert.equal(once.status, "accepted");
    assert.equal(posts, 1);
  });

  it("maps timeout after send to outcome_unknown", async () => {
    const client = createHubClient({
      baseUrl,
      token,
      timeoutMs: 10,
      fetch: async (_url, init) => {
        return new Promise((_, reject) => {
          init?.signal?.addEventListener("abort", () => {
            const err = new Error("aborted");
            err.name = "AbortError";
            reject(err);
          });
        });
      },
    });
    const result = await client.send({
      id: "33333333-3333-4333-8333-333333333333",
      from: agentA,
      to: agentB,
      kind: "prompt",
      body: "go",
    });
    assert.equal(result.status, "outcome_unknown");
  });

  it("refuses redirects and malformed bodies", async () => {
    const redirect = createHubClient({
      baseUrl,
      token,
      fetch: async () => jsonResponse(302, {}, { location: "http://evil.example" }),
    });
    const redirected = await redirect.listAgents();
    assert.equal(redirected.status, "not_sent");

    const malformed = createHubClient({
      baseUrl,
      token,
      fetch: async () => ({
        status: 500,
        headers: { get: () => null },
        async text() {
          return "<html>nope";
        },
      }),
    });
    const bad = await malformed.listAgents();
    assert.equal(bad.status, "not_sent");
  });
});

describe("POST failure fencing", () => {
  const message = { id: agentA, from: agentA, to: agentB, kind: "notice" as const, body: "hi" };
  it("keeps malformed accepted responses uncertain and never retries", async () => {
    let calls = 0;
    const client = createHubClient({ baseUrl, token, fetch: async () => { calls++; return jsonResponse(202, {}); } });
    assert.equal((await client.send(message)).status, "outcome_unknown");
    assert.equal(calls, 1);
  });
  it("handles unauthorized headers without depending on the body", async () => {
    const client = createHubClient({ baseUrl, token, fetch: async () => ({ ...jsonResponse(401, {}), text: async () => { throw Error(token); } }) });
    assert.deepEqual(await client.send(message), { status: "rejected", reason: "unauthorized" });
  });
  it("does not expose echoed authentication data in remote errors", async () => {
    const client = createHubClient({ baseUrl, token, fetch: async () => jsonResponse(403, { error: { message: token } }) });
    assert.ok(!JSON.stringify(await client.send(message)).includes(token));
  });
});

describe("extension factory", () => {
  it("does not touch the network when created", () => {
    let called = 0;
    createAgentBusExtension({
      fetch: async () => {
        called += 1;
        throw new Error("network");
      },
      env: { PI_AGENT_BUS_TOKEN: token },
    });
    assert.equal(called, 0);
  });

  it("stays quiet when disabled or offline", async () => {
    let called = 0;
    const notifies: string[] = [];
    const disabled = createAgentBusExtension({
      fetch: async () => {
        called += 1;
        throw new Error("network");
      },
      env: { PI_AGENT_BUS_TOKEN: token, PI_AGENT_BUS_ENABLED: "0" },
    });
    await disabled.sessionStart({ reason: "startup" }, { mode: "tui" });
    const offline = createAgentBusExtension({
      fetch: async () => {
        called += 1;
        throw new Error("network");
      },
      env: { PI_AGENT_BUS_TOKEN: token, PI_OFFLINE: "1" },
    });
    await offline.sessionStart({ reason: "startup" }, { mode: "tui" });
    const rpc = createAgentBusExtension({
      fetch: async () => {
        called += 1;
        throw new Error("network");
      },
      env: { PI_AGENT_BUS_TOKEN: token },
    });
    await rpc.sessionStart({ reason: "startup" }, { mode: "rpc" });
    const missing = createAgentBusExtension({
      fetch: async () => {
        called += 1;
        throw new Error("network");
      },
      env: {},
    });
    await missing.sessionStart(
      { reason: "startup" },
      {
        mode: "tui",
        ui: {
          notify(message) {
            notifies.push(message);
          },
        },
      },
    );
    assert.equal(called, 0);
    assert.equal(disabled.status(), "disabled");
    assert.equal(offline.status(), "disabled");
    assert.equal(rpc.status(), "disabled");
    assert.equal(notifies.length, 1);
  });

  it("keeps runtime id across model change and serializes puts", async (t) => {
    const puts: string[] = [];
    const runtime = createAgentBusExtension({
      uuid: () => agentA,
      hostname: () => "foundation",
      cwd: () => "/tmp",
      pid: () => 9,
      env: { PI_AGENT_BUS_TOKEN: token, PI_AGENT_BUS_URL: baseUrl },
      fetch: async (url, init) => {
        if (init?.method === "PUT") {
          puts.push(String(init.body));
          return {
            status: 204,
            headers: { get: () => null },
            async text() {
              return "";
            },
          };
        }
        throw new Error(url);
      },
    });
    await runtime.sessionStart(
      { reason: "startup" },
      {
        mode: "tui",
        isIdle: () => true,
        model: { provider: "anthropic", id: "claude-sonnet-4-5" },
        sessionManager: { getSessionId: () => "22222222-2222-4222-8222-222222222222" },
      },
    );
    t.after(() => runtime.sessionShutdown());
    const first = runtime.runtimeId();
    runtime.refresh(context({ model: {
      provider: "openai-codex", id: "gpt-5", baseUrl: "https://secret.example",
    } }));
    await runtime.handleCommand("label", "work", {
      mode: "tui",
    });
    assert.equal(runtime.runtimeId(), first);
    assert.equal(puts.length >= 2, true);
    assert.equal(puts.some((body) => body.includes("secret.example")), false);
    assert.equal(puts.some((body) => body.includes("openai-codex")), true);
  });

  it("sends no POST after an incomplete paged tell discovery", async (t) => {
    let posts = 0;
    let gets = 0;
    const runtime = createAgentBusExtension({ uuid: () => agentA,
      env: { PI_AGENT_BUS_TOKEN: token, PI_AGENT_BUS_URL: baseUrl },
      fetch: async (_url, init) => {
        if (_url.endsWith('/v1/operator/announce')) return jsonResponse(404, {});
        if (init?.method === "PUT" || init?.method === "DELETE") return jsonResponse(204, null);
        if (init?.method === "POST") { posts++; return jsonResponse(202, {}); }
        gets++;
        return jsonResponse(200, { epoch: agentA, revision: "1", snapshotId: agentB, capturedAt: 1,
          page: 0, total: 1, nextCursor: null, agents: [] });
      },
    });
    t.after(() => runtime.sessionShutdown());
    await runtime.sessionStart({ reason: "startup" }, { mode: "tui", isIdle: () => true });
    const result = await runtime.handleCommand("tell", "peer hi", { mode: "tui" });
    assert.match(result, /not sent|discovery failed/i); assert.equal(posts, 0); assert.equal(gets, 1);
  });

  for (const [failure, reason] of [
    ["reset", "discovery reset"], ["unauthorized", "unauthorized"],
    ["malformed", "discovery failed"], ["timeout", "timeout"],
  ] as const) {
    for (const primeCache of [false, true]) {
      it(`tell continuation ${failure} sends no POST and preserves ${primeCache ? "prior" : "empty"} cache`, { timeout: 2000 }, async (t) => {
        if (failure === "timeout") t.mock.timers.enable({ apis: ["setTimeout"] });
        const peer = { agentId: agentB, sessionId: agentB, host: "peer-host", cwd: "/tmp",
          sessionName: "peer", label: "peer cached", model: null, status: "idle", pid: 2,
          acceptsControl: false, receiving: true, updatedAt: 1 };
        const stagedPeer = { ...peer, label: "peer staged", pid: 3 };
        const metadata = { epoch: agentA, revision: "1", snapshotId: agentB, capturedAt: 1 };
        const cursor = Buffer.from(`${agentB}:1`).toString("base64url");
        const continuationReached = Promise.withResolvers<AbortSignal | undefined>();
        const continuation = Promise.withResolvers<ReturnType<typeof jsonResponse>>();
        const urls: string[] = [];
        let posts = 0;
        let tellGets = 0;
        let priming = primeCache;
        const runtime = createAgentBusExtension({ uuid: () => agentA,
          env: { PI_AGENT_BUS_TOKEN: token, PI_AGENT_BUS_URL: baseUrl },
          fetch: async (url, init) => {
            if (url.endsWith('/v1/operator/announce')) return jsonResponse(404, {});
            if (init?.method === "PUT" || init?.method === "DELETE") return jsonResponse(204, null);
            if (init?.method === "POST") { posts++; return jsonResponse(202, {}); }
            assert.equal(init?.method, "GET");
            urls.push(url);
            if (priming) return jsonResponse(200, { ...metadata, page: 0, total: 1, agents: [peer], nextCursor: null });
            tellGets++;
            if (tellGets === 1) return jsonResponse(200, {
              ...metadata, page: 0, total: 2, agents: [stagedPeer], nextCursor: cursor,
            });
            continuationReached.resolve(init?.signal);
            return continuation.promise;
          },
        });
        t.after(() => runtime.sessionShutdown());
        await runtime.sessionStart({ reason: "startup" }, { mode: "tui", isIdle: () => true });
        if (primeCache) {
          assert.match(await runtime.handleCommand("agents", "", { mode: "tui" }), /peer cached/);
          priming = false;
        }
        const cached = primeCache ? [peer] : [];
        assert.deepEqual(runtime.listCached(), cached);
        let settled = false;
        const command = runtime.handleCommand("tell", "peer hi", { mode: "tui" }).then((result) => {
          settled = true;
          return result;
        });
        const signal = await continuationReached.promise;
        assert.equal(settled, false);
        assert.equal(tellGets, 2, "a valid first page must reach the continuation");
        assert.deepEqual(runtime.listCached(), cached, "staged peers must not enter the cache");
        assert.equal(posts, 0);
        if (failure === "timeout") t.mock.timers.tick(5000);
        else if (failure === "malformed") continuation.resolve(jsonResponse(200, {
          ...metadata, page: 1, total: 2, agents: [], nextCursor: null,
        }));
        else continuation.resolve(jsonResponse(failure === "reset" ? 409 : 401, { error: { message: token } }));
        assert.equal(await command, `not sent: ${reason}`);
        assert.equal(signal?.aborted, true);
        assert.equal(posts, 0, "neither cached nor staged targets may cause a POST");
        assert.deepEqual(runtime.listCached(), cached);
        assert.deepEqual(urls, [
          ...(primeCache ? [`${baseUrl}/v1/agents`] : []),
          `${baseUrl}/v1/agents`, `${baseUrl}/v1/agents?cursor=${cursor}`,
        ]);
        if (failure === "timeout") {
          // Even a late valid response cannot publish the abandoned traversal.
          continuation.resolve(jsonResponse(200, { ...metadata, page: 1, total: 2, nextCursor: null,
            agents: [{ ...peer, agentId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc" }] }));
          await new Promise<void>((resolve) => setImmediate(resolve));
          assert.deepEqual(runtime.listCached(), cached);
          assert.equal(posts, 0);
          assert.equal(tellGets, 2);
        }
      });
    }
  }

  it("resolves tell against a fresh list and reports unknown on timeout", async (t) => {
    let posts = 0;
    const runtime = createAgentBusExtension({
      uuid: () => (posts === 0 ? agentA : "33333333-3333-4333-8333-333333333333"),
      hostname: () => "foundation",
      cwd: () => "/tmp",
      env: { PI_AGENT_BUS_TOKEN: token, PI_AGENT_BUS_URL: baseUrl },
      fetch: async (_url, init) => {
        if (_url.endsWith('/v1/operator/announce')) return jsonResponse(404, {});
        if (init?.method === "PUT") {
          return {
            status: 204,
            headers: { get: () => null },
            async text() {
              return "";
            },
          };
        }
        if (init?.method === "GET") {
          return jsonResponse(200, {
                epoch: agentA, revision: "1", snapshotId: agentB, capturedAt: 1,
                page: 0, total: 2, nextCursor: null,
                agents: [
                  {
                    agentId: agentA,
                    sessionId: agentA,
                    receiving: true, updatedAt: 1,
                    host: "foundation",
                    cwd: "/tmp",
                    sessionName: "s",
                    label: "me",
                    model: null,
                    status: "idle",
                    pid: 1,
                    acceptsControl: false,
                  },
                  {
                    agentId: agentB,
                    sessionId: agentB,
                    receiving: true, updatedAt: 1,
                    host: "andromeda",
                    cwd: "/tmp",
                    sessionName: "s",
                    label: "flake checks",
                    model: null,
                    status: "idle",
                    pid: 2,
                    acceptsControl: false,
                  },
                ],
              });
        }
        posts += 1;
        const err = new Error("aborted");
        err.name = "AbortError";
        throw err;
      },
    });
    t.after(() => runtime.sessionShutdown());
    await runtime.sessionStart({ reason: "startup" }, { mode: "tui", isIdle: () => true });
    const timeout = await runtime.handleCommand("tell", '"flake checks" done', { mode: "tui" });
    assert.match(timeout, /lost|unknown|aborted|timeout/i);
    assert.equal(posts, 1);
    const missing = await runtime.handleCommand("tell", "nope hi", { mode: "tui" });
    assert.match(missing, /no matching agent/);
  });
});
