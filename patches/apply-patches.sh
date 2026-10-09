#!/usr/bin/env bash
# apply-patches.sh — apply the local Hermes patches in this directory to a Hermes Agent checkout.
# Generic: no host-specific assumptions. Checks every patch first, then applies them in order;
# if any patch does not apply cleanly, nothing is changed.
# Usage: ./apply-patches.sh /path/to/hermes-agent
set -euo pipefail

repo=${1:-}
[ -n "$repo" ] || { echo "usage: $0 /path/to/hermes-agent" >&2; exit 1; }
[ -d "$repo/.git" ] || { echo "not a git checkout: $repo" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
order=(p03-dispatch-lock.diff p04-multiplex-quiet.diff p05-hosted-rooms-per-profile.diff \
       p06-preflight-symlink.diff p07-kanban-lock-symlink.diff P-08-kanban-foreign-worker.diff)

patches=()
for p in "${order[@]}"; do
  [ -f "$here/$p" ] && patches+=("$here/$p")
done
[ "${#patches[@]}" -gt 0 ] || { echo "no patch files found next to $0" >&2; exit 1; }

echo "Checking ${#patches[@]} patches against $repo ..."
for p in "${patches[@]}"; do
  git -C "$repo" apply --check "$p" || { echo "does not apply cleanly: ${p##*/}" >&2; exit 1; }
done

echo "All patches check out. Applying ..."
for p in "${patches[@]}"; do
  git -C "$repo" apply "$p"
  echo "  applied ${p##*/}"
done
echo "Done."
