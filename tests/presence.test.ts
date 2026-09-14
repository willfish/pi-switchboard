import assert from "node:assert/strict";
import { it } from "node:test";
import * as presence from "../extension/presence.ts";

const epoch = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const snapshotId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
function agent(n: number) {
  return { agentId: `${n.toString(16).padStart(8, "0")}-0000-4000-8000-000000000000`,
    sessionId: epoch, host: "host", cwd: "/tmp", sessionName: "session", label: "peer 😀",
    model: null, status: "idle", pid: 1, acceptsControl: false, receiving: true, updatedAt: 1 };
}
function snapshot(overrides = {}) {
  return { epoch, revision: "1", snapshotId, capturedAt: 1, chunk: 0, total: 1, agents: [agent(1)], final: true, ...overrides };
}
function apply(state: presence.PresenceState, event: string, doc: unknown, now = 0) {
  return presence.reducePresence(state, event, new TextEncoder().encode(JSON.stringify(doc)), now);
}
it("stages snapshots privately, commits atomically and remains synchronizing until caught up", () => {
  const initial = presence.createPresenceState();
  const staging = apply(initial, "presence_snapshot", snapshot({ total: 2, final: false }));
  assert.equal(staging.status, "synchronizing"); assert.equal(staging.agents.length, 0);
  const committed = apply(staging, "presence_snapshot", snapshot({ total: 2, chunk: 1, agents: [agent(2)] }));
  assert.deepEqual(committed.agents, [agent(1), agent(2)]); assert.equal(initial.agents.length, 0);
  assert.equal(committed.status, "synchronizing");
  const ready = apply(committed, "presence_delta", { epoch, fromRevision: "1", toRevision: "1", changes: [], caughtUp: true });
  assert.equal(ready.status, "current");
  const updated = apply(ready, "presence_delta", { epoch, fromRevision: "1", toRevision: "4", changes: [
    { op: "remove", agentId: agent(1).agentId }, { op: "upsert", agent: { ...agent(2), label: "changed" } }], caughtUp: false });
  assert.deepEqual(updated.agents, [{ ...agent(2), label: "changed" }]);
  assert.equal(updated.revision, "4"); assert.equal(updated.status, "synchronizing");
  assert.equal(ready.agents.length, 2);
});
it("rejects exact-schema, Unicode, chunk, epoch and revision violations atomically", () => {
  const initial = presence.createPresenceState();
  for (const invalid of [{ revision: "01" }, { revision: "18446744073709551616" }, { revision: 1 },
    { epoch: "bad" }, { extra: true }, { total: 5001 }, { chunk: 1 }, { total: 2 },
    { agents: [agent(1), agent(1)], total: 2 }, { agents: [{ ...agent(1), model: { provider: "p", id: "m", extra: true } }] },
    { agents: [{ ...agent(1), label: "\ud800" }] }, { agents: [{ ...agent(1), updatedAt: undefined }] }]) {
    const result = apply(initial, "presence_snapshot", snapshot(invalid));
    assert.equal(result.reconnect, true, JSON.stringify(invalid)); assert.deepEqual(result.agents, []);
  }
  const staging = apply(initial, "presence_snapshot", snapshot({ total: 2, final: false }));
  for (const invalid of [{ revision: "2" }, { snapshotId: epoch }, { epoch: snapshotId }, { capturedAt: 2 }, { total: 3 }, { chunk: 0 }, { agents: [agent(1)] }]) {
    const result = apply(staging, "presence_snapshot", snapshot({ total: 2, chunk: 1, agents: [agent(2)], ...invalid }));
    assert.equal(result.reconnect, true); assert.deepEqual(result.agents, []); assert.equal(result.staging, null);
  }
  const expired = apply(staging, "presence_snapshot", snapshot({ total: 2, chunk: 1, agents: [agent(2)] }), 30000);
  assert.equal(expired.reconnect, true);
  assert.equal(apply(staging, "presence_snapshot", snapshot({ total: 2, chunk: 1, agents: [agent(2)] }), 29999).reconnect, false);
});
it("delta validation is atomic, contiguous, epoch-fenced, unique and uint64 bounded", () => {
  const state = apply(presence.createPresenceState(), "presence_snapshot", snapshot({ revision: "18446744073709551614" }));
  const delta = { epoch, fromRevision: state.revision, toRevision: "18446744073709551615", caughtUp: true,
    changes: [{ op: "remove", agentId: agent(1).agentId }] };
  assert.equal(apply(state, "presence_delta", delta).agents.length, 0);
  for (const invalid of [{ epoch: snapshotId }, { fromRevision: "1" }, { toRevision: "18446744073709551616" },
    { toRevision: "18446744073709551613" }, { extra: true }, { changes: [] }, { caughtUp: 1 },
    { changes: [{ op: "remove", agentId: agent(1).agentId }, { op: "bad" }] }]) {
    const result = apply(state, "presence_delta", { ...delta, ...invalid });
    assert.equal(result.reconnect, true); assert.deepEqual(result.agents, state.agents); assert.equal(result.revision, state.revision);
  }
  const low = apply(presence.createPresenceState(), "presence_snapshot", snapshot());
  for (const changes of [[{ op: "remove", agentId: agent(1).agentId }, { op: "upsert", agent: agent(1) }],
    [{ op: "remove", agentId: agent(1).agentId }, { op: "upsert", agent: { ...agent(2), pid: 0 } }]]) {
    const result = apply(low, "presence_delta", { epoch, fromRevision: "1", toRevision: "3", caughtUp: true, changes });
    assert.equal(result.reconnect, true); assert.deepEqual(result.agents, low.agents);
  }
  assert.equal(apply(low, "presence_delta", { epoch, fromRevision: "1", toRevision: "130", caughtUp: true, changes: [{ op: "remove", agentId: agent(1).agentId }] }).reconnect, true);
});
it("requires reset before replacing a baseline, fences regression, and stops after invalid events", () => {
  const committed = apply(presence.createPresenceState(), "presence_snapshot", snapshot({ revision: "9" }));
  assert.equal(apply(committed, "presence_snapshot", snapshot({ revision: "10" })).reconnect, true);
  const staging = apply(apply(committed, "presence_reset", { epoch, reason: "snapshot_expired" }),
    "presence_snapshot", snapshot({ revision: "10", total: 2, final: false }));
  assert.deepEqual(staging.agents, committed.agents);
  const reset = apply(staging, "presence_reset", { epoch, reason: "history_lost" });
  assert.equal(reset.staging, null); assert.equal(reset.status, "stale"); assert.deepEqual(reset.agents, committed.agents);
  for (const doc of [{ epoch: snapshotId, reason: "history_lost" }, { epoch, reason: "bad" }, { epoch, reason: "history_lost", extra: true }]) {
    assert.equal(apply(reset, "presence_reset", doc).reconnect, true);
  }
  for (const change of [{ revision: "8" }, { epoch: snapshotId }]) {
    const bad = apply(reset, "presence_snapshot", snapshot(change));
    assert.equal(bad.reconnect, true); assert.deepEqual(bad.agents, committed.agents);
    assert.equal(apply(bad, "presence_snapshot", snapshot({ revision: "10" })), bad);
  }
  assert.equal(apply(presence.createPresenceState(), "presence_delta", { epoch, fromRevision: "0", toRevision: "0", changes: [], caughtUp: true }).reconnect, true);
});
it("enforces the 128-record and change prefix limits", () => {
  const initial = presence.createPresenceState();
  assert.equal(apply(initial, "presence_snapshot", snapshot({ total: 129, agents: Array.from({ length: 129 }, (_, n) => agent(n)) })).reconnect, true);
  const committed = apply(initial, "presence_snapshot", snapshot({ total: 0, agents: [] }));
  const changes = Array.from({ length: 128 }, (_, n) => ({ op: "upsert", agent: agent(n) }));
  const valid = apply(committed, "presence_delta", { epoch, fromRevision: "1", toRevision: "129", changes, caughtUp: true });
  assert.equal(valid.reconnect, false); assert.equal(valid.agents.length, 128);
  const bad = apply(committed, "presence_delta", { epoch, fromRevision: "1", toRevision: "130", changes: [...changes, { op: "upsert", agent: agent(128) }], caughtUp: true });
  assert.equal(bad.reconnect, true); assert.equal(bad.agents.length, 0);
  assert.equal(apply(committed, "presence_delta", { epoch, fromRevision: "1", toRevision: "1", changes: [], caughtUp: false }).reconnect, true);
});
it("bounds data bytes independently of framing, with fatal UTF-8 and escaped Unicode decoding", () => {
  const initial = presence.createPresenceState();
  const doc = JSON.stringify(snapshot());
  const exact = doc + " ".repeat(1048576 - Buffer.byteLength(doc));
  for (const data of [exact.slice(0, -1), exact]) {
    assert.equal(presence.reducePresence(initial, "presence_snapshot", new TextEncoder().encode(data), 0).reconnect, false);
  }
  for (const data of [new TextEncoder().encode(exact + " "), new Uint8Array([0xc0, 0xaf]),
    new Uint8Array([0xf0, 0x9f, 0x98]), new TextEncoder().encode(doc.replace('"total":1', '"total":1,"total":1'))]) {
    assert.equal(presence.reducePresence(initial, "presence_snapshot", data, 0).reconnect, true);
  }
});
it("bounds staging bytes at 256MiB without exposing a partial snapshot", () => {
  let state = presence.createPresenceState();
  const overhead = Buffer.byteLength("event: presence_snapshot\ndata: \n\n");
  for (let chunk = 0; chunk <= 256; chunk++) {
    const doc = JSON.stringify(snapshot({ chunk, total: 258, agents: [agent(chunk)], final: false }));
    state = presence.reducePresence(state, "presence_snapshot", new TextEncoder().encode(doc + " ".repeat(1048576 - overhead - Buffer.byteLength(doc))), 0);
    assert.equal(state.reconnect, chunk === 256);
    assert.equal(state.agents.length, 0);
    if (chunk === 255) assert.equal(state.staging?.bytes, 268435456);
  }
  assert.equal(state.staging, null);
});
it("checks canonical staging equality and final-chunk overflow before atomic publication", () => {
  let state = presence.createPresenceState();
  const overhead = Buffer.byteLength("event: presence_snapshot\ndata: \n\n");
  const padded = (chunk: number, final: boolean, charge: number) => {
    const doc = JSON.stringify(snapshot({ chunk, total: 256, agents: [agent(chunk)], final }));
    return new TextEncoder().encode(doc + " ".repeat(charge - overhead - Buffer.byteLength(doc)));
  };
  // The first frame's data reaches the admission cap, so its canonical charge exceeds 1MiB.
  for (let chunk = 0; chunk < 255; chunk++) {
    state = presence.reducePresence(state, "presence_snapshot", padded(chunk, false, 1048576 + (chunk === 0 ? overhead : 0)), 0);
    assert.equal(state.reconnect, false); assert.equal(state.agents.length, 0);
  }
  assert.equal(state.staging?.bytes, 255 * 1048576 + overhead);
  for (const extra of [-1, 0, 1]) {
    const result = presence.reducePresence(state, "presence_snapshot", padded(255, true, 1048576 - overhead + extra), 0);
    assert.equal(result.reconnect, extra > 0);
    assert.equal(result.agents.length, extra > 0 ? 0 : 256);
    assert.equal(result.staging, null);
  }
  assert.equal(state.agents.length, 0);
});
it("commits 5000 records but refuses a delta adding record 5001", () => {
  let state = presence.createPresenceState();
  for (let start = 0; start < 5000; start += 128) {
    state = apply(state, "presence_snapshot", snapshot({ chunk: start / 128, total: 5000,
      agents: Array.from({ length: Math.min(128, 5000 - start) }, (_, n) => agent(start + n)), final: start + 128 >= 5000 }));
  }
  assert.equal(state.agents.length, 5000); assert.equal(state.reconnect, false);
  const over = apply(state, "presence_delta", { epoch, fromRevision: "1", toRevision: "2", caughtUp: true, changes: [{ op: "upsert", agent: agent(5000) }] });
  assert.equal(over.reconnect, true); assert.equal(over.agents.length, 5000);
  const replace = apply(state, "presence_delta", { epoch, fromRevision: "1", toRevision: "3", caughtUp: true,
    changes: [{ op: "upsert", agent: agent(5000) }, { op: "remove", agentId: agent(0).agentId }] });
  assert.equal(replace.reconnect, false); assert.equal(replace.agents.length, 5000);
});
it("reset discards staging and marks committed cache stale; gaps require reconnect without partial writes", () => {
  const state = apply(presence.createPresenceState(), "presence_snapshot", snapshot());
  const bad = apply(state, "presence_delta", { epoch, fromRevision: "0", toRevision: "2", changes: [{ op: "remove", agentId: agent(1).agentId }], caughtUp: true });
  assert.equal(bad.reconnect, true); assert.deepEqual(bad.agents, state.agents); assert.equal(bad.status, "stale");
  const reset = apply(state, "presence_reset", { epoch, reason: "history_lost" });
  assert.equal(reset.status, "stale"); assert.equal(reset.reconnect, false); assert.equal(reset.staging, null);
  const next = apply(reset, "presence_snapshot", snapshot({ revision: "2" }));
  assert.equal(next.revision, "2");
});
