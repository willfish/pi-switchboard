# Protocol v1

The hub is a volatile relay, not a job queue or remote-execution acknowledgement service. Hub and client releases share this protocol but deploy independently. A deployed strict schema needs an explicit migration before required fields change.

## Trust and identity

All `/v1` routes require `Authorization: Bearer <token>`. `/health` is unauthenticated liveness, not proof that the store can accept work. Restrict network access independently of the token.

Every token holder can inspect presence and impersonate other peers. Presence exposes host, cwd, session name, label, provider/model and activity. This is for trusted peers, not hostile multi-user isolation.

`agentId` identifies one live client runtime. `sessionId` identifies saved Pi session metadata and is not a routing identity. Reload/new/resume/fork create new runtime identities; two processes opening the same saved session remain separate recipients.

Use UTF-8 JSON with exact schemas. Reject duplicate/unknown keys, malformed Unicode and invalid identifiers. IDs are UUID strings. Presence metadata rejects terminal controls; session names, labels and model identifiers are single-line. Host is at most 255 ASCII characters, cwd at most 4096 UTF-8 bytes, session name/label at most 200 code points, model provider at most 200 and model ID at most 512. A model is null or exactly `{provider,id}`. PID is a positive process ID.

## Routes

| Method | Route | Result |
|---|---|---|
| GET | `/health` | `{"ok":true}` |
| PUT | `/v1/agents/:agentId` | Register/update, 204 |
| DELETE | `/v1/agents/:agentId` | Remove, 204 |
| GET | `/v1/agents[?cursor=…]` | One bounded discovery page |
| POST | `/v1/messages` | Acceptance, 202 |
| GET | `/v1/events?agentId=…` | Authenticated SSE |

Registration requires `agentId`, `sessionId`, `host`, `cwd`, `sessionName`, `label`, `model`, `status`, `pid`, `acceptsControl`. Status is `idle` or `busy`. Public records add `updatedAt` and `receiving`; readiness is owned by the hub, not supplied in PUT.

The lease is 15 monotonic seconds. Clients heartbeat every five seconds. `updatedAt` records PUT wall time, but timestamp-only heartbeats do not broadcast presence changes. Expiry, removal and expired re-registration discard the old mailbox/subscription. Listener restart preserves state; store restart loses it and closes streams.

## Discovery

A page has exactly:

```json
{"epoch":"uuid","revision":"123","snapshotId":"uuid","capturedAt":1770000000,"page":0,"total":2,"agents":[],"nextCursor":null}
```

The example omits agent records for readability. Each page holds at most 128 records and 1,048,576 encoded body bytes. Records are ordered by exact agent ID. Empty discovery has one terminal empty page. Epoch identifies the store incarnation; revisions are canonical uint64 decimal strings, not JSON numbers.

Pages share a frozen capture, including timestamps. Continuations require the same live snapshot and current routing-relevant revision. Meaningful changes cause `409 discovery_reset`; quiet heartbeats do not. Snapshots expire after 30 monotonic seconds. Cursors are bounded opaque continuations, not credentials; malformed cursors fail with 400.

Clients stage the entire traversal before publication or target resolution. Limits are 5,000 records, 256 MiB encoded staging, 30 seconds overall and five seconds per request. Failure discards staging: no partial results, cached fallback or automatic traversal restart. Changes after successful resolution remain a normal race; POST checks the pinned runtime ID and never retargets.

## Mail

POST requires exactly `id`, `from`, `to`, `kind`, `body`. Kind is `notice`, `prompt` or `steer`; self-send is rejected. Body is nonempty UTF-8 text up to 16 KiB. Complete request and stamped public envelope are limited to 32 KiB.

Acceptance contains exactly `id`, `to`, `state: "accepted"`, `expiresAt`, `receiving`. It means queued in hub memory, never delivered, read, executed or answered.

Each recipient has a 32-message FIFO. Pending mail expires 60 monotonic seconds after acceptance. The global accepted-mail budget charges encoded public JSON, up to 5,000,000,000 bytes. Previously accepted mail is not evicted to admit new mail. Pop immediately before one write attempt; an interrupted write may lose that item.

After authentication/schema validation, deduplication precedes current liveness, permission and capacity checks. `(from,id)` is retained for 120 seconds, up to 4,096 entries. Identical repeats return the original acceptance without re-enqueueing; changed payload returns 409. Store restart loses this protection. Clients make one POST attempt, with no offline spool or automatic replay.

Public SSE mail adds frozen `sender: {host,label}`, `acceptedAt` and `expiresAt`. These are wall timestamps; pending expiry is monotonic. Received client history does not acquire a second wall-clock expiry timer.

## SSE

The stream emits `message`, `presence_snapshot`, `presence_delta` and `presence_reset`. Comment keepalives arrive every ten seconds. No `Last-Event-ID` replay contract exists.

```text
event: presence_snapshot
data: {"epoch":"uuid","revision":"123","snapshotId":"uuid","capturedAt":1770000000,"chunk":0,"total":2,"agents":[],"final":true}

event: presence_delta
data: {"epoch":"uuid","fromRevision":"123","toRevision":"125","caughtUp":true,"changes":[{"op":"remove","agentId":"uuid"}]}

event: presence_reset
data: {"epoch":"uuid","reason":"history_lost"}

```

Upserts use `{"op":"upsert","agent":{...}}`. Snapshot records and delta changes are additionally byte-packed, with at most 128 records/changes per frame. Every actual raw frame, including framing/comments/ignored fields, is capped at 1 MiB.

One shared SSE baseline is independent of the HTTP snapshot. Each shared snapshot is bounded to 5,000 records, 256 MiB encoded retention and 30 seconds. A shared journal retains at most 8,192 changes, 64 MiB encoded changes and 30 seconds. Deltas cover contiguous revision prefixes and coalesce repeated IDs to their last historical operation. Subscribers retain scalar progress, not private snapshots or dirty maps.

Clients stage snapshot chunks and commit atomically. The first catch-up delta is sent even when empty. `fromRevision` must match committed state; `caughtUp` describes the store serialization point. Missing history or expired/replaced unfinished snapshots produce reset, then a fresh snapshot on the same stream. Reset discards staging and marks cached state stale. Invalid sequencing closes the stream; lifecycle owns sequencing and publication.

The parser enforces actual raw bytes. The reducer's separate 256 MiB staging charge uses canonical encoded framing; it is not an estimate of actual network traffic or total heap use. Normal CR terminators complete immediately when optional LF fits; an exact-limit final CR waits for another byte or EOF to distinguish valid CR from oversized CRLF. Chunk boundaries have no semantic significance.

## Failures and limits

Errors are `{"error":{"code":"…","message":"…"}}`; clients display local allowlisted explanations, not arbitrary remote diagnostics. Typical statuses are 400 invalid schema/cursor/self-send, 401 unauthorized, 403 control disabled, 404 unknown runtime, 409 conflict/discovery reset, 413 oversized payload, 429 recipient mailbox full, and 503 capacity/dedup exhaustion/unavailability.

A known rejection remains rejected. A lost or invalid POST response after dispatch is `outcome_unknown`: check the peer before resending. A 401 stops automatic client background work; it does not establish the outcome of another concurrent POST.

Short requests and individual writes have five-second absolute deadlines. Healthy SSE lifetime is exempt; client inactivity is 30 seconds, refreshed by valid complete comments/frames, not drip bytes. Each server frame uses its own actual-send barrier, not merely Cowboy acknowledgement.

The store's sampled 4,096-operation ingress guard and Ranch limits can overshoot through concurrency/internal cleanup. Ranch's limit is per connection supervisor. A 5,000-registration fixture is not a 5,000-connection benchmark. Mail, snapshot and journal byte budgets are not total RAM limits.
