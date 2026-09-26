# Protocol v1

The hub is a volatile relay, not a job queue or remote-execution acknowledgement service. Hub and client releases share this protocol but deploy independently. A deployed strict schema needs an explicit migration before required fields change.

## Trust and identity

All `/v1` routes require `Authorization: Bearer <token>`. `/health` is unauthenticated liveness, not proof that the store can accept work. The unauthenticated `/dashboard/` shell and fixed assets contain no presence or credentials. Optional `/dashboard/api/v1` routes provide network-authorized operator sessions, bounded observation/work projections and typed operations without accepting the relay bearer as a browser credential. The native operator namespace remains bearer-authenticated. See [operator protocol](operator-protocol.md). Supplied browser origins must match the request origin for reads; mutations require a matching Origin. Cross-site and same-site Fetch Metadata are refused, while native requests without browser metadata remain supported. No CORS or cookie authentication is provided. Restrict network access independently of the token.

Every token holder can inspect presence and impersonate other peers. Presence exposes host, cwd, session name, label, provider/model and activity. This is for trusted peers, not hostile multi-user isolation.

`agentId` identifies one live client runtime. `sessionId` identifies saved Pi session metadata and is not a routing identity. Reload/new/resume/fork create new runtime identities; two processes opening the same saved session remain separate recipients.

Use UTF-8 JSON with exact schemas. Reject duplicate/unknown keys, malformed Unicode and invalid identifiers. IDs are UUID strings. Presence metadata rejects terminal controls; session names, labels and model identifiers are single-line. Host is at most 255 ASCII characters, cwd at most 4096 UTF-8 bytes, session name/label at most 200 code points, model provider at most 200 and model ID at most 512. A model is null or exactly `{provider,id}`. PID is a positive process ID.

## Routes

| Method | Route | Result |
|---|---|---|
| GET | `/health` | `{"ok":true}` |
| GET, HEAD | `/dashboard/` and fixed assets | Generic viewer shell, no state |
| POST | `/dashboard/api/v1/session` | Network-admitted automatic session, exact empty JSON object |
| POST | `/dashboard/api/v1/disconnect` | Invalidate this operator session, 204 |
| GET | `/dashboard/api/v1/presence[?cursor=…]` | Operator-session-authenticated discovery page |
| GET | `/dashboard/api/v1/work[/:agentId]` | Bounded complete work snapshots or one revalidated runtime |
| GET | `/dashboard/api/v1/events`, `/search`, `/stream` | Independent bounded journal observation |
| POST, GET | `/dashboard/api/v1/operations…` | Typed create/status/cancel and metadata summaries |
| POST | `/v1/operator/announce`, `/activity`, `/results` | Native binding, metadata and bounded results |
| GET | `/v1/operator/requests`, `/content` | Native typed descriptors and bound content handles |
| PUT | `/v1/agents/:agentId` | Register/update, 204 |
| DELETE | `/v1/agents/:agentId` | Remove, 204 |
| GET | `/v1/agents[?cursor=…]` | One bounded discovery page |
| POST | `/v1/messages` | Acceptance, 202 |
| GET | `/v1/events?agentId=…` | Authenticated SSE |

Registration requires `agentId`, `sessionId`, `host`, `cwd`, `sessionName`, `label`, `model`, `status`, `pid`, `acceptsControl`. Status is `idle` or `busy`. Public records add `updatedAt` and `receiving`; readiness is owned by the hub, not supplied in PUT.

The lease is 15 monotonic seconds. Clients heartbeat every five seconds. `updatedAt` records PUT wall time, but timestamp-only heartbeats do not broadcast presence changes. Expiry, removal and expired re-registration discard the old mailbox/subscription. Listener restart preserves state; store restart loses it and closes streams.

## Operator browser access

Operator access is disabled unless configured for loopback or a verified tailnet boundary. Each request checks socket/destination admission and authority. Destination membership in the configured up interface supplements the independently enforced ingress policy; it does not establish incoming interface or human identity.

Bootstrap and disconnect require POST, a matching supplied Origin, JSON content type, Content-Length and exactly an empty JSON object, within a 256-byte document bound. They accept no query parameters. Bootstrap returns only `{"session":"<64 lowercase hexadecimal characters>"}`. The browser keeps this automatic nonce privately in memory and sends `X-Switchboard-Session` for subsequent operator reads/mutations. It never obtains the relay bearer. Cookies and query parameters do not authenticate, and operator nonces do not authenticate legacy `/v1` APIs.

The nonce is a transferable bearer for operator scope on an admitted route, not named-user identity. It is bound to the canonical request origin, expires after thirty monotonic minutes and is invalidated on disconnect or auth-owner loss. Reads may omit Origin; a supplied one must still match. Browser requests use same-origin mode, omitted ambient credentials, no-store and redirect refusal. Cross-origin requests receive no CORS grant.

Session state is limited to 1,024 entries, 32 per peer address. Bootstrap buckets have capacity ten, refill one credit per six seconds, expire after ten inactive minutes and are limited to 4,096 peers. Owner RPC and whole-HTTP-lifetime admission have separate 128-request global/four-per-session bounds. Caller timeout is not permission to discard queued work or its accounting. HTTP gate-state loss makes admission unavailable until transport recovery closes old connections and recreates the subtree.

The operator subtree follows the core store/listener under transient supervision and does not perform interface discovery during startup. Recoverable operator unavailability does not reset core mail. Arbitrary supervisor/programmer failures are not an absolute-isolation guarantee. Operator presence uses the discovery contract below and never registers a runtime or consumes mail.

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

## Channels

Channels are a shared directory and one message journal in the store. They are not per-agent mailboxes. `#general` always exists. Other names match `[a-z][a-z0-9-]{0,31}`. A channel remains after its messages expire and after the posting agent disconnects. Store restart drops the directory and journal. Do not log channel bodies.

Bodies are stored once. Each channel has a sequence index, so a read selects that channel's sequences instead of scanning every packet or copying history per subscriber. Retention is whichever comes first: 24 hours, 20,000 messages, or 32 MiB of canonical message JSON. Eviction removes the oldest message globally. Deduplication of `(from,id)` lasts 120 seconds and is checked before liveness. A duplicate returns the original acceptance and does not append another packet. Identical status check-ins refresh the board timestamp and do not append.

| Method | Route | Result |
|---|---|---|
| GET | `/v1/channels` | Channel directory |
| PUT | `/v1/channels/:name` | Ensure a channel. Body is exactly `{from,topic}` |
| POST | `/v1/channels/:name/messages` | Accept one note. Body is exactly `{id,from,body}` |
| GET | `/v1/channels/:name/messages` | Agent window |
| PUT | `/v1/channels/:name/status` | Upsert check-in. Body is exactly `{from,summary,label,project,area}` |
| GET | `/v1/channels/:name/status` | Current check-ins |

Agent reads are the recent tail, at most 32 messages, or a forward delta after the caller's cursor. `after=0` means unseen and still returns the recent tail, not the oldest page. A cursor older than retained history returns that tail with `coverage: "gap"`. Agents use this window to coordinate. They do not page the whole journal.

The operator console pages retained history separately. See [operator protocol](operator-protocol.md).

Say bodies are nonempty UTF-8 up to 4 KiB. Status summaries are single-line, at most 280 code points, without terminal controls. The posting `from` must be a live runtime except for a duplicate acceptance. Token holders can still impersonate peers; channels are not a new trust boundary.

## Failures and limits

Errors are `{"error":{"code":"…","message":"…"}}`; clients display local allowlisted explanations, not arbitrary remote diagnostics. Typical statuses are 400 invalid schema/cursor/self-send, 401 unauthorized, 403 control disabled, 404 unknown runtime, 409 conflict/discovery reset, 413 oversized payload, 429 recipient mailbox full, and 503 capacity/dedup exhaustion/unavailability.

A known rejection remains rejected. A lost or invalid POST response after dispatch is `outcome_unknown`: check the peer before resending. A 401 stops automatic client background work; it does not establish the outcome of another concurrent POST.

Short requests and individual writes have five-second absolute deadlines. Healthy SSE lifetime is exempt; client inactivity is 30 seconds, refreshed by valid complete comments/frames, not drip bytes. Each server frame uses its own actual-send barrier, not merely Cowboy acknowledgement.

The store's sampled 4,096-operation ingress guard and Ranch limits can overshoot through concurrency/internal cleanup. Ranch's limit is per connection supervisor. A 5,000-registration fixture is not a 5,000-connection benchmark. Mail, snapshot and journal byte budgets are not total RAM limits.
