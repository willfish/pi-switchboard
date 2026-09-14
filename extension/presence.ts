import {
  decodeWireJson, exactKeys, isSnapshotPart, sameSnapshot, isUnsignedInteger,
  isPublicAgent, isRevision, isUuid, MAX_AGENTS, MAX_DISCOVERY_BYTES,
  MAX_PAGE_RECORDS, MAX_STAGE_BYTES, DISCOVERY_LIFETIME_MS,
  type PublicAgent, type SnapshotPart,
} from "./protocol.ts";

export function isPresenceData(event: string, value: unknown): boolean {
  if (event === "presence_snapshot") return exactKeys(value, ["epoch", "revision", "snapshotId", "capturedAt", "chunk", "total", "agents", "final"])
    && isSnapshotPart(value) && isUnsignedInteger(value.chunk) && typeof value.final === "boolean";
  if (event === "presence_reset") return exactKeys(value, ["epoch", "reason"])
    && typeof value.epoch === "string" && isUuid(value.epoch)
    && (value.reason === "history_lost" || value.reason === "snapshot_expired");
  if (event !== "presence_delta" || !exactKeys(value, ["epoch", "fromRevision", "toRevision", "caughtUp", "changes"])
    || typeof value.epoch !== "string" || !isUuid(value.epoch) || !isRevision(value.fromRevision)
    || !isRevision(value.toRevision) || typeof value.caughtUp !== "boolean"
    || !Array.isArray(value.changes) || value.changes.length > MAX_PAGE_RECORDS) return false;
  const span = BigInt(value.toRevision) - BigInt(value.fromRevision);
  const seen = new Set<string>();
  return span >= 0n && span <= BigInt(MAX_PAGE_RECORDS) && BigInt(value.changes.length) <= span
    && (span === 0n ? value.caughtUp : value.changes.length > 0)
    && value.changes.every((change) => {
      let id: string;
      if (exactKeys(change, ["op", "agent"]) && change.op === "upsert" && isPublicAgent(change.agent)) id = change.agent.agentId;
      else if (exactKeys(change, ["op", "agentId"]) && change.op === "remove" && typeof change.agentId === "string" && isUuid(change.agentId)) id = change.agentId;
      else return false;
      if (seen.has(id)) return false;
      seen.add(id); return true;
    });
}

type SnapshotChunk = SnapshotPart & { chunk: number; final: boolean };
type Staging = {
  snapshot: SnapshotChunk; agents: readonly PublicAgent[]; nextChunk: number;
  bytes: number; startedAt: number;
};
export type PresenceState = {
  readonly status: "stale" | "synchronizing" | "current";
  readonly reconnect: boolean;
  readonly epoch: string | null;
  readonly revision: string | null;
  readonly agents: readonly PublicAgent[];
  readonly staging: Staging | null;
  readonly awaitingSnapshot: boolean;
};

// A new transport incarnation starts with a new state. No timers or I/O live here.
export function createPresenceState(): PresenceState {
  return { status: "stale", reconnect: false, epoch: null, revision: null,
    agents: [], staging: null, awaitingSnapshot: true };
}

function invalid(state: PresenceState): PresenceState {
  return { ...state, staging: null, status: "stale", reconnect: true };
}

/** Reduce one complete event's UTF-8 data, not an HTTP chunk. The framing layer
 * must bound the whole SSE frame before assembling data. now is monotonic ms. */
export function reducePresence(state: PresenceState, event: string, data: Uint8Array, now: number): PresenceState {
  if (state.reconnect) return state;
  try {
    if (!Number.isFinite(now) || data.byteLength > MAX_DISCOVERY_BYTES) return invalid(state);
    // Canonical staging charge, not the incoming frame size or total heap use.
    const canonicalEncodedBytes = new TextEncoder().encode(`event: ${event}\ndata: \n\n`).length + data.byteLength;
    const value = decodeWireJson(data);
    if (event === "presence_reset") {
      if (!exactKeys(value, ["epoch", "reason"]) || typeof value.epoch !== "string" || !isUuid(value.epoch)
        || (state.epoch !== null && value.epoch !== state.epoch)
        || (value.reason !== "history_lost" && value.reason !== "snapshot_expired")) return invalid(state);
      return { ...state, epoch: value.epoch, staging: null, status: "stale", awaitingSnapshot: true };
    }
    if (event === "presence_snapshot") {
      if (!exactKeys(value, ["epoch", "revision", "snapshotId", "capturedAt", "chunk", "total", "agents", "final"])
        || !isSnapshotPart(value) || !isUnsignedInteger(value.chunk) || typeof value.final !== "boolean") return invalid(state);
      const chunk = value as unknown as SnapshotChunk;
      const stage = state.staging;
      if (!state.awaitingSnapshot || (state.epoch !== null && state.epoch !== chunk.epoch)
        || (state.revision !== null && BigInt(chunk.revision) < BigInt(state.revision))
        || chunk.chunk !== (stage?.nextChunk ?? 0)
        || (stage && (!sameSnapshot(stage.snapshot, chunk) || now < stage.startedAt || now - stage.startedAt >= DISCOVERY_LIFETIME_MS))) return invalid(state);
      const previous = stage?.agents ?? [];
      const bytes = (stage?.bytes ?? 0) + canonicalEncodedBytes;
      if (bytes > MAX_STAGE_BYTES || previous.length + chunk.agents.length > chunk.total
        || (previous.length && chunk.agents.length && previous.at(-1)!.agentId >= chunk.agents[0].agentId)) return invalid(state);
      const agents = [...previous, ...chunk.agents];
      if (chunk.final) {
        if (agents.length !== chunk.total || (chunk.chunk > 0 && !chunk.agents.length)) return invalid(state);
        return { ...state, epoch: chunk.epoch, revision: chunk.revision, agents,
          staging: null, status: "synchronizing", awaitingSnapshot: false };
      }
      if (!chunk.agents.length || agents.length >= chunk.total) return invalid(state);
      return { ...state, epoch: chunk.epoch, status: "synchronizing",
        staging: { snapshot: chunk, agents, nextChunk: chunk.chunk + 1, bytes, startedAt: stage?.startedAt ?? now } };
    }
    if (event === "presence_delta") {
      if (state.awaitingSnapshot || state.staging || state.revision === null
        || !exactKeys(value, ["epoch", "fromRevision", "toRevision", "caughtUp", "changes"])
        || value.epoch !== state.epoch || !isRevision(value.fromRevision) || !isRevision(value.toRevision)
        || value.fromRevision !== state.revision || typeof value.caughtUp !== "boolean"
        || !Array.isArray(value.changes) || value.changes.length > MAX_PAGE_RECORDS) return invalid(state);
      const span = BigInt(value.toRevision) - BigInt(value.fromRevision);
      if (span < 0n || span > BigInt(MAX_PAGE_RECORDS) || BigInt(value.changes.length) > span
        || (span === 0n ? !value.caughtUp : value.changes.length === 0)) return invalid(state);
      const agents = new Map(state.agents.map((agent) => [agent.agentId, agent]));
      const seen = new Set<string>();
      for (const change of value.changes) {
        let id: string;
        if (exactKeys(change, ["op", "agent"]) && change.op === "upsert" && isPublicAgent(change.agent)) {
          id = change.agent.agentId;
          agents.set(id, change.agent);
        } else if (exactKeys(change, ["op", "agentId"]) && change.op === "remove"
          && typeof change.agentId === "string" && isUuid(change.agentId)) {
          id = change.agentId;
          agents.delete(id);
        } else return invalid(state);
        if (seen.has(id)) return invalid(state);
        seen.add(id);
      }
      if (agents.size > MAX_AGENTS) return invalid(state);
      return { ...state, revision: value.toRevision, agents: [...agents.values()].sort((a, b) => a.agentId < b.agentId ? -1 : a.agentId > b.agentId ? 1 : 0),
        status: value.caughtUp ? "current" : "synchronizing" };
    }
    return invalid(state);
  } catch {
    return invalid(state);
  }
}
