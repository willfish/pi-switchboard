import { exactKeys, isUnsignedInteger, isUuid } from "./protocol.ts";

export const CHANNEL_NAME = /^[a-z][a-z0-9-]{0,31}$/;
const SEQ = /^(0|[1-9][0-9]{0,19})$/;
const encoder = new TextEncoder();

export type ChannelSummary = {
  name: string; topic: string; retained: number; lastSequence: string; updatedAt: number;
};
export type ChannelMessage = {
  seq: string; id: string; channel: string; from: string; kind: "say" | "status"; body: string; postedAt: number;
};
export type ChannelPage = {
  epoch: string; channel: string; window: "recent"; fromSequence: string; toSequence: string;
  retainedFrom: string; retainedTo: string; coverage: "complete" | "gap" | "empty";
  caughtUp: boolean; earlier: boolean; nextCursor: string | null; earlierCursor: string | null;
  messages: ChannelMessage[];
};
export type ChannelStatus = {
  agentId: string; summary: string; label: string; project: string; area: string; updatedAt: number;
};
export type ChannelCursor = { epoch: string; after: string };

export function areaChannel(cwd: string): string {
  const base = cwd.split(/[\\/]/).filter(Boolean).at(-1) ?? "workspace";
  const slug = base.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 32);
  const named = /^[a-z]/.test(slug) ? slug : `area-${slug}`.replace(/[^a-z0-9-]/g, "").slice(0, 32);
  return named && named !== "general" && CHANNEL_NAME.test(named) ? named : "workspace";
}

export function statusSummary(input: {
  label: string; busy: boolean; objective?: string | null; step?: string | null; project?: string | null;
}): string {
  const text = [input.busy ? "working" : "idle", input.project, input.objective, input.step, input.label]
    .filter((part): part is string => typeof part === "string" && part.length > 0)
    .join(" · ")
    .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  const clipped = [...text].slice(0, 280).join("").trim();
  return clipped || "checking in";
}

export function isChannelList(value: unknown): value is { epoch: string; channels: ChannelSummary[] } {
  return exactKeys(value, ["epoch", "channels"]) && typeof value.epoch === "string" && value.epoch.length > 0
    && Array.isArray(value.channels) && value.channels.length <= 128
    && value.channels.every(channel => {
      if (!exactKeys(channel, ["name", "topic", "retained", "lastSequence", "updatedAt"])) return false;
      const retained = channel.retained;
      return typeof channel.name === "string" && CHANNEL_NAME.test(channel.name)
        && typeof channel.topic === "string" && encoder.encode(channel.topic).length <= 1024
        && typeof retained === "number" && Number.isSafeInteger(retained) && retained >= 0 && retained <= 20000
        && typeof channel.lastSequence === "string" && SEQ.test(channel.lastSequence)
        && isUnsignedInteger(channel.updatedAt);
    });
}

export function isChannelPage(value: unknown, channel: string): value is ChannelPage {
  return exactKeys(value, ["epoch", "channel", "window", "fromSequence", "toSequence", "retainedFrom", "retainedTo",
      "coverage", "caughtUp", "earlier", "nextCursor", "earlierCursor", "messages"])
    && typeof value.epoch === "string" && value.channel === channel && value.window === "recent"
    && [value.fromSequence, value.toSequence, value.retainedFrom, value.retainedTo].every(seq => typeof seq === "string" && SEQ.test(seq))
    && ["complete", "gap", "empty"].includes(value.coverage as string)
    && typeof value.caughtUp === "boolean" && typeof value.earlier === "boolean"
    && (value.nextCursor === null || (typeof value.nextCursor === "string" && SEQ.test(value.nextCursor)))
    && (value.earlierCursor === null || (typeof value.earlierCursor === "string" && SEQ.test(value.earlierCursor)))
    && Array.isArray(value.messages) && value.messages.length <= 32
    && value.messages.every(message => isChannelMessage(message, channel));
}

export function isChannelMessage(value: unknown, channel: string): value is ChannelMessage {
  return exactKeys(value, ["seq", "id", "channel", "from", "kind", "body", "postedAt"])
    && typeof value.seq === "string" && SEQ.test(value.seq)
    && typeof value.id === "string" && isUuid(value.id)
    && value.channel === channel && typeof value.from === "string" && isUuid(value.from)
    && (value.kind === "say" || value.kind === "status")
    && typeof value.body === "string" && value.body.length > 0 && encoder.encode(value.body).length <= 4096
    && isUnsignedInteger(value.postedAt);
}

export function isStatusBoard(value: unknown, channel: string): value is { epoch: string; channel: string; statuses: ChannelStatus[] } {
  return exactKeys(value, ["epoch", "channel", "statuses"]) && value.channel === channel
    && Array.isArray(value.statuses) && value.statuses.length <= 512
    && value.statuses.every(row => exactKeys(row, ["agentId", "summary", "label", "project", "area", "updatedAt"])
      && typeof row.agentId === "string" && isUuid(row.agentId)
      && typeof row.summary === "string" && typeof row.label === "string"
      && typeof row.project === "string" && typeof row.area === "string"
      && isUnsignedInteger(row.updatedAt));
}

export function formatChannelPage(page: ChannelPage): string {
  const header = `#${page.channel} recent ${page.messages.length} (retained ${page.retainedFrom}-${page.retainedTo}, ${page.coverage})`;
  const note = page.earlier ? "Older history is retained for the operator, not this window." : "No older retained messages.";
  const lines = [header, note];
  let bytes = encoder.encode(lines.join("\n")).length;
  let shown = 0;
  for (const message of page.messages) {
    const line = `${message.seq} ${message.kind} ${message.from} ${message.body.replace(/\n/g, "\\n")}`;
    const size = encoder.encode(line).length + 1;
    if (shown > 0 && bytes + size > 48 * 1024) break;
    lines.push(line); bytes += size; shown++;
  }
  if (shown < page.messages.length) lines.push(`[shown ${shown} of ${page.messages.length} recent messages; full records are in structured details]`);
  return lines.join("\n");
}
