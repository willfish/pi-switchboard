import { createHash } from "node:crypto";
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
/** RFC 4122 namespace for mapping non-UUID work ids onto version-5 UUIDs. */
export const WORK_ID_NAMESPACE = "9c4e2d8a-7b31-4f56-a1c0-8e5d6b9f2a14";

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

export function stableWorkUuid(name: string): string {
  const ns = Buffer.from(WORK_ID_NAMESPACE.replaceAll("-", ""), "hex");
  const digest = createHash("sha1").update(ns).update(name).digest().subarray(0, 16);
  digest[6] = (digest[6] & 0x0f) | 0x50;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  const hex = Buffer.from(digest).toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

function blankToNull(value: unknown): unknown {
  if (value === undefined) return null;
  if (typeof value === "string" && value.trim() === "") return null;
  return value;
}

function clampText(value: string, maxBytes: number): string | null {
  if (!value || !isUnicode(value)) return null;
  if (utf8Bytes(value) <= maxBytes) return value;
  const chars = Array.from(value);
  while (chars.length > 0 && utf8Bytes(chars.join("")) > maxBytes) chars.pop();
  return chars.length > 0 ? chars.join("") : null;
}

function textField(value: unknown, maxBytes: number): string | null {
  const raw = blankToNull(value);
  if (raw === null || typeof raw !== "string") return null;
  return clampText(raw.trim(), maxBytes);
}

function uuidField(value: unknown): string | null {
  const raw = blankToNull(value);
  if (raw === null || typeof raw !== "string" || !isUnicode(raw)) return null;
  const trimmed = raw.trim();
  return isUuid(trimmed) ? trimmed : stableWorkUuid(trimmed);
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

export function normalizeWorkReport(value: unknown): WorkSnapshot | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return;
  const src = value as Record<string, unknown>;
  const phaseRaw = blankToNull(src.phase);
  const phase = typeof phaseRaw === "string" && (WORK_PHASES as readonly string[]).includes(phaseRaw)
    ? phaseRaw as WorkPhase : null;
  const evidence: WorkEvidence[] = [];
  if (Array.isArray(src.evidence)) {
    for (const item of src.evidence) {
      if (evidence.length >= MAX_WORK_EVIDENCE) break;
      if (!item || typeof item !== "object" || Array.isArray(item)) continue;
      const rec = item as Record<string, unknown>;
      const ref = textField(rec.ref, MAX_WORK_REF_BYTES);
      if (typeof rec.kind === "string" && (EVIDENCE_KINDS as readonly string[]).includes(rec.kind) && ref) {
        evidence.push({ kind: rec.kind as EvidenceKind, ref });
      }
    }
  }
  let blocker: WorkBlocker | null = null;
  if (src.blocker && typeof src.blocker === "object" && !Array.isArray(src.blocker)) {
    const rec = src.blocker as Record<string, unknown>;
    const reason = textField(rec.reason, MAX_WORK_TEXT_BYTES);
    if ((rec.kind === "blocked" || rec.kind === "decision") && reason) {
      blocker = { kind: rec.kind, reason };
    }
  }
  const snap: WorkSnapshot = {
    workId: uuidField(src.workId),
    objective: textField(src.objective, MAX_WORK_TEXT_BYTES),
    phase,
    currentStep: textField(src.currentStep, MAX_WORK_TEXT_BYTES),
    nextStep: textField(src.nextStep, MAX_WORK_TEXT_BYTES),
    owner: textField(src.owner, MAX_WORK_OWNER_BYTES),
    blocker,
    project: textField(src.project, MAX_WORK_TEXT_BYTES),
    repository: textField(src.repository, MAX_WORK_TEXT_BYTES),
    branch: textField(src.branch, MAX_WORK_TEXT_BYTES),
    worktree: textField(src.worktree, MAX_WORK_TEXT_BYTES),
    parentWorkId: uuidField(src.parentWorkId),
    delegatedWorkId: uuidField(src.delegatedWorkId),
    evidence,
  };
  return isWorkSnapshot(snap) ? snap : undefined;
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
