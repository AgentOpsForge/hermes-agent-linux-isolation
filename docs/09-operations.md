# Operations — updates, checks, backup

Three things change over time: the operating system, Hermes itself, and the agent definitions. Each
has a path that keeps the isolation intact. The one rule that underlies all of them: **agents never
update themselves** — they have no write access to `/opt` and no `sudo`, so every change to the code
is made by an administrator as `root`.

## Updating Hermes

Do **not** use `hermes update`. It tracks a branch instead of a release tag, parks or discards local
changes (your patch series), and restarts gateways on its own. Pin a release tag and update by hand:

1. Pick the target tag. Read the changelog since the pinned version and check whether each local patch
   is still needed — some may already be upstream (see "Limits and known issues", chapter 10).
2. Snapshot the host or VM.
3. Back up each agent's state.
4. Stop all gateways.
5. As `root`: `git fetch --tags`, `git checkout <tag>`, then apply the patch series
   (`patches/apply-patches.sh`). A conflict means stop and roll back — never force it.
6. As `root`, reinstall and compile bytecode:
   `uv pip install --compile-bytecode -e ".[all]"`, then `python -m compileall -q <tree>` — the agents
   cannot write `__pycache__` themselves.
7. Restore ownership and modes across the tree: `hermes-agent-lock.sh --host`.
8. Run each agent's config migration. Migrations run **as the agent**, because they write into the
   profile; fold the result back into your platform repository.
9. Deploy the definitions from the platform repository.
10. Start gateways one at a time and smoke-test each: unit active, agent reachable, one test request, no
    new errors in the log.
11. Record the new tag in your platform config.

**Code ownership.** `/opt/hermes-agent` is owned entirely by `root:root`; agents and admins only read.
Every writing step (git, `uv`, patches, `compileall`) runs as `root`. Only migrations run as the agent.

**Read-only data root.** `/var/lib/hermes` and the profiles under it are read-only to agents, and a
shared board is reached through a symlink. A migration that tries to create a file *next to* the
database in the root will fail. Read such a migration in source first, run it deliberately as `root`,
never widen the group's rights, then run `hermes-agent-lock.sh --host` again.

**Migrations can turn features on.** A migration may enable a toolset you do not want. Read new
migrations before running them; disable the toolset per agent in `config.yaml` before migrating.

**Rollback.** Check out the previous tag, re-apply the patches, reinstall, restore the state backup,
start the gateways. If a database migration has already run, the host snapshot is the real rollback.

## Checking

`hermes-agent-verify.sh --all` checks the host layer and every agent — ownership, groups, immutable
instruction files, drop-ins, and the running gateways. Run it after every change, and run the per-agent
smoke test from the update procedure.

## Logs

Logs go to journald per unit and to `logs/` in each agent's home, kept about 30 days. With
`security.redact_secrets: true` set, log lines carry no secret values.

## Monitoring

Monitoring runs **outside** the agents and alerts over a channel that does not depend on any agent — an
agent that misbehaves must not be able to suppress its own alarm. Watch at least: gateway units active
and agents reachable; for each scheduled job, the age of the last good run and any error streak; backup
and vault-sync freshness; memory, disk, and unit restarts. The guide fixes the independence
requirement; the stack itself is yours to choose.

## Backup and recovery

| What | How | How often |
| --- | --- | --- |
| Whole host or VM | snapshot | daily |
| Agent state (`profiles/`, `kanban/`) | file backup to a backup dir, plus an off-host copy | daily |
| Vault repositories | their Git host | continuous |
| Platform repository | its Git host | continuous |

Test recovery regularly. A rebuild **takes no runtime data**: no sessions, memory, Kanban data,
agent-to-agent history, logs, or scheduler state carry over. Only the definitions (from the platform
repository) and the vaults come back; everything stateful starts empty. That is deliberate — runtime
state is disposable, identity and definitions are version-controlled.

## What is automated

| Step | By hand | Script |
| --- | --- | --- |
| OS updates | unattended security upgrades, reboot in a window | — |
| Hermes core update | the manual procedure above | `patches/apply-patches.sh` |
| Post-update ownership and checks | — | `hermes-agent-lock.sh --host`, `hermes-agent-verify.sh --all` |
| Deploying agent definitions | from the platform repository | — (a future Ansible role) |
| Backup and monitoring | operator-implemented | — |
