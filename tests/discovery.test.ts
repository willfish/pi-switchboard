import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  parseHubUrl,
  parseTell,
  resolveTarget,
  shortestUniquePrefix,
  snapshotModel,
  type Agent,
} from "../extension/protocol.ts";

function agent(partial: Partial<Agent> & Pick<Agent, "agentId" | "host" | "label">): Agent {
  return {
    sessionId: "22222222-2222-4222-8222-222222222222",
    cwd: "/tmp/work",
    sessionName: "s",
    model: null,
    status: "idle",
    pid: 1,
    acceptsControl: false,
    ...partial,
  };
}

const self = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const a = agent({
  agentId: self,
  host: "andromeda",
  label: "self label",
});
const b = agent({
  agentId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  host: "foundation",
  label: "flake checks",
});
const c = agent({
  agentId: "bbbbbbbb-cccc-4ccc-8ccc-cccccccccccc",
  host: "terminus",
  label: "flake review",
});

describe("parseHubUrl", () => {
  it("accepts the default form", () => {
    const parsed = parseHubUrl("http://terminus:7420");
    assert.deepEqual(parsed, { ok: "http://terminus:7420" });
  });
  it("rejects userinfo query and fragment", () => {
    assert.equal("error" in parseHubUrl("http://u:p@terminus:7420"), true);
    assert.equal("error" in parseHubUrl("http://terminus:7420/?x=1"), true);
    assert.equal("error" in parseHubUrl("http://terminus:7420/#frag"), true);
  });
});

describe("parseTell", () => {
  it("parses notice target and remaining text", () => {
    assert.deepEqual(parseTell("foundation ready to review"), {
      kind: "notice",
      target: "foundation",
      body: "ready to review",
    });
  });
  it("parses quoted targets and flags", () => {
    assert.deepEqual(parseTell('--prompt "flake checks" please look'), {
      kind: "prompt",
      target: "flake checks",
      body: "please look",
    });
  });
  it("supports -- to stop flags", () => {
    assert.deepEqual(parseTell("-- --prompt foundation not a flag"), {
      kind: "notice",
      target: "--prompt",
      body: "foundation not a flag",
    });
  });
  it("preserves body whitespace, quotes, and flags verbatim", () => {
    const body = 'say  "hello"\n\t--steer stays text  ';
    assert.deepEqual(parseTell(`--prompt "flake checks" ${body}`), {
      kind: "prompt", target: "flake checks", body,
    });
    assert.deepEqual(parseTell("foundation don't repair this \"quote"), {
      kind: "notice", target: "foundation", body: "don't repair this \"quote",
    });
  });
  it("rejects malformed target quoting and conflicting flags", () => {
    assert.ok("error" in parseTell('"flake"suffix hello'));
    assert.ok("error" in parseTell('--prompt --steer foundation hello'));
    assert.ok("error" in parseTell('"" hello'));
  });
  it("rejects ask and empty bodies", () => {
    assert.equal("error" in parseTell("--ask foundation hi"), true);
    assert.equal("error" in parseTell("foundation"), true);
    assert.equal("error" in parseTell('"unclosed'), true);
  });
});

describe("resolveTarget", () => {
  const agents = [a, b, c];
  it("matches unique prefix of at least eight", () => {
    const got = resolveTarget("bbbbbbbb-bbbb", agents, self);
    assert.equal("ok" in got && got.ok.agentId, b.agentId);
  });
  it("stops on ambiguous prefix", () => {
    const got = resolveTarget("bbbbbbbb", agents, self);
    assert.equal("error" in got, true);
  });
  it("matches exact host then label substring", () => {
    const host = resolveTarget("foundation", agents, self);
    assert.equal("ok" in host && host.ok.host, "foundation");
    const label = resolveTarget("review", agents, self);
    assert.equal("ok" in label && label.ok.agentId, c.agentId);
  });
  it("does not reinterpret an explicit self runtime ID as another peer's label", () => {
    const alias = { ...b, label: self };
    for (const target of [self, self.toUpperCase()]) {
      const result = resolveTarget(target, [a, alias], self);
      assert.equal("error" in result, true);
    }
  });
  it("does not resolve self shorthand and does not retarget missing peers", () => {
    const selfHit = resolveTarget("andromeda", agents, self);
    assert.equal("error" in selfHit, true);
    const gone = resolveTarget("foundation", [a, c], self);
    assert.equal("error" in gone && gone.error, "no matching agent");
  });
});

describe("shortestUniquePrefix", () => {
  it("returns at least eight characters", () => {
    const prefix = shortestUniquePrefix(b.agentId, [a, b, c]);
    assert.ok(prefix.length >= 8);
    assert.ok(b.agentId.startsWith(prefix));
    assert.notEqual(prefix, "bbbb");
  });
});

describe("snapshotModel", () => {
  it("keeps provider and id only", () => {
    assert.deepEqual(
      snapshotModel({
        provider: "anthropic",
        id: "claude-sonnet-4-5",
        apiKey: "secret",
        baseUrl: "https://example.invalid",
      }),
      { provider: "anthropic", id: "claude-sonnet-4-5" },
    );
    assert.equal(snapshotModel(null), null);
  });
});
