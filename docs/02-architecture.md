# Architecture

One host runs several Hermes agents. Each agent is a separate Linux user with its own home, its own
credentials and its own tool set, so one agent cannot read another's files, use another's tokens or
reach a network it was not given. Everything below — users, groups, IDs, directories and units — is
declared once in [`platform.toml`](../platform.toml), applied by `hermes-agent-lock.sh` and checked by
`hermes-agent-verify.sh`. Nothing is hard-coded to a particular host.

The examples use the neutral configuration shipped in this repository: a host `example-host`, one
domain `team`, two zones `Z1` (Private) and `Z2` (Infrastructure), and three agents `assistant`
(orchestrator), `worker` and `analyst`.

## Domains and zones

- A **zone** is a trust zone. It is not a Linux group; it is the label a definition is checked
  against.
- A **domain** groups the zones that belong together (one person, one team). Kanban is shared only
  within a domain: a domain has its own Kanban home and its own group `kanban-<domain>`, and a board
  belongs to exactly one domain.
- Data crosses zones only through agent-to-agent calls (information) or a Kanban board (a task),
  never through a shared writable file. Crossing a **domain** boundary needs an explicit exception in
  `platform.toml` — a named A2A pair, or a vault shared by two domains.

**A board is a trust boundary.** Hermes stores a task's workspaces under
`boards/<board>/workspaces/<task>/`, readable and writable by every member of the board, so follow-up
tasks can read the hand-off of the previous one. Two zones that must not influence each other
therefore get **separate boards** with their own group, not one shared board.

## Users

| User | Purpose | Home | Shell | sudo |
| --- | --- | --- | --- | --- |
| `<agent>-agent` | one system user per agent | `/var/lib/hermes/profiles/<agent>` | nologin | never |
| `github` | credential service (catalog, deploy keys) | `/var/lib/github` | nologin | never |
| admin | administration | `/home/<admin>` | login | yes, named |

Rules:

- An agent user is never a member of another agent's primary group.
- Admins are not members of agent, vault or kanban groups; administration is done with `sudo`.
- No agent user has `sudo`, and no group is granted `NOPASSWD: ALL`.
- Agent names are stable. Renaming means a new user, a migration, and removal of the old one.

## Groups

| Group | Members | Purpose |
| --- | --- | --- |
| `<agent>-agent` | the agent itself (primary group, same ID as the user) | ownership of the agent's files |
| `kanban-<domain>` | the domain's agents that use Kanban | the domain's Kanban home and boards |
| `vault-<vault>-rw` | agents that write the vault, plus `github` | write access to the vault |
| `vault-<vault>-ro` | agents that read the vault | read access to the vault |

Groups are derived from `platform.toml`, not maintained by hand. Per-board groups are introduced only
once a domain has boards with different membership.

## Fixed IDs

All platform users and groups have fixed IDs, so ownership and permissions still match after a rebuild
or a restore from backup. The range **2000–2199** is reserved for the platform; directory accounts sit
well above it. Every user has a primary group of the same name and the same ID. For agents the rule is:

```text
uid = gid = 2000 + (a2a_port - 9900)
```

An agent without A2A keeps its port number reserved so the rule stays unambiguous. Groups sit in
blocks: agents from 2000, the shared kanban groups from 2110, the vault groups from 2120.

| User / primary group | UID = GID | A2A port |
| --- | --- | --- |
| `assistant-agent` | 2000 | 9900 |
| `worker-agent` | 2001 | 9901 |
| `analyst-agent` | 2008 | 9908 (reserved, no A2A) |
| `github` | 2091 | — |

| Group | GID |
| --- | --- |
| `kanban-team` | 2110 |
| `vault-team-wiki-rw` / `-ro` | 2120 / 2121 |

## Directories

```text
/opt/hermes-agent/            root:root              0755   Hermes core, pinned release tag, venv
/etc/systemd/system/
  hermes-gateway-<agent>.service                            one gateway unit per agent
  hermes-gateway-.service.d/10-hardening.conf               common hardening (all gateways)
  hermes-gateway-<agent>.service.d/20-agent.conf            per-agent environment and limits
/var/lib/hermes/              root:root              0711   traverse yes, list no; no ACLs
  profiles/<agent>/           <agent>-agent          0700   HERMES_HOME and HOME of the agent
  kanban/                     root:kanban-<domain>   2770   the domain's Kanban home
    boards/<board>/           <agent>:kanban-<domain> 2770  a board of the domain
/var/lib/github/              github                 0700   deploy keys, SSH config, state
/srv/vaults/<vault>/          github:vault-<vault>-rw 2770  + ACL group:vault-<vault>-ro:r-X
/var/backups/hermes/          root:root              0700   backups taken before changes and updates
```

### An agent's home

| Path | Owner | Mode | Protected | Content |
| --- | --- | --- | --- | --- |
| `config.yaml` | root:`<agent>-agent` | 0640 | immutable | configuration |
| `SOUL.md`, `.hermes.md` | root:`<agent>-agent` | 0640 | immutable | identity, operating rules |
| `.env` | root:`<agent>-agent` | 0640 | immutable | static secrets |
| `auth.json` | `<agent>-agent` | 0600 | — | OAuth data (rotated) |
| runtime dirs, caches, `state.db` | `<agent>-agent` | 0700 | — | run-time data |

**Protected** means owned by root **and** carrying the immutable attribute (`chattr +i`). The home
belongs to the agent, so without this it could delete and replace these files; the attribute prevents
that and only root can clear it. `hermes-agent-lock.sh` clears it, writes, and sets it again.

The agent home is `profiles/<agent>` because Hermes derives its root directory from the parent folder:
with a parent named `profiles`, the root is `/var/lib/hermes`, which the shared Kanban store, the
worker start and the profile enumeration on updates all depend on.

## Units

Each gateway has its own unit `hermes-gateway-<agent>.service`; scripts and the Kanban dispatch refer
to it by name. Hardening comes from drop-ins:

| File | Content |
| --- | --- |
| `hermes-gateway-.service.d/10-hardening.conf` | common for all gateways; source `units/hermes-gateway-hardening.conf`, installed by `hermes-agent-lock.sh --host` |
| `hermes-gateway-<agent>.service.d/20-agent.conf` | `ReadWritePaths` (profile, Kanban home, writable vaults), `BindPaths=-/run/user/<uid>`, `MemoryHigh`/`MemoryMax` |
| `user-<uid>.slice.d/50-hermes.conf` | memory and task limits for the agent's worker scopes |

The hardening sets, among others, `User`/`Group` to the agent, `UMask=0007`, `ProtectSystem=strict`,
`ProtectHome=tmpfs` (with `BindPaths=-/run/user/<uid>` for the user bus), `ProtectProc=invisible`, an
empty `CapabilityBoundingSet`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`, and the
usual `Protect*`/`Restrict*` switches. `ReadWritePaths` is derived from `platform.toml`: the agent's
own home, the Kanban home, and the vaults it may write.

Under `ProtectSystem=strict` each `ReadWritePaths` entry is its own mount, so `rename()` between two of
them fails with `EXDEV` even on the same file system. Services therefore do not move files between
them — they read, write and delete. A test without systemd does not show this.

**Capacity:** the sum of all `MemoryMax` plus a reserve must stay below the host's RAM. A new agent is
added only once that still holds after it joins.

## How this is defined and checked

Domains, zones, vaults, services and agents live in [`platform.toml`](../platform.toml). From it the
tools derive each agent's groups, its `ReadWritePaths` and its allowed environment variables, and they
check the definition against the rules above (one zone per agent, one domain per zone, write access
only from a zone of the vault, A2A only within a domain unless excepted, the ID rule). See the
[Tools section of the README](../README.md#tools) for `create`, `lock` and `verify`.
