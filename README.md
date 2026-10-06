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

## Tested versions

Each release lists the Hermes Agent version and the distribution it was tested with.
The current work targets Hermes Agent v0.21.5 (tag `v2026.9.24`).

## Contents

Planned chapters (added one by one):

1. Threat model — what user isolation protects and what it does not
2. Architecture — users, groups, IDs, directories, units
3. Host setup, step by step
4. Local patches
5. Creating and verifying an agent
6. Hardening the units and user slices
7. Collaboration through Kanban
8. Credential pattern: a dedicated service holds the keys
9. Operations — updates, checks, backup
10. Limits and known issues

## Contributing, security, support

- [CONTRIBUTING.md](CONTRIBUTING.md) — how to propose changes
- [SECURITY.md](SECURITY.md) — how to report a problem in this guide or its scripts
- [SUPPORT.md](SUPPORT.md) — what to expect

## License

[MIT](LICENSE)
