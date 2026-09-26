import assert from "node:assert/strict";
import test from "node:test";
import { areaChannel, isChannelPage, statusSummary } from "../extension/channels.ts";
import { createHubClient } from "../extension/client.ts";

test("area channels stay distinct from general and reject path noise", () => {
  assert.equal(areaChannel("/srv/media/imports"), "imports");
  assert.equal(areaChannel("C:\\Work\\Pi Switchboard"), "pi-switchboard");
  assert.equal(areaChannel("/"), "workspace");
  assert.equal(areaChannel("/tmp/general"), "workspace");
});

test("a lost or malformed channel post is not reported as a clean rejection", async () => {
  const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", fetch: async () => ({
    status: 202, headers: { get: () => null }, text: async () => "{}",
    body: { getReader: () => reader("{}{}") },
  }) });
  const result = await client.postChannel("general", { id: "33333333-3333-4333-8333-333333333333", from: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", body: "note" });
  assert.equal(result.status, "outcome_unknown");
});

test("status text is one bounded line", () => {
  const summary = statusSummary({ label: "agent", busy: true, objective: "ship channels", step: "verify", project: "switchboard" });
  assert.match(summary, /^working · switchboard · ship channels · verify · agent$/);
  assert.equal(statusSummary({ label: "a\nb", busy: false }).includes("\n"), false);
  assert.ok([...statusSummary({ label: "x".repeat(500), busy: false })].length <= 280);
});

test("agent client accepts only a recent channel window", async () => {
  const page = {
    epoch: "11111111-1111-4111-8111-111111111111", channel: "general", window: "recent",
    fromSequence: "1", toSequence: "1", retainedFrom: "1", retainedTo: "1", coverage: "complete",
    caughtUp: true, earlier: false, nextCursor: null, earlierCursor: null,
    messages: [{ seq: "1", id: "33333333-3333-4333-8333-333333333333", channel: "general",
      from: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", kind: "say", body: "hello", postedAt: 10 }],
  };
  const client = createHubClient({ baseUrl: "http://hub", token: "synthetic", fetch: async () => ({
    status: 200, headers: { get: () => null }, text: async () => JSON.stringify(page),
    body: { getReader: () => reader(JSON.stringify(page)) },
  }) });
  const result = await client.readChannel("general", "0");
  assert.equal(result.status, "ok");
  if (result.status === "ok") assert.equal(isChannelPage(result.page, "general"), true);
  const history = createHubClient({ baseUrl: "http://hub", token: "synthetic", fetch: async () => ({
    status: 200, headers: { get: () => null }, text: async () => JSON.stringify({ ...page, window: "history" }),
    body: { getReader: () => reader(JSON.stringify({ ...page, window: "history" })) },
  }) });
  assert.equal((await history.readChannel("general", "0")).status, "rejected");
});

function reader(text: string) {
  let done = false;
  return { async read() { if (done) return { done: true }; done = true; return { done: false, value: new TextEncoder().encode(text) }; } };
}
