import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { AgentBusRuntime } from "./runtime.ts";
import { showText, showInbox, safeText } from "./viewer.ts";
import type { Agent } from "./protocol.ts";
import { cwdBasename, parseTell } from "./protocol.ts";

/** A sorted ID's longest shared prefix is with one of its two neighbors. */
function uniquePrefixes(agents: Agent[]): Map<string, string> {
  const ids = [...new Set(agents.map(agent => agent.agentId.toLowerCase()))].sort();
  const lengths = new Map<string, number>();
  const lcp = (a: string, b = "") => {
    let n = 0;
    while (n < a.length && n < b.length && a[n] === b[n]) n++;
    return n;
  };
  for (let i = 0; i < ids.length; i++) lengths.set(ids[i], Math.max(8, 1 + lcp(ids[i], ids[i - 1]), 1 + lcp(ids[i], ids[i + 1])));
  return new Map(agents.map(agent => {
    const id = agent.agentId;
    return [id, id.slice(0, lengths.get(id.toLowerCase()))];
  }));
}

export function formatAgentLine(agent: Agent, selfId: string, population: Agent[] = [agent]): string {
  return agentLine(agent, selfId, uniquePrefixes(population).get(agent.agentId) ?? agent.agentId);
}

function agentLine(agent: Agent, selfId: string, short: string): string {
  const model =
    agent.model === null
      ? "no model"
      : `${agent.model.provider}/${agent.model.id}`;
  const me = agent.agentId === selfId ? " (self)" : "";
  const ready = agent.receiving ? "receiving" : "not-receiving";
  const control = agent.acceptsControl ? "control" : "notice-only";
  return safeText(`${short}${me} ${agent.host} ${cwdBasename(agent.cwd)} ${agent.label} ${model} ${agent.status} ${ready} ${control}`).replace(/\n/g, "\\n");
}

export function completionItems(
  prefix: string,
  agents: Agent[],
  selfId: string,
): { value: string; label: string; description: string }[] {
  const q = prefix.trim().toLowerCase();
  const prefixes = uniquePrefixes(agents);
  return agents
    .filter((a) => a.agentId !== selfId)
    .filter((a) => {
      if (!q) {
        return true;
      }
      return (
        a.agentId.toLowerCase().startsWith(q) ||
        a.host.toLowerCase().startsWith(q) ||
        a.label.toLowerCase().includes(q)
      );
    })
    .map((a) => ({
      value: prefixes.get(a.agentId)!,
      label: prefixes.get(a.agentId)!,
      description: safeText(`${a.host} ${a.label} ${a.model ? `${a.model.provider}/${a.model.id}` : "no model"}`),
    }));
}

export function formatAgentList(agents: Agent[], selfId: string): string {
  const prefixes = uniquePrefixes(agents);
  const header = `${agents.length} agents (full records in structured details)`;
  const lines: string[] = [header];
  let bytes = Buffer.byteLength(header);
  let shown = 0;
  for (const agent of agents) {
    const line = agentLine(agent, selfId, prefixes.get(agent.agentId)!);
    const size = Buffer.byteLength(line) + 1;
    // Reserve room for an explicit truncation summary within both limits.
    if (lines.length >= 1999 || bytes + size > 50 * 1024 - 150) break;
    lines.push(line); bytes += size; shown++;
  }
  if (shown < agents.length) lines.push(`[truncated: shown ${shown} of ${agents.length} agents; full records in structured details]`);
  return agents.length ? lines.join("\n") : "no agents";
}

export function bindCommands(pi: ExtensionAPI, runtime: AgentBusRuntime): void {
  for (const name of ["label", "agents", "tell", "bus"] as const) {
    pi.registerCommand(name, {
      description: name === "tell" ? "Send a notice, --prompt, or --steer (can affect active work)" : `Switchboard ${name}`,
      getArgumentCompletions: prefix => {
        if (name === "tell") {
          const match = /^(--prompt\s+|--steer\s+|--\s+)?([^\s]*)$/.exec(prefix);
          if (!match) return null;
          const items = completionItems(match[2], runtime.listCached(), runtime.runtimeId() ?? "");
          return items.length ? items.map(item => ({ ...item, value: (match[1] ?? "") + item.value })) : null;
        }
        const choices = name === "bus" ? ["inbox", "control on", "control off", "operator read on", "operator read off", "operator manage on", "operator manage off", "operator notices on", "operator notices off", "operator history on", "operator history off"] : name === "label" ? ["--clear"] : [];
        return choices.filter(value => value.startsWith(prefix)).map(value => ({ value, label: value }));
      },
      handler: async (args, ctx) => {
        if (ctx.mode !== "tui") return;
        const id = runtime.runtimeId();
        const version = runtime.version();
        const stillCurrent = () => id ? runtime.isCurrent(id, version) : runtime.version() === version;
        try {
          if (name === "bus" && args.trim() === "inbox") {
            if (!id) { ctx.ui.notify("agent bus unavailable", "warning"); return; }
            await showInbox(ctx, runtime.inbox, key => { if (stillCurrent()) runtime.markRead(key); }, runtime.signal());
            return;
          }
          if (name === "agents") {
            if (!id) { ctx.ui.notify("agent bus unavailable", "warning"); return; }
            const result = await runtime.list();
            if (!stillCurrent()) return;
            if (result.status !== "ok") { ctx.ui.notify(describeOutcome(result), "warning"); return; }
            const prefixes = uniquePrefixes(result.agents);
            await showText(ctx, result.agents.length ? result.agents.map(a => agentLine(a, id!, prefixes.get(a.agentId)!)).join("\n") : "no agents", runtime.signal());
            return;
          }
          if (name === "tell") {
            const parsed = parseTell(args);
            if ("kind" in parsed && parsed.kind === "steer") ctx.ui.notify("Steering can affect the peer's active work; no execution or reply is promised.", "warning");
          }
          const result = await runtime.handleCommand(name, args, ctx);
          if (stillCurrent()) ctx.ui.notify(safeText(result), "info");
        } catch {
          if (stillCurrent()) ctx.ui.notify("Switchboard command unavailable or invalid label", "warning");
        }
      },
    });
  }
}

export function describeOutcome(outcome: {
  status: string;
  id?: string;
  to?: string;
  reason?: string;
}): string {
  switch (outcome.status) {
    case "accepted":
      return `accepted ${outcome.id} -> ${outcome.to} (hub memory only, not delivered)`;
    case "rejected":
      return `rejected: ${outcome.reason}`;
    case "outcome_unknown":
      return outcome.reason ?? "The hub response was lost; this may already have run. Check the peer before resending.";
    case "not_sent":
      return `not sent: ${outcome.reason}`;
    default:
      return outcome.status;
  }
}
