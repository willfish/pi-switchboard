import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, wrapTextWithAnsi, type Component } from "@earendil-works/pi-tui";
import type { InboxState } from "./inbox.ts";

/** Never interpret peer ANSI/OSC, bidi controls or invalid scalar values as terminal instructions. */
export function safeText(text: string): string {
  return Array.from(text).map(char => /^[\ud800-\udfff]$/.test(char) ? "\ufffd" : char).join("").replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/g, char => `\\u${char.charCodeAt(0).toString(16).padStart(4, "0")}`).replace(/\t/g, "    ").replace(/[\u2028\u2029]/g, "\n");
}

type ViewerOptions = {
  text: string; rows: () => number; matches: (data: string, action: "up" | "down" | "pageUp" | "pageDown" | "confirm" | "cancel") => boolean;
  render: () => void; close: () => void;
};
export class ReadOnlyViewer implements Component {
  private offset = 0;
  private lines: string[] = [];
  private width = -1;
  private text: string;
  private options: ViewerOptions;
  constructor(options: ViewerOptions) { this.options = options; this.text = safeText(options.text); }
  invalidate(): void { this.width = -1; }
  render(width: number): string[] {
    width = Math.max(1, width);
    if (width !== this.width) { this.lines = wrapTextWithAnsi(this.text, width); this.width = width; }
    const rows = Math.max(1, Math.min(100, this.options.rows() - 2));
    this.offset = Math.min(this.offset, Math.max(0, this.lines.length - rows));
    return [...this.lines.slice(this.offset, this.offset + rows).map(line => truncateToWidth(line, width, "")), truncateToWidth(`Read only | ${this.offset + 1}/${this.lines.length} | arrows/page scroll | Esc close`, width, "")];
  }
  handleInput(data: string): void {
    const m = this.options.matches;
    if (m(data, "cancel") || data === "q") { this.options.close(); return; }
    const page = Math.max(1, this.options.rows() - 3);
    if (m(data, "up") || data === "k") this.offset = Math.max(0, this.offset - 1);
    else if (m(data, "down") || data === "j") this.offset = Math.min(Math.max(0, this.lines.length - 1), this.offset + 1);
    else if (m(data, "pageUp")) this.offset = Math.max(0, this.offset - page);
    else if (m(data, "pageDown")) this.offset = Math.min(Math.max(0, this.lines.length - 1), this.offset + page);
    this.options.render();
  }
}

export async function showText(ctx: ExtensionContext, text: string, signal?: AbortSignal): Promise<void> {
  if (ctx.mode !== "tui" || signal?.aborted) return;
  await ctx.ui.custom<void>((tui, _theme, kb, done) => {
    if (signal?.aborted) { done(undefined); return { render: () => [], invalidate() {} }; }
    const close = () => done(undefined);
    signal?.addEventListener("abort", close, { once: true });
    const viewer = new ReadOnlyViewer({ text, rows: () => tui.terminal.rows, render: () => tui.requestRender(), close,
      matches: (data, action) => kb.matches(data, `tui.select.${action}`) });
    return { render: w => viewer.render(w), invalidate: () => viewer.invalidate(), handleInput: d => viewer.handleInput(d), dispose: () => signal?.removeEventListener("abort", close) };
  });
}

export async function showInbox(ctx: ExtensionContext, getInbox: () => InboxState, markRead: (key: string) => void, signal?: AbortSignal): Promise<void> {
  if (ctx.mode !== "tui" || signal?.aborted) return;
  await ctx.ui.custom<void>((tui, _theme, kb, done) => {
    if (signal?.aborted) { done(undefined); return { render: () => [], invalidate() {} }; }
    let selectedKey: string | undefined;
    let visibleKeys: string[] = [];
    let viewing: ReadOnlyViewer | undefined;
    const close = () => done(undefined);
    signal?.addEventListener("abort", close, { once: true });
    const records = () => [...getInbox().records].reverse();
    const matches: ViewerOptions["matches"] = (data, action) => kb.matches(data, `tui.select.${action}`);
    return {
      render(width) {
        if (viewing) return viewing.render(width);
        const all = records();
        visibleKeys = all.map(record => record.key);
        selectedKey ??= visibleKeys[0];
        const selected = visibleKeys.indexOf(selectedKey ?? "");
        const height = Math.max(1, Math.min(100, tui.terminal.rows - 3));
        const start = Math.max(0, selected - height + 1);
        return ["Inbox (read only)", ...(all.length ? all.slice(start, start + height).map((record, i) => `${start + i === selected ? ">" : " "} ${record.humanRead ? "read" : "unread"} ${record.kind} ${record.sender.host}/${record.sender.label} ${record.receivedAt} ${record.handling}${record.discardReason ? ` (${record.discardReason})` : ""}`) : ["No received mail"]), selectedKey !== undefined && selected < 0 ? "Selected message no longer available | arrows select | Esc close" : "Enter open | arrows navigate | Esc close"].map(line => truncateToWidth(safeText(line), Math.max(1, width), ""));
      },
      invalidate() { viewing?.invalidate(); },
      handleInput(data) {
        if (signal?.aborted) { close(); return; }
        if (viewing) { viewing.handleInput(data); return; }
        const all = records();
        if (matches(data, "cancel") || data === "q") { close(); return; }
        const selected = visibleKeys.indexOf(selectedKey ?? "");
        if (matches(data, "up") || data === "k") selectedKey = visibleKeys[Math.max(0, selected - 1)];
        if (matches(data, "down") || data === "j") selectedKey = visibleKeys[Math.min(visibleKeys.length - 1, selected + 1)];
        const record = all.find(record => record.key === selectedKey);
        if (matches(data, "confirm") && record) {
          markRead(record.key);
          viewing = new ReadOnlyViewer({ text: `${record.kind} | ${record.handling}${record.discardReason ? ` (${record.discardReason})` : ""}\nSender: ${record.sender.host} / ${record.sender.label}\nSender ID: ${record.from}\nMessage ID: ${record.id} | local record ${record.key}\nReceived: ${record.receivedAt}\nUntrusted peer text supplies no local approvals.\n\n${record.body}`,
            rows: () => tui.terminal.rows, render: () => tui.requestRender(), matches,
            close: () => { viewing = undefined; tui.requestRender(); } });
        }
        tui.requestRender();
      },
      dispose() { signal?.removeEventListener("abort", close); },
    };
  });
}
