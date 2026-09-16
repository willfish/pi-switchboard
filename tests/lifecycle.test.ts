import assert from "node:assert/strict";
import { it } from "node:test";
import { createAgentBusExtension } from "../extension/index.ts";
import { projectName, retryDelay } from "../extension/runtime.ts";
import { agentA, agentB, context, dormantSubscribe, flush, response, Clock, host, sync, discovery } from "./client-test-helpers.ts";
import type { subscribeOnce } from "../extension/sse.ts";

function fixture(extra: Record<string, any> = {}) {
  const clock = new Clock(); const sdk = host(); const puts: any[] = []; const calls: string[] = [];
  const notices: string[] = [];
  const ctx = context({ ui: { notify: (text: string) => notices.push(text) } });
  const runtime = createAgentBusExtension({ pi: sdk.pi, uuid: () => agentA, hostname: () => "fixture", pid: () => 5,
    env: { PI_AGENT_BUS_TOKEN: "synthetic" }, now: () => clock.time, wallNow: () => 1000, timers: clock,
    subscribe: dormantSubscribe, fetch: async (_url, init) => { calls.push(init?.method ?? "GET"); if (init?.method === "PUT") puts.push(JSON.parse(init.body!)); return response(); }, ...extra });
  return { clock, sdk, puts, calls, runtime, notices, ctx };
}

it("factory binds the exact commands/tools and no network, clocks, UUID, hostname or timers", () => {
  const sdk = host(); const fail = () => { throw Error("factory effect"); };
  createAgentBusExtension({ pi: sdk.pi, env: { PI_AGENT_BUS_TOKEN: "synthetic" }, fetch: fail, uuid: fail, hostname: fail, now: fail, timers: { setTimeout: fail, clearTimeout: fail } });
  assert.deepEqual([...sdk.commands.keys()].sort(), ["agents", "bus", "label", "tell"]);
  assert.deepEqual([...sdk.tools.keys()].sort(), ["list_agents", "report_work", "send_agent_message", "set_agent_label"]);
  assert.ok(sdk.events.has("agent_settled")); assert.ok(!sdk.events.has("agent_end")); assert.ok(!sdk.events.has("session_switch"));
});

it("exact TUI, disabled, offline and qwen composition remain completely quiet; a Qwen model is eligible", async () => {
  for (const [mode, env] of [[undefined, {}], ["rpc", {}], ["print", {}], ["json", {}], ["tui", { PI_OFFLINE: "1" }], ["tui", { PI_AGENT_BUS_ENABLED: "0" }], ["tui", { PI_OFFLINE: "true" }], ["tui", { PI_OFFLINE: "YES" }]] as const) {
    const f = fixture({ env: { PI_AGENT_BUS_TOKEN: "synthetic", ...env }, uuid: () => { throw Error("inert UUID"); } });
    f.runtime.sessionStart({}, context({ mode, ui: { notify: () => { throw Error("inert UI"); } } }));
    assert.equal(f.runtime.status(), "disabled"); assert.equal(f.clock.tasks.size, 0); assert.deepEqual(f.calls, []);
  }
  const f = fixture(); f.runtime.sessionStart({}, context({ model: { provider: "qwen", id: "coder" } })); await flush();
  assert.equal(f.puts.length, 1); await f.runtime.sessionShutdown();
});

it("warns once for missing or invalid configuration and tools return explicit unavailability", async () => {
  const f = fixture({ env: {} });
  f.runtime.sessionStart({}, f.ctx); f.runtime.sessionStart({}, f.ctx);
  assert.equal(f.notices.length, 1); assert.equal(f.calls.length, 0);
  await assert.rejects(f.sdk.tools.get("list_agents").execute("id", {}, undefined), /unavailable/);
});

it("startup never waits for registration; one PUT plus dirty flag coalesces 100 updates", async () => {
  const pending = Promise.withResolvers<ReturnType<typeof response>>();
  let inFlight = 0; let maximum = 0; const puts: any[] = [];
  const f = fixture({ fetch: async (_url: string, init: any) => {
    if (init.method !== "PUT") return response();
    puts.push(JSON.parse(init.body)); maximum = Math.max(maximum, ++inFlight);
    const result = puts.length === 1 ? await pending.promise : response(); inFlight--; return result;
  } });
  assert.equal(f.runtime.sessionStart({}, f.ctx), undefined);
  for (let i = 0; i < 100; i++) f.runtime.setBusy(i % 2 === 0, f.ctx);
  assert.equal(puts.length, 1); pending.resolve(response()); await flush();
  assert.equal(puts.length, 2); assert.equal(puts[1].status, "idle"); assert.equal(maximum, 1);
  await f.clock.advance(5000); assert.equal(puts.length, 3);
  await f.runtime.sessionShutdown(); assert.equal(f.clock.tasks.size, 0);
});

it("registration precedes subscription; synchronized receive plus fresh PUT is connected immediately", async () => {
  const register = Promise.withResolvers<ReturnType<typeof response>>();
  let subscribed = 0; let stream: Parameters<typeof subscribeOnce>[0] | undefined;
  const f = fixture({ fetch: async (_url: string, init: any) => init.method === "PUT" ? register.promise : response(),
    subscribe: (options: Parameters<typeof subscribeOnce>[0]) => { subscribed++; stream = options; return dormantSubscribe(options); } });
  f.runtime.sessionStart({}, f.ctx); assert.equal(subscribed, 0); register.resolve(response()); await flush();
  assert.equal(subscribed, 1); assert.equal(f.runtime.status(), "degraded"); sync(stream!);
  assert.equal(f.runtime.status(), "connected"); await f.runtime.sessionShutdown();
});

it("one jittered retry owner re-registers and resets only after 10 uninterrupted healthy seconds", async () => {
  const ends: ReturnType<typeof Promise.withResolvers<{ reason: "closed" }>>[] = [];
  const streams: Parameters<typeof subscribeOnce>[0][] = [];
  const f = fixture({ random: () => 1, subscribe: (options: Parameters<typeof subscribeOnce>[0]) => {
    const end = Promise.withResolvers<{ reason: "closed" }>(); ends.push(end); streams.push(options); return end.promise;
  } });
  f.runtime.sessionStart({}, f.ctx); await flush(); sync(streams[0]); ends[0].resolve({ reason: "closed" }); await flush();
  await f.clock.advance(999); assert.equal(streams.length, 1);
  await f.clock.advance(1); assert.equal(streams.length, 2); sync(streams[1]);
  await f.clock.advance(9000); ends[1].resolve({ reason: "closed" }); await flush();
  await f.clock.advance(1999); assert.equal(streams.length, 2);
  await f.clock.advance(1); assert.equal(streams.length, 3); sync(streams[2]);
  await f.clock.advance(10000); ends[2].resolve({ reason: "closed" }); await flush();
  await f.clock.advance(999); assert.equal(streams.length, 3);
  await f.clock.advance(1); assert.equal(streams.length, 4);
  await f.runtime.sessionShutdown();
  assert.deepEqual([0, 1, 2, 5, 90].map(n => retryDelay(n, 1)), [1000, 2000, 4000, 30000, 30000]);
});

it("losing the 15 second registration lease cannot remain connected even with valid receive activity", async () => {
  let stream: Parameters<typeof subscribeOnce>[0]; let puts = 0;
  const f = fixture({ fetch: async (_url: string, init: any) => init.method === "PUT" && ++puts > 1 ? response(503) : response(),
    subscribe: (options: Parameters<typeof subscribeOnce>[0]) => { stream = options; return dormantSubscribe(options); } });
  f.runtime.sessionStart({}, f.ctx); await flush(); sync(stream!);
  await f.clock.advance(14999); stream!.onActivity(); assert.equal(f.runtime.status(), "connected");
  await f.clock.advance(1); stream!.onActivity(); assert.equal(f.runtime.status(), "down");
  await f.runtime.sessionShutdown();
});

it("lease status expires at the PUT completion boundary, not only the next heartbeat", async () => {
  const registered = Promise.withResolvers<ReturnType<typeof response>>(); let puts = 0;
  let stream: Parameters<typeof subscribeOnce>[0]; const statuses: string[] = [];
  const f = fixture({ fetch: async (_url: string, init: any) => init.method === "PUT" ? (++puts === 1 ? registered.promise : response(503)) : response(),
    subscribe: (options: Parameters<typeof subscribeOnce>[0]) => { stream = options; return dormantSubscribe(options); } });
  f.runtime.sessionStart({}, context({ ui: { setStatus: (_key: string, text: string) => statuses.push(text) } }));
  assert.equal(f.runtime.status(), "connecting"); assert.match(f.runtime.statusText(), /status=connecting/);
  await f.clock.advance(750); registered.resolve(response()); await flush(); sync(stream!);
  await f.clock.advance(14999); assert.match(statuses.at(-1)!, /bus connected/);
  await f.clock.advance(1); assert.match(statuses.at(-1)!, /bus down/);
  await f.runtime.sessionShutdown();
});

it("branch labels use latest matching entry.data, automatic names are separate and explicit labels validate", async () => {
  const f = fixture(); f.sdk.setName("Session name");
  let branch: any[] = [{ type: "custom", customType: "agent-bus-label", data: { label: "explicit" } }];
  const ctx = context({ sessionManager: { getBranch: () => branch } });
  f.runtime.sessionStart({}, ctx); await flush();
  assert.equal(f.puts[0].label, "explicit"); assert.equal(f.puts[0].sessionName, "Session name");
  f.sdk.setName("Renamed"); f.sdk.events.get("session_info_changed")!({}, ctx); await flush();
  assert.equal(f.puts.at(-1).label, "explicit"); assert.equal(f.puts.at(-1).sessionName, "Renamed");
  branch.push({ type: "custom", customType: "agent-bus-label", data: { nope: "malformed" } });
  f.sdk.events.get("session_tree")!({}, ctx); await flush(); assert.equal(f.puts.at(-1).label, "Renamed");
  assert.equal(f.runtime.setLabel("  work  "), "work"); assert.deepEqual(f.sdk.entries.at(-1), { type: "agent-bus-label", data: { label: "work" } });
  for (const label of ["", "a\nb", "a\x1bb", "x".repeat(201), "\ud800"]) assert.throws(() => f.runtime.setLabel(label));
  assert.equal(f.runtime.setLabel("ignored", true), "Renamed");
  assert.equal(projectName(" \ud800\n" + "😀".repeat(250)), "� " + "😀".repeat(198));
  await f.runtime.sessionShutdown();
});

it("current model, null and invalid model semantics preserve runtime ID and never leak identity extras", async () => {
  const f = fixture(); const ctx = context();
  f.runtime.sessionStart({}, ctx); await flush(); const id = f.runtime.runtimeId();
  for (const model of [{ provider: "p", id: "m", baseUrl: "SECRET" }, undefined, { provider: "", id: "bad" }, { provider: "new", id: "valid" }]) {
    ctx.model = model as any; f.sdk.events.get("model_select")!({ model }, ctx); await flush();
    if (model?.provider === "") assert.equal(f.runtime.status(), "down");
    else assert.deepEqual(f.puts.at(-1).model, model ? { provider: model.provider, id: model.id } : null);
  }
  assert.equal(f.puts.length, 4); assert.equal(f.runtime.runtimeId(), id); assert.ok(!JSON.stringify(f.puts).includes("SECRET"));
  ctx.model = undefined; await f.clock.advance(5000); assert.equal(f.puts.at(-1).model, null);
  await f.runtime.sessionShutdown();
});

it("model events override different context through serialized PUT, then heartbeat and reconnect refresh context", async () => {
  const pending = Promise.withResolvers<ReturnType<typeof response>>(); const puts: any[] = [];
  const ends: ReturnType<typeof Promise.withResolvers<{ reason: "closed" }>>[] = [];
  const f = fixture({ fetch: async (_url: string, init: any) => {
    if (init.method !== "PUT") return response();
    puts.push(JSON.parse(init.body)); return puts.length === 1 ? pending.promise : response();
  }, subscribe: () => { const end = Promise.withResolvers<{ reason: "closed" }>(); ends.push(end); return end.promise; } });
  const ctx = context({ model: { provider: "context", id: "old" } });
  f.runtime.sessionStart({}, ctx);
  for (const source of ["set", "cycle", "restore"]) {
    const model = { provider: "event", id: source, baseUrl: "SECRET", headers: { authorization: "SECRET" } };
    f.sdk.events.get("model_select")!({ model, source }, ctx);
    model.id = "mutated after callback";
  }
  assert.equal(puts.length, 1); pending.resolve(response()); await flush();
  assert.deepEqual(puts[1].model, { provider: "event", id: "restore" });
  assert.equal(puts.length, 2); assert.ok(!JSON.stringify(puts).includes("SECRET"));
  for (const source of ["set", "cycle", "restore"]) {
    f.sdk.events.get("model_select")!({ model: { provider: "event", id: source }, source }, ctx); await flush();
    assert.deepEqual(puts.at(-1).model, { provider: "event", id: source });
  }
  f.sdk.events.get("model_select")!({ model: { provider: "", id: "invalid" } }, ctx); await flush();
  assert.equal(puts.length, 5); assert.equal(f.runtime.status(), "down");
  ctx.model = undefined; await f.clock.advance(5000); assert.equal(puts.at(-1).model, null);
  ends.at(-1)!.resolve({ reason: "closed" }); await flush();
  ctx.model = { provider: "recovery", id: "current" } as any;
  await f.clock.advance(1000); assert.deepEqual(puts.at(-1).model, { provider: "recovery", id: "current" });
  await f.runtime.sessionShutdown(); const count = puts.length;
  f.sdk.events.get("model_select")!({ model: { provider: "late", id: "ignored" } }, ctx); await flush();
  assert.equal(puts.length, count);
});

for (const boundary of ["replacement", "cancel"] as const) it(`list tool fences ${boundary} at its outer await boundary`, async () => {
  const f = fixture(); f.runtime.sessionStart({}, f.ctx); await flush();
  const controller = new AbortController();
  // Resolve a successful inner list, then invalidate before execute resumes.
  f.runtime.list = () => {
    const result = Promise.resolve({ status: "ok" as const, agents: [] });
    queueMicrotask(() => {
      if (boundary === "replacement") f.runtime.sessionStart({ reason: "reload" }, f.ctx);
      else controller.abort();
    });
    return result;
  };
  try { await assert.rejects(f.sdk.tools.get("list_agents").execute("id", {}, controller.signal), /runtime closed|cancelled/); }
  finally { await f.runtime.sessionShutdown(); }
});

for (const outcome of ["accepted", "rejected", "outcome_unknown"] as const) it(`send tool preserves observed ${outcome} after replacement`, async () => {
  let posts = 0;
  const f = fixture({ fetch: async (_url: string, init: any) => {
    if (_url.endsWith('/v1/operator/announce')) return response(404, {});
    if (init.method === "GET") return discovery();
    if (init.method !== "POST") return response();
    posts++;
    if (outcome === "outcome_unknown") throw Error("response lost");
    if (outcome === "rejected") return response(403, { error: { code: "control_disabled", message: "disabled" } });
    const mail = JSON.parse(init.body);
    return response(202, { id: mail.id, to: mail.to, state: "accepted", expiresAt: 60, receiving: true });
  } });
  f.runtime.sessionStart({}, f.ctx); await flush();
  const send = f.runtime.send;
  f.runtime.send = async (...args) => {
    const result = await send(...args);
    f.runtime.sessionStart({ reason: "reload" }, f.ctx);
    return result;
  };
  const result = await f.sdk.tools.get("send_agent_message").execute("id", { to: "peer", body: "hello" });
  assert.equal(result.details.status, outcome); assert.equal(posts, 1);
  await f.runtime.sessionShutdown();
});

it("busy starts promptly and only agent_settled consults final idle state", async () => {
  const f = fixture(); let idle = true; const ctx = context({ isIdle: () => idle });
  f.runtime.sessionStart({}, ctx); await flush();
  idle = false; f.sdk.events.get("agent_start")!({}, ctx); await flush(); assert.equal(f.puts.at(-1).status, "busy");
  f.sdk.events.get("agent_settled")!({}, ctx); await flush(); assert.equal(f.puts.at(-1).status, "busy");
  idle = true; f.sdk.events.get("agent_settled")!({}, ctx); await flush(); assert.equal(f.puts.at(-1).status, "idle");
  await f.runtime.sessionShutdown();
});

for (const route of ["PUT", "GET", "POST", "SSE"] as const) it(`${route} 401 stops every background producer and requires local credential refresh`, async () => {
  let unauthorized = false; let count = 0; const streams: Parameters<typeof subscribeOnce>[0][] = [];
  const f = fixture({ fetch: async (_url: string, init: any) => { count++; if (unauthorized && init.method === route) return response(401); return init.method === "GET" ? discovery() : response(); },
    subscribe: (options: Parameters<typeof subscribeOnce>[0]) => { streams.push(options); return route === "SSE" ? Promise.resolve({ reason: "unauthorized" }) : dormantSubscribe(options); } });
  f.runtime.sessionStart({}, f.ctx); await flush(); unauthorized = true;
  if (route === "PUT") f.runtime.setBusy(true);
  if (route === "GET") await f.runtime.list();
  if (route === "POST") assert.deepEqual(await f.runtime.send("peer", "hello"), { status: "rejected", reason: "unauthorized" });
  await flush(); assert.equal(f.runtime.status(), "down");
  assert.match(f.runtime.statusText(), /credentials must be refreshed locally/);
  const stopped = count; await f.clock.advance(120000); assert.equal(count, stopped); assert.equal(streams[0]?.signal.aborted, true);
  await f.runtime.sessionShutdown();
});

it("shutdown fences an uncooperative PUT and independently bounds DELETE to 2 seconds", async () => {
  const pending = Promise.withResolvers<ReturnType<typeof response>>(); const signals: AbortSignal[] = []; let subscribed = 0;
  const f = fixture({ fetch: async (_url: string, init: any) => { signals.push(init.signal); return pending.promise; }, subscribe: (options: Parameters<typeof subscribeOnce>[0]) => { subscribed++; return dormantSubscribe(options); } });
  f.runtime.sessionStart({}, f.ctx); let stopped = false;
  const cleanup = f.runtime.sessionShutdown().then(() => { stopped = true; });
  assert.equal(signals[0].aborted, true); assert.equal(signals[1].aborted, false); assert.equal(f.runtime.runtimeId(), undefined);
  await f.clock.advance(1999); assert.equal(stopped, false);
  await f.clock.advance(1); await cleanup; assert.equal(stopped, true); assert.equal(signals[1].aborted, true);
  pending.resolve(response()); await flush(); assert.equal(subscribed, 0); assert.equal(f.clock.tasks.size, 0);
  await f.runtime.sessionShutdown(); assert.equal(signals.length, 2);
});

it("invalid host/cwd metadata is never truncated into a false identity, and publication resumes after correction", async () => {
  let hostname = "é";
  const f = fixture({ hostname: () => hostname });
  const ctx = context(); f.runtime.sessionStart({}, ctx); await flush();
  assert.equal(f.puts.length, 0); assert.match(f.runtime.statusText(), /invalid local presence metadata/);
  hostname = "fixture"; ctx.cwd = "/tmp/" + "x".repeat(4096);
  await f.clock.advance(5000); assert.equal(f.puts.length, 0);
  ctx.cwd = "/tmp/invalid\u2028path"; await f.clock.advance(5000); assert.equal(f.puts.length, 0);
  ctx.cwd = "/tmp/correct"; await f.clock.advance(5000); assert.equal(f.puts.length, 1); assert.equal(f.puts[0].cwd, ctx.cwd);
  await f.runtime.sessionShutdown();
});

it("late command completion cannot notify an old context even with a reused injected UUID", async () => {
  const pending = Promise.withResolvers<ReturnType<typeof response>>();
  const f = fixture({ fetch: async (_url: string, init: any) => init.method === "GET" ? pending.promise : response() });
  f.runtime.sessionStart({}, f.ctx); await flush();
  const command = f.sdk.commands.get("tell").handler("peer hello", f.ctx);
  f.runtime.sessionStart({ reason: "reload" }, context());
  const notices = f.notices.length; pending.resolve(discovery()); await command; await flush();
  assert.equal(f.notices.length, notices); await f.runtime.sessionShutdown();
});

it("discovery-to-POST is fenced against replacement; late discovery cannot replace the cache", async () => {
  const pending = Promise.withResolvers<ReturnType<typeof response>>(); let posts = 0; let sequence = 0;
  const f = fixture({ uuid: () => sequence++ === 0 ? agentA : agentB, fetch: async (_url: string, init: any) => {
    if (_url.endsWith('/v1/operator/announce')) return response(404, {});
    if (init.method === "POST") posts++;
    return init.method === "GET" ? pending.promise : response();
  } });
  f.runtime.sessionStart({}, f.ctx); await flush(); const sending = f.runtime.send("peer", "hello");
  f.runtime.sessionStart({ reason: "resume" }, f.ctx); pending.resolve(discovery()); await flush();
  assert.equal((await sending).status, "not_sent"); assert.equal(posts, 0); assert.deepEqual(f.runtime.listCached(), []);
  await f.runtime.sessionShutdown();
});
