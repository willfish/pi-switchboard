# Fleet operator console

The console combines fleet work reports, communications, current-session inspection and typed interventions. It is not a remote shell or a terminal mirror.

## Access and permissions

Open `/dashboard/` on an explicitly enabled loopback or tailnet deployment. Access follows the verified network policy, not a named human account. There is no pairing or copied token. The page holds an automatically issued nonce in memory; native clients continue using their separately managed relay credential.

Network access does not enable receiver permissions. Each Pi runtime starts with control and inspection permissions off. Enable only the required scope locally:

| Command | Runtime-local permission |
|---|---|
| `/bus control on` | Work requests and best-effort guidance |
| `/bus operator notices on` | Passive operator notices |
| `/bus operator read on` | Bounded user-visible current-session inspection and its content enrollment |
| `/bus operator manage on` | Work assignment, label changes and selected-run interruption |
| `/bus operator history on` | Bounded message previews in volatile operator history |

Enabling requires a local TUI confirmation. Replace `on` with `off` to revoke. Browser controls and model tools cannot grant these permissions. Reload/new runtime resets consent. Revocation cannot undo effects or erase copies already received; history-policy propagation and retained previews are separate from immediate local permission checks.

Peer-message previews require both current sender and recipient registrations to be enrolled for history. Operator-request previews require the target's history enrollment. History is metadata-only otherwise. Session inspection and history enrollment are distinct. Hidden reasoning, raw tool arguments/results, environment data and arbitrary files are not exported.

## Fleet and work

Fleet shows reported objectives, phases, current steps, last observed events and receiving state. Group by project/work and filter host, model, reported owner/team, capability or watchlist. An explicit blocker or decision request is attention-worthy; a busy runtime or a recent heartbeat is not proof of progress.

`report_work` records a complete structured work snapshot. Use stable work IDs, null for unknown values and explicit evidence references. Reports persist on the active saved-session branch and synchronize independently of lease renewal. A reported completion is not independently verified completion.

The inspector preserves the selected runtime and saved-session identity. It has Overview, Conversation, Session, Changes and Activity views. Ownership/delegation references and communications participants link back to their context. Shared-checkout changes are not automatically attributed to an agent.

An enrolled management client can apply a typed work assignment without asking a model to interpret it. This changes metadata, not execution state. Use Ask to work separately when work should begin.

## Communications

Communications separates messages/operations, work activity and diagnostics. Retained-history search supports literal text, runtime participant, work/thread, outcome and time range. Search continuation keeps the same filters, epoch and high-water mark. A gap or expired cursor requires a fresh read.

The observation stream is separate from the agent mailbox stream. It never registers an observer as an agent, replaces an agent subscription, consumes mail or extends leases. Pause preserves the displayed history while updates remain indicated; Follow applies bounded live updates. Hidden pages pause observation.

History is volatile and bounded by the earliest of24 hours,100,000 events or128MiB encoded data. It is not guaranteed24-hour retention or a total RAM limit. Source and coverage are explicit. A hub/owner restart can lose history and unresolved operation state.

## Interventions and outcomes

Drafts remain in page memory, pinned to runtime/session/work context. Context changes require review rather than automatic retargeting. Disconnect and clear removes drafts, projections and local history and fences late responses. It is not a physical security lock: permitted network peers can reconnect.

| Action | Meaning of an acknowledgement |
|---|---|
| Notice | Client receipt, context reservation and matching observation are separate; none is a human read receipt |
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

Old clients remain presence-only for unavailable capabilities. Native capability negotiation and immediate polling run alongside the existing heartbeat without a second always-on native connection. Unsupported endpoints are re-probed on a bounded cadence, and authentication failure stops producers rather than becoming successful fallback.

Native POST documents stay at32768 bytes. Larger session pages use bounded fragments, never partial browser publication. Operation queues, tombstones, snapshots, observation buffers and client inboxes have separate count/byte limits. Capacity failures are preferable to evicting deduplication state needed to prevent repeated effects.

See [protocol](protocol.md) for legacy wire contracts and [operations](operations.md) for deployment boundaries. Runtime, saved session, work item, thread, event and operation IDs are distinct concepts; cwd and labels are not control targets.
