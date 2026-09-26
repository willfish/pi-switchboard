import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { StringEnum } from "@earendil-works/pi-ai";
import type { AgentBusRuntime } from "./runtime.ts";
import { describeOutcome, formatAgentList } from "./commands.ts";
import { CHANNEL_NAME, formatChannelPage, statusSummary } from "./channels.ts";

export function bindTools(pi: ExtensionAPI, runtime: AgentBusRuntime): void {
  const nullableText = () => Type.Union([Type.String(), Type.Null()]);
  pi.registerTool({ name: 'report_work', label: 'Report work',
    description: 'Record explicit work metadata for the console. Prefer a stable UUID workId; other ids map to a stable UUID. Use null for unknown fields. Missing fields, empty strings and extra keys are ignored. No credentials, hidden reasoning or raw tool output. This reports work; it does not grant permissions or prove completion.',
    parameters: Type.Object({
      workId: Type.Optional(nullableText()), objective: Type.Optional(nullableText()),
      phase: Type.Optional(Type.Union([Type.String(), Type.Null()])),
      currentStep: Type.Optional(nullableText()), nextStep: Type.Optional(nullableText()), owner: Type.Optional(nullableText()),
      blocker: Type.Optional(Type.Union([Type.Object({ kind: Type.String(), reason: Type.String() }), Type.Null()])),
      project: Type.Optional(nullableText()), repository: Type.Optional(nullableText()), branch: Type.Optional(nullableText()), worktree: Type.Optional(nullableText()),
      parentWorkId: Type.Optional(nullableText()), delegatedWorkId: Type.Optional(nullableText()),
      evidence: Type.Optional(Type.Array(Type.Object({ kind: Type.String(), ref: Type.String() }), { maxItems: 8 })),
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
  pi.registerTool({ name: "list_channels", label: "List channels", description: "List shared Switchboard channels. #general is the fleet check-in. Also read the channel for the current project when working in the same area. This is a recent directory, not full history.",
    parameters: Type.Object({}),
    async execute(_id, _params, signal) {
      if (signal?.aborted) throw new Error("cancelled");
      const result = await runtime.listChannels(signal);
      if (result.status !== "ok") throw new Error(describeOutcome(result));
      const text = result.channels.map(channel => `#${channel.name} retained=${channel.retained} last=${channel.lastSequence} ${channel.topic}`).join("\n") || "no channels";
      return { content: [{ type: "text", text }], details: { epoch: result.epoch, channels: result.channels } };
    } });
  pi.registerTool({ name: "read_channel", label: "Read channel", description: "Read the recent window for one channel, or the forward delta since this runtime's cursor. Do not page older history; the operator console keeps that. Check #general and the area channel at the start of work and when coordination details change.",
    parameters: Type.Object({ channel: Type.String() }),
    async execute(_id, params, signal) {
      if (signal?.aborted) throw new Error("cancelled");
      if (!CHANNEL_NAME.test(params.channel)) throw new Error("invalid channel");
      const result = await runtime.readChannel(params.channel, signal);
      if (result.status !== "ok") throw new Error(describeOutcome(result));
      return { content: [{ type: "text", text: formatChannelPage(result.page) }], details: { page: result.page } };
    } });
  pi.registerTool({ name: "post_channel", label: "Post to channel", description: "Post one coordination note to a channel. Use #general for fleet-wide notes and the project channel when the detail only matters to agents in that area. Acceptance is stored once in hub memory. A lost response is outcome unknown: check the channel before posting again. Do not post secrets, credentials, hidden reasoning, or raw tool output.",
    parameters: Type.Object({ channel: Type.String(), body: Type.String() }),
    async execute(_id, params, signal) {
      if (signal?.aborted) throw new Error("cancelled");
      const result = await runtime.postChannel(params.channel, params.body, signal);
      return { content: [{ type: "text", text: result.status === "accepted" ? `accepted into #${params.channel}` : describeOutcome(result) }], details: result };
    } });
  pi.registerTool({ name: "update_channel_status", label: "Update channel status", description: "Upsert this runtime's check-in on a channel. Identical text refreshes the board without another history packet. A changed summary adds one status note. Call this when the objective, step, or area changes, in addition to the automatic check-in.",
    parameters: Type.Object({ channel: Type.Optional(Type.String()), summary: Type.Optional(Type.String()) }),
    async execute(_id, params, signal) {
      if (signal?.aborted) throw new Error("cancelled");
      const channel = params.channel && params.channel.length > 0 ? params.channel : "general";
      if (!CHANNEL_NAME.test(channel)) throw new Error("invalid channel");
      const summary = params.summary && params.summary.trim().length > 0 ? params.summary : statusSummary({ label: runtime.label(), busy: runtime.isBusy(), objective: runtime.currentWork().objective, step: runtime.currentWork().currentStep, project: runtime.currentWork().project });
      const result = await runtime.updateChannelStatus(channel, summary, signal);
      if (result.status !== "ok") throw new Error(describeOutcome(result));
      return { content: [{ type: "text", text: `status ${result.state} on #${channel}` }], details: result };
    } });
  pi.registerTool({ name: "send_agent_message", label: "Send agent message", description: "Send a message to a freshly resolved peer. The default message is delivered to that agent and starts or continues its work. Prompt and steer still require receiver control consent. Acceptance is not proof the peer finished the work; never automatically resend an uncertain outcome.",
    parameters: Type.Object({ to: Type.String(), body: Type.String(), kind: Type.Optional(StringEnum(["notice", "prompt", "steer"] as const)) }),
    async execute(_id, params, signal) {
      const result = await runtime.send(params.to, params.body, params.kind ?? "notice", signal);
      return { content: [{ type: "text", text: describeOutcome(result) }], details: result };
    } });
}
