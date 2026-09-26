# Operator protocol

Operator routes are separate from the strict legacy presence/mail schemas. Browser routes use an automatically issued `X-Switchboard-Session` nonce plus the configured network/origin boundary. Native routes use the relay bearer. Neither credential substitutes for the other.

## Identities and negotiation

`POST /v1/operator/announce` binds a live agent to the authoritative store epoch and per-registration generation, its runtime/session generations, branch anchor, reported active run, permissions, implementation capabilities and complete work snapshot. It returns a binding receipt. Canonical uint64 values are decimal strings, not lossy JSON numbers.

A live heartbeat preserves registration identity. Deletion/expiry and re-registration allocate a new generation. Identical reports preserve binding ID; context, capability or permission changes invalidate the old binding. Work-only updates and run-state changes have separate revisions and do not rotate unrelated session bindings. Older reports are rejected rather than replacing current data.

Capabilities are versioned and negotiated against actual hub implementation. Receiver permissions are distinct: notices, work/guidance, session reading, management/work assignment and history enrollment are not implied by network access. Unknown work fields remain null.

The native client re-probes unchanged metadata on its existing heartbeat. Clients may send `X-Switchboard-Updates: 1` when opening `/v1/events`. An enabled operator subtree then emits `operator_update` frames with exactly `{"schemaVersion":1}`, initially and when an operator request is created for that agent. These are invalidations, not mail or permission grants. The client fetches pending typed requests immediately, coalescing wakes during an active read. Heartbeats still renew liveness and flush activity; request polling falls back to every15 seconds after push support is observed, or every heartbeat with older/disabled servers. No second connection is opened. Clients without the header receive only the legacy SSE vocabulary.

## Observation

| Browser GET | Result |
|---|---|
| `/dashboard/api/v1/work` | Frozen paged work view |
| `/dashboard/api/v1/work/:agentId` | One revalidated work/capability view |
| `/dashboard/api/v1/events` | Retained journal page |
| `/dashboard/api/v1/search` | Filtered retained-history scan with a fixed high-water mark |
| `/dashboard/api/v1/stream` | Independent observation SSE, not consuming agent mail |

Work pages contain `epoch`, `snapshotId`, `revision`, `capturedAt`, `page`, `total`, `snapshots` and `nextCursor`. Each view contains a binding, complete work snapshot and receiver permissions. Pages are limited to128 views/1MiB; the fleet to5000 views; shared frozen snapshots to8/64MiB and30 seconds.

Journal pages contain `epoch`, `fromSequence`, `toSequence`, `retainedFrom`, `coverage`, `caughtUp`, `nextCursor` and `events`. Sequence is canonical uint64 text. The journal is bounded by100000 events,128MiB encoded data and24 hours, whichever is reached first. An expired position is a gap, not empty history.

Every event declares its source. Work/run/tool state is client-reported. Operator intent is network-authorized, not attributed to a verified human. A client result is not independent proof of execution. Journal timestamps are UNIX seconds; operation deadlines and native activity input timestamps are UNIX milliseconds.

Search supports literal text, runtime participant, work/thread, outcome, source/category and time bounds. Continuations bind filters, epoch and frozen high-water. Each read scans at most2048 positions and returns at most128 hits/1MiB. A filter change or lost history invalidates the continuation.

The stream sends `observation` events containing complete journal pages, including an initial empty baseline. `reset` indicates epoch/history/capacity loss and closes the stream. Comments are keepalives, not data or replay IDs. There is no `Last-Event-ID` resume. Bounds cover32 observers, one per session,512KiB complete framed data and16MiB aggregate in-flight data. Session and network admission are periodically revalidated. Actual transport-send completion governs frame release/rearm.

### Live invalidation

With `X-Switchboard-Updates: 1`, the browser observation stream also emits `update` frames with exactly `{"schemaVersion":1}`. Presence, work and operation changes invalidate the browser's views without adding synthetic journal events. The browser coalesces snapshot refreshes over250ms, keeps a60-second reconciliation fallback while push is available, and returns to ordinary retry polling when the stream is lost. Pending action results use pushed invalidations with a5-second fallback. Pausing the message view still preserves its reading position.

The invalidation owner admits at most32 browser watches and5000 native watches, with one native watch per agent. Each watch retains one dirty bit and at most one queued wake, plus a bounded in-flight frame. Producers perform indexed ETS lookups, never synchronous owner calls. Watches monitor their streams and streams monitor the owner; owner loss closes the stream for resynchronization. Invalidation frames contain no message text, credentials or state snapshots. They never authorize automatic mutation replay.

## Channels

Operator channel reads use the session nonce, not the relay bearer. They page the same shared journal the agents write. They do not consume agent mail or register an observer.

| Browser GET | Result |
|---|---|
| `/dashboard/api/v1/channels` | Directory |
| `/dashboard/api/v1/channels/:name/messages` | One history page |
| `/dashboard/api/v1/channels/:name/status` | Current check-ins |

Omit the query to open the newest page. `after` walks forward and `before` walks backward, up to 64 messages and 1 MiB of message bytes. Continue until `caughtUp` and `earlier` are both false to see every retained message. A gap means older packets expired; the page restarts at `retainedFrom`. This is all retained history, not an infinite archive. The same 24-hour, 20,000-message, or 32 MiB bound applies, and a hub restart clears it.

Invalidation frames still carry no message text. The console refetches the open channel after an update.

## Typed operations

Browser routes:

- `POST /dashboard/api/v1/operations`: submit one exact, idempotent intent.
- `GET /dashboard/api/v1/operations/:operationId`: reconcile its state without repeating it.
- `GET /dashboard/api/v1/operations?agentId=…`: bounded metadata-only summaries.
- `POST /dashboard/api/v1/operations/:operationId/cancel`: request cancellation with an empty JSON object. Cancellation ownership remains tied to the creating browser session.

Kinds are `notice`, `work`, `guidance`, `label`, `interrupt`, `sessionRead` and `workAssign`. Each create document pins agent, binding, runtime/session generations, branch, work ID and an exact run ID for interruption. It includes a unique operation ID, bounded deadline and kind-specific payload. No label/cwd routing or automatic retargeting is permitted.

Identical IDs/documents reconcile to the same operation while retained. Conflicting reuse is rejected. Deadlines and retained tombstones prevent replay after expiry; live deduplication state is not evicted to admit another effect. Capacity bounds include retained metadata, not only active payloads.

Native routes:

- `GET /v1/operator/requests?agentId=…`: at most8 descriptors,2KiB each and16KiB total. Content is referenced by a bound handle.
- `GET /v1/operator/content?operationId=…&contentId=…`: bounded content for that operation.
- `POST /v1/operator/results`: receipt, action-specific result or fragment. The response is a small `{schemaVersion,operationId,state}` acknowledgement, never the assembled session page.
- `POST /v1/operator/activity`: bounded tool metadata batches and explicit coverage-loss information. No arguments or raw results.

Native POST documents remain32768 bytes. Browser operation creation has the same cap. Limits on individual fields do not imply every maximum-sized combination fits.

## Outcomes and session pages

Hub queueing, client receipt, SDK attempt, matching observation, label application, abort request and matching settlement are different facts. Notice receipt is not context reservation, and neither is a human read receipt. Guidance cannot guarantee selected-run consumption or withdrawal of one queued message. Interruption is neither process kill nor rollback.

Session reading requires both read permission and explicit content enrollment. A projection is at most64 records/512KiB, with16KiB text previews, and uses issued client continuation handles within a30-second traversal. A page contains session/leaf context, records, omission count and truncation flag. Records expose only entry ID, approved role and text. Hidden reasoning, raw tool payloads, arbitrary paths and unrecognized/custom-hidden content are excluded.

Pages arrive as at most32 sequential fragments of16384 raw bytes. Canonical base64 and the small envelope must fit the native POST cap. The hub validates binding, order, size, digest and exact projection schema before publication. Partial assembly is never returned to the browser. Cancelling inspection discards collection/publication, not unrelated agent work.

Operations allow at most four outstanding intents per browser, one execution-mutating request and one session traversal per runtime, with separately bounded passive notices. Total retained operations/tombstones and64MiB staged/encoded state are capped. History and operation state remain volatile across owner/hub restart.

See the [console guide](operator-console.md) for local permission commands and the [legacy protocol](protocol.md) for mail/discovery contracts.
