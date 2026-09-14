import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Timers, FetchLike } from "../extension/client.ts";
import type { subscribeOnce } from "../extension/sse.ts";

export const agentA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const agentB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
export function context(overrides: Record<string, any> = {}): ExtensionContext {
  return { mode: "tui", hasUI: true, cwd: "/tmp/work", model: undefined, isIdle: () => true,
    ...overrides,
    sessionManager: { getSessionId: () => agentB, getBranch: () => [], ...overrides.sessionManager },
    ui: { notify() {}, setStatus() {}, confirm: async () => false, ...overrides.ui },
  } as ExtensionContext;
}
export const flush = async () => { for (let n = 0; n < 30; n++) await Promise.resolve(); };
export function response(status = 204, value: unknown = null) {
  return { status, headers: { get: (name: string) => name === "content-type" ? "application/json" : null },
    text: async () => JSON.stringify(value),
    body: { getReader() { let done = false; return { read: async () => {
      if (done) return { done: true }; done = true;
      return { done: false, value: new TextEncoder().encode(JSON.stringify(value)) };
    }, cancel: async () => {}, releaseLock() {} }; } },
  };
}
export const dormantSubscribe: typeof subscribeOnce = ({ signal }) => new Promise(resolve => {
  if (signal.aborted) resolve({ reason: "aborted" });
  else signal.addEventListener("abort", () => resolve({ reason: "aborted" }), { once: true });
});
export class Clock implements Timers {
  time = 0;
  next = 0;
  tasks = new Map<number, { at: number; callback: () => void }>();
  setTimeout(callback: () => void, ms: number) { const id = ++this.next; this.tasks.set(id, { at: this.time + ms, callback }); return id; }
  clearTimeout(handle: unknown) { this.tasks.delete(handle as number); }
  async advance(ms: number) {
    const end = this.time + ms;
    for (;;) {
      const next = [...this.tasks].filter(([, task]) => task.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      this.time = next[1].at; this.tasks.delete(next[0]); next[1].callback(); await flush();
    }
    this.time = end; await flush();
  }
}
export function host() {
  const events = new Map<string, (...args: any[]) => any>();
  const commands = new Map<string, any>(); const tools = new Map<string, any>(); const renderers = new Map<string, any>();
  const injected: { text: string; options: unknown }[] = []; const entries: unknown[] = [];
  let name: string | undefined;
  const pi = { on: (event: string, handler: (...args: any[]) => any) => events.set(event, handler),
    registerCommand: (name: string, spec: unknown) => commands.set(name, spec),
    registerTool: (spec: any) => tools.set(spec.name, spec),
    registerMessageRenderer: (name: string, renderer: unknown) => renderers.set(name, renderer),
    appendEntry: (type: string, data: unknown) => entries.push({ type, data }),
    getSessionName: () => name,
    sendUserMessage: (text: string, options: unknown) => injected.push({ text, options }),
  } as unknown as ExtensionAPI;
  return { pi, events, commands, tools, renderers, injected, entries, setName: (next: string | undefined) => { name = next; } };
}
export const peer = { agentId: agentB, sessionId: agentB, host: "peer", cwd: "/tmp/peer", sessionName: "peer", label: "peer label", model: null, status: "idle" as const, pid: 2, receiving: true, acceptsControl: true, updatedAt: 0 };
export function discovery(agents = [peer]) { return response(200, { epoch: agentA, revision: "1", snapshotId: agentB, capturedAt: 0, page: 0, total: agents.length, nextCursor: null, agents }); }
export function sync(options: Parameters<typeof subscribeOnce>[0]) {
  const frame = (event: "presence_snapshot" | "presence_delta", data: unknown) => options.onFrame({ event, data: new TextEncoder().encode(JSON.stringify(data)) });
  frame("presence_snapshot", { epoch: agentA, revision: "1", snapshotId: agentB, capturedAt: 0, chunk: 0, total: 0, agents: [], final: true });
  frame("presence_delta", { epoch: agentA, fromRevision: "1", toRevision: "1", caughtUp: true, changes: [] });
}
export type { FetchLike };
