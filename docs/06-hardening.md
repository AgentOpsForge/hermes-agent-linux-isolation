# Hardening the units and user slices

After an agent is created (chapter "Creating and verifying an agent"), `hermes-agent-lock.sh <agent>`
brings it to its hardened target state and verifies the running gateway. It is the per-agent
counterpart to the host layer (`--host`, [chapter 3](03-host-setup.md)) and builds on the common
hardening drop-in installed there. The run is idempotent — a second run changes nothing, a run after
drift corrects only the deviations — and it rolls back every change if a step fails.

```sh
bash hermes-agent-lock.sh worker
bash hermes-agent-verify.sh worker
```

## What locking an agent does

- **Ownership and groups.** The profile stays owned by the agent; the agent is placed in exactly the
  groups `platform.toml` derives (the domain's `kanban-<domain>`, the `vault-*-rw`/`-ro` it needs), with
  traversal ACLs where required. Admins are kept out of those groups.
- **Immutable instruction files.** `config.yaml`, `SOUL.md`, `.hermes.md` and `.env` are set to
  `root:<agent>-agent`, mode `0640`, and the immutable attribute. The home belongs to the agent, so
  without this it could delete and replace them. To change one by hand: `chattr -i`, edit, `chattr +i`
  — which is exactly what the lock does for you.
- **systemd drop-ins** (see the table below).
- **Linger.** Enabled for the agent user so the gateway can start worker scopes
  (`systemd-run --user --scope`).
- **Runtime check.** After the changes it checks the running gateway: unit active, `HOME` correct, no
  new permission errors in the log.

## The three hardening layers

| File | Scope | Applied by | Content |
| --- | --- | --- | --- |
| `hermes-gateway-.service.d/10-hardening.conf` | all gateways | `lock --host` (chapter 3) | `ProtectSystem=strict`, `ProtectHome=tmpfs`, `ProtectProc=invisible`, empty `CapabilityBoundingSet`, `RestrictAddressFamilies`, `UMask=0007`, the `Protect*`/`Restrict*` switches |
| `hermes-gateway-<agent>.service.d/20-agent.conf` | this agent | `lock <agent>` | `ReadWritePaths` (profile + Kanban home + writable vaults), `BindPaths=-/run/user/<uid>`, `MemoryHigh`, `MemoryMax` |
| `hermes-gateway-<agent>.service.d/zz-home.conf` | this agent | `lock <agent>` | `HOME` = profile (plus any extra environment); named `zz-` so it wins over `override.conf` |
| `user-<uid>.slice.d/50-hermes.conf` | this agent's worker scopes | `lock <agent>` | `MemoryMax`, `TasksMax=512` |

All values — `ReadWritePaths`, the memory limits — are derived from `platform.toml`, not written by
hand. A change that touches only comments in a generated drop-in is rewritten and reloaded **without**
restarting the gateway; a real change triggers a restart.

## Worker scopes

The gateway starts each worker in its own scope (`systemd-run --user --scope`). A scope inherits the
gateway's namespace, `NoNewPrivileges`, capabilities and seccomp filter; its memory and task limits
come from the `user-<uid>.slice`. So the worker can never exceed the gateway's isolation, only sit
within it.

## Writing files under `ProtectSystem=strict`

Each `ReadWritePaths` entry is a separate mount, so `rename()` between two of them fails with `EXDEV`
even on the same file system (see [Architecture](02-architecture.md)). A service therefore reads,
writes and deletes between those paths — it does not move. A test without systemd does not show this,
so it is easy to miss until the hardened unit runs.

## Running it

`hermes-agent-lock.sh <agent>` backs up every file it replaces, an ACL dump, an owner manifest and an
`undo.sh` into `/var/backups/hermes/`, and on failure runs the undo automatically. It prints no
secrets: file contents are compared, never shown; journal lines are masked. When it finishes, confirm
with `hermes-agent-verify.sh <agent>` (and `--host` for the host layer, or `--all` for everything).

## What is automated

| Step | By hand | Script |
| --- | --- | --- |
| Ownership, groups, ACLs, linger | — | `hermes-agent-lock.sh <agent>` |
| Immutable instruction files | `chattr -i` / edit / `chattr +i` | `hermes-agent-lock.sh <agent>` |
| Per-agent and slice drop-ins | — | `hermes-agent-lock.sh <agent>` |
| Check the result | — | `hermes-agent-verify.sh <agent>` |

The host-wide common drop-in is applied once by `hermes-agent-lock.sh --host` (chapter 3); this chapter
is the per-agent layer on top of it.
