import assert from "node:assert/strict";
import test from "node:test";
import { createAgentBusExtension } from "../extension/index.ts";
import { decodeCoordinationNote } from "../extension/coordination-notes.ts";
import { agentA, agentB, Clock, context, dormantSubscribe, flush, host, response } from "./client-test-helpers.ts";
import type { ChannelMessage, ChannelPage } from "../extension/channels.ts";

async function fixture(t: { after(fn: () => Promise<void>): void }) {
  const sdk = host(), clock = new Clock();
  const records = new Map<string, ChannelMessage[]>();
  const gets: { channel: string; after: string }[] = [];
  const posts: { channel: string; body: string }[] = [];
  let serial = 0, sequence = 0, losePost = false;
  const add = (channel: string, body: string, from = agentB, id = `bbbbbbbb-bbbb-4bbb-8bbb-${String(++serial).padStart(12, "0")}`) => {
    const rows = records.get(channel) ?? [];
    rows.push({ channel, body, from, id, seq: String(++sequence), kind: "say", postedAt: 1_700_000_000 });
    records.set(channel, rows);
    return rows.at(-1)!;
  };
  const runtime = createAgentBusExtension({ pi: sdk.pi, timers: clock, now: () => clock.time, wallNow: () => 1_700_000_000_000,
    uuid: () => `aaaaaaaa-aaaa-4aaa-8aaa-${String(++serial).padStart(12, "0")}`,
    env: { PI_AGENT_BUS_TOKEN: "synthetic" }, subscribe: dormantSubscribe,
    fetch: async (url, init) => {
      const parsed = new URL(String(url)), path = parsed.pathname;
      if (path.startsWith("/v1/operator/")) return response(404, {});
      if (!path.startsWith("/v1/channels/")) return response();
      const channel = path.split("/")[3];
      if (init?.method === "PUT") return path.endsWith("/status")
        ? response(200, { channel, agentId: runtime.runtimeId(), state: "current", sequence: null })
        : response(200, { channel, topic: "", state: "ready" });
      if (init?.method === "POST") {
        const message = JSON.parse(String(init.body));
        posts.push({ channel, body: message.body });
        const stored = add(channel, message.body, message.from, message.id);
        if (losePost) throw new Error("synthetic lost response");
        return response(202, { channel, id: message.id, sequence: stored.seq, state: "accepted", postedAt: stored.postedAt });
      }
      const after = parsed.searchParams.get("after") ?? "0";
      gets.push({ channel, after });
      const all = records.get(channel) ?? [];
      const rows = after === "0" ? all.slice(-24) : all.filter(row => BigInt(row.seq) > BigInt(after)).slice(0, 24);
      const page: ChannelPage = { epoch: agentA, channel, window: "recent", fromSequence: rows[0]?.seq ?? "0", toSequence: rows.at(-1)?.seq ?? "0",
        retainedFrom: all[0]?.seq ?? "0", retainedTo: all.at(-1)?.seq ?? "0", coverage: rows.length ? "complete" : "empty",
        caughtUp: rows.length === 0 || rows.at(-1)?.seq === all.at(-1)?.seq, earlier: rows.length > 0 && rows[0].seq !== all[0]?.seq,
        nextCursor: rows.length && rows.at(-1)?.seq !== all.at(-1)?.seq ? rows.at(-1)!.seq : null,
        earlierCursor: rows.length && rows[0].seq !== all[0]?.seq ? rows[0].seq : null, messages: rows };
      return response(200, page);
    },
  });
  t.after(() => runtime.sessionShutdown());
  runtime.sessionStart({}, context());
  for (let i = 0; i < 5; i++) await flush();
  return { sdk, runtime, gets, posts, add, losePosts: () => { losePost = true; },
    call: (name: string, params: unknown) => sdk.tools.get(name).execute("fixture", params) };
}

test("bound tools join an explicit scope and link a request without waking peers", async t => {
  const f = await fixture(t);
  await assert.rejects(f.call("read_channel", {}), /explicitly agreed/);
  await f.call("set_coordination_scope", { channel: "project" });
  assert.equal(f.posts.length, 0);
  const posted = await f.call("post_channel", { body: "Check the unchanged client.", note: {
    kind: "request", owner: agentB, artifact: "abc123", checkpoint: "before integration",
  } });
  assert.equal(posted.details.status, "accepted");
  assert.equal(posted.details.reference.channel, "project");
  assert.equal(posted.details.reference.from, f.runtime.runtimeId());
  assert.equal(decodeCoordinationNote(f.posts[0].body)?.body, "Check the unchanged client.");
  const page = await f.call("read_channel", {});
  assert.match(page.content[0].text, /Check the unchanged client/);
  assert.equal(page.details.hasMore, false);
  const unchanged = await f.call("read_channel", { mode: "new" });
  assert.equal(unchanged.details.page.messages.length, 0);
  assert.equal(f.gets.at(-1)?.after, page.details.returnedThrough);
  assert.deepEqual(f.sdk.injected, []);
  assert.equal(f.runtime.beforeAgentStart(), undefined);
  await f.call("set_coordination_scope", { channel: null });
  await assert.rejects(f.call("post_channel", { body: "no implicit general" }), /explicitly agreed/);
});

test("brief reads preserve free-text dissent and do not consume message checkpoints", async t => {
  const f = await fixture(t);
  f.add("project", "Contrary evidence: integration still fails.");
  const brief = await f.call("read_channel", { channel: "project", view: "brief" });
  assert.match(brief.content[0].text, /Contrary evidence/);
  assert.equal(brief.details.checkpointConsumed, false);
  const before = f.gets.length;
  await assert.rejects(f.call("read_channel", { channel: "project", mode: "new", view: "brief" }), /always recent/);
  assert.equal(f.gets.length, before);
  const full = await f.call("read_channel", { channel: "project", mode: "new" });
  assert.equal(full.details.page.messages.length, 1);
  assert.equal(f.gets.at(-1)?.after, "0");
});

test("whole-result truncation commits only complete returned records and can continue", async t => {
  const f = await fixture(t);
  for (let i = 0; i < 24; i++) f.add("project", "x".repeat(4096));
  const first = await f.call("read_channel", { channel: "project" });
  assert.equal(first.details.outputTruncated, true);
  assert.equal(first.details.serverCaughtUp, true);
  assert.equal(first.details.hasMore, true);
  assert.ok(Buffer.byteLength(first.content[0].text) <= 48 * 1024);
  const next = await f.call("read_channel", { channel: "project", mode: "new" });
  assert.equal(f.gets.at(-1)?.after, first.details.returnedThrough);
  assert.ok(next.details.page.messages.every((row: ChannelMessage) => BigInt(row.seq) > BigInt(first.details.returnedThrough)));
});

test("invalid notes fail before dispatch and unknown posts retain a reference without retry", async t => {
  const f = await fixture(t);
  await assert.rejects(f.call("post_channel", { channel: "project", body: "scope", note: {
    kind: "request", owner: "tester", artifact: "abc123", checkpoint: "before integration",
  } }), /invalid coordination note/);
  assert.equal(f.posts.length, 0);
  f.losePosts();
  const result = await f.call("post_channel", { channel: "project", body: "one attempt only" });
  assert.equal(result.details.status, "outcome_unknown");
  assert.equal(f.posts.length, 1);
  assert.equal(result.details.reference.channel, "project");
  assert.match(result.content[0].text, /Attempt reference/);
});
