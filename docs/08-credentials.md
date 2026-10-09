# Credential pattern: a dedicated service holds the keys

The isolation only holds if a compromised or mistaken agent cannot reach keys that are not its own.
So no agent holds a shared or service credential. Secrets that belong to one agent live in that
agent's profile; the keys that act on shared resources (a Git host, a deploy target) are held by a
**dedicated service** that runs no model, does only a fixed set of operations, and performs any
changing one only after a person approves it. The example service in `platform.toml` is `github`.

## Where an agent's secrets live

| Kind | Location | Owner / mode |
| --- | --- | --- |
| Static secrets | `<home>/.env` | `root:<agent>-agent` `0640`, immutable |
| Rotating OAuth data | `<home>/auth.json` | `<agent>-agent` `0600` |
| Tool tokens | `<home>/tools/<tool>/` | `<agent>-agent` `0700` |

Rules: one secret belongs to exactly one agent; no shared tokens (agent-to-agent tokens are per
caller→callee pair); never in a vault, in a repository, in a log, or under another agent's or a
person's home. `config.yaml` holds no secret values — it refers to them with `${env:NAME}`, which
Hermes resolves against the profile's `.env`. Document each secret's name, purpose, owner, location and
rotation — never its value.

## The service holds the keys

- A dedicated system user (example `github`, declared under `[services]` in `platform.toml`): `nologin`,
  no `sudo`, home `0700`. It holds the deploy keys; no agent does.
- One SSH deploy key per repository and purpose, in the service's home, chosen by an SSH alias in its
  own `ssh/config`, with the host key pinned in `known_hosts`. Git runs with `BatchMode=yes` and a
  timeout — never an interactive prompt.
- The service is a member only of the `vault-*-rw` groups it needs, and reaches a Kanban board through
  an ACL rather than full membership.

## A fixed catalog, not free commands

The service runs only operations from a catalog that is root-owned and read-only to it; changes to the
catalog go through the normal review-and-merge, not through the service. Parameters come only from
fixed value lists (which repository, which strategy) — never free text passed to Git or a shell.
Operations are classed `auto` (read-only or routine) or `approval` (changing). Destructive operations
(force-push, delete) are not in the catalog at all.

## Approval with a kernel-verified sender

A changing operation needs the person's approval, and the approval is trusted because the **kernel**
vouches for who sent it, not because a message says so:

1. The person approves (for example by replying with the number of a listed option). A relaying agent
   writes the approval as a file into a spool directory.
2. The service picks the file up without following symlinks, and checks: the file's **owner** — set by
   the kernel — is the expected relaying agent; the operation and its parameters are in the catalog;
   the state has not changed since the request. Only then does it run the operation and log the result.
3. The relaying agent only carries the decision; it holds no key and performs no write. Because the
   catalog has no destructive options, even a forged approval can only choose between harmless ones.

## What the toolset does, and what you implement

`platform.toml` declares the service user and the groups it belongs to; the host setup
([chapter 3](03-host-setup.md)) creates them, and `hermes-agent-lock.sh` keeps each agent's `.env`
root-owned and immutable. The catalog runner and the approval spool themselves are **not** shipped as a
generic script in this repository — they are implemented to each operator's need. This chapter defines
the security properties they must have: keys only in the service, a fixed catalog, fixed parameters, no
destructive actions, and a sender verified by the kernel.

## What is automated

| Step | By hand | Script |
| --- | --- | --- |
| Service user and group memberships | host setup (chapter 3) | — (from `platform.toml`) |
| Agent `.env` kept root-owned and immutable | — | `hermes-agent-lock.sh <agent>` |
| Catalog runner and approval spool | operator-implemented | — |
| Check that agents hold no service keys | — | `hermes-agent-verify.sh` |
