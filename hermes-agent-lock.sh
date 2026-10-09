#!/usr/bin/env bash
# hermes-agent-lock.sh - CHANGES THE SYSTEM. Brings one isolated Hermes agent, or the host-wide part,
# to the state defined in platform.toml and units/, verifies the result and rolls back on failure.
# Idempotent: a second run changes nothing; a run after drift corrects only the deviations.
#
# Usage:  sudo bash hermes-agent-lock.sh <agent>   per-agent layers L1-L3, then runtime checks (L4)
#         sudo bash hermes-agent-lock.sh --host    host-wide layer: common hardening drop-in for all gateways,
#                                                  install tree root-owned, state root and kanban homes as defined,
#                                                  kanban groups named, admins out of agent/vault/kanban groups
# Exit:   0 locked (changed or already as defined)    1 usage or environment error, nothing changed
#         2 pre-check failed, nothing changed           3 failed, all changes rolled back
#         4 failed and rollback incomplete: manual action needed, the log lists the open undo commands
# Log:    $LOG_DIR/lock-<agent|host>-<time>.log (default /var/log/hermes-agent), copy in $REPORT_DIR if set
# Backup: $BACKUP_DIR/lock-<agent|host>-<time>/ (default /var/backups/hermes): replaced files, ACL dump,
#         owner manifest, moved leftovers, undo.sh
# Prints no secrets: file contents are compared, never shown; journal lines are masked.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo" >&2; exit 1; }
exec </dev/null
SELF=$(readlink -f "$0")                    # before "cd /", otherwise wrong for a relative invocation
TOOL_DIR=$(dirname "$SELF")
cd /
export LC_ALL=C.UTF-8 SYSTEMD_PAGER='' PAGER=cat SYSTEMD_COLORS=0
# shellcheck source=hermes-agent-lib.sh
source "$TOOL_DIR/hermes-agent-lib.sh" || { echo "ERROR: cannot load $TOOL_DIR/hermes-agent-lib.sh" >&2; exit 1; }

ARG=${1:-}
case $ARG in
  ""|-h|--help) sed -n '2,16p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
  --host) MODE=host; RUN=host ;;
  *) MODE=agent; RUN=$ARG ;;
esac
STAMP=$(date +%Y%m%d-%H%M%S)
BK=$BACKUP_DIR/lock-$RUN-$STAMP
UNDO=() UNDO_DESC=() CHANGED=0 RELOAD=0 RESTART=0 START=""
log_init "lock-$RUN"

# --- Failure handling -------------------------------------------------------------------------
add_undo() {   # $1 description, $2.. command; recorded for rollback in reverse order and in undo.sh
  local desc=$1; shift
  UNDO+=("$(printf '%q ' "$@")"); UNDO_DESC+=("$desc")
  printf '# %s\n%s\n' "$desc" "${UNDO[-1]}" >> "$BK/undo.sh"
}
journal_excerpt() {   # errors of the gateway since the last restart, masked
  [[ $MODE == agent && -n $START ]] || return 0
  info "journal of $S since $START (errors only, max 20 lines):"
  journalctl -u "$S" --since "$START" --no-pager -o cat 2>/dev/null \
    | grep -iE 'error|denied|traceback|not permitted|failed' | mask | head -20 | sed 's/^/      /' || true
}
MANUAL=()
rollback() {   # returns 0 if every undo step and the restart succeeded; collects open actions in MANUAL
  local i
  section "Rollback (${#UNDO[@]} steps, reverse order)"
  for ((i=${#UNDO[@]}-1; i>=0; i--)); do
    if bash -c "${UNDO[i]}" >/dev/null 2>&1; then info "undone: ${UNDO_DESC[i]}"
    else info "FAILED to undo: ${UNDO_DESC[i]}"; MANUAL+=("${UNDO[i]}"); fi
  done
  systemctl daemon-reload >/dev/null 2>&1 || { info "FAILED: systemctl daemon-reload"; MANUAL+=("systemctl daemon-reload"); }
  if [[ $MODE == agent ]]; then
    if systemctl restart "$S" >/dev/null 2>&1; then
      wait_stable || { info "gateway not stable after the rollback"; journal_excerpt; MANUAL+=("systemctl status $S   # check why the gateway does not stay up"); }
    else
      info "FAILED: systemctl restart $S"; MANUAL+=("systemctl restart $S")
    fi
  fi
  (( ${#MANUAL[@]} == 0 ))
}
fail() {   # $1 message, $2 exit code when nothing was changed (default 2)
  trap - ERR; trap '' INT TERM HUP PIPE   # finish the rollback even if interrupted again or the terminal is gone
  # in a subshell (command substitution) only report: the main shell owns the undo list and rolls back
  if (( BASH_SUBSHELL > 0 )); then echo "ERROR (subshell): $1" >&2; exit 1; fi
  section "FAILED: $1"
  if (( CHANGED == 0 )); then info "nothing was changed"; log_finish; exit "${2:-2}"; fi
  if rollback; then info "RESULT: failed, all changes rolled back (backup $BK)"; log_finish; exit 3; fi
  info "RESULT: failed, ROLLBACK INCOMPLETE - manual action needed, in this order:"
  local m; for m in "${MANUAL[@]}"; do info "   sudo $m"; done
  info "all undo commands of this run: $BK/undo.sh (in order of the changes; undo bottom-up)"
  log_finish; exit 4
}
trap 'fail "unexpected error in line $LINENO: $BASH_COMMAND" 1' ERR
# an interrupt (Ctrl+C, closed SSH session, kill) must not leave a half-done change: roll back as on an error
trap 'fail "interrupted by a signal" 1' INT TERM HUP
run() {   # $1 description, $2.. command: runs it, on failure logs the command and its output, then fails
  local desc=$1 out; shift
  if ! out=$("$@" 2>&1); then
    info "step failed: $desc"; info "   command: $(printf '%q ' "$@")"
    [[ -n $out ]] && printf '%s\n' "$out" | mask | head -10 | sed 's/^/      /'
    fail "$desc"
  fi
}
wait_stable() {   # gateway active within 60 s, then no restart during STABLE_SECONDS (default 45 s)
  local i st n0 n1
  for ((i=0; i<60; i++)); do st=$(systemctl is-active "$S" 2>/dev/null || true); [[ $st == active ]] && break; sleep 1; done
  [[ $st == active ]] || { info "gateway state after 60 s: $st"; return 1; }
  n0=$(unit_prop NRestarts); sleep "${STABLE_SECONDS:-45}"
  st=$(systemctl is-active "$S" 2>/dev/null || true); n1=$(unit_prop NRestarts)
  info "gateway $st, restarts during the observation: $((n1 - n0))"
  [[ $st == active && $n1 == "$n0" ]]
}
write_generated() {   # $1 target path, $2 generator function, $3 description; backs up and records undo
  local path=$1 gen=$2 desc=$3 dir tmp
  dir=$(dirname "$path")
  if [[ ! -d $dir ]]; then   # undo order is reverse: the file is removed before the directory
    add_undo "remove directory $dir if empty" rmdir --ignore-fail-on-non-empty "$dir"
    run "create $dir" install -d -m 0755 "$dir"
  fi
  if [[ -e $path ]]; then
    run "back up $path" cp -a "$path" "$BK/$(echo "$path" | tr / _)"
    add_undo "restore $path" cp -a "$BK/$(echo "$path" | tr / _)" "$path"
  else
    add_undo "remove $path" rm -f "$path"
  fi
  tmp=$(mktemp "$dir/.lock.XXXXXX") || fail "cannot create a temporary file in $dir"
  "$gen" > "$tmp" || { rm -f "$tmp"; fail "cannot generate $desc"; }
  run "set mode of $desc" chmod 0644 "$tmp"
  run "install $desc" mv -f "$tmp" "$path"
  CHANGED=1; RELOAD=1
}

# --- One item: show state before, change if needed, show state after ----------------------------
# item <layer> <label> <check function and args...> -- <fix function and args...>
item() {
  local layer=$1 label=$2 chk=() fix=() before
  shift 2
  while [[ $1 != -- ]]; do chk+=("$1"); shift; done; shift; fix=("$@")
  if "${chk[@]}"; then row "$layer" "$label" "$WANT" "$ACT" "$ACT" unchanged; return 0; fi
  before=$ACT
  "${fix[@]}"
  RESTART=1   # every fix of a deviation restarts the gateway (agent mode); comment refresh does not
  if "${chk[@]}"; then row "$layer" "$label" "$WANT" "$before" "$ACT" CHANGED
  else row "$layer" "$label" "$WANT" "$before" "$ACT" "STILL WRONG"; fail "$label is still not as defined after the change"; fi
}

# --- Fixes (each records its undo before it changes anything) ------------------------------------
fix_shell() {
  local old; old=$(getent passwd "$U" | cut -d: -f7)
  add_undo "shell of $U back to $old" usermod -s "$old" "$U"
  run "set shell of $U" usermod -s /usr/sbin/nologin "$U"; CHANGED=1
}
fix_groups() {
  local g have want
  have=" $(agent_groups_actual) "; want=" $(agent_groups_want) "
  for g in $(agent_groups_want); do
    [[ $have == *" $g "* ]] && continue
    add_undo "remove $U from $g" gpasswd -d "$U" "$g"
    run "add $U to $g" gpasswd -a "$U" "$g"; CHANGED=1
  done
  for g in $(agent_groups_actual); do
    [[ $want == *" $g "* ]] && continue
    add_undo "add $U to $g again" gpasswd -a "$U" "$g"
    run "remove $U from $g" gpasswd -d "$U" "$g"; CHANGED=1
  done
}
fix_profile_dir() {
  local own mode; own=$(stat -c '%U:%G' "$D"); mode=$(stat -c '%a' "$D")
  add_undo "profile owner/mode back to $own $mode" sh -c 'chown "$1" "$3" && chmod "$2" "$3"' sh "$own" "$mode" "$D"
  run "set owner of $D" chown "$U:$U" "$D"
  run "set mode of $D" exact_mode "$D" 0700; CHANGED=1
}
fix_profile_acl() {
  run "save ACLs of $D" sh -c 'getfacl -R -p "$1" > "$2"' sh "$D" "$BK/profile-acl.dump"
  add_undo "restore ACLs of $D from $BK/profile-acl.dump" setfacl --restore="$BK/profile-acl.dump"
  run "remove ACLs in $D" setfacl -R -b "$D"; CHANGED=1
}
fix_locked() {   # $1 file name in the profile
  local f=$D/$1 own mode imm
  own=$(stat -c '%U:%G' "$f"); mode=$(stat -c '%a' "$f"); is_immutable "$f" && imm=+i || imm=-i
  run "back up $f" cp -a "$f" "$BK/profile_$1"
  add_undo "$1 back to $own $mode $imm" sh -c 'chattr -i "$4"; chown "$1" "$4" && chmod "$2" "$4" && { [ "$3" = -i ] || chattr +i "$4"; }' sh "$own" "$mode" "$imm" "$f"
  [[ $imm == +i ]] && run "clear immutable on $1" chattr -i "$f"
  run "set owner of $1" chown "root:$U" "$f"
  run "set mode of $1" chmod 0640 "$f"
  run "set immutable on $1" chattr +i "$f"
  CHANGED=1
}
fix_profile_bins() {   # moves tirith/uv/uvx out of the profile; Hermes then uses the root-owned ones in PATH
  local b
  c_tirith || fail "tirith system-wide: $ACT - install it first, otherwise Hermes downloads it into the profile again"
  run "create $BK/profile-bin" install -d -m 0700 "$BK/profile-bin"
  for b in $MANAGED_BINS; do
    [[ -e $D/bin/$b || -L $D/bin/$b ]] || continue
    add_undo "move $b back into $D/bin" mv "$BK/profile-bin/$b" "$D/bin/$b"
    run "move $D/bin/$b into the backup" mv "$D/bin/$b" "$BK/profile-bin/$b"
  done
  CHANGED=1   # the gateway caches the tirith path: item() restarts it
}
fix_linger() {
  if [[ $LINGER == yes ]]; then
    add_undo "disable linger for $U" loginctl disable-linger "$U"
    run "enable linger for $U" loginctl enable-linger "$U"
  else
    add_undo "enable linger for $U" loginctl enable-linger "$U"
    run "disable linger for $U" loginctl disable-linger "$U"
  fi
  CHANGED=1
}
fix_common_dropin() {
  if [[ -f $LEGACY_COMMON_DROPIN ]]; then
    run "back up legacy drop-in" cp -a "$LEGACY_COMMON_DROPIN" "$BK/legacy-10-haertung.conf"
    add_undo "restore legacy drop-in" cp -a "$BK/legacy-10-haertung.conf" "$LEGACY_COMMON_DROPIN"
    run "remove legacy drop-in" rm -f "$LEGACY_COMMON_DROPIN"; CHANGED=1; RELOAD=1
  fi
  cmp -s "$COMMON_DROPIN" "$UNIT_TEMPLATE" 2>/dev/null || write_generated "$COMMON_DROPIN" cat_template "common hardening drop-in"
}
cat_template() { cat "$UNIT_TEMPLATE"; }

fix_code_owner() {   # whole install tree to root:root, go-w, a+r; the manifest restores every entry
  run "record owner and mode of every entry in $HERMES_INSTALL" owner_tool manifest "$HERMES_INSTALL" "$BK/install-owner.manifest"
  info "manifest: $(wc -l < "$BK/install-owner.manifest") entries in $BK/install-owner.manifest"
  add_undo "owner and mode in $HERMES_INSTALL back from the manifest" "$PY" -I "$BK/hermes-agent-lib.py" owner restore "$BK/install-owner.manifest"
  CHANGED=1   # before the change: a failure in the middle still triggers the rollback
  run "set owner root:root and mode go-w,a+r in $HERMES_INSTALL" owner_tool apply "$HERMES_INSTALL"
}
fix_root_dir() {   # $1 directory: owner root:ROOT_GROUP, mode ROOT_MODE; ACL removed when others may traverse
  local d=$1 u g m dump
  u=$(stat -c '%u' "$d"); g=$(stat -c '%g' "$d"); m=$(stat -c '%a' "$d"); dump=$BK/acl$(tr / _ <<<"$d").dump
  run "save ACL of $d" sh -c 'getfacl -p "$1" > "$2"' sh "$d" "$dump"
  # undo runs in reverse order: owner back, mode back, then the ACL (it also sets the mask)
  add_undo "ACL of $d restored from $dump" setfacl --restore="$dump"
  add_undo "mode of $d back to $m" "$PY" -I "$BK/hermes-agent-lib.py" owner chmod "$m" "$d"
  add_undo "owner of $d back to uid $u, gid $g" "$PY" -I "$BK/hermes-agent-lib.py" owner chown "$u" "$g" "$d"
  CHANGED=1
  if others_traverse && [[ $(acl_named "$d") != 0 ]]; then
    run "remove the ACL of $d (every user may traverse, entries not needed)" setfacl -b "$d"
  fi
  run "set owner of $d to root:$ROOT_GROUP" owner_tool chown root "$ROOT_GROUP" "$d"
  run "set mode of $d to $ROOT_MODE" owner_tool chmod "$ROOT_MODE" "$d"
}
fix_kanban_groups() {   # renames the group at the defined gid; creating a domain group is not part of the lock
  local k d home g gid name
  for k in "${KANBANS[@]}"; do
    read -r d home g gid <<<"$k"
    name=$(getent group "$gid" | cut -d: -f1 || true)
    [[ $name == "$g" ]] && continue
    [[ -n $name ]] || fail "no group with gid $gid for domain $d - create it first (not part of the lock)"
    getent group "$g" >/dev/null && fail "group name $g is already used by another gid"
    add_undo "group gid $gid back to the name $name" groupmod -n "$name" "$g"
    CHANGED=1
    run "rename group $name (gid $gid) to $g" groupmod -n "$g" "$name"
  done
}
fix_admin_groups() {   # removes admins from agent, vault and kanban groups (local memberships only)
  local a g list
  list=$(admin_bad_groups) || fail "cannot determine the groups of the admins"
  while read -r a g; do
    [[ -n $a ]] || continue
    add_undo "add $a to $g again" gpasswd -a "$a" "$g"
    CHANGED=1
    run "remove $a from $g" gpasswd -d "$a" "$g"
  done <<<"$list"
}
fix_kanban_owner() {   # entries of admins in the kanban homes to owner root (group and mode kept)
  local k d home g gid a uid m
  for k in "${KANBANS[@]}"; do
    read -r d home g gid <<<"$k"
    for a in "${ADMINS[@]}"; do
      uid=$(id -u "$a" 2>/dev/null) || continue
      m=$BK/kanban-$d-$a.manifest
      add_undo "owner of the entries of $a in $home back from $m" "$PY" -I "$BK/hermes-agent-lib.py" owner restore "$m"
      CHANGED=1
      run "entries of $a in $home to owner root" owner_tool reown "$uid" "$home" "$m"
      info "changed to owner root: $(wc -l < "$m") entries of $a (list in $m)"
    done
  done
}
fix_kanban_obsolete() {   # obsolete files into the backup (same file system: a rename)
  local f list dst=$BK/kanban-obsolete
  list=$(kanban_obsolete) || fail "cannot list obsolete kanban files"
  run "create $dst" install -d -m 0700 "$dst"
  while read -r f; do
    [[ -n $f ]] || continue
    add_undo "move $f back" mv -n "$dst/$(tr / _ <<<"$f")" "$f"
    CHANGED=1
    run "move $f to $dst" mv -n "$f" "$dst/$(tr / _ <<<"$f")"
  done <<<"$list"
}
fix_root_clean() {   # moves every entry besides ROOT_ENTRIES into the backup (same file system: a rename)
  local e list dst=$BK/root-leftovers
  list=$(root_extra) || fail "cannot list the entries of $HERMES_ROOT"
  run "create $dst" install -d -m 0700 "$dst"
  while read -r e; do
    [[ -n $e ]] || continue
    add_undo "move $e back to $HERMES_ROOT" mv -n "$dst/$e" "$HERMES_ROOT/$e"
    CHANGED=1
    run "move $HERMES_ROOT/$e to $dst" mv -n "$HERMES_ROOT/$e" "$dst/$e"
    [[ -e $dst/$e || -L $dst/$e ]] || fail "$e not found in $dst after the move"
    info "moved: $e ($(stat -c '%U:%G %a %F, %s bytes' "$dst/$e"))"
  done <<<"$list"
}

# --- State tables -------------------------------------------------------------------------------
table_agent() {   # $1 title
  section "$1"
  local f
  for c in "L1 user_and_ids c_user" "L1 shell c_shell" "L1 passwd_home c_home" "L1 groups c_groups" \
           "L2 profile_directory c_profile_dir" "L2 ACLs_in_profile c_profile_acl" "L2 programs_in_bin/ c_profile_bins" LOCKED \
           "L3 common_drop-in c_common_dropin" "L3 20-agent.conf c_agent_dropin" "L3 zz-home.conf c_home_dropin" \
           "L3 user_slice_drop-in c_slice_dropin" "L3 linger c_linger"; do
    if [[ $c == LOCKED ]]; then
      for f in $LOCKED_FILES; do
        [[ -e $D/$f ]] || continue
        if c_locked "$f"; then crow L2 "$f" "$WANT" "$ACT" OK; else crow L2 "$f" "$WANT" "$ACT" DIFFERS; fi
      done
      continue
    fi
    read -r l n fn <<<"$c"
    if "$fn"; then crow "$l" "${n//_/ }" "$WANT" "$ACT" OK; else crow "$l" "${n//_/ }" "$WANT" "$ACT" DIFFERS; fi
  done
}
table_host() {   # $1 title
  section "$1"
  local c l n fn
  for c in "H common_drop-in c_common_dropin" "H entries_in_state_root c_root_clean" "H kanban_groups c_kanban_groups" \
           "H admins_not_in_agent_groups c_admin_groups" "H state_root c_root_dir" "H profiles_directory c_profiles_dir" \
           "H kanban_entries_of_admins c_kanban_owner" "H obsolete_kanban_files c_kanban_obsolete" "H install_tree c_code_owner"; do
    read -r l n fn <<<"$c"
    if "$fn"; then crow "$l" "${n//_/ }" "$WANT" "$ACT" OK; else crow "$l" "${n//_/ }" "$WANT" "$ACT" DIFFERS; fi
  done
}
snapshot_gateways() {   # effective settings of all gateways (for --host): one line per property
  local props=Environment,UMask,NoNewPrivileges,CapabilityBoundingSet,AmbientCapabilities,PrivateTmp,PrivateDevices,ProtectSystem,ProtectHome,BindPaths,ReadWritePaths,ProtectKernelTunables,ProtectKernelModules,ProtectKernelLogs,ProtectControlGroups,ProtectClock,ProtectHostname,ProtectProc,RestrictSUIDSGID,LockPersonality,RestrictRealtime,SystemCallArchitectures,RestrictAddressFamilies,MemoryHigh,MemoryMax,TasksMax
  local a
  for a in $(list_agents); do
    systemctl show "hermes-gateway-$a" -p "$props" 2>/dev/null | sed "s/^/$a /"
  done | sort
}

# =================================================================================================
section "hermes-agent-lock $(sha256sum "$SELF" | cut -c1-12)  mode=$MODE  target=$RUN  host=$(hostname)"
info "backup directory: $BK"
{ install -d -m 0700 "$BK" && : > "$BK/undo.sh"; } || { echo "ERROR: cannot create the backup directory $BK"; log_finish; exit 1; }

if [[ $MODE == host ]]; then
  section "Pre-checks (host) - nothing is changed if one fails"
  c_platform || fail "platform.toml breaks a rule: $ACT"
  info "platform.toml: $ACT"
  [[ -f $UNIT_TEMPLATE ]] || fail "template missing: $UNIT_TEMPLATE"
  [[ -x $PY ]] || fail "system Python $PY missing (needed to change owners without following symlinks)"
  [[ -d $HERMES_INSTALL/.git && -e $HERMES_INSTALL/venv/bin/python ]] || fail "$HERMES_INSTALL is not a Hermes installation"
  [[ ! -e $HERMES_INSTALL/.git/index.lock ]] || fail "$HERMES_INSTALL/.git/index.lock exists - a git command is running or crashed"
  getent group "$ROOT_GROUP" >/dev/null || fail "group $ROOT_GROUP (ROOT_GROUP) does not exist"
  for d in "$HERMES_ROOT" "$HERMES_ROOT/profiles"; do
    [[ -d $d && ! -L $d ]] || fail "$d is missing or a symlink"
    if [[ $(stat -c '%a' "$d") != "$ROOT_MODE" && $(acl_named "$d") != 0 ]] && ! others_traverse; then
      fail "mode of $d is $(stat -c '%a' "$d"), want $ROOT_MODE, and it has an ACL - not changed (chmod would rewrite the ACL mask)"
    fi
  done
  for k in "${KANBANS[@]}"; do read -r d home g gid <<<"$k"; [[ -d $home && ! -L $home ]] || fail "kanban home $home of domain $d missing or a symlink"; done
  OBS=(); _l=$(kanban_obsolete) || fail "cannot run kanban_obsolete"; [[ -z $_l ]] || mapfile -t OBS <<<"$_l"
  if (( ${#OBS[@]} )); then
    n=$(owner_tool open "${OBS[@]}") || fail "cannot check open files"
    [[ $n == 0 ]] || fail "obsolete kanban files are in use ($n open): ${OBS[*]}"
    [[ $(stat -c '%d' "${OBS[0]}") == "$(stat -c '%d' "$BK")" ]] || fail "$BK is on another file system than the kanban home"
  fi
  EXTRA=(); _l=$(root_extra) || fail "cannot run root_extra"; [[ -z $_l ]] || mapfile -t EXTRA <<<"$_l"
  if (( ${#EXTRA[@]} )); then
    [[ $(stat -c '%d' "$HERMES_ROOT") == "$(stat -c '%d' "$BK")" ]] \
      || fail "$BK is on another file system than $HERMES_ROOT - leftovers must be moved, not copied"
    n=$(owner_tool open "${EXTRA[@]/#/$HERMES_ROOT/}") || fail "cannot check open files"
    [[ $n == 0 ]] || fail "$n open files or working directories in the leftovers of $HERMES_ROOT - a process still uses them"
    info "leftovers in $HERMES_ROOT, not in use: ${EXTRA[*]}"
  fi
  declare -A NR0=()
  for a in $(list_agents); do
    load_agent "$a" >/dev/null || fail "cannot load the definition of '$a'" 1
    [[ $(systemctl is-active "$S" 2>/dev/null || true) == active ]] || fail "$S is not active - start it first, so the result can be checked"
    NR0[$a]=$(unit_prop NRestarts)
  done
  info "gateways active: $(list_agents | tr '\n' ' ')"
  cp "$LIBPY" "$BK/hermes-agent-lib.py" || fail "cannot copy $LIBPY to $BK (needed by the undo steps)"
  snapshot_gateways > "$BK/effective-before.txt"
  info "effective settings recorded: $(wc -l < "$BK/effective-before.txt") lines"
  table_host "State BEFORE"

  section "Change (only deviations; every change is backed up and can be undone)"
  START=$(date '+%Y-%m-%d %H:%M:%S')
  item H "common hardening drop-in"  c_common_dropin -- fix_common_dropin
  item H "leftovers in state root"   c_root_clean    -- fix_root_clean
  item H "kanban groups (name at gid)" c_kanban_groups -- fix_kanban_groups
  item H "admins not in agent groups" c_admin_groups -- fix_admin_groups
  item H "state root directory"      c_root_dir      -- fix_root_dir "$HERMES_ROOT"
  item H "profiles directory"        c_profiles_dir  -- fix_root_dir "$HERMES_ROOT/profiles"
  item H "kanban entries of admins"  c_kanban_owner  -- fix_kanban_owner
  item H "obsolete kanban files"     c_kanban_obsolete -- fix_kanban_obsolete
  item H "install tree $HERMES_INSTALL" c_code_owner -- fix_code_owner
  if (( RELOAD )); then run "systemctl daemon-reload" systemctl daemon-reload; fi
  snapshot_gateways > "$BK/effective-after.txt"
  section "Check: effective settings of all gateways must be unchanged"
  if diff -u "$BK/effective-before.txt" "$BK/effective-after.txt" > "$BK/effective.diff"; then
    info "identical: $(wc -l < "$BK/effective-after.txt") settings"
  else
    info "DIFFERENCES:"; sed 's/^/      /' "$BK/effective.diff" | mask | head -30
    fail "effective settings changed"
  fi
  if (( CHANGED )); then
    section "Runtime checks: all gateways, ${STABLE_SECONDS:-45} s after the change (no restart)"
    sleep "${STABLE_SECONDS:-45}"
    RBAD=0
    for a in $(list_agents); do
      load_agent "$a" >/dev/null
      st=$(systemctl is-active "$S" 2>/dev/null || true); nr=$(unit_prop NRestarts)
      tb=$(journalctl -u "$S" --since "$START" --no-pager -o cat 2>/dev/null | grep -c '^Traceback' || true)
      pe=$(journalctl -u "$S" --since "$START" --no-pager -o cat 2>/dev/null \
           | grep -iE 'permission denied|operation not permitted|read-only file system|could not save' | grep -cvE "$KNOWN_WARNINGS" || true)
      if [[ $st == active && $nr == "${NR0[$a]}" && $tb == 0 && $pe == 0 ]]; then
        crow H "$S" "active, 0 restarts/errors" "$st, restarts $((nr - NR0[$a])), tracebacks $tb, perm $pe" OK
      else
        crow H "$S" "active, 0 restarts/errors" "$st, restarts $((nr - NR0[$a])), tracebacks $tb, perm $pe" FAILED; RBAD=1
        journalctl -u "$S" --since "$START" --no-pager -o cat 2>/dev/null \
          | grep -iE 'error|denied|traceback|not permitted|read-only' | mask | head -10 | sed 's/^/      /' || true
      fi
    done
    (( RBAD == 0 )) || fail "a gateway reports errors after the change"
  fi
  table_host "State AFTER"
  section "Result"
  if (( CHANGED )); then info "RESULT: OK, host layer changed (changes: ${#UNDO[@]}, undo script $BK/undo.sh; no gateway restart)"
  else info "RESULT: OK, host layer already as defined - nothing changed"; fi
  info "full check: sudo bash $TOOL_DIR/hermes-agent-verify.sh --all"
  trap - ERR
  log_finish; exit 0
fi

# ----- agent mode ------------------------------------------------------------------------------------
section "Pre-checks ($RUN) - nothing is changed if one fails"
c_platform || fail "platform.toml breaks a rule: $ACT" 1
load_agent "$RUN" || fail "cannot load the definition of '$RUN'" 1
[[ -n $AUID ]] || fail "user $U does not exist - create the agent first (hermes-agent-create.sh)"
c_user    || fail "identity differs: want $WANT, actual $ACT - not changed by the lock (manual migration)"
c_home    || fail "passwd home differs: want $WANT, actual $ACT - not changed by the lock (manual migration)"
c_no_home || fail "/home/$U exists - move it away first"
c_no_sudo || fail "$U has sudo rights - remove them first"
[[ -d $D ]] || fail "profile $D missing"
for f in config.yaml .env; do [[ -f $D/$f ]] || fail "$D/$f missing"; done
systemctl cat "$S" >/dev/null 2>&1 || fail "unit $S not found"
[[ $(systemctl is-active "$S" 2>/dev/null || true) == active ]] || fail "$S is not active - start it first, so the result can be checked"
if pgrep -u "$U" -f 'work kanban task' >/dev/null; then fail "a Kanban worker of $U is running - try again later"; fi
for g in $AGENT_GROUPS; do getent group "$g" >/dev/null || fail "group $g (AGENT_GROUPS) does not exist"; done
for p in $RW_PATHS; do [[ -d $p ]] || fail "RW_PATHS: directory $p does not exist"; done
c_common_dropin || fail "host layer not in place ($ACT) - run: hermes-agent-lock.sh --host"
info "OK: $U uid=$AUID, profile $D, unit $S active"

table_agent "State BEFORE"

section "Change (only deviations; every change is backed up and can be undone)"
item L1 "shell"                c_shell        -- fix_shell
item L1 "groups (besides own)" c_groups       -- fix_groups
item L2 "profile directory"    c_profile_dir  -- fix_profile_dir
item L2 "ACLs in profile"      c_profile_acl  -- fix_profile_acl
item L2 "programs in bin/"     c_profile_bins -- fix_profile_bins
for f in $LOCKED_FILES; do
  [[ -e $D/$f ]] || continue
  item L2 "$f"                 c_locked "$f"  -- fix_locked "$f"
done
item L3 "20-agent.conf"        c_agent_dropin -- write_generated "$(agent_dropin_path)" want_agent_dropin "20-agent.conf"
item L3 "zz-home.conf"         c_home_dropin  -- write_generated "$(home_dropin_path)" want_home_dropin "zz-home.conf"
item L3 "user slice drop-in"   c_slice_dropin -- write_generated "$(slice_dropin_path)" want_slice_dropin "user slice drop-in"
item L3 "linger"               c_linger       -- fix_linger

# comment-only differences in the generated drop-ins: rewrite, reload, no restart
for c in "20-agent.conf c_agent_dropin agent_dropin_path want_agent_dropin" \
         "zz-home.conf c_home_dropin home_dropin_path want_home_dropin" \
         "user_slice_drop-in c_slice_dropin slice_dropin_path want_slice_dropin"; do
  read -r n fn pathfn gen <<<"$c"
  # shellcheck disable=SC2015  # write only when the check ran and reported an outdated comment; otherwise skip
  "$fn" && [[ $ACT == *"comment outdated"* ]] || continue
  write_generated "$("$pathfn")" "$gen" "${n//_/ }"
  "$fn"; row L3 "${n//_/ } (comment only)" "= generated" "comment outdated" "$ACT" CHANGED
done

if (( RESTART )); then
  section "Apply: reload systemd, restart $S"
  (( RELOAD )) && run "systemctl daemon-reload" systemctl daemon-reload
  START=$(date '+%Y-%m-%d %H:%M:%S')
  run "restart $S" systemctl restart "$S"
  wait_stable || { journal_excerpt; fail "$S is not stable after the restart"; }
elif (( CHANGED )); then
  section "Apply: reload systemd (comments or files without effect on the running gateway - no restart)"
  (( RELOAD )) && run "systemctl daemon-reload" systemctl daemon-reload
else
  section "No deviations - no restart"
fi

section "Runtime checks (L4)"
RBAD=0
rcheck() { local label=$1; shift; if "$@"; then crow L4 "$label" "$WANT" "$ACT" OK; else crow L4 "$label" "$WANT" "$ACT" FAILED; RBAD=1; fi; }
rcheck "gateway state"          c_active
rcheck "HOME of the gateway"    c_proc_home
rcheck "tracebacks since start" c_tracebacks
rcheck "new permission errors"  c_perm_errors
for f in $LOCKED_FILES; do
  [[ -e $D/$f ]] || continue
  rcheck "$f agent reads"         c_agent_reads "$f"
  rcheck "$f agent cannot write"  c_agent_writes "$f"
  rcheck "$f agent cannot rename" c_agent_renames "$f"
done
rcheck "effective hardening"    c_unit_hardening
rcheck "ReadWritePaths"         c_unit_rw
rcheck "memory limits"          c_unit_mem
if (( RBAD )); then journal_excerpt; fail "runtime checks failed"; fi

table_agent "State AFTER"

section "Result"
if (( CHANGED )); then info "RESULT: OK, $RUN locked (changes: ${#UNDO[@]}, undo script $BK/undo.sh)"
else info "RESULT: OK, $RUN was already locked - nothing changed"; fi
info "full check incl. isolation: sudo bash $TOOL_DIR/hermes-agent-verify.sh $RUN"
trap - ERR
log_finish
exit 0
