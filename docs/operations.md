# Operations

## Packages and modules

`packages.<system>.hub` is the compiled OTP release, including ERTS and its Nix closure. Run `bin/pi-agent-bus`, not a checkout script or relx administration command. Copying that executable alone does not distribute its dependencies.

`packages.<system>.pi-extension` contains the source Pi package. It does not include the hub, ERTS or development dependencies.

Import `nixosModules.default` into a NixOS configuration and configure:

```nix
services.pi-agent-bus = {
  enable = true;
  tokenFile = "/run/secrets/agent-bus-token";
  # listenAddress defaults to "127.0.0.1"; port defaults to 7420.
};
```

`package` is overrideable. `tokenFile` must be an absolute runtime-path string, not a Nix path, store path or credential value. The module must never read the secret during evaluation. Use a syntactically normalized path: no root-only path, empty segments, `.` or `..`. Control characters, spaces, single/double quotes, backslashes and `%` are rejected because the pinned systemd executor cannot safely serialize them here. Literal `$` is supported. This is validation of path syntax, not symlink resolution or filesystem canonicalization. Arrange a suitable runtime path through the consumer's secret workflow when necessary.

The service uses `LoadCredential`, `DynamicUser`, `ProtectHome`, a read-only system and private temporary storage. The application reads the copied systemd credential, not the original file. Keep the original root-protected; do not broaden its permissions for the dynamic user. The consumer owns ordering after its secret-installation unit. No sops implementation is required by this repository.

Import `homeManagerModules.default` and enable:

```nix
programs.pi-agent-bus.enable = true;
```

Its overrideable `package` links the complete output at `~/.pi/agent/extensions/agent-bus`. It does not own Pi wrappers, writable settings, environment variables, credentials or consent. Remove any duplicate manual/npm installation before enabling it.

## Credentials and network exposure

Provision one high-entropy shared token through encrypted secret management. Supply its runtime path to the hub and its value to Pi's environment through the consumer's credential wrapper. Keep values out of source, Nix evaluation, arguments, logs and failure captures.

For remote clients, choose the intended bind address explicitly. The module never opens the firewall. A wildcard listener is restricted to the tailnet only if the effective firewall permits the trusted tailnet interface and loopback while denying physical-LAN/public access. A bearer token is not a firewall.

Validate both sides: an authenticated real tailnet client must connect, and a separate physical-LAN client must fail even to reach unauthenticated health. First establish that the negative-test peer's network works. VM interface tests do not establish deployment-host isolation.

To rotate credentials, update the private runtime secret, restart the hub, and restart Pi through its credential wrapper. `/reload` resets extension state but does not refresh inherited environment variables. Hub restart loses pending mail and deduplication; Pi reload/restart loses inbox and consent.

## Failure recovery

- `connected`: recent registration and synchronized reception.
- `degraded`: registration is live but reception is unavailable.
- `down`: registration/reception cannot establish a usable connection.
- `disabled`: no eligible configured runtime.

A 401 stops automatic background work. Refresh credentials locally rather than repeatedly resending messages.

Notice reception and inbox viewing never start work. Pending notices enter context on a later idle prompt submission; steering, queued continuations and compaction do not force early inclusion. Viewing marks a record read, not context-included.

Control is off for each new runtime. Enabling requires a local confirmation. A submitted control request reserves one slot until its exact user-message event appears. Handled/transformed input, compaction rejection and other preflight failures can leave it occupied. `/bus` shows this; `/reload` clears the slot, inbox and consent. Do not retry automatically or infer execution from a void API return.

A lost POST response is ambiguous. Ask the peer before manually resending. There is no durable spool, execution receipt or exactly-once guarantee.

## Resource and shutdown evidence

Encoded mail, snapshot and journal budgets are separate from total memory, kernel socket buffers, process queues and Pi's session storage. The 5,000-record fixture does not size a 5,000-connection deployment.

Inspect effective descriptor limits, task counts, CPU/memory accounting and observed peaks under the intended workload before setting host-specific limits. Application connection settings do not raise OS limits; an inherited soft descriptor limit can be lower than the configured connection ceiling. Do not derive a RAM ceiling from the 5 GB encoded-mail budget. The service's outer shutdown allowance provides headroom; ordinary shutdown must still complete cleanly within five seconds in its acceptance fixture.

Keep structural logging and crash-dump suppression enabled. Raw debugger state, tracing and direct IO are separate exposure boundaries. Use only synthetic data in diagnostic fixtures. Filesystem/process snapshots cannot exclude transient effects; retain the separate ordinary-launcher syscall check.

## Rollout and rollback

Before activation, verify current packages, module configuration, credential ordering, native Pi compatibility and network isolation. Exercise notice/no-turn, control off/on, reconnection, hub restart and runtime replacement with the actual clients. Native Darwin needs native evidence.

On failed consent or network-isolation checks, disable or roll back before further use. Roll back the pinned input/generation and restart affected services/clients. Pending hub mail is lost, not migrated or replayed. Publication, private-secret changes and activation are separate authorized operations.
