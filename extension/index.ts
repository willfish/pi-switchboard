import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createRuntime, type AgentBusDeps } from "./runtime.ts";
import { bindCommands } from "./commands.ts";
import { bindTools } from "./tools.ts";
import { Text } from "@earendil-works/pi-tui";
import { safeText } from "./viewer.ts";
export type { AgentBusDeps, AgentBusRuntime, Env } from "./runtime.ts";

/** Cold factory: bind SDK callbacks only. Session startup owns all producers. */
export function createAgentBusExtension(deps: AgentBusDeps = {}) {
  const runtime = createRuntime(deps);
  const pi = deps.pi;
  if (pi) bindHost(pi, runtime);
  return runtime;
}
function bindHost(pi: ExtensionAPI, runtime: ReturnType<typeof createRuntime>): void {
  pi.on("session_start", (event, ctx) => runtime.sessionStart(event, ctx));
  pi.on("session_shutdown", () => runtime.sessionShutdown());
  pi.on("agent_start", (_event, ctx) => runtime.setBusy(true, ctx));
  pi.on("agent_settled", (_event, ctx) => runtime.setBusy(!ctx.isIdle(), ctx));
  pi.on("model_select", (event, ctx) => runtime.modelSelect(event.model, ctx));
  pi.on("session_info_changed", (_event, ctx) => runtime.refresh(ctx));
  pi.on("session_tree", (_event, ctx) => runtime.refresh(ctx, true));
  pi.on("before_agent_start", () => runtime.beforeAgentStart());
  pi.on("message_start", event => runtime.messageStart(event.message));
  pi.registerMessageRenderer("agent-bus-mail", (message, options) => new Text(safeText(typeof message.content === "string" ? message.content : message.content.filter(block => block.type === "text").map(block => block.type === "text" ? block.text : "").join("\n")), options.outputPad, 0));
  bindCommands(pi, runtime);
  bindTools(pi, runtime);
}
