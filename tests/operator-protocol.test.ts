import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { it } from "node:test";
import {
  WORK_KEYS,
  decodeWorkSnapshot,
  encodeWorkSnapshot,
  isWorkSnapshot,
  MAX_WORK_EVIDENCE,
  MAX_WORK_OWNER_BYTES,
  MAX_WORK_REF_BYTES,
  MAX_WORK_TEXT_BYTES,
  type WorkSnapshot,
} from "../extension/operator-protocol.ts";
import { MAX_ENVELOPE_BYTES } from "../extension/protocol.ts";

const fixtures = JSON.parse(
  await readFile(new URL("./fixtures/operator-work.json", import.meta.url), "utf8"),
) as { allNull: WorkSnapshot; populated: WorkSnapshot; hostile: WorkSnapshot };

const encoder = new TextEncoder();

function roundTrip(value: WorkSnapshot): WorkSnapshot {
  return decodeWorkSnapshot(encodeWorkSnapshot(value));
}

it("round-trips shared all-null, populated and hostile fixtures without inventing phase or objective", () => {
  for (const name of ["allNull", "populated", "hostile"] as const) {
    const snap = fixtures[name];
    assert.equal(isWorkSnapshot(snap), true, name);
    assert.deepEqual(Object.keys(snap).sort(), [...WORK_KEYS].sort());
    const again = roundTrip(snap);
    assert.deepEqual(again, snap);
  }
  assert.equal(fixtures.allNull.phase, null);
  assert.equal(fixtures.allNull.objective, null);
  assert.equal(fixtures.allNull.currentStep, null);
  assert.equal(fixtures.allNull.nextStep, null);
  assert.equal(fixtures.allNull.blocker, null);
  assert.deepEqual(fixtures.allNull.evidence, []);
  assert.equal(fixtures.allNull.parentWorkId, null);
  assert.equal(fixtures.allNull.delegatedWorkId, null);
  assert.equal(fixtures.populated.currentStep, "write shared fixture");
  assert.equal(fixtures.populated.nextStep, "round-trip Erlang and TypeScript");
  assert.equal(fixtures.populated.blocker?.kind, "decision");
  assert.equal(fixtures.populated.evidence.length, 2);
  assert.ok(fixtures.populated.parentWorkId);
  assert.ok(fixtures.populated.delegatedWorkId);
  assert.match(fixtures.hostile.objective ?? "", /<script>/);
});

it("requires currentStep, nextStep, blocker, evidence and relationships", () => {
  const required = ["currentStep", "nextStep", "blocker", "evidence", "parentWorkId", "delegatedWorkId"] as const;
  for (const key of required) {
    const { [key]: _dropped, ...rest } = fixtures.allNull;
    assert.equal(isWorkSnapshot(rest), false, key);
    assert.throws(() => decodeWorkSnapshot(encoder.encode(JSON.stringify(rest))));
  }
});

it("rejects extra keys, bodies, nested maps, empty strings and unknown phase", () => {
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, body: "secret" }), false);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, extra: true }), false);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, objective: "" }), false);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, phase: "planningx" }), false);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, blocker: { kind: "blocked", reason: "x", extra: 1 } }), false);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, evidence: [{ kind: "file", ref: "a", nested: {} }] }), false);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, project: { name: "x" } }), false);
});

it("rejects lone surrogates and duplicate keys on the wire", () => {
  const base = JSON.stringify(fixtures.allNull);
  const surrogate = encoder.encode(base.replace('"objective":null', '"objective":"\\ud800"'));
  assert.throws(() => decodeWorkSnapshot(surrogate));
  const dup = encoder.encode(base.slice(0, -1) + ',"workId":null}');
  assert.throws(() => decodeWorkSnapshot(dup));
});

it("enforces byte bounds, not code-point counts, and a 32KiB envelope", () => {
  const text2048 = "a".repeat(MAX_WORK_TEXT_BYTES);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, objective: text2048 }), true);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, objective: text2048 + "a" }), false);
  const owner200 = "o".repeat(MAX_WORK_OWNER_BYTES);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, owner: owner200 }), true);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, owner: owner200 + "o" }), false);
  const pound = "£".repeat(1024);
  assert.equal(encoder.encode(pound).length > 1024, true);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, objective: pound }), true);
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, objective: pound + "£" }), false);
  const ref512 = "r".repeat(MAX_WORK_REF_BYTES);
  assert.equal(isWorkSnapshot({
    ...fixtures.allNull,
    evidence: [{ kind: "file", ref: ref512 }],
  }), true);
  assert.equal(isWorkSnapshot({
    ...fixtures.allNull,
    evidence: [{ kind: "file", ref: ref512 + "r" }],
  }), false);
  const tooMany = Array.from({ length: MAX_WORK_EVIDENCE + 1 }, () => ({ kind: "file" as const, ref: "a" }));
  assert.equal(isWorkSnapshot({ ...fixtures.allNull, evidence: tooMany }), false);
  const oversize = new Uint8Array(MAX_ENVELOPE_BYTES + 1);
  oversize.fill(0x20);
  assert.throws(() => decodeWorkSnapshot(oversize));
});
