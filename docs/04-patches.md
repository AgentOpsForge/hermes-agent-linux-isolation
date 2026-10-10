# Local patches

The guide applies a small series of source patches to Hermes before install. They exist for two
reasons, both coming straight from the isolation model: it needs behaviour the upstream single-user
assumption does not provide, and its hardening — a read-only data root, `ProtectProc=invisible` —
exposes bugs that never show without it. The patches live in [`patches/`](../patches/README.md) as
`git diff` files against the pinned release tag and are applied as the patch step of the Hermes build
([Operations](09-operations.md)).

## Why patch at all

One Linux user and one gateway per agent, a read-only data root, and hidden processes together diverge
from upstream's single-user and multiplexing assumptions. Rather than fork Hermes, the guide keeps a
**minimal diff series** that is re-applied on every upgrade and shrinks as fixes land upstream.

## The three kinds

- **Already upstream** — not carried at all. Two earlier fixes (an auth-store fix and a plugin-toolset
  fix) are in upstream main and are therefore not in the series.
- **Submitted upstream** — bug fixes for problems that only surface under this hardening. They will be
  dropped when the fix ships, and are re-cut against each new version rather than replayed as an old
  diff.
- **Deliberate divergences** from upstream's direction — kept local indefinitely and not submitted. The
  multiplexing tension behind this is in [Limits and known issues](10-limits.md).

## What each patch does

**Deliberate divergences (kept local):**

| Patch | Topic | Why the isolation model needs it |
| --- | --- | --- |
| P-03 | per-user dispatch | each agent dispatches only its own tasks; upstream assumes one dispatcher per board under one user ([Kanban](07-kanban.md)) |
| P-04 | multiplex quiet | a gateway that cannot read another profile — by design, under the hardening — serves only its own profile instead of crashing |
| P-05 | hosted rooms per profile | the group-chat database lives per profile, not as one shared file in the read-only data root |

**Bug fixes (submitted upstream):**

| Patch | Topic | What it fixes |
| --- | --- | --- |
| P-06 | preflight follows symlink | the writability check follows a board symlinked under the read-only root instead of testing the symlink's own directory |
| P-07 | kanban lock via symlink | lock files land at the symlink target, not beside the symlink in the read-only root — otherwise the dispatch lock silently becomes a no-op |
| P-08 | foreign-worker liveness | a worker owned by another agent, invisible under `ProtectProc=invisible`, counts as alive (`EPERM`), not dead |

The exact target file per patch is in [`patches/README.md`](../patches/README.md).

## Applying

By hand, from a checkout at the pinned tag, apply them in order:

```sh
git -C /path/to/hermes-agent apply patches/p03-dispatch-lock.diff
# … p04, p05, p06, p07, then P-08 …
```

Automated, the helper checks every patch with `git apply --check` first and applies them in order, or
changes nothing if one does not apply cleanly:

```sh
./patches/apply-patches.sh /path/to/hermes-agent
```

This is the patch step of the Hermes build and of every update ([Operations](09-operations.md)).

## Maintenance

Re-evaluate the whole series at every upgrade ([Operations](09-operations.md), step 1): drop what is now
upstream, re-cut the bug fixes against the refactored files, keep the divergences. Never carry a patch
that the new version already includes — a stale patch is how an upgrade silently breaks.

## What is automated

| Step | By hand | Script |
| --- | --- | --- |
| Apply the series to a checkout | `git apply` each file in order | `patches/apply-patches.sh` |
| Re-evaluate the series at an upgrade | read the changelog, check each patch | — |
| Verify the running result | — | `hermes-agent-verify.sh` ([Operations](09-operations.md)) |
