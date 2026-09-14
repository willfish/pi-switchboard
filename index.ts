import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { hostname } from "node:os";
import { createAgentBusExtension } from "./extension/index.ts";
export { createAgentBusExtension } from "./extension/index.ts";

export default function agentBus(pi: ExtensionAPI): void {
  createAgentBusExtension({ pi, env: process.env, fetch: globalThis.fetch,
    uuid: randomUUID, hostname, pid: () => process.pid,
    now: () => performance.now(), wallNow: Date.now, random: Math.random,
    timers: { setTimeout: (callback, ms) => setTimeout(callback, ms), clearTimeout: handle => clearTimeout(handle as ReturnType<typeof setTimeout>) },
  });
}
