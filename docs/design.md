# Design

This chapter explains **why** the setup is shaped the way it is, and **which script automates which
step**. It sits between the [Architecture](02-architecture.md) (what the host looks like) and the
work-package chapters (how each part is built, by hand). Every decision here is a trade-off, stated so
a reader can disagree with intent rather than guess at it.

## Decisions

- **The operating system is the boundary, not the prompt.** Each agent is a separate Linux user. An
  agent that is compromised or simply wrong cannot read another agent's files, use another agent's
  tokens, or reach a network it was not given, because the kernel enforces it. The threat model
  ([chapter 1](01-threat-model.md)) states what this does and does not cover.
- **An agent may not rewrite its own instructions.** `config.yaml`, `SOUL.md`, `.hermes.md` and `.env`
  are owned by root and carry the immutable attribute, even though they live in the agent's home.
  Without this, the agent could delete and replace them; with it, only root can. The lock tool clears
  the attribute, writes, and sets it again.
- **One source of truth: `platform.toml`.** Groups, `ReadWritePaths`, allowed environment variables
  and the unit drop-ins are all **derived** from it and **checked** against its rules — never kept by
  hand in a script or a role. Fixed IDs in a reserved range make ownership survive a rebuild or a
  restore. The alternative, maintaining the same facts in several places, drifts.
- **Explicit tool sets per platform.** A chat, a scheduled job, a task run and a call from another
  agent are different surfaces with different tools. The tool refuses to deploy an agent that relies on
  the full default bundle (terminal, code execution, browser) where it was not asked for.
- **Collaboration is explicit.** Agent-to-agent calls use one token per direction and stay within a
  domain unless an exception is declared. A Kanban board is a trust boundary: its workspaces are shared
  among all members, so zones that must not influence each other get separate boards.
- **In-place scripts now, Ansible later.** The host is brought to the target state by small,
  auditable shell scripts applied in place, not by a full provisioning framework. This reaches a
  publishable, hand-reproducible guide sooner. A later version can wrap these same scripts in Ansible;
  the end state is identical because it is defined by one contract (below), not by the mechanism.
- **`verify` is the contract.** `hermes-agent-verify.sh` defines the target state and checks it. A
  fresh host built step by step and an existing host hardened in place must both end **verify-green**.
  That is what makes "built by hand" and "built by a script" equivalent.

## Reproducible by hand

Every script in this repository automates a procedure that is written out, step by step, in its
chapter. Nothing is a black box: you can run the documented commands yourself and reach the same state,
and the script is only there to do it reliably and the same way every time. A future Ansible layer will
call the very same steps.

## Automation map

Which script automates which work package, and what stays manual:

| Work package | Chapter | By hand | Script |
| --- | --- | --- | --- |
| Threat model (reference) | 1 | — | — |
| Architecture (reference) | 2 | — | — |
| Host base and Hermes core | 3 | yes | — (a future Ansible role) |
| Local patches | 4 | `git apply` | `patches/apply-patches.sh` |
| Host groups and directories | 3 | yes | — (a future Ansible role) |
| Host ownership and hardening | 3 | — | `hermes-agent-lock.sh --host` |
| Create an agent | 5 | model-provider login | `hermes-agent-create.sh` |
| Harden an agent | 6 | — | `hermes-agent-lock.sh <agent>` |
| Verify (agent or host) | 3, 5, 6 | — | `hermes-agent-verify.sh [--host]` |
| Rule check of `platform.toml` | — | — | `hermes-agent-lib.py check` (used by the tools above) |

The tools own the parts that must be exact and checkable — ownership, permissions, the hardening
drop-ins, the ID rule and the isolation rules — and the manual steps are the ones a later Ansible role
will take over unchanged.
