# Pi Switchboard

Standalone Pi client extension and volatile Erlang/OTP relay. Keep application code here; consuming dotfiles compose packages/modules and private credentials. Publication, credential changes and host activation require their own authorization.

## Layout and checks

- `hub/src/`: pure model/protocol, single state-owning store and supervised Cowboy/Ranch transport.
- `extension/`: source-only Pi client; root `index.ts` is its package entry.
- `tests/fixtures/`: canonical wire fixtures shared by Erlang and TypeScript.
- `hub/test/`: EUnit/Common Test; `tests/`: Node and compiled-package tests.
- `nix/`, `flake.nix`: separate release, extension and test inputs.

Use this checkout's direnv environment and serialize Rebar/Nix build ownership. From the repository root:

```sh
direnv exec . scripts/rebar3-patched eunit
direnv exec . scripts/rebar3-patched ct
direnv exec . npm test
direnv exec . npm run typecheck
direnv exec . nixfmt --check flake.nix nix/*.nix
direnv exec . nix flake check --no-update-lock-file
git diff --check
# When no dependency update is intended:
git diff --exit-code -- flake.lock hub/rebar.lock package-lock.json
```

Use `scripts/rebar3-patched`, not plain local Rebar: it verifies the repository-owned Cowboy patch and removes stale dependency BEAMs. Keep one digest-checked patch path for local development, Nix tests and release packaging; reject unknown dependency sources. Keep Beam package selection consistent across dependency fetching, builds and development.

Use locked, script-disabled development dependencies; do not bundle them into the extension. During intentional dependency updates, review lock diffs and verify repeat checks do not change them further. Intent-to-add intended new files before git-backed flake checks. Check explicit test filesets when adding tests: a wildcard cannot run files omitted from the Nix source. Node's type stripping is not static type checking or real Pi compatibility evidence. Run full relevant behaviour groups after changes, not just new regressions.

Pack npm artifacts from the complete public Git source, not the prefiltered client output. Validate physical gzip/tar structure and an independent reviewed file inventory before extraction; logical tar members alone can hide extension headers or padding data. Keep compiler tooling outside the package. Use the TypeScript AST and documented restricted Markdown grammar for packaged references. Update the inventory deliberately and test the actual extracted archive through the full Pi harness; inspection is not publication authorization.

## State and delivery invariants

- Capture one monotonic/wall-clock pair per time-dependent store callback. Use it throughout expiry, liveness, model transitions, discovery and change recording. Resampling across a lease boundary can retain an old subscription after resetting its mailbox, or omit a removal revision.
- Keep absolute request deadlines separate: sample actual monotonic milliseconds immediately before admission/calling and before publishing expensive results. Resolve, admit and call the same store PID. Never retry or replay an uncertain store operation.
- The ingress queue guard is sampled, not a hard semaphore. Cleanup casts, monitor messages and internal work remain unfiltered and may overshoot it.
- Fence subscription operations by both reference and caller PID. Observe emptiness and rearm wakes atomically. A final presence frame with `More=false` must also rearm, so changes during its write can queue a fresh wake.
- Check deduplication before current liveness/control/capacity and retain the original acceptance. Acceptance is not delivery. Pop mail immediately before one write attempt; interrupted writes may lose that item. Never automatically retry message POSTs.
- Preserve a request's observed 401 before notifying authentication shutdown, which may synchronously abort every request. A global unauthorized latch cannot establish another concurrent POST's outcome.
- Indefinite SSE streams cannot be drained to natural completion at shutdown. Check pinned Cowboy parent/system-stop semantics; preserve orderly stream/child cleanup with a separate bounded grace period, rather than relying on the last stream finishing.
- Listener failure preserves store state; store failure loses volatile registrations, mail and deduplication state and restarts transport.

## Bounded discovery and transport

Keep shared bounded snapshots and one bounded journal, with scalar subscriber progress. Do not retain full snapshots or dirty maps per subscriber. Select delta prefixes through bounded revision-index lookups, not a full journal scan. Store historical change values, not references to today's agent state.

HTTP traversal must remain one routing-relevant revision; discard partial results on reset or error. Heartbeats update timestamps without broadcasting meaningful changes, and snapshots explicitly freeze those timestamps. Missing history during chunking requires immediate reset. Clients stage snapshots and apply deltas atomically.

Bound encoded bytes as well as record counts, including complete SSE framing. Actual raw-frame admission belongs to the parser; canonical staging charges are a separate accounting unit. CR/CRLF handling must not depend on network chunk boundaries. Use one actual-send barrier per frame; Cowboy acknowledgement alone is not transport-send completion. Preserve healthy-stream lifetime exemption without allowing stalled writes indefinitely.

Ranch applies `max_connections` per connection supervisor and permits overshoot. Registered-population tests do not prove simultaneous-connection capacity. Accepted-mail, snapshot and journal byte budgets are not total RAM limits.

## Pi, secrets and runtime evidence

Use the pinned Pi API and actual binary fixtures for lifecycle/timing decisions. Require `ctx.mode === "tui"`; `hasUI` also covers RPC. Keep network and timers out of the extension factory and exclude disabled, offline and `qwen-pi` sessions, not ordinary Pi sessions merely using a Qwen model. Restore labels from custom-entry `data` on the active branch. Remote control requires receiver-local consent; a callable slash command is not proof of human origin. Keep prompt expansion disabled for bus input.

Keep real credentials and private data out of git, logs and Nix outputs; use synthetic fixtures. Production logging must not serialize presence documents or mail. Preserve structural fail-closed logging and status sanitization; raw debugger state and direct IO are separate exposure boundaries. Force crash-dump suppression rather than merely supplying a default.

Test the compiled Nix artifact, not a source-tree server. Retained-file/process snapshots cannot exclude transient writes, listeners or EPMD. Keep startup syscall evidence distinct from exhaustive isolation claims and native-platform verification. Trace ordinary startup without diagnostic hooks; preserve observation through VM shutdown. Bound cleanup independently of tracer close. For forced cleanup, strace's `--kill-on-exit` requires killing the tracer, not graceful detachment; verify ownership before signalling descendants.
