# Compatibility and acceptance

Release version, wire version and Pi version are separate:

- Package release: `0.1.0`.
- Wire contract: `/v1`.
- Pi API/runtime target: `0.85.1`.

Targeted native systems are x86-64 Linux and Apple Silicon Darwin. The service module is Linux/NixOS only. A declared flake output or Linux execution does not establish native Darwin compatibility.

## Dependencies and runtime

Development SDK packages are pinned and locked separately from production source. Installs keep lifecycle scripts disabled. Typechecking is strict for client source; `skipLibCheck` accommodates upstream declaration defects, with positive/negative SDK type assertions in the Nix check. It is not a substitute for execution against Pi.

Standalone runtime fixtures use the pinned Bun-compiled Pi from `llm-agents.nix`, preserving its own dependency graph. Do not replace it with Node CLI acceptance: the compiled loader and extension aliasing are part of the behaviour being checked. Do not make that input follow another nixpkgs without checking its Bun packaging constraints.

`lib.mkPiRuntimeCheck` accepts `pkgs`, `piPackage`, `hubPackage` and `extensionPackage`. Consumers use it with their actual candidate Pi package. The runner executes the validated native binary beneath the package root, not a credential-loading user wrapper or a PATH fallback.

Fixture inputs are explicit package/executable paths through `PI_AGENT_BUS_TEST_PI_PACKAGE`, `PI_AGENT_BUS_TEST_EXTENSION_PACKAGE`, `PI_AGENT_BUS_TEST_EXECUTABLE` and `PI_AGENT_BUS_TEST_PYTHON`. Python's standard-library PTY helper provides a controlling terminal without native npm PTY dependencies.

## Required evidence

Unit tests cover pure state, parsing, bounds, cancellation and controlled races. Node type stripping does not typecheck them. SDK source typechecking verifies consumed API shapes, not actual lifecycle timing.

The packaged TUI fixture must demonstrate successful registration and behaviour. Pi can continue running after an extension-load error, so exit zero alone proves nothing. RPC/print fixtures establish nonparticipation, not positive interactive acceptance.

The runtime scenario inventory is maintained in `tests/fixtures/pi-runtime/scenarios.mjs`. Remaining scenarios there are open acceptance work, even if implemented smoke tests pass. Complete lifecycle acceptance includes notice/context timing, read-only viewers, local consent, exact control-slot consumption, input handling, compaction/retry failures, model changes, reload/new/resume/fork/tree transitions and shutdown fencing.

Run fixtures with isolated settings, credentials, session storage, cwd and an allowlisted environment. Positive tests are not offline tests: they use a deterministic provider, loopback services and enforced network isolation. Disable version checks and telemetry explicitly. Never load real credential wrappers to test composition.

Linux Nix checks use the build network namespace. Darwin checks need native execution and the narrowly scoped local-network sandbox exception. Neither arrangement is proof of isolation from every unrelated host-loopback service; use explicit fixture endpoints.

## Upgrade checklist

1. Review pinned Pi declarations, implementation and relevant documentation; examples can lag APIs.
2. Update exact SDK/test dependencies and the Pi fixture pin deliberately, preserving script controls and integrity checks.
3. Run full unit, source-typecheck, compiled hub, packaged TUI and module checks on each native target.
4. Test the consumer's actual Pi/client/hub composition, not only the standalone fixture version.
5. Preserve runtime identity, branch label restoration, unset consent off, exact-`1` launcher control, disabled prompt expansion and at-most-one pending control submission.
6. Treat required deployed wire-field changes as a protocol migration, not a silent strict-schema update.

Do not promote partial scenario coverage, mock results, cached logs or another platform's execution into full compatibility or rollout acceptance.
