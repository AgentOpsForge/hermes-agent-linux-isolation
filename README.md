# Hermes Agent — Linux user isolation

A step-by-step guide for running several [Hermes Agent](https://github.com/NousResearch/hermes-agent)
instances on one Linux host, each under its own system user, so that the agents are isolated
from one another.

> **Status: work in progress.** The chapters are being written and have not yet been validated
> on a freshly installed host. Do not rely on them in production yet.

## What this is — and what it is not

- **Unofficial.** This project is not affiliated with, endorsed by or maintained by Nous Research.
  It does not develop Hermes Agent. Bugs in Hermes Agent belong in the
  [Hermes Agent issue tracker](https://github.com/NousResearch/hermes-agent/issues).
- **No support.** The guide and its scripts are provided as is, without warranty or support
  (see [SUPPORT.md](SUPPORT.md) and [LICENSE](LICENSE)).
- **A complement, not a replacement.** The Hermes Agent security policy names OS-level isolation
  as the only security boundary and supports terminal-backend isolation and whole-process
  wrapping (containers). Separate Linux users isolate agents **from each other** on a shared
  host. They do not replace a container or sandbox when an agent processes untrusted input.

## Scope

- one system user, profile and systemd unit per agent
- file system permissions, groups and ACLs between agents and the host
- systemd hardening of the agent gateways and of their worker processes
- collaboration between isolated agents (Kanban, agent-to-agent calls with per-pair tokens)
- credential patterns: keys held by a dedicated service, not by the agents
- local patches needed for this setup, with their upstream status
- scripts to create and verify an agent

## Tools

Everything is driven by a single configuration file, [`platform.toml`](platform.toml): domains,
trust zones, vaults, services and agents. The scripts derive groups, paths and allowed environment
variables from it and check it against the isolation rules — nothing is hard-coded to one host.

| Script | What it does |
| --- | --- |
| `hermes-agent-create.sh <agent>` | Create the system user, profile, config and systemd unit for one agent. |
| `hermes-agent-lock.sh <agent>` or `--host` | Apply ownership, permissions, ACLs and systemd hardening; verify, roll back on failure. |
| `hermes-agent-verify.sh <agent>` or `--host` | Read-only check of one agent and the host layer against `platform.toml`. |

`hermes-agent-lib.py` (rule checker and TOML reader) and `hermes-agent-lib.sh` (shared shell helpers)
are used by the three scripts and are not run directly. The `platform.toml` in this repository is a
neutral example — replace it with your own before use. Verify the toolset against `SHA256SUMS`.

Requirements: a Linux host with `systemd`, `setfacl`, `chattr` and Python 3.11+ (for `tomllib`).

## Tested versions

Each release lists the Hermes Agent version and the distribution it was tested with.
The current work targets Hermes Agent v0.21.5 (tag `v2026.9.24`).

## Contents

Planned chapters (added one by one):

1. [Threat model](docs/01-threat-model.md) — what user isolation protects and what it does not
2. [Architecture](docs/02-architecture.md) — users, groups, IDs, directories, units
3. [Host setup](docs/03-host-setup.md), step by step
4. [Local patches](docs/04-patches.md)
5. [Creating and verifying an agent](docs/05-create-verify.md)
6. [Hardening the units and user slices](docs/06-hardening.md)
7. [Collaboration through Kanban](docs/07-kanban.md)
8. [Credential pattern: a dedicated service holds the keys](docs/08-credentials.md)
9. [Operations — updates, checks, backup](docs/09-operations.md)
10. [Limits and known issues](docs/10-limits.md)

## Design

[Design](docs/design.md) — why the architecture is shaped this way, and which script automates which
work package (the automation map).

## Contributing, security, support

- [CONTRIBUTING.md](CONTRIBUTING.md) — how to propose changes
- [SECURITY.md](SECURITY.md) — how to report a problem in this guide or its scripts
- [SUPPORT.md](SUPPORT.md) — what to expect

## License

[MIT](LICENSE)
