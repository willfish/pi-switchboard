import assert from "node:assert/strict";
import { it } from "node:test";
import { visibleWidth } from "@earendil-works/pi-tui";
import entry from "../index.ts";
import { createAgentBusExtension } from "../extension/index.ts";
import { completionItems, formatAgentList, formatAgentLine } from "../extension/commands.ts";
import { ReadOnlyViewer, safeText, showInbox, showText } from "../extension/viewer.ts";
import { createInboxState, receive, markRead } from "../extension/inbox.ts";
import { agentA, agentB, context, dormantSubscribe, flush, host, peer, response } from "./client-test-helpers.ts";
import type { Component } from "@earendil-works/pi-tui";

function ui() {
  let component: Component & { dispose?(): void }; let complete = false; let renders = 0;
  const ctx = context({ ui: { custom: (factory: any) => new Promise<void>(resolve => {
    component = factory({ terminal: { rows: 8 }, requestRender: () => renders++ }, {}, { matches: (data: string, action: string) => data === action.split(".").at(-1) }, () => { complete = true; component?.dispose?.(); resolve(); });
  }) } });
  return { ctx, component: () => component, complete: () => complete, renders: () => renders };
}

it("real root entry binds host registrations without starting fetch or timers", () => {
  const sdk = host(); entry(sdk.pi);
  assert.equal(sdk.tools.size, 4); assert.equal(sdk.commands.size, 4); assert.equal(sdk.injected.length, 0);
});

it("completion values use full population uniqueness and documented labels/provider descriptions without I/O", () => {
  const sibling = { ...peer, agentId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbc", model: { provider: "provider", id: "model" } };
  const items = completionItems("peer", [peer, sibling], agentA);
  assert.equal(items[0].value, peer.agentId); assert.equal(items[1].value, sibling.agentId);
  assert.equal(items[0].label, items[0].value); assert.match(items[1].description, /provider\/model/);
  assert.equal(completionItems("", [peer], peer.agentId).length, 0);
  assert.equal(completionItems("peer", [peer, { ...sibling, host: "hidden", label: "hidden" }], sibling.agentId)[0].value, peer.agentId);
  assert.equal(completionItems("", [peer], agentA)[0].value, peer.agentId.slice(0, 8));
  assert.match(formatAgentLine(peer, agentA, [peer, sibling]), new RegExp(`^${peer.agentId}`));
  const sdk = host(); let calls = 0;
  createAgentBusExtension({ pi: sdk.pi, fetch: async () => { calls++; throw Error(); } });
  sdk.commands.get("tell").getArgumentCompletions("--prompt "); assert.equal(calls, 0);
  assert.equal(sdk.commands.get("tell").getArgumentCompletions("--ask peer"), null);
});

it("readable discovery is bounded at 50 KiB and 2000 lines with totals, no-model and self markers", () => {
  const agents = Array.from({ length: 5000 }, (_, i) => ({ ...peer, agentId: `${i.toString(16).padStart(8, "0")}-0000-4000-8000-000000000000`, label: "😀".repeat(200) }));
  const text = formatAgentList(agents, agents[0].agentId);
  assert.ok(Buffer.byteLength(text) <= 50 * 1024); assert.ok(text.split("\n").length <= 2000);
  assert.match(text, /truncated: shown \d+ of 5000 agents/); assert.match(text, /no model/); assert.match(text, /\(self\)/);
  assert.equal(formatAgentList([], agentA), "no agents");
});

it("list_agents retains all complete validated records in details despite readable truncation", async () => {
  const sdk = host(); const agents = Array.from({ length: 2200 }, (_, i) => ({ ...peer, agentId: `${i.toString(16).padStart(8, "0")}-0000-4000-8000-000000000000`, label: "long ".repeat(40) }));
  let page = 0;
  const runtime = createAgentBusExtension({ pi: sdk.pi, uuid: () => agentA, env: { PI_AGENT_BUS_TOKEN: "synthetic" }, subscribe: dormantSubscribe,
    fetch: async (_url, init) => {
      if (init?.method !== "GET") return response();
      const start = page * 128; const chunk = agents.slice(start, start + 128); const current = page++;
      return response(200, { epoch: agentA, revision: "1", snapshotId: agentB, capturedAt: 0, page: current, total: agents.length, agents: chunk,
        nextCursor: start + chunk.length < agents.length ? Buffer.from(`${agentB}:${page}`).toString("base64url") : null });
    } });
  runtime.sessionStart({}, context()); await flush();
  const result = await sdk.tools.get("list_agents").execute("id", {}, undefined);
  assert.deepEqual(result.details.agents, agents); assert.match(result.content[0].text, /truncated/);
  assert.ok(Buffer.byteLength(result.content[0].text) <= 50 * 1024);
  await runtime.sessionShutdown();
});

it("notice renderer sanitizes terminal controls without modifying the context message", () => {
  const sdk = host(); createAgentBusExtension({ pi: sdk.pi });
  const message = { content: "original\x1b]52;c;payload\x07\nbody" };
  const renderer = sdk.renderers.get("agent-bus-mail");
  const component = renderer(message, { outputPad: 0 });
  assert.ok(component.render(100).join("\n").includes("\\u001b"));
  assert.equal(message.content, "original\x1b]52;c;payload\x07\nbody");
});

it("viewer safely renders terminal escapes, malformed scalars and long Unicode at tiny widths", () => {
  const text = "\x1b]52;c;PRIVATE\x07\x1b[2J\u202e\ud800\n" + "😀".repeat(100) + "\nlast line";
  let closed = false; let renders = 0;
  const viewer = new ReadOnlyViewer({ text, rows: () => 5, matches: (data, action) => data === action, render: () => renders++, close: () => { closed = true; } });
  for (const width of [1, 2, 10, 80]) {
    const lines = viewer.render(width); assert.ok(lines.every(line => visibleWidth(line) <= width)); assert.ok(lines.length <= 4);
    // Pi's width truncator may add its own final SGR reset; no peer controls survive.
    assert.ok(lines.every(line => !/[\x00-\x1f\x7f-\x9f\u202e]/.test(line.replace(/\x1b\[0m/g, ""))));
  }
  assert.match(safeText(text), /\\u001b/); assert.match(safeText(text), /�/);
  for (let i = 0; i < 1000; i++) viewer.handleInput("pageDown");
  assert.ok(viewer.render(80).some(line => line.includes("last line")));
  for (let i = 0; i < 1000; i++) viewer.handleInput("pageUp");
  assert.ok(viewer.render(80)[0].includes("\\u001b"));
  viewer.invalidate(); viewer.handleInput("arbitrary peer input"); assert.ok(renders > 0); assert.equal(closed, false);
  viewer.handleInput("cancel"); assert.equal(closed, true);
});

it("inbox list is newest-first without marking read; opening changes only human-read and Escape returns", async () => {
  let inbox = createInboxState();
  for (const [i, body] of [[1, "first body"], [2, "second body\x1b[2J"]] as const) inbox = receive(inbox, { id: `${i}0000000-0000-4000-8000-000000000000`, from: agentB, to: agentA, kind: "notice", body, sender: { host: "peer", label: `label${i}` }, acceptedAt: 0, expiresAt: 60 }, { monoMs: i, wallMs: i }, false).state;
  const view = ui(); const pending = showInbox(view.ctx, () => inbox, key => { inbox = markRead(inbox, key); });
  await flush(); const component = view.component();
  const list = component.render(120); assert.match(list[1], /label2/); assert.match(list[2], /label1/);
  assert.ok(inbox.records.every(record => !record.humanRead));
  component.handleInput!("confirm"); component.render(120);
  assert.equal(inbox.records[1].humanRead, true); assert.equal(inbox.records[0].humanRead, false);
  assert.ok(inbox.records.every(record => record.handling === "pending_context"));
  assert.equal(inbox.pendingControl, null);
  component.handleInput!("cancel"); assert.equal(view.complete(), false);
  component.handleInput!("cancel"); await pending; assert.equal(view.complete(), true);
});

for (const rerender of [false, true]) it(`inbox selection survives arrival before Enter (rerender=${rerender})`, async () => {
  let inbox = createInboxState();
  const add = (n: number) => { inbox = receive(inbox, { id: `${n}0000000-0000-4000-8000-000000000000`, from: agentB, to: agentA, kind: "notice", body: `body${n}`, sender: { host: "peer", label: `label${n}` }, acceptedAt: 0, expiresAt: 60 }, { monoMs: n, wallMs: n }, false).state; };
  add(1); add(2);
  const view = ui(); const pending = showInbox(view.ctx, () => inbox, key => { inbox = markRead(inbox, key); });
  const component = view.component(); component.render(120); component.handleInput!("down");
  assert.match(component.render(120).find(line => line.startsWith(">"))!, /label1/);
  add(3);
  if (rerender) assert.match(component.render(120).find(line => line.startsWith(">"))!, /label1/);
  component.handleInput!("confirm");
  assert.deepEqual(inbox.records.map(r => r.humanRead), [true, false, false]);
  component.render(120); component.handleInput!("pageDown"); assert.match(component.render(120).join("\n"), /body1/);
  component.handleInput!("cancel"); component.handleInput!("cancel"); await pending;
});

it("evicted inbox selection cannot open or mark a replacement, even after rerender", async () => {
  let inbox = createInboxState();
  const add = (n: number) => { inbox = receive(inbox, { id: `${n.toString(16).padStart(8, "0")}-0000-4000-8000-000000000000`, from: agentB, to: agentA, kind: "prompt", body: `body${n}`, sender: { host: "peer", label: `label${n}` }, acceptedAt: 0, expiresAt: 60 }, { monoMs: n, wallMs: n }, false).state; };
  add(1);
  const view = ui(); const pending = showInbox(view.ctx, () => inbox, key => { inbox = markRead(inbox, key); });
  const component = view.component(); component.render(120);
  for (let n = 2; n <= 33; n++) add(n);
  component.handleInput!("confirm"); assert.ok(inbox.records.every(r => !r.humanRead));
  assert.match(component.render(120).join("\n"), /no longer available/i);
  component.handleInput!("confirm"); assert.ok(inbox.records.every(r => !r.humanRead));
  component.handleInput!("down"); component.render(120); component.handleInput!("confirm");
  assert.equal(inbox.records.filter(r => r.humanRead).length, 1);
  component.handleInput!("cancel"); component.handleInput!("cancel"); await pending;
});

it("population formatting and completions avoid quadratic ID reads", () => {
  let reads = 0;
  const agents = Array.from({ length: 5000 }, (_, i) => ({ ...peer,
    get agentId() { reads++; return `aaaaaaaa-0000-4000-8000-${i.toString(16).padStart(12, "0")}`; },
  }));
  const items = completionItems("", agents, agentA);
  assert.equal(items.length, 5000); assert.equal(new Set(items.map(item => item.value)).size, 5000);
  assert.ok(reads < 100000, `completion ID reads: ${reads}`);
  reads = 0; const text = formatAgentList(agents, agentA);
  assert.match(text, /of 5000 agents/); assert.ok(reads < 100000, `list ID reads: ${reads}`);
});

it("viewer is TUI-only and an independent lifetime signal closes it without edits or turns", async () => {
  const rpc = context({ mode: "rpc", ui: { custom: () => { throw Error("RPC viewer"); } } });
  await showText(rpc, "ignored");
  const view = ui(); const controller = new AbortController();
  const pending = showText(view.ctx, "read only", controller.signal); await flush();
  assert.equal(view.complete(), false); controller.abort(); await pending; assert.equal(view.complete(), true);
});

it("a deferred UI factory cannot open after its runtime lifetime was aborted", async () => {
  let factory: any; let complete = false;
  const ctx = context({ ui: { custom: (callback: any) => { factory = callback; return Promise.resolve(); } } });
  const controller = new AbortController(); await showText(ctx, "old text", controller.signal); controller.abort();
  const component = factory({}, {}, {}, () => { complete = true; });
  assert.equal(complete, true); assert.deepEqual(component.render(80), []);
});

it("bus inbox remains available after 401 and shutdown closes it, without further network or injection", async () => {
  const sdk = host(); const view = ui(); let unauthorized = false; let calls = 0;
  const runtime = createAgentBusExtension({ pi: sdk.pi, uuid: () => agentA, env: { PI_AGENT_BUS_TOKEN: "synthetic" }, subscribe: dormantSubscribe,
    fetch: async () => { calls++; return response(unauthorized ? 401 : 204); } });
  runtime.sessionStart({}, view.ctx); await flush(); unauthorized = true; await runtime.list();
  const before = calls;
  const showing = sdk.commands.get("bus").handler("inbox", view.ctx); await flush();
  assert.match(view.component().render(80).join("\n"), /No received mail/); assert.equal(calls, before);
  await runtime.sessionShutdown(); await showing; assert.equal(view.complete(), true); assert.equal(sdk.injected.length, 0);
});
