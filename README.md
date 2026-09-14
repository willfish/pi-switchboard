# Pi Switchboard

Discover interactive Pi sessions and send them small messages through a self-hosted relay. The client needs a running hub; installing the extension alone does not provide one.

The hub is an Erlang/OTP release with authenticated HTTP and SSE. The client is a source-only Pi package using Node built-ins and Pi's host APIs. Nix packages keep those artifacts separate.

## Behaviour

- Sessions register automatically and advertise host, cwd, label, model, activity and receive readiness.
- Notices enter a bounded local inbox without starting a model turn. Pending notices join context on a later idle prompt submission.
- Prompt and steering requests require receiver-local consent, off by default for every runtime.
- Discovery is paged and revision-fenced. Failed discovery never silently sends to a cached or substitute target.
- Everything is best effort. Acceptance means queued in hub memory, not delivered or executed. Restart loses hub mail; client reload loses inbox and consent.

Token holders can see presence and impersonate peers. Use a trusted tailnet and an appropriate host firewall, not a public Internet listener or a hostile multi-user deployment.

## Build and install

```sh
nix build .#hub --out-link result-hub
nix build .#pi-extension --out-link result-client
```

Run the compiled hub with an absolute runtime credential-file path:

```sh
PI_AGENT_BUS_BIND_HOST=127.0.0.1 \
PI_AGENT_BUS_TOKEN_FILE=/absolute/runtime/path/to/token \
./result-hub/bin/pi-agent-bus
```

Port defaults to 7420. Provision the token through your secret-management workflow; never embed it in a flake or repository.

Install the complete client package root, not just `index.ts`. Choose one installation method: the Home Manager module or Pi's local-package installation of this checkout. Do not load the client twice. Npm publication is separate from Nix/source installation.

Before launching Pi, supply `PI_AGENT_BUS_URL` and `PI_AGENT_BUS_TOKEN` through your runtime credential wrapper. The URL defaults to `http://terminus:7420`; set it explicitly for other deployments. `PI_AGENT_BUS_ENABLED=0` disables participation. Offline and non-TUI sessions remain inert.

See [operations](docs/operations.md) for modules, credential handling, failure recovery and rollout checks, and [compatibility](docs/compatibility.md) before upgrading Pi.

## Browser dashboard

Open `/dashboard/` on the hub to inspect runtime presence, search and filter sessions, and view receiving/control state. Unlock with the hub token on a trusted device and network. The page only reads presence, but the token itself grants full hub access; it stays in page memory and is cleared on Lock or reload. Snapshot freshness is explicit, and the page never consumes inbox messages or starts agent work.

## Commands and tools

| Command | Purpose |
|---|---|
| `/label [text]` | Show/set work label; `--clear` restores the session/cwd default |
| `/agents` | Fresh discovery with readiness and control permission |
| `/tell <target> <text>` | Send a notice |
| `/tell --prompt <target> <text>` | Request a consenting peer's next prompt |
| `/tell --steer <target> <text>` | Request steering, which can affect active work |
| `/bus` | Connection, identity, unread count, consent and pending-slot status |
| `/bus inbox` | Read-only local viewer, including while disconnected |
| `/bus control on\|off` | Receiver-local consent; enabling requires confirmation |

Targets resolve by runtime ID, unique prefix of at least eight characters, exact host, then label substring. Ambiguity stops the send. Quote targets containing spaces; `--` ends leading flag parsing. Saved session IDs are not routing identities.

The model tools are `list_agents`, `set_agent_label` and `send_agent_message`. No tool enables consent. There is no `ask` mode or execution receipt.

A lost POST response is **outcome unknown**. Check the peer before resending. If a control submission never produces its matching user-message event, the local slot stays occupied; `/reload` clears it and disables consent. Off/on is not a retry mechanism.

## Development

For checkout development, use its direnv environment and the instructions in `AGENTS.md`. Run unit tests, strict SDK source typechecking, compiled hub checks and actual Pi TUI fixtures. A passing mock suite or Pi process exit is not runtime acceptance.

[Protocol v1](docs/protocol.md) defines limits, schemas and failure semantics. Functional discovery of 5,000 registrations is not a 5,000-connection performance guarantee, and encoded queue budgets are not total RAM limits.
