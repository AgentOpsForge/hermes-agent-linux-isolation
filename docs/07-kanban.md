# Collaboration through Kanban

Isolated agents still have to work together. They do it in two ways, and keeping them apart is what
makes the isolation hold: a **request** asks for information and changes nothing; a **task** asks for
work that changes data. Requests go over agent-to-agent calls, tasks over a Kanban board. This chapter
is about tasks. The examples use the domain `team`, its board `team`, the orchestrator `assistant` and
the workers `worker` and `analyst`.

| | Request | Task |
| --- | --- | --- |
| Carrier | agent-to-agent call | Kanban board |
| Result | an answer | a work product or a change |
| Changes data | never | yes, within the task |

If answering a request needs a change, the orchestrator turns it into a task.

## A board is a trust boundary

A board belongs to exactly one domain. Its members are the domain's `kanban-<domain>` group. Hermes
stores each task's workspaces under `boards/<board>/workspaces/<task>/`, readable and writable by
**every** member of the board: a follow-up task — even one run by a different agent — reads the
hand-off left in the previous task's workspace, and whoever closes or archives a task deletes its
workspace. That sharing is by design and cannot be narrowed per task without breaking hand-offs.

The consequence for isolation: zones that may collaborate share a board; zones that must **not**
influence each other get **separate boards**, each with its own group. The credential service
(`github`) reaches a board through an ACL, not through group membership, so it can sync the board
without being a full member.

## The task flow

```text
schedule or request
  └─▶ orchestrator creates the task (board of the domain, assignee = a worker)
        └─▶ worker does the work ─▶ hands it back for review (request review)
              └─▶ orchestrator reviews
                    ├─ fine ──────▶ record result and answers in the task ─▶ done
                    ├─ question ──▶ ask (call or comment) ─▶ record the answer in the task
                    └─ rework ────▶ back to the worker (request changes)
```

- **Workers never close a task.** They hand it back with a review request.
- **Only the orchestrator closes** a task (`done`), after any open question is answered and recorded.
- **Follow-up work** on a closed task is a new child task, not a reopen.
- **Schedules live only with orchestrators.** A schedule creates a task; it does not do worker work.

## Dispatch with separate Linux users

By default Hermes runs **one** dispatcher per Kanban home, and it starts workers for **all** assignees
under its own user — it treats Kanban as a single-user feature. That breaks the isolation: a dispatcher
running as `worker-agent` cannot correctly start a worker that must run as `analyst-agent`.

This guide therefore has **each agent dispatch only its own tasks** (local patch P-03, see the
[patches](../patches/README.md)): the dispatcher considers only tasks whose assignee is its own
profile and holds one lock per profile. Every agent that has tasks runs with
`kanban.dispatch_in_gateway: true` in its `config.yaml` (set from `platform.toml`).

Each dispatching gateway still scans **all** of the board's running tasks every tick for dead workers.
Under `ProtectProc=invisible` a worker owned by another agent is invisible and would look dead. Local
patch P-08 treats "no permission" from `kill -0` (`EPERM`) as "alive, owned by another agent"; only the
owning gateway ever acts on its own worker.

## Upstream direction

Hermes upstream is moving toward multiplexing — one process serving all profiles under **one** Linux
user, with separation only in-process. That is in tension with this guide's model of one gateway per
Linux user. It is not triggered automatically, but it is the reason patches P-03/P-04 are kept local
rather than submitted. See "Limits and known issues" for how to weigh it.

## What is automated

| Step | By hand | Script |
| --- | --- | --- |
| Board group membership | host setup (chapter 3) | — (a future Ansible role) |
| Per-profile dispatch (`dispatch_in_gateway`) | — | `hermes-agent-create.sh` (from `platform.toml`) |
| Patches P-03 (dispatch lock) and P-08 (foreign worker) | `git apply` | `patches/apply-patches.sh` |
| Check dispatch and board access | — | `hermes-agent-verify.sh` |
