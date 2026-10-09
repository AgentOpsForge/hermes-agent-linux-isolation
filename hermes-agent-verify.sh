#!/usr/bin/env bash
# hermes-agent-verify.sh - READ-ONLY check of isolated Hermes agents against their definition.
# Changes nothing. Prints no secrets (only variable names from .env). Network: loopback A2A probe only.
#
# Usage:  sudo bash hermes-agent-verify.sh <agent>     check one agent (definition in platform.toml)
#         sudo bash hermes-agent-verify.sh --host      check the host layer (drop-in, install tree, state root)
#         sudo bash hermes-agent-verify.sh --all       check the host layer and every agent in platform.toml
# Exit:   0 all checks OK, 1 usage or environment error, 2 at least one check failed
# Log:    $LOG_DIR/verify-<agent|all>-<time>.log (default /var/log/hermes-agent), copy in $REPORT_DIR if set
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo" >&2; exit 1; }
exec </dev/null
SELF=$(readlink -f "$0")                    # before "cd /", otherwise wrong for a relative invocation
TOOL_DIR=$(dirname "$SELF")
cd /
export LC_ALL=C.UTF-8 SYSTEMD_PAGER='' PAGER=cat SYSTEMD_COLORS=0
# shellcheck source=hermes-agent-lib.sh
source "$TOOL_DIR/hermes-agent-lib.sh" || { echo "ERROR: cannot load $TOOL_DIR/hermes-agent-lib.sh" >&2; exit 1; }
trap 'echo "ERROR: unexpected failure in line $LINENO (exit $?): $BASH_COMMAND" >&2; (( BASH_SUBSHELL > 0 )) || log_finish; exit 1' ERR

ARG=${1:-}; HOST=0
case $ARG in
  --all) AGENTS=$(list_agents); HOST=1 ;;
  --host) AGENTS=""; HOST=1 ;;
  ""|-h|--help) sed -n '2,9p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
  *) AGENTS=$ARG ;;
esac
log_init "verify-${ARG#--}"
section "hermes-agent-verify $(sha256sum "$SELF" | cut -c1-12)  host $(hostname)  host layer: $( ((HOST)) && echo yes || echo no)  agents: $AGENTS"
for t in "$UNIT_TEMPLATE" "$TOOL_DIR/hermes-agent-lib.sh"; do [[ -f $t ]] || { echo "ERROR: missing $t"; exit 1; }; done

TOTAL_OK=0; TOTAL_BAD=0; FAILED_AGENTS=""
check() {  # $1 layer, $2 item, $3.. check function and arguments
  local layer=$1 item=$2; shift 2
  WANT=""; ACT=""
  if "$@"; then crow "$layer" "$item" "$WANT" "$ACT" OK; OK=$((OK+1))
  else crow "$layer" "$item" "$WANT" "$ACT" MISSING; BAD=$((BAD+1)); fi
}

if (( HOST )); then
  section "Host layer"
  OK=0; BAD=0
  check H "platform.toml rules"       c_platform
  check H "common hardening drop-in"  c_common_dropin
  check H "entries in state root"     c_root_clean
  check H "kanban groups (name at gid)" c_kanban_groups
  check H "admins not in agent groups" c_admin_groups
  check H "state root directory"      c_root_dir
  check H "profiles directory"        c_profiles_dir
  check H "kanban entries of admins"  c_kanban_owner
  check H "obsolete kanban files"     c_kanban_obsolete
  check H "signal-cli service"        c_signal_service
  check H "install tree $HERMES_INSTALL" c_code_owner
  check H "tirith system-wide"        c_tirith
  info "== host: $OK OK, $BAD MISSING"
  TOTAL_OK=$((TOTAL_OK+OK)); TOTAL_BAD=$((TOTAL_BAD+BAD))
  (( BAD == 0 )) || FAILED_AGENTS="$FAILED_AGENTS host"
fi

for A in $AGENTS; do
  section "Agent $A"
  if ! load_agent "$A"; then TOTAL_BAD=$((TOTAL_BAD+1)); FAILED_AGENTS="$FAILED_AGENTS $A"; continue; fi
  OK=0; BAD=0
  if [[ -z $AUID ]]; then
    crow L1 "user $U" "exists" "missing" MISSING; TOTAL_BAD=$((TOTAL_BAD+1)); FAILED_AGENTS="$FAILED_AGENTS $A"; continue
  fi
  info "-- L1 identity"
  check L1 "user and ids"            c_user
  check L1 "shell"                   c_shell
  check L1 "passwd home"             c_home
  check L1 "no /home/$U"             c_no_home
  check L1 "no sudo"                 c_no_sudo
  check L1 "groups (besides own)"    c_groups
  info "-- L2 profile"
  check L2 "profile directory"       c_profile_dir
  check L2 "no ACLs in profile"      c_profile_acl
  for f in $LOCKED_FILES; do
    [[ -e $D/$f ]] || continue
    check L2 "$f locked"             c_locked "$f"
    check L2 "$f agent reads"        c_agent_reads "$f"
    if c_locked "$f"; then   # write and rename tests only on locked files, never on a live unlocked config
      check L2 "$f agent cannot write"  c_agent_writes "$f"
      check L2 "$f agent cannot rename" c_agent_renames "$f"
    else
      crow L2 "$f write/rename tests" "file locked first" "not locked" "SKIPPED"
    fi
  done
  check L2 "foreign-owned files"     c_foreign
  check L2 "no programs in bin/"     c_profile_bins
  check L2 ".env variable names"     c_env_names
  info "-- L3 units"
  check L3 "common hardening drop-in" c_common_dropin
  check L3 "20-agent.conf"           c_agent_dropin
  check L3 "zz-home.conf"            c_home_dropin
  check L3 "user slice drop-in"      c_slice_dropin
  check L3 "linger"                  c_linger
  check L3 "unit user"               c_unit_user
  check L3 "effective hardening"     c_unit_hardening
  check L3 "ReadWritePaths"          c_unit_rw
  check L3 "memory limits"           c_unit_mem
  info "-- L4 runtime"
  check L4 "gateway state"           c_active
  check L4 "HOME of the gateway"     c_proc_home
  check L4 "tracebacks since start"  c_tracebacks
  check L4 "new permission errors"   c_perm_errors
  check L4 "A2A"                     c_a2a
  info "-- L5 isolation and configuration"
  for o in $(list_agents); do [[ $o == "$A" ]] || check L5 "isolation from $o" c_cross_read "$o"; done
  check L5 "no access to admin homes" c_admin_home
  check L5 "$HERMES_ROOT not writable" c_root_ro
  check L5 "no own files in /opt /usr/local /etc" c_sys_owned
  check L5 "nothing writable in /opt /usr/local /etc" c_sys_writable
  check L5 "model"                   c_model
  check L5 "connections toolset"     c_connections
  check L5 "gateway mode"            c_standalone
  [[ $KANBAN_DISPATCH == yes ]] && check L5 "Kanban dispatch" c_dispatch
  [[ -f $SYSTEMD_DIR/$S.service.d/override.conf ]] && info "note: $S.service.d/override.conf exists (not managed, contents not shown)"
  info "== $A: $OK OK, $BAD MISSING"
  TOTAL_OK=$((TOTAL_OK+OK)); TOTAL_BAD=$((TOTAL_BAD+BAD))
  (( BAD == 0 )) || FAILED_AGENTS="$FAILED_AGENTS $A"
done

section "Summary"
info "checks: $TOTAL_OK OK, $TOTAL_BAD MISSING"
# shellcheck disable=SC2015  # info never fails, so the fallback runs only when the test is false
[[ -z $FAILED_AGENTS ]] && info "all as defined" || info "deviations:$FAILED_AGENTS  (hermes-agent-lock.sh <agent> corrects layers L1-L3, --host the host layer)"
log_finish
[[ -z $FAILED_AGENTS ]] || exit 2
exit 0
