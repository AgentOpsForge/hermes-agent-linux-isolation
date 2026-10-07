# 1 Threat model

This chapter states what running each Hermes Agent instance under its own Linux user protects against, what it
does not, and which assumptions the rest of the guide relies on. Read it before deciding whether this setup fits
your use.

## Starting point

Hermes Agent is a single-tenant personal agent. Its
[security policy](https://github.com/NousResearch/hermes-agent/blob/v2026.9.24/SECURITY.md) names the operating system
as the only security boundary against an adversarial model. Approval prompts, output redaction, tool allowlists
and instructions in files such as `SOUL.md` are useful, but they are not boundaries.

This guide runs **several** agents on **one** host. It uses the operating system boundary between them: each
agent is a separate Linux user with its own profile, its own systemd unit and its own credentials. If one agent
is misled or compromised, it should not be able to read, change or impersonate another.

## Assets

| Asset | Examples |
| --- | --- |
| Agent profile | configuration, memory, sessions, logs, state databases |
| Agent credentials | model provider tokens, messaging accounts, tokens between agents |
| Shared work items | Kanban boards that several agents use |
| Data the agents work on | notes, repositories, documents |
| Host code and configuration | Hermes Agent installation, extensions, systemd units, `/etc` |

## Adversary

The main adversary is **an agent that follows instructions it should not follow**. Every agent that reads
content from outside — web pages, mail, chat messages, tool and MCP results — can be steered by that content.
Assume such an agent acts with the full rights of its Linux user, through any code path: shell commands, code
execution, plugins, hooks and skills.

A second adversary is a faulty or malicious component inside one agent, for example a skill, plugin or MCP
server. It runs with the same rights as the agent that loaded it.

Out of scope: an attacker with root or administrator access to the host, physical access, a compromised model
provider, and a compromised Hermes Agent release.

## What the isolation protects

| Threat from one agent | Mechanism | Holds as long as |
| --- | --- | --- |
| Reading or changing another agent's profile, memory or credentials | one user and group per agent; profile mode `0700` | no group, ACL or shared directory grants access |
| Changing the shared code and extensions | owned by root, read-only for agents; `ProtectSystem=strict` | no file under `/opt`, `/usr/local` or `/etc` is owned by or writable for the agent |
| Changing its own configuration, instructions or keys (`config.yaml`, `SOUL.md`, `.hermes.md`, `.env`) | the files belong to root, are readable by the agent's group (`0640`) and carry the immutable attribute | the profile carries no ACLs; with an ACL, `chmod` only sets the mask and the agent may lose read access or keep write access |
| Sending signals to or tracing another agent | the kernel refuses this across users; no capabilities, `NoNewPrivileges=yes` | the agent gets no capabilities and no sudo rights |
| Seeing other agents' processes, command lines or environment | `ProtectProc=invisible` | the hardening is active for every agent unit |
| Reading files that others leave in `/tmp` | `PrivateTmp=yes` | as above |
| Reaching another agent through a side door | communication only through explicit interfaces: agent-to-agent calls with a token per pair of agents, Kanban boards with group permissions | each interface authenticates its caller |
| Using up memory or processes for everyone | `MemoryMax` and `TasksMax` per unit **and** per user slice | limits are set on both levels |

Locking these files has a visible effect: features with which an agent writes its own configuration — for
example "always allow" for a command, or setting a home channel — still work for the running process but are
no longer saved. Hermes Agent logs a warning and continues. Configuration changes are made by root.

Hermes Agent starts some work — Kanban workers, cron runs, background commands — through the user's own
systemd manager instead of the gateway unit. Those processes inherit the gateway's file system and privilege
restrictions, but their memory and process limits come from the user slice. The hardening chapter sets both.

## What the isolation does not protect

**The kernel is shared.** A kernel vulnerability crosses every user boundary on the host. Keep the kernel
patched. For agents that process untrusted input, consider wrapping the agent process in a container or
sandbox in addition, as the Hermes Agent security policy recommends.

**Root and administrators control everything.** Whoever has root, sudo or write access to the systemd units
controls all agents. Keep agent data and credentials out of the home directories of people, and do not give
agents sudo rights.

**Loopback and abstract sockets are open to all local users.** Any local process can connect to a TCP port on
`127.0.0.1` and to an abstract Unix socket; file permissions do not apply to either. Every local listener must
authenticate its callers, or must use a Unix socket in the file system with restrictive permissions. Without
per-user firewall rules, every agent can reach every loopback port.

**Outbound network access is not restricted.** By default every agent can reach the internet and the local
network. User isolation does not limit where an agent sends its own data. Per-user egress rules are covered in a
later chapter.

**An agent fully controls its own data and credentials.** A misled agent can leak or misuse everything its user
can read, including its own tokens and messaging accounts. It can also change everything in its profile that is
not locked — memory, sessions, skills it writes, cron jobs — and so influence its own later behaviour. Give each
agent only what its role needs, and keep long-lived keys out of agents where possible (see the credential pattern
chapter).

**The model provider sees what the agent sends.** Prompts, tool results and file contents leave the host. Host
isolation does not change this. Process sensitive data with a local model, in an agent that has no cloud model
configured.

**Shared provider accounts link agents.** Agents that share one provider account or token share its quota and,
at the provider, its history. Use one credential per agent.

**Deliberately shared data is a channel.** A directory, repository or Kanban board that two agents can write is a
path between them. Treat everything another agent wrote as untrusted input.

**Timing and other side channels** between processes on the same host are out of scope.

## Assumptions

The rest of the guide assumes:

1. The host — preferably a virtual machine — runs agents only. Administrators log in with their own accounts,
   and those accounts hold no agent data.
2. Hermes Agent and its extensions are installed by root and are read-only for the agents.
3. systemd runs the agent gateways and supports the hardening options used here.
4. Each agent has its own model provider credential and its own messaging accounts.

## Relation to the postures supported by Hermes Agent

The Hermes Agent security policy supports terminal-backend isolation and whole-process wrapping. Both confine an
agent from the host. Separate Linux users separate agents **from each other**. The approaches combine: an agent
can run as its own user and inside a sandbox at the same time. For agents that read content from sources you do
not control, whole-process wrapping remains the supported posture; this guide does not change that.
