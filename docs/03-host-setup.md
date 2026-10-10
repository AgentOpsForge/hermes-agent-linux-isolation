# Host setup

This chapter builds the host base that agents are later created on: packages, the Hermes core, the
local patches, the platform groups and the directory root. Every step is done by hand and is meant to
be reproducible by hand; where a script automates a step, it is named. The last two steps hand the
ownership, permissions and hardening to the tool and then check the result.

All examples use the neutral configuration from [`platform.toml`](../platform.toml) (`example-host`,
domain `team`, agents `assistant`, `worker`, `analyst`). The values — IDs, group names, paths — come
from that file; see the [Architecture](02-architecture.md) chapter for the full model. Target a Linux
host with `systemd` (Debian or Ubuntu in the examples). Run every command as root (`sudo`).

## 1. Packages

```sh
apt-get update
apt-get install -y git acl e2fsprogs python3 python3-venv
# uv (the Python installer Hermes uses); pin a version and install system-wide as root:
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
```

- `acl` provides `setfacl` (traversal entries for agents), `e2fsprogs` provides `chattr`/`lsattr` (the
  immutable attribute on profile files).
- **Python version.** The tools need Python 3.11 or newer (`tomllib`). Hermes itself requires
  `>=3.11,<3.14`, and a current distribution may ship a newer default — Ubuntu 26.04 ships 3.14, which
  is too new. The host's `python3` may also sit under a path the agent users cannot reach. Step 2
  therefore builds the venv from a pinned, supported Python that `uv` installs in a world-readable
  location, rather than from the system `python3`.
- `uv` is installed under `/usr/local/bin`, owned by root. Never use a `uv` from a user's home.

## 2. Hermes core

Install the version this guide targets (see the README, "Tested versions") into `/opt/hermes-agent`,
owned by root. Agents only read it; they have no write access and no `sudo`, so they cannot update
themselves.

```sh
install -d -o root -g root -m 0755 /opt/hermes-agent
git clone --depth 1 --branch v2026.9.24 https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent
cd /opt/hermes-agent
```

Build the venv from a pinned, supported Python that `uv` installs in a **world-readable** location, so
the agent users can execute it (they run the interpreter). A Python under a user's home — for example
`uv`'s default `~/.local` — is not reachable (`/root` is mode `0700`):

```sh
# a supported Python (choose a version inside >=3.11,<3.14), installed world-readable:
UV_PYTHON_INSTALL_DIR=/opt/uv-python uv python install 3.13
chmod -R a+rX /opt/uv-python
# build the venv from exactly that interpreter, then install Hermes:
uv venv --python "$(echo /opt/uv-python/cpython-3.13.*/bin/python3.13)" venv
uv pip install --python venv/bin/python --compile-bytecode -e ".[all]"
venv/bin/python -m compileall -q .
# uv leaves world-writable lock files in both trees; the install tree must not be agent-writable:
chmod o-w venv/.lock /opt/uv-python/.lock 2>/dev/null || true
```

- The interpreter must be readable and executable by the agent users. A Python under `/root` (mode
  `0700`) is not reachable — build from a world-readable path such as `/opt/uv-python`.
- `compileall` writes the bytecode caches now, as root: agents cannot write `__pycache__` later.
- Do **not** use `hermes update`. It follows the `main` branch instead of a tag, parks or discards
  local changes, and restarts gateways on its own. Updates are done by hand against release tags.

### Command scanner (`tirith`) system-wide

Hermes looks for a command scanner `tirith` (alongside `uv`/`uvx`) in `PATH` and, if it is missing,
downloads it into the agent's profile — where the agent could later replace it. Install it once,
root-owned, system-wide, so Hermes finds it in `PATH` first and never writes it into a profile. Let
Hermes fetch it (its own installer verifies the release), into a throwaway home, then move it into
place:

```sh
install -d -m 0700 /tmp/tirith-stage
HERMES_HOME=/tmp/tirith-stage venv/bin/python \
  -c 'from tools.tirith_security import _install_tirith; print(_install_tirith())'
install -o root -g root -m 0755 /tmp/tirith-stage/bin/tirith /usr/local/bin/tirith
/usr/local/bin/tirith --version
rm -rf /tmp/tirith-stage
```

## 3. Local patches

Apply the local patches against the checkout (details in the [patches overview](../patches/README.md)).
Run this from your clone of this repository:

```sh
bash patches/apply-patches.sh /opt/hermes-agent
```

Automated by `patches/apply-patches.sh` (it runs `git apply --check` on every patch, then applies them
in order). To apply one by hand: `git -C /opt/hermes-agent apply patches/p06-preflight-symlink.diff`.

## 4. Groups and the service user

Create the platform groups at the fixed GIDs from `platform.toml`, and the credential service user.
Fixed IDs mean ownership still matches after a rebuild or a restore. Agent **users** are not created
here — that is `hermes-agent-create.sh` (chapter "Creating and verifying an agent").

```sh
# Kanban group of the domain, and the vault groups (rw, ro) — GIDs from platform.toml:
groupadd --system -g 2110 kanban-team
groupadd --system -g 2120 vault-team-wiki-rw
groupadd --system -g 2121 vault-team-wiki-ro

# Credential service "github" (holds deploy keys; member of every vault-*-rw):
groupadd --system -g 2091 github
useradd  --system -u 2091 -g github -d /var/lib/github -M -s /usr/sbin/nologin github
```

- The platform uses fixed IDs in the 2000–2199 range, above the system-account range. `useradd
  --system` with such a UID prints `uid 2091 is greater than SYS_UID_MAX 999` — that warning is
  expected and the user is created correctly.
- `hermes-agent-verify.sh --all` later checks that the groups and their members match `platform.toml`.

## 5. Base directories

```sh
install -d -o root   -g root        -m 0711 /var/lib/hermes
install -d -o root   -g root        -m 0711 /var/lib/hermes/profiles
install -d -o root   -g kanban-team -m 2770 /var/lib/hermes/kanban
install -d -o github -g github      -m 0700 /var/lib/github
install -d -o root   -g root        -m 0755 /srv/vaults
# one directory per vault under vaults_root, group-owned by the vault's rw group (setgid):
install -d -o root   -g vault-team-wiki-rw -m 2770 /srv/vaults/team-wiki
install -d -o root   -g root        -m 0700 /var/backups/hermes
```

- `/var/lib/hermes` and `profiles/` are `0711`: every user may traverse them, nobody may list them. The
  next step fixes their ownership and removes any ACLs.
- The Kanban home is group-owned by `kanban-team` with the setgid bit (`2770`) so new entries inherit
  the group. A vault directory must exist before an agent that is `rw`/`ro` on it is created, because
  that path is one of the agent's `ReadWritePaths`; the vault's Git content is set up with the
  credential service (chapter "Credential pattern").

### The default Kanban board

Hermes keeps the default board's database at `<root>/kanban.db` — which is the read-only state root. Put
the real database in the writable Kanban home, leave only a symlink in the root, and grant the Kanban
group write access with a default ACL so every member can share the board:

```sh
# the default board lives in the writable Kanban home; the state root holds only a symlink to it
install -d -o root -g kanban-team -m 2770 /var/lib/hermes/kanban/default
ln -s kanban/default/kanban.db /var/lib/hermes/kanban.db

# a shared SQLite board must be group-writable; a default ACL grants that on the files Hermes creates
# later. setgid only inherits the group, and SQLite creates its files 0644 -> 0640 under the gateway
# umask, so the group would otherwise get no write bit. The local patches put the board's lock files at
# the symlink target, so they land in this writable directory too.
setfacl -R    -m g:kanban-team:rwX /var/lib/hermes/kanban
setfacl -R -d -m g:kanban-team:rwX /var/lib/hermes/kanban
```

Without this, a gateway fails every dispatcher tick with `kanban.db ... is read-only for this user` (the
init lock lands in the read-only root, or the shared database is not group-writable).

## 6. Ownership and hardening — `hermes-agent-lock.sh --host`

```sh
bash hermes-agent-lock.sh --host
```

This sets `/var/lib/hermes` and `profiles/` to `root:root 0711` (removing stray ACLs), moves any
foreign entries out of the root into a backup, and installs the common gateway hardening drop-in
`hermes-gateway-.service.d/10-hardening.conf` from `units/hermes-gateway-hardening.conf`. It refuses to
run and changes nothing if a precondition is missing (for example a group from step 4). This is the
host-layer counterpart to locking a single agent (chapter "Hardening the units and user slices").

## 7. Verify — `hermes-agent-verify.sh --host`

```sh
bash hermes-agent-verify.sh --host
```

The host layer must report no missing items before any agent is created. From here, create agents one
by one with `hermes-agent-create.sh` (chapter "Creating and verifying an agent").

## What is automated

| Step | By hand | Script |
| --- | --- | --- |
| 1 Packages | yes | — (a future Ansible role) |
| 2 Hermes core, venv, `tirith` | yes | — (a future Ansible role) |
| 3 Local patches | `git apply` | `patches/apply-patches.sh` |
| 4 Groups and service user | yes | — (a future Ansible role) |
| 5 Base directories | yes | — (a future Ansible role) |
| 6 Ownership and hardening | — | `hermes-agent-lock.sh --host` |
| 7 Verify | — | `hermes-agent-verify.sh --host` |

Steps 1, 2, 4 and 5 are manual for now; a later version will automate them with Ansible around exactly
these same commands. The tool owns the parts that must be exact and checkable: ownership, permissions,
the hardening drop-in, and verification.
