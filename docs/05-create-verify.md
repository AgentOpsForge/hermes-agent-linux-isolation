# Creating and verifying an agent

With the host set up ([Host setup](03-host-setup.md)) and the patches applied ([Local patches](04-patches.md)),
each agent is created from its entry in `platform.toml` — never by editing files on the host by hand.
`hermes-agent-create.sh` changes the system but does **not** start the agent, and rolls back everything
it made if any step fails. After an interactive model login the agent is started, locked
([Hardening the units and user slices](06-hardening.md)) and verified. The examples use the agent
`worker` (user `worker-agent`, unit `hermes-gateway-worker`).

## Decide first — it all goes into `platform.toml`

| Decision | Rule |
| --- | --- |
| Name | `a-z0-9-`; yields the user `<name>-agent` and the unit `hermes-gateway-<name>` |
| ID and A2A port | UID = GID in the fixed range, `UID = base + (port − base_port)` ([Architecture](02-architecture.md)) |
| Model and provider | per agent; sensitive data only with a model that will not send it out |
| Toolsets | least privilege; `terminal`, `file`, `web` only with a stated reason |
| Zone | sets the domain, vault rights and A2A partners; the groups are derived from it |
| Kanban | a board plus `dispatch` dispatches only the agent's own tasks (needs linger) |
| Keys | none in `.env` except the A2A variables; the model login is interactive |
| RAM | sum of all `MemoryMax` plus headroom must fit the host's RAM |

## Creating — by hand, so it is reproducible

Each step below is what `hermes-agent-create.sh` automates:

1. **Define** the agent: the `[agents.<name>]` entry in `platform.toml` (both sides of any vault or A2A
   relation) and its role/`SOUL.md` text. Regenerate and check the repository's checksums.
2. **Create** (changes the system, does not start): `sudo bash hermes-agent-create.sh <name>`. It creates
   the system user and group, the profile directory (mode exactly `0700`, with no inherited setgid),
   `config.yaml`, `SOUL.md`, `.env` (only `A2A_AGENT_NAME` and `A2A_PORT` — no keys), linger, the unit,
   and the per-agent hardening drop-ins. It prints no secrets and rolls back on any failure. Exit codes:
   `0` created, `2` a pre-check failed and nothing was created, `3` failed and everything was removed
   again, `4` failed with the rollback incomplete (the log lists the commands to finish by hand).
3. **Log in at the model provider**, interactively, as the agent user — the exact command is printed at
   the end of the create run. Use `hermes model`, not `hermes auth add` (which writes only the root auth
   store and is silently discarded under the auth isolation).
4. **Start** the gateway.
5. **Lock** it ([Hardening the units and user slices](06-hardening.md)) — only *after* the login,
   because the login writes `config.yaml`, which the lock makes immutable.
6. **Verify** (read-only): `sudo bash hermes-agent-verify.sh <name>` — aim for zero failures.
7. **Functional test**: one test task on the agent's board or channel.

## Verifying — read-only

`hermes-agent-verify.sh <name> | --host | --all` changes nothing and prints no secrets (only variable
names from `.env`). It checks identity (uid, gid, groups), the profile (ownership, mode, no stray ACLs),
the locked instruction files, the units and drop-ins, the runtime (unit active, `HOME` correct, no
permission errors), isolation, and the config. Rights are always checked with a **real access attempt**
(reading and writing a byte), never with `test -r`/`-w` or mode bits, because those miss ACLs. Run
`--all` after any host-level change.

## What stays manual, per agent

The toolset handles the user, profile, config, unit and hardening. Operator-specific pieces are done by
hand and are outside the generic toolset: messaging channels, creating vault groups, network and egress
rules, A2A tokens (see the next section), the memory backend's workspace, and any scheduled jobs.

## A2A tokens

`hermes-agent-create.sh` writes only `A2A_AGENT_NAME` and `A2A_PORT` into `.env`; it does not set up
authentication between agents. Until a token is configured, an agent's A2A server answers an
unauthenticated request on its loopback port with `200` — any local user who can reach `127.0.0.1:<port>`
could call it. Configure a token for every caller→receiver pair so the receiver rejects tokenless calls
with `401`. `hermes-agent-verify.sh` checks exactly this: it reports the A2A check as OK only once the
server answers `401` without a token.

A token is a shared secret for one direction: caller *c* calling receiver *r* uses one value, held by
both. Use an independent 32-byte hex value per pair.

**Receiver** — set `A2A_PEER_TOKENS` on every agent that runs an A2A server (every agent with an `a2a`
port), listing the callers allowed to reach it (`<caller>:<token>[,<caller>:<token>]`). With `worker`
allowed to call `assistant`:

```sh
# as root; the profile is locked, so clear the immutable flag, append, re-lock
TOK=$(openssl rand -hex 32)                 # keep this value — the caller needs the same one
chattr -i /var/lib/hermes/profiles/assistant/.env
printf 'A2A_PEER_TOKENS=worker:%s\n' "$TOK" >> /var/lib/hermes/profiles/assistant/.env
bash hermes-agent-lock.sh assistant         # restores owner, mode and the immutable flag, then re-checks
```

**Caller** — the caller holds the same value in its own `.env` as `A2A_TOKEN_<TARGET>` and references it
from `config.yaml`, so the secret never appears in the config:

```sh
# .env of the caller (worker): the token for calling assistant
chattr -i /var/lib/hermes/profiles/worker/.env
printf 'A2A_TOKEN_ASSISTANT=%s\n' "$TOK" >> /var/lib/hermes/profiles/worker/.env
bash hermes-agent-lock.sh worker
```

```yaml
# config.yaml of the caller (worker): address the target and read the token from the environment
a2a_agents:
  assistant:
    url: http://127.0.0.1:9900
    auth:
      type: bearer
      token: "${env:A2A_TOKEN_ASSISTANT}"
```

`hermes-agent-create.sh` does not generate the caller's `a2a_agents` block — which agents an agent calls,
and how it addresses them, depends on the role and is added by hand (or by the model's own configuration).
Add one block per target, and a matching `A2A_PEER_TOKENS` entry on each receiver. Re-run the lock after
every `.env` or `config.yaml` change so the file returns to the hardened, immutable state.

## Common pitfalls

- **Editing a config after locking:** as root `chattr -i <file>`, edit, then re-run the lock — it
  restores owner, mode and the immutable flag and re-checks.
- **`SOUL.md` changes** load per conversation: start a new conversation for them to take effect.
- **`gateway.standalone` must be `false`;** the multiplex pre-check patch keeps the start quiet
  ([Local patches](04-patches.md)).
- **Kanban workers need linger** on the agent user, or the worker scopes never start.
- **A profile under a setgid parent** inherits setgid; create sets the mode exactly rather than trusting
  `chmod 0700`, which leaves setgid on a directory.
- **Check rights with a real access attempt**, never just `test -r`/`-w` — mode bits miss ACLs.

## Removing an agent

```sh
sudo systemctl disable --now hermes-gateway-<name>
sudo rm /etc/systemd/system/hermes-gateway-<name>.service
sudo rm -rf /etc/systemd/system/hermes-gateway-<name>.service.d \
            /etc/systemd/system/user-"$(id -u <name>-agent)".slice.d
sudo loginctl disable-linger <name>-agent
sudo systemctl daemon-reload
# back up the profile, then unlock and remove it; the user goes last
sudo tar -C /var/lib/hermes/profiles -czf /var/backups/hermes/<name>-profile-"$(date +%F)".tgz <name>
sudo chattr -i /var/lib/hermes/profiles/<name>/{config.yaml,SOUL.md,.hermes.md,.env} 2>/dev/null || true
sudo rm -rf /var/lib/hermes/profiles/<name>
sudo userdel <name>-agent
```

## What is automated

| Step | By hand | Script |
| --- | --- | --- |
| Define the agent | edit `platform.toml` and write its `SOUL.md` | — |
| Create user, profile, config, unit, hardening | — | `hermes-agent-create.sh <name>` |
| Model-provider login | interactive, as the agent user | — |
| Lock to the hardened state | — | `hermes-agent-lock.sh <name>` ([Hardening](06-hardening.md)) |
| Verify the result | — | `hermes-agent-verify.sh <name>` |
| A2A tokens (if the agent has peers) | edit `.env` + `config.yaml`, then re-lock | — |
