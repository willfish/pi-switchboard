# Fleet operator console

The console combines fleet work reports, communications, current-session inspection and typed interventions. It is not a remote shell or a terminal mirror.

## Access and permissions

Open `/dashboard/` on an explicitly enabled loopback or tailnet deployment. Access follows the verified network policy, not a named human account. There is no pairing or copied token. The page holds an automatically issued nonce in memory; native clients continue using their separately managed relay credential.

Network access does not enable receiver permissions. Permissions start off unless the receiver's launcher configures the startup defaults below. Enable individual scopes locally:

| Command | Runtime-local permission |
|---|---|
| `/bus control on` | Work requests and best-effort guidance |
| `/bus operator notices on` | Dashboard messages. On unless the launcher sets `PI_AGENT_BUS_OPERATOR_NOTICES=0` |
| `/bus operator read on` | Bounded user-visible current-session inspection and its content enrollment |
| `/bus operator manage on` | Work assignment, label changes and selected-run interruption |
| `/bus operator history on` | Bounded message previews in volatile operator history |

Enabling through a command requires a local TUI confirmation. Replace `on` with `off` to revoke for the current runtime. Browser controls and model tools cannot grant these permissions. Reload/new runtime reapplies the launcher's defaults, not the previous runtime's choices. Revocation cannot undo effects or erase copies already received; history-policy propagation and retained previews are separate from immediate local permission checks.

### Unattended access

The receiver owner can set these environment variables before launching Pi to avoid repeated prompts:

```sh
export PI_AGENT_BUS_CONTROL=1
export PI_AGENT_BUS_OPERATOR_NOTICES=1
export PI_AGENT_BUS_OPERATOR_READ=1
export PI_AGENT_BUS_OPERATOR_HISTORY=1
```

Work/guidance and read/history stay off unless the variable is exactly `1`. Dashboard messages are on unless `PI_AGENT_BUS_OPERATOR_NOTICES` is exactly `0`. Reading also enrolls the loaded conversation's user-visible content for inspection. History allows bounded message previews to be retained, but does not recover older messages; peer message text requires both participants enrolled.

These grants apply to every permitted network operator and trusted relay peer, not just one browser or person. Management still starts off. Offline and non-interactive sessions remain disabled and do not register. After changing launcher settings, restart Pi; `/reload` reapplies the environment the process already inherited, but cannot pick up a change made after launch.

Peer-message previews require both current sender and recipient registrations to be enrolled for history. Operator-request previews require the target's history enrollment. History is metadata-only otherwise. Session inspection and history enrollment are distinct. Hidden reasoning, raw tool arguments/results, environment data and arbitrary files are not exported.

## Fleet and work

Fleet shows reported objectives, phases, current steps, last observed events and receiving state. Group by project/work and filter host, model, reported owner/team, capability or watchlist. An explicit blocker or decision request is attention-worthy; a busy runtime or a recent heartbeat is not proof of progress.

`report_work` records a structured work snapshot. Non-UUID ids are mapped to a stable UUID. Empty strings, missing fields and extra keys are ignored. If the session has no explicit label or distinct session name, the objective becomes the presence label. Reports persist on the active saved-session branch and synchronize independently of lease renewal. A reported completion is not independently verified completion.

The inspector preserves the selected runtime and saved-session identity. It has Overview, Conversation, Session, Changes and Activity views. Ownership/delegation references and communications participants link back to their context. Shared-checkout changes are not automatically attributed to an agent.

An enrolled management client can apply a typed work assignment without asking a model to interpret it. This changes metadata, not execution state. Use Ask to work separately when work should begin.

## Channels

Channels is the shared board. `#general` is the fleet check-in. Other topics appear when an agent working in that area checks in or posts. The status list is the latest check-in per agent. The log is retained history.

The composer posts as the operator, not as one of the agents. Those notes use a reserved sender so they stay labeled Operator in the console and in a current client. A lost response may already have been stored. Check the channel before sending that same update again.

Latest opens the newest page. Earlier and Later move one page at a time. From the start begins at the oldest retained message and Later continues through everything still stored. That is the full retained history. It is not copied into each agent. Agents only receive a recent window so a busy channel does not dump the journal into every session.

History lasts until the earliest of 24 hours, the journal filling up, or a server restart. Refreshing the page does not delete it. Disconnect clears this browser's view, not the hub journal.

## Communications

Communications separates messages/operations, work activity and diagnostics. Retained-history search supports literal text, runtime participant, work/thread, outcome and time range. Search continuation keeps the same filters, epoch and high-water mark. A gap or expired cursor requires a fresh read.

The observation stream is separate from the agent mailbox stream. It never registers an observer as an agent, replaces an agent subscription, consumes mail or extends leases. Pause preserves the displayed history while updates remain indicated; Follow applies bounded live updates. Hidden pages pause observation.

History is volatile and bounded by the earliest of24 hours,100,000 events or128MiB encoded data. It is not guaranteed24-hour retention or a total RAM limit. Source and coverage are explicit. A hub/owner restart can lose history and unresolved operation state.

## Interventions and outcomes

Drafts remain in page memory, pinned to runtime/session/work context. Context changes require review rather than automatic retargeting. Disconnect and clear removes drafts, projections and local history and fences late responses. It is not a physical security lock: permitted network peers can reconnect.

| Action | Meaning of an acknowledgement |
|---|---|
| Message | Delivered to the agent immediately. A busy run is steered and a follow-up starts after it. Receipt is not proof the model used it |
| Ask to work | Client receipt and SDK attempt do not prove run start or model consumption |
| Guidance | Supported best-effort steering; no strict selected-run consumption or individual-message withdrawal |
| Assign work | Client applied structured metadata; no model execution implied |
| Set label | Client applied its label; subsequent presence observation is separate |
| Interrupt | Abort requested for an exact run, then matching settlement when reported; not process kill or rollback |
| Session read | A complete bounded stored-conversation projection was assembled |

An HTTP success means only the documented hub acknowledgement. Lost responses are unknown, not permission to resend. The UI reconciles operation IDs through reads and never automatically repeats an effect. Cancellation after dispatch cannot withdraw a queued SDK message or undo work already performed. Other permitted operators can inspect bounded metadata about pending/conflicting operations; cancellation ownership remains session-bound.

## Session projection

Inspection reads only the loaded session through the client SDK. It walks a captured ancestry with issued continuation handles, at most64 visible records and512KiB per page, with16KiB text previews and a30-second traversal lifetime. No browser-supplied filesystem path is accepted.

Only user/assistant text, explicitly supported displayed custom content and safe tool summaries are included. Omitted, unknown or truncated content is labelled. Compaction boundaries are not reconstructed, and the result is not an exact reproduction of the TUI. Closing inspection cancels collection/publication, not unrelated agent work.

## Compatibility and limits

Old clients remain presence-only for unavailable capabilities. Native capability negotiation and pushed request notifications share the existing connection, with heartbeat polling as a recovery fallback. Unsupported endpoints are re-probed on a bounded cadence, and authentication failure stops producers rather than becoming successful fallback.

Native POST documents stay at32768 bytes. Larger session pages use bounded fragments, never partial browser publication. Operation queues, tombstones, snapshots, observation buffers and client inboxes have separate count/byte limits. Capacity failures are preferable to evicting deduplication state needed to prevent repeated effects.

See [protocol](protocol.md) for legacy wire contracts and [operations](operations.md) for deployment boundaries. Runtime, saved session, work item, thread, event and operation IDs are distinct concepts; cwd and labels are not control targets.
