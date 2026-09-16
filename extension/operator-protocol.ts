import { decodeWireJson, exactKeys, isUnicode, isUuid, MAX_ENVELOPE_BYTES } from "./protocol.ts";

/** Later transport, not this codec:
 *  bindingId is stable across identical heartbeats; rotate only on
 *  registration, runtimeGeneration, sessionId, sessionGeneration, branchId,
 *  capability, or permission change.
 *  Reject same-runtime older sessionGeneration; sessionId must match the
 *  live registration.
 *  Digest-skip of identical work must not suppress a bounded heartbeat
 *  announce probe after storeEpoch loss (hub restart).
 */

export const WORK_KEYS = [
  "workId", "objective", "phase", "currentStep", "nextStep", "owner", "blocker",
  "project", "repository", "branch", "worktree", "parentWorkId", "delegatedWorkId",
  "evidence",
] as const;

export const MAX_WORK_TEXT_BYTES = 2048;
export const MAX_WORK_OWNER_BYTES = 200;
export const MAX_WORK_REF_BYTES = 512;
export const MAX_WORK_EVIDENCE = 8;
export const WORK_PHASES = [
  "planning", "implementing", "verifying", "waiting", "completed", "failed",
] as const;
export const EVIDENCE_KINDS = ["file", "test", "commit", "artifact"] as const;

export type WorkPhase = (typeof WORK_PHASES)[number];
export type EvidenceKind = (typeof EVIDENCE_KINDS)[number];

export type WorkBlocker = { kind: "blocked" | "decision"; reason: string };
export type WorkEvidence = { kind: EvidenceKind; ref: string };

export type WorkSnapshot = {
  workId: string | null;
  objective: string | null;
  phase: WorkPhase | null;
  currentStep: string | null;
  nextStep: string | null;
  owner: string | null;
  blocker: WorkBlocker | null;
  project: string | null;
  repository: string | null;
  branch: string | null;
  worktree: string | null;
  parentWorkId: string | null;
  delegatedWorkId: string | null;
  evidence: WorkEvidence[];
};

const encoder = new TextEncoder();

function utf8Bytes(value: string): number {
  return encoder.encode(value).length;
}

function optionalUuid(value: unknown): value is string | null {
  return value === null || (typeof value === "string" && isUuid(value));
}

function optionalText(value: unknown, maxBytes: number): value is string | null {
  if (value === null) return true;
  return typeof value === "string" && value.length > 0 && isUnicode(value)
    && utf8Bytes(value) <= maxBytes;
}

function isBlocker(value: unknown): value is WorkBlocker {
  return exactKeys(value, ["kind", "reason"])
    && (value.kind === "blocked" || value.kind === "decision")
    && typeof value.reason === "string" && value.reason.length > 0
    && isUnicode(value.reason) && utf8Bytes(value.reason) <= MAX_WORK_TEXT_BYTES;
}

function isEvidence(value: unknown): value is WorkEvidence {
  return exactKeys(value, ["kind", "ref"])
    && typeof value.kind === "string" && (EVIDENCE_KINDS as readonly string[]).includes(value.kind)
    && typeof value.ref === "string" && value.ref.length > 0 && isUnicode(value.ref)
    && utf8Bytes(value.ref) <= MAX_WORK_REF_BYTES;
}

export function isWorkSnapshot(value: unknown): value is WorkSnapshot {
  if (!exactKeys(value, [...WORK_KEYS])) return false;
  if ("body" in value) return false;
  return optionalUuid(value.workId)
    && optionalText(value.objective, MAX_WORK_TEXT_BYTES)
    && (value.phase === null || (typeof value.phase === "string"
      && (WORK_PHASES as readonly string[]).includes(value.phase)))
    && optionalText(value.currentStep, MAX_WORK_TEXT_BYTES)
    && optionalText(value.nextStep, MAX_WORK_TEXT_BYTES)
    && optionalText(value.owner, MAX_WORK_OWNER_BYTES)
    && (value.blocker === null || isBlocker(value.blocker))
    && optionalText(value.project, MAX_WORK_TEXT_BYTES)
    && optionalText(value.repository, MAX_WORK_TEXT_BYTES)
    && optionalText(value.branch, MAX_WORK_TEXT_BYTES)
    && optionalText(value.worktree, MAX_WORK_TEXT_BYTES)
    && optionalUuid(value.parentWorkId)
    && optionalUuid(value.delegatedWorkId)
    && Array.isArray(value.evidence)
    && value.evidence.length <= MAX_WORK_EVIDENCE
    && value.evidence.every(isEvidence)
    && encoder.encode(JSON.stringify(value)).length <= MAX_ENVELOPE_BYTES;
}

export function encodeWorkSnapshot(value: WorkSnapshot): Uint8Array {
  if (!isWorkSnapshot(value)) throw new Error("invalid work snapshot");
  return encoder.encode(JSON.stringify(value));
}

export function decodeWorkSnapshot(bytes: Uint8Array): WorkSnapshot {
  if (bytes.byteLength > MAX_ENVELOPE_BYTES) throw new Error("protocol");
  const value = decodeWireJson(bytes);
  if (!isWorkSnapshot(value)) throw new Error("protocol");
  return value;
}
