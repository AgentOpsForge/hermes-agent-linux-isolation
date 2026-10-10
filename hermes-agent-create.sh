#!/usr/bin/env bash
# hermes-agent-create.sh - CHANGES THE SYSTEM. Creates a new isolated Hermes agent defined in platform.toml:
# system user and group, profile, config.yaml, SOUL.md, .env, systemd unit and the per-agent hardening.
# Does NOT start the agent: the login at the model provider is interactive and writes config.yaml,
# so it has to happen before the lock. Rolls back everything it created when a step fails.
#
# Usage:  sudo bash hermes-agent-create.sh <agent>
# Then:   1 login at the model provider (command printed at the end)  2 start the gateway
#         3 sudo bash hermes-agent-lock.sh <agent>                      4 sudo bash hermes-agent-verify.sh <agent>
# Exit:   0 created   1 usage or environment error   2 pre-check failed, nothing created
#         3 failed, everything created was removed again   4 failed and cleanup incomplete (see log)
# Log:    $LOG_DIR/create-<agent>-<time>.log (default /var/log/hermes-agent), copy in $REPORT_DIR if set
# Backup: $BACKUP_DIR/create-<agent>-<time>/ (ACLs of directories changed for traversal)
# Prints no secrets: .env receives only A2A_AGENT_NAME and A2A_PORT; keys are added later by the operator.
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
case $ARG in ""|-h|--help|--*) sed -n '2,14p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;; esac
log_init "create-$ARG"
UNDO=() UNDO_DESC=() CREATED=0 MANUAL=()
BK=$BACKUP_DIR/create-$ARG-$(date +%Y%m%d-%H%M%S)
{ install -d -m 0700 "$BK"; } || { echo "ERROR: cannot create the backup directory $BK"; log_finish; exit 1; }

# --- Failure handling: everything created is recorded and removed again in reverse order ---------------
add_undo() { local desc=$1; shift; UNDO+=("$(printf '%q ' "$@")"); UNDO_DESC+=("$desc"); }
cleanup() {
  local i
  section "Cleanup (${#UNDO[@]} steps, reverse order)"
  for ((i=${#UNDO[@]}-1; i>=0; i--)); do
    if bash -c "${UNDO[i]}" >/dev/null 2>&1; then info "removed: ${UNDO_DESC[i]}"
    else info "FAILED to remove: ${UNDO_DESC[i]}"; MANUAL+=("${UNDO[i]}"); fi
  done
  systemctl daemon-reload >/dev/null 2>&1 || MANUAL+=("systemctl daemon-reload")
  (( ${#MANUAL[@]} == 0 ))
}
fail() {   # $1 message, $2 exit code when nothing was created (default 2)
  trap - ERR; trap '' INT TERM HUP PIPE   # finish the rollback even if interrupted again or the terminal is gone
  if (( BASH_SUBSHELL > 0 )); then echo "ERROR (subshell): $1" >&2; exit 1; fi   # the main shell cleans up
  section "FAILED: $1"
  if (( CREATED == 0 )); then info "nothing was created"; log_finish; exit "${2:-2}"; fi
  if cleanup; then info "RESULT: failed, everything created was removed again"; log_finish; exit 3; fi
  info "RESULT: failed, CLEANUP INCOMPLETE - run these commands by hand, in this order:"
  local m; for m in "${MANUAL[@]}"; do info "   sudo $m"; done
  log_finish; exit 4
}
trap 'fail "unexpected error in line $LINENO: $BASH_COMMAND" 1' ERR
# an interrupt (Ctrl+C, closed SSH session, kill) must not leave a half-done change: roll back as on an error
trap 'fail "interrupted by a signal" 1' INT TERM HUP
run() {   # $1 description, $2.. command
  local desc=$1 out; shift
  if out=$("$@" 2>&1); then info "done: $desc"; return 0; fi
  info "step failed: $desc"; info "   command: $(printf '%q ' "$@")"
  [[ -n $out ]] && printf '%s\n' "$out" | mask | head -10 | sed 's/^/      /'
  fail "$desc"
}
write_file() {   # $1 path, $2 mode, $3 owner:group, $4 generator function, $5 description
  local path=$1 mode=$2 own=$3 gen=$4 desc=$5 tmp
  tmp=$(mktemp "$(dirname "$path")/.create.XXXXXX") || fail "cannot create a temporary file for $desc"
  "$gen" > "$tmp" || { rm -f "$tmp"; fail "cannot generate $desc"; }
  run "set owner of $desc" chown "$own" "$tmp"
  run "set mode of $desc" chmod "$mode" "$tmp"
  run "install $desc ($path)" mv -f "$tmp" "$path"
}

# --- Generated content ---------------------------------------------------------------------------------
gen_config() {   # config.yaml from the definition (keys as checked by hermes-agent-verify.sh)
  A_MODEL="$MODEL" A_PROVIDER="$PROVIDER" A_BASE_URL="$BASE_URL" A_PLUGINS="$PLUGINS" A_CLI="$TOOLSETS_CLI" \
  A_A2A="$TOOLSETS_A2A" A_CRON="$TOOLSETS_CRON" A_DISPATCH="$KANBAN_DISPATCH" A_MAX="$KANBAN_MAX" A_NAME="$NAME" \
  A_TZ="$TIMEZONE" "$HERMES_INSTALL/venv/bin/python" - <<'PY'
import os, sys, yaml
e = os.environ.get
model = {"default": e("A_MODEL"), "provider": e("A_PROVIDER")}
if e("A_BASE_URL"):
    model["base_url"] = e("A_BASE_URL")
cfg = {
    "model": model,
    "plugins": {"enabled": e("A_PLUGINS").split()},
    "platform_toolsets": {"cli": e("A_CLI").split(), "a2a": e("A_A2A").split(), "cron": e("A_CRON").split()},
    "approvals": {"mode": "smart"},
    "skills": {"write_approval": True, "guard_agent_created": True},
    "curator": {"enabled": False},
    "agent": {"disabled_toolsets": ["connections"]},   # otherwise config migration 45 enables it
    "gateway": {"standalone": False},                   # true stops the gateway from starting
    "security": {"allow_lazy_installs": False},         # no runtime pip into the root-owned read-only venv
    "timezone": e("A_TZ"),
}
if e("A_DISPATCH") == "yes":
    cfg["kanban"] = {"dispatch_in_gateway": True, "dispatch_profiles": e("A_NAME"), "max_in_progress": int(e("A_MAX"))}
yaml.safe_dump(cfg, sys.stdout, sort_keys=False, allow_unicode=True)
PY
}
gen_env()  { [[ -n $A2A_PORT ]] && printf 'A2A_AGENT_NAME=%s\nA2A_PORT=%s\n' "$NAME" "$A2A_PORT"; return 0; }
gen_soul() { cat "$SOULF"; }
gen_unit() {
  cat <<EOF
[Unit]
Description=Hermes Agent Gateway - $NAME${DESCRIPTION:+ ($DESCRIPTION)}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$U
Group=$U
ExecStart=$HERMES_INSTALL/venv/bin/python -m hermes_cli.main --profile $NAME gateway run
WorkingDirectory=$D
Environment="VIRTUAL_ENV=$HERMES_INSTALL/venv"
Environment="HERMES_HOME=$D"
Restart=always
RestartSec=5
RestartForceExitStatus=75
RestartPreventExitStatus=78
KillMode=mixed
KillSignal=SIGTERM
ExecStopPost=-$HERMES_INSTALL/venv/bin/python -m gateway.cgroup_cleanup
TimeoutStopSec=70
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# =========================================================================================================
section "hermes-agent-create $(sha256sum "$SELF" | cut -c1-12)  agent=$ARG  host=$(hostname)"
section "Pre-checks - nothing is created if one fails"
# optional fields used only by create
DESCRIPTION="" BASE_URL="" PLUGINS="" TOOLSETS_CLI="" TOOLSETS_A2A="" TOOLSETS_CRON="" KANBAN_MAX=1 TIMEZONE=UTC SOUL=""
c_platform || fail "platform.toml breaks a rule: $ACT" 1
load_agent "$ARG" || fail "cannot load the definition of '$ARG'" 1   # sets the create-only fields above as well
SOULF=$SOUL   # absolute; platform.toml gives it relative to its own directory
UNIT=$SYSTEMD_DIR/$S.service
[[ $ID =~ ^2[01][0-9][0-9]$ ]]            || fail "ID $ID is outside the platform range 2000-2199"
[[ $GID == "$ID" ]]                        || fail "GID must equal ID for new agents (GID=$GID, ID=$ID)"
getent passwd "$U" >/dev/null              && fail "user $U already exists - use hermes-agent-lock.sh for existing agents"
getent group "$U" >/dev/null               && fail "group $U already exists"
getent passwd "$ID" >/dev/null             && fail "UID $ID is in use by $(getent passwd "$ID" | cut -d: -f1)"
getent group "$ID" >/dev/null              && fail "GID $ID is in use by $(getent group "$ID" | cut -d: -f1)"
[[ -e $D ]]                                && fail "profile $D already exists"
[[ -e $UNIT ]]                             && fail "unit $UNIT already exists"
if [[ -n $A2A_PORT ]]; then
  (( ID == 2000 + A2A_PORT - 9900 ))      || fail "ID rule violated: ID must be 2000 + (A2A_PORT - 9900)"
  ss -ltnH "sport = :$A2A_PORT" 2>/dev/null | grep -q . && fail "port $A2A_PORT is in use"
  grep -lqs "^A2A_PORT=$A2A_PORT$" "$HERMES_ROOT"/profiles/*/.env && fail "port $A2A_PORT is assigned to another agent"
fi
[[ -n $SOUL && -f $SOULF ]]                || fail "SOUL file missing: ${SOULF:-SOUL not set}"
[[ -x $HERMES_INSTALL/venv/bin/python ]]   || fail "Hermes venv missing: $HERMES_INSTALL/venv/bin/python"
[[ -d $HERMES_ROOT/profiles ]]             || fail "$HERMES_ROOT/profiles missing"
for g in $AGENT_GROUPS; do getent group "$g" >/dev/null || fail "group $g (AGENT_GROUPS) does not exist"; done
for p in $RW_PATHS; do [[ -d $p ]] || fail "RW_PATHS: directory $p does not exist"; done
c_common_dropin                            || fail "host layer not in place ($ACT) - run: hermes-agent-lock.sh --host"
info "OK: $U uid=gid=$ID, profile $D, unit $S${A2A_PORT:+, A2A port $A2A_PORT}"

section "Create"
CREATED=1
add_undo "group $U" sh -c 'getent group "$1" >/dev/null || exit 0; groupdel "$1"' sh "$U"
run "group $U ($ID)" groupadd --system -g "$ID" "$U"
add_undo "user $U" sh -c 'getent passwd "$1" >/dev/null || exit 0; userdel "$1"' sh "$U"
run "user $U ($ID), nologin, home = profile" useradd --system -u "$ID" -g "$U" -d "$D" -M -s /usr/sbin/nologin "$U"
for g in $AGENT_GROUPS; do run "add $U to $g" gpasswd -a "$U" "$g"; done
AUID=$ID
add_undo "profile $D" rm -rf --one-file-system "$D"
run "profile $D" install -d -o "$U" -g "$U" -m 0700 "$D"
run "mode of $D exactly 700 (no setgid inherited from profiles/)" exact_mode "$D" 0700
for d in "$HERMES_ROOT" "$HERMES_ROOT/profiles"; do   # traverse only (x), never list or read
  if ! runuser -u "$U" -- test -x "$d" 2>/dev/null || ! runuser -u "$U" -- ls -d "$D" >/dev/null 2>&1; then
    acl_save=$BK/acl-$(echo "$d" | tr / _).dump
    run "save ACL of $d" sh -c 'getfacl -cp "$1" > "$2"' sh "$d" "$acl_save"
    add_undo "ACL of $d restored" setfacl --set-file="$acl_save" "$d"
    run "traverse right (--x) for $U on $d" setfacl -m "u:$U:--x" "$d"
  fi
done
write_file "$D/config.yaml" 0600 "$U:$U" gen_config "config.yaml"
write_file "$D/SOUL.md"     0600 "$U:$U" gen_soul   "SOUL.md"
write_file "$D/.env"        0600 "$U:$U" gen_env    ".env"
run "config migration (as $U)" runuser -u "$U" -- env HOME="$D" HERMES_HOME="$D" "$HERMES_INSTALL/venv/bin/python" \
  -c 'from hermes_cli.config import migrate_config; migrate_config(interactive=False, quiet=True)'
c_connections || fail "after migration: connections toolset is $ACT (must be disabled)"
c_standalone  || fail "after migration: gateway is $ACT (must not be standalone)"
info "config after migration: connections disabled, gateway not standalone"
if [[ $LINGER == yes ]]; then
  add_undo "linger for $U" loginctl disable-linger "$U"
  run "enable linger for $U" loginctl enable-linger "$U"
fi
add_undo "unit $UNIT" rm -f "$UNIT"
write_file "$UNIT" 0644 root:root gen_unit "unit $S"
run "drop-in directory" install -d -m 0755 "$SYSTEMD_DIR/$S.service.d" "$SYSTEMD_DIR/user-$ID.slice.d"
add_undo "drop-in directory $S.service.d" rm -rf "$SYSTEMD_DIR/$S.service.d"
add_undo "slice drop-in directory user-$ID.slice.d" rm -rf "$SYSTEMD_DIR/user-$ID.slice.d"
write_file "$(agent_dropin_path)" 0644 root:root want_agent_dropin "20-agent.conf"
write_file "$(home_dropin_path)"  0644 root:root want_home_dropin  "zz-home.conf"
write_file "$(slice_dropin_path)" 0644 root:root want_slice_dropin "user slice drop-in"
run "systemctl daemon-reload" systemctl daemon-reload
add_undo "enable of $S" systemctl disable "$S"
run "enable $S (not started)" systemctl enable "$S"

section "Check"
BAD=0
for c in "L1 user c_user" "L1 shell c_shell" "L1 home c_home" "L1 groups c_groups" "L2 profile c_profile_dir" \
         "L2 ACLs c_profile_acl" "L3 20-agent.conf c_agent_dropin" "L3 zz-home.conf c_home_dropin" \
         "L3 slice c_slice_dropin" "L3 linger c_linger" "L3 hardening c_unit_hardening" "L3 ReadWritePaths c_unit_rw"; do
  read -r l n fn <<<"$c"
  if "$fn"; then crow "$l" "$n" "$WANT" "$ACT" OK; else crow "$l" "$n" "$WANT" "$ACT" FAILED; BAD=1; fi
done
(( BAD == 0 )) || fail "the created agent does not match its definition"

trap - ERR
section "Result"
info "RESULT: OK, $NAME created (not started)"
info "next steps:"
info " 1 login at the model provider, interactive, as $U:"
info "     sudo runuser -u $U -- env HOME=$D HERMES_HOME=$D $HERMES_INSTALL/venv/bin/hermes model"
info " 2 start:   sudo systemctl start $S"
info " 3 lock:    sudo bash $TOOL_DIR/hermes-agent-lock.sh $NAME"
info " 4 verify:  sudo bash $TOOL_DIR/hermes-agent-verify.sh $NAME"
log_finish
exit 0
