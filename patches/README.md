# Local patches

Local source patches against Hermes Agent `v2026.9.24` (0.21.5), needed for the setup described in
this guide. Each file is a `git diff` against the upstream source tree.

## Applying

From a Hermes Agent checkout at tag `v2026.9.24`, run the helper from this directory:

```sh
./apply-patches.sh /path/to/hermes-agent
```

It checks every patch with `git apply --check` first and applies them in order (P-03 … P-08), or
stops without changing anything if one does not apply cleanly. To apply a single patch by hand:

```sh
git -C /path/to/hermes-agent apply patches/p06-preflight-symlink.diff
```

## Patches

| Patch | Target file | Topic | Upstream status |
| --- | --- | --- | --- |
| P-03 | `gateway/kanban_watchers.py` | dispatch lock | kept local (differs from upstream direction) |
| P-04 | `hermes_cli/gateway_multiplex_mode.py` | multiplex quiet | kept local (differs from upstream direction) |
| P-05 | `gateway/hosted_rooms.py` | hosted rooms per profile | kept local (differs from upstream direction) |
| P-06 | `hermes_state_repair.py` | preflight follows symlink | submitted upstream |
| P-07 | `hermes_cli/kanban_db_connect.py` | kanban lock files via symlink | submitted upstream |
| P-08 | `hermes_cli/kanban_db_dispatch.py` | foreign-worker liveness under hidepid | submitted upstream |

Two earlier patches (an auth-store fix and a plugin-toolset fix) are already fixed in upstream main
and are not included here. P-03–P-05 are local choices that differ from the upstream direction;
P-06–P-08 have been submitted upstream.
