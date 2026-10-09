# Limits and known issues

This model buys a real operating-system boundary between agents. It is worth being honest about what it
costs, what it does not protect against, and one upstream direction that may eventually force a choice.

## The patch series is a maintenance burden

The guide relies on a small series of local patches. They fall into three kinds, and each upgrade you
re-evaluate all of them (step 1 of [Operations](09-operations.md)):

- **Already fixed upstream** — remove at the next upgrade; do not carry them forever.
- **Workarounds for upstream bugs** — reported upstream; drop each when its fix lands. Because the files
  are refactored upstream, re-cut these against the new version rather than replaying an old diff. The
  `patches/` series records which issue each one tracks.
- **Deliberate divergences** from upstream's direction — kept local indefinitely and **not** submitted,
  because they would be rejected. The next section is why.

## The multiplexing tension

Upstream is moving to **multiplexing as the only mode**: one process serves all profiles under **one**
Linux user, with separation only in-process (context variables, secret scrubbing) — no per-profile uid,
namespace, cgroup or container, and Kanban workers running as that same one user. Upstream states the
intent openly: the goal is confidentiality *between* profiles, not containing a hostile agent; the
kernel-enforced boundary (`User=`, file ownership) is replaced by in-process isolation as "the
operator's choice."

This guide's whole model — one Linux user and one gateway per agent — is exactly the topology upstream
is retiring (the standalone mode is marked temporary). That is why the dispatch-related patches are kept
local and not submitted.

It is **not** forced today: migration never crosses a user boundary on its own, you fold a setup into
multiplexing only with an explicit force flag, and you can lock that off in config. The risk is the
future — standalone is marked for removal. Three ways to weigh it:

1. **Stay on per-user standalone** (a pinned version plus the local patches) — recommended while it
   works; you own the maintenance.
2. **Accept multiplexing** — in-process separation plus the terminal-backend sandbox only. This gives up
   the OS-level boundary this guide is built on.
3. **Move isolation into a container per agent** — keeps a kernel boundary without fighting upstream; a
   larger change, kept as a plan B.

Pick deliberately and write the decision down. Do not let an upgrade decide it for you.

## What user isolation does not give you

- **It is not a kernel sandbox against a hostile agent.** The boundary is users, groups, ownership and
  systemd hardening — not a VM per agent. All agents share one kernel; a kernel or hypervisor exploit
  crosses the line. It raises the cost of lateral movement; it does not make it impossible.
- **Kanban workspaces are shared per board.** The trust boundary is the board, not the task: every board
  member can read and delete every task's workspace. It cannot be narrowed per task
  ([Collaboration through Kanban](07-kanban.md)).
- **No rename across `ReadWritePaths` mounts** (`EXDEV`) — read, write and delete, do not move
  ([Hardening the units and user slices](06-hardening.md)).
- **A migration that writes next to the database in the read-only data root fails** — read it and run it
  deliberately as root ([Operations](09-operations.md)).
- **Immutable instruction files need `chattr -i`/`+i` to edit by hand** (the lock does this for you).
- **Workers owned by another agent are invisible under `ProtectProc=invisible`** and look dead without
  the foreign-worker patch ([Collaboration through Kanban](07-kanban.md)).

## Scale and cost

- Every agent is a Linux user **plus** a gateway unit, drop-ins and a slice. More agents means more
  systemd units and more review surface — not more work sharing one process.
- The example ID scheme bounds how many agents fit; choose the range for your expected maximum up front.
- This is heavier than in-process multiplexing **by design**: you trade shared processes for a real OS
  boundary.

## Out of scope here

- Network egress rules, the monitoring stack, and the credential service's catalog runner are
  operator-implemented; the guide fixes the requirements, not the implementation.
- Automated provisioning is planned, not shipped. Today every procedure is reproducible by hand with the
  helper scripts.

## Where each limit is handled

| Limit | Handled in |
| --- | --- |
| Patch maintenance across upgrades | `patches/`, [Operations](09-operations.md) step 1 |
| Shared board workspaces | [Collaboration through Kanban](07-kanban.md) |
| No cross-mount rename | [Hardening the units and user slices](06-hardening.md) |
| Read-only data root during migrations | [Operations](09-operations.md) |
| Foreign workers invisible under `hidepid` | foreign-worker patch, [Kanban](07-kanban.md) |
| Multiplexing direction | this chapter — a decision to record, not a script |
