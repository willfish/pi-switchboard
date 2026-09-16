import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { StringEnum } from "@earendil-works/pi-ai";
import type { AgentBusRuntime } from "./runtime.ts";
import { describeOutcome, formatAgentList } from "./commands.ts";

export function bindTools(pi: ExtensionAPI, runtime: AgentBusRuntime): void {
  const nullableText = () => Type.Union([Type.String(), Type.Null()]);
  pi.registerTool({ name: 'report_work', label: 'Report work',
    description: 'Record explicit work metadata for the console. Use a stable UUID workId and null for unknown fields. No credentials, hidden reasoning or raw tool output. This reports work; it does not grant permissions or prove completion.',
    parameters: Type.Object({
      workId: nullableText(), objective: nullableText(),
      phase: Type.Union([StringEnum(['planning', 'implementing', 'verifying', 'waiting', 'completed', 'failed'] as const), Type.Null()]),
      currentStep: nullableText(), nextStep: nullableText(), owner: nullableText(),
      blocker: Type.Union([Type.Object({ kind: StringEnum(['blocked', 'decision'] as const), reason: Type.String() }), Type.Null()]),
      project: nullableText(), repository: nullableText(), branch: nullableText(), worktree: nullableText(),
      parentWorkId: nullableText(), delegatedWorkId: nullableText(),
      evidence: Type.Array(Type.Object({ kind: StringEnum(['file', 'test', 'commit', 'artifact'] as const), ref: Type.String() }), { maxItems: 8 }),
    }),
    async execute(_id, params, signal) {
      if (signal?.aborted) throw new Error('cancelled');
      const work = runtime.reportWork(params);
      if (typeof work === 'string') throw new Error(work);
      return { content: [{ type: 'text', text: 'Work report recorded locally. Console synchronization is separate from this acknowledgement.' }], details: { work } };
    },
  });
  pi.registerTool({ name: "list_agents", label: "List agents", description: "Fetch live Switchboard agents. Readable output is limited to 50 KiB/2,000 lines; structured details retain all records.",
    parameters: Type.Object({}),
    async execute(_id, _params, signal) {
      const id = runtime.runtimeId();
      const version = runtime.version();
      if (signal?.aborted) throw new Error("cancelled");
      const result = await runtime.list(signal);
      if (signal?.aborted) throw new Error("cancelled");
      if (runtime.version() !== version || (id !== undefined && !runtime.isCurrent(id, version))) throw new Error("runtime closed");
      if (result.status !== "ok") throw new Error(describeOutcome(result));
      return { content: [{ type: "text", text: formatAgentList(result.agents, id ?? "") }], details: { agents: result.agents } };
    } });
  pi.registerTool({ name: "set_agent_label", label: "Set agent label", description: "Set a nonempty, single-line work label, at most 200 Unicode code points. Cannot clear labels or enable peer control.",
    parameters: Type.Object({ label: Type.String() }),
    async execute(_id, params, signal) {
      if (signal?.aborted) throw new Error("cancelled");
      const label = runtime.setLabel(params.label);
      return { content: [{ type: "text", text: label }], details: { label } };
    } });
  pi.registerTool({ name: "send_agent_message", label: "Send agent message", description: "Send one best-effort notice (default), prompt or steer to a freshly resolved peer. Control requires receiver-local consent. Steer can affect active work. Acceptance is not delivery or execution; never automatically resend an uncertain outcome.",
    parameters: Type.Object({ to: Type.String(), body: Type.String(), kind: Type.Optional(StringEnum(["notice", "prompt", "steer"] as const)) }),
    async execute(_id, params, signal) {
      const result = await runtime.send(params.to, params.body, params.kind ?? "notice", signal);
      return { content: [{ type: "text", text: describeOutcome(result) }], details: result };
    } });
}
