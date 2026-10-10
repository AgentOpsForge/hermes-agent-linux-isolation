# shellcheck shell=bash
# hermes-agent-lib.sh - shared definitions for hermes-agent-verify.sh, -lock.sh and -create.sh.
# Not executable on its own. Reads the target state from platform.toml (through hermes-agent-lib.py),
# defines the checks against it and the logging, so that all scripts check exactly the same things.
#
# Every check function c_<name> sets two globals and returns 0 (as wanted) or 1 (deviation):
#   WANT  the target value, ACT  the actual value (both one line, no secrets)

# --- Paths (can be overridden in the environment) ------------------------------------------
SYSTEMD_DIR=${SYSTEMD_DIR:-/etc/systemd/system}
LOG_DIR=${LOG_DIR:-/var/log/hermes-agent}
BACKUP_DIR=${BACKUP_DIR:-/var/backups/hermes}
REPORT_DIR=${REPORT_DIR:-}                    # optional: a copy of each log is written here
COMMON_DROPIN=$SYSTEMD_DIR/hermes-gateway-.service.d/10-hardening.conf
LEGACY_COMMON_DROPIN=$SYSTEMD_DIR/hermes-gateway-.service.d/10-haertung.conf
LOCKED_FILES="config.yaml SOUL.md .hermes.md .env"   # root:<agent>-agent 0640 + immutable when present
ROOT_ENTRIES="kanban kanban.db profiles"       # the only entries allowed in $HERMES_ROOT itself
PY=${PY:-/usr/bin/python3}                     # system Python for helpers (never the Hermes venv as root)
# Programs Hermes looks for in $HERMES_HOME/bin before (uv) or after (tirith) PATH and downloads there when missing.
# In an agent-owned profile the agent could replace them (tirith is the command scanner), so they belong root-owned
# into /usr/local/bin and nowhere in a profile.
MANAGED_BINS="tirith uv uvx"
SYS_TIRITH=${SYS_TIRITH:-/usr/local/bin/tirith}
# Journal lines that are expected under isolation and are not counted as errors.
KNOWN_WARNINGS='other profiles not readable|Could not resolve profile homes for cron|Could not save allowlist'
# TOOL_DIR must be set by the caller (directory of the scripts, platform.toml and units/).
: "${TOOL_DIR:?TOOL_DIR must be set before sourcing hermes-agent-lib.sh}"
PLATFORM=${PLATFORM:-$TOOL_DIR/platform.toml}  # single source of truth: domains, zones, vaults, agents
LIBPY=$TOOL_DIR/hermes-agent-lib.py
UNIT_TEMPLATE=$TOOL_DIR/units/hermes-gateway-hardening.conf
platform() { "$PY" -I "$LIBPY" "$@"; }
# Host values from [host] in platform.toml: HERMES_INSTALL, HERMES_ROOT, ROOT_GROUP, ROOT_MODE (env overrides win)
[[ -f $LIBPY ]] || { echo "ERROR: missing $LIBPY"; return 1; }
"$PY" -c 'import tomllib' 2>/dev/null || { echo "ERROR: $PY has no tomllib (Python 3.11+ needed)"; return 1; }
_host_env=$(platform host-env "$PLATFORM") || { echo "ERROR: cannot read [host] from $PLATFORM"; return 1; }
eval "$_host_env"; unset _host_env
# Kanban homes of the domains, admins, and the groups admins must not be in (all from platform.toml)
_host_lists=$(platform host-lists "$PLATFORM") || { echo "ERROR: cannot read the host lists from $PLATFORM"; return 1; }
KANBANS=() ADMINS=() FORBIDDEN=() SERVICES=() VAULTS=() AGENTIDS=()
while read -r _k _a _b _c _d; do
  case $_k in
    kanban) KANBANS+=("$_a $_b $_c $_d") ;; admin) ADMINS+=("$_a") ;; forbidden) FORBIDDEN+=("$_a") ;;
    service) SERVICES+=("$_a $_b $_c") ;; vault) VAULTS+=("$_a $_b $_c") ;; agentid) AGENTIDS+=("$_a $_b $_c") ;;
  esac
done <<<"$_host_lists"
unset _host_lists _k _a _b _c _d
KANBAN_OBSOLETE=""   # P-03 keeps .dispatcher.lock as the live notify-owner lock; nothing is obsolete now

# --- Logging --------------------------------------------------------------------------------
LOG_FILE="" TEE_PID="" LOG_DONE=0
log_init() {   # $1 = name of the run, e.g. "lock-assistant"; opens the log and mirrors stdout/stderr into it
  local name=$1 stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  install -d -m 0750 "$LOG_DIR" || { echo "ERROR: cannot create log directory $LOG_DIR" >&2; exit 1; }
  LOG_FILE=$LOG_DIR/$name-$stamp.log
  { : > "$LOG_FILE" && chmod 0640 "$LOG_FILE"; } || { echo "ERROR: cannot write $LOG_FILE" >&2; exit 1; }
  exec > >(tee -a "$LOG_FILE") 2>&1
  TEE_PID=$!
}
log_finish() {   # flushes the log; copies it to REPORT_DIR (if set). Call once, as the last action.
  (( LOG_DONE == 0 )) || return 0; LOG_DONE=1
  [[ -n $LOG_FILE ]] || return 0
  echo "Log: $LOG_FILE${REPORT_DIR:+ (copy in $REPORT_DIR)}"
  exec 1>&- 2>&-
  # shellcheck disable=SC2015  # the || true is a guard; wait failing is harmless here
  [[ -n $TEE_PID ]] && wait "$TEE_PID" 2>/dev/null || true
  if [[ -n $REPORT_DIR ]]; then
    # shellcheck disable=SC2015  # best-effort copy; the trailing || true swallows any failure
    install -d "$REPORT_DIR" 2>/dev/null && cp "$LOG_FILE" "$REPORT_DIR/" 2>/dev/null \
      && chown --reference="$REPORT_DIR" "$REPORT_DIR/${LOG_FILE##*/}" 2>/dev/null || true
  fi
}
ts() { date '+%Y-%m-%d %H:%M:%S'; }
section() { printf '\n%s === %s ===\n' "$(ts)" "$*"; }
info() { printf '%s   %s\n' "$(ts)" "$*"; }
# One table row: layer, item, wanted, before, after, result
row() { printf '%s   %-3s %-34s | want: %-28s | before: %-28s | after: %-28s | %s\n' "$(ts)" "$1" "$2" "$3" "$4" "$5" "$6"; }
# One check row (verify): layer, item, wanted, actual, result
crow() { printf '%s   %-3s %-34s | want: %-34s | actual: %-34s | %s\n' "$(ts)" "$1" "$2" "$3" "$4" "$5"; }
# Masks long token-like strings in text that comes from the system (journal lines).
mask() { sed -E 's/[A-Za-z0-9_+=-]{32,}/***/g'; }
to_bytes() {   # 768M, 1G, 1536M, 512K or plain bytes -> bytes (base 1024, as systemd)
  local v=$1 n u; n=${v%[KMGTkmgt]}; u=${v:${#n}}
  [[ $n =~ ^[0-9]+$ ]] || { echo "invalid:$v"; return 0; }
  case ${u^^} in K) echo $((n*1024));; M) echo $((n*1024**2));; G) echo $((n*1024**3));; T) echo $((n*1024**4));; *) echo "$n";; esac
}

# --- Agent definition -----------------------------------------------------------------------
load_agent() {   # $1 = agent name; sets NAME U D S AUID and the values derived from platform.toml
  local a=$1 env
  [[ $a =~ ^[a-z][a-z0-9-]{1,20}$ ]] || { echo "ERROR: invalid agent name '$a' (a-z, 0-9, -; 2-21 chars)"; return 1; }
  env=$(platform agent-env "$PLATFORM" "$a") || return 1   # the Python part prints the reason
  eval "$env"
  [[ $NAME == "$a" ]] || { echo "ERROR: definition of '$a' could not be loaded"; return 1; }
  local f; for f in ID MODEL PROVIDER MEM_HIGH MEM_MAX SLICE_MEM; do
    [[ -n ${!f} ]] || { echo "ERROR: $f is empty for agent $a in $PLATFORM"; return 1; }
  done
  U=$NAME-agent; D=$HERMES_ROOT/profiles/$NAME; S=hermes-gateway-$NAME
  AUID=$(id -u "$U" 2>/dev/null || true)
  return 0
}
list_agents() { platform agents "$PLATFORM"; }

# --- Target content of the managed systemd files ----------------------------------------------
want_agent_dropin() {
  echo "# Per-agent part of the gateway hardening, generated from platform.toml. Do not edit; run hermes-agent-lock.sh."
  echo "# Common part: $COMMON_DROPIN"
  echo "[Service]"
  echo "ReadWritePaths=$D${RW_PATHS:+ $RW_PATHS}"
  echo "BindPaths=-/run/user/$AUID"
  echo "MemoryHigh=$MEM_HIGH"
  echo "MemoryMax=$MEM_MAX"
}
want_home_dropin() {
  echo "# HOME = profile, generated from platform.toml. Named zz- so it wins over override.conf. Do not edit."
  echo "[Service]"
  echo "Environment=HOME=$D"
  local e; for e in $EXTRA_ENV; do echo "Environment=$e"; done
}
want_slice_dropin() {
  echo "# Limits for the worker scopes and the user manager of $U, generated from platform.toml. Do not edit."
  echo "[Slice]"
  echo "MemoryMax=$SLICE_MEM"
  echo "TasksMax=512"
}
agent_dropin_path() { echo "$SYSTEMD_DIR/$S.service.d/20-agent.conf"; }
home_dropin_path()  { echo "$SYSTEMD_DIR/$S.service.d/zz-home.conf"; }
slice_dropin_path() { echo "$SYSTEMD_DIR/user-$AUID.slice.d/50-hermes.conf"; }
# compares a file with generated content: 0 = identical
same_content() { [[ -f $1 ]] && cmp -s "$1" <("$2"); }
# same settings, comments ignored: a comment-only difference needs no restart (lock refreshes it with a reload)
same_settings() { [[ -f $1 ]] && cmp -s <(grep -v '^#' "$1") <("$2" | grep -v '^#'); }
dropin_state() {   # $1 path, $2 generator: sets ACT; 0 = settings as generated
  if [[ ! -f $1 ]]; then ACT=missing; return 1; fi
  if same_content "$1" "$2"; then ACT="= generated"; return 0; fi
  if same_settings "$1" "$2"; then ACT="= generated (comment outdated)"; return 0; fi
  ACT=differs; return 1
}

# --- Helpers ----------------------------------------------------------------------------------
as_agent() { runuser -u "$U" -- "$@"; }
is_immutable() { lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q i; }
ext_acl_files() { getfacl -R -s -p "$1" 2>/dev/null | grep -c '^# file:' || true; }   # files with extended ACL entries
file_state() { [[ -e $1 ]] || { echo "missing"; return; }; printf '%s %s' "$(stat -c '%U:%G %a' "$1")" "$(is_immutable "$1" && echo +i || echo -i)"; }
agent_groups_actual() { id -nG "$U" 2>/dev/null | tr ' ' '\n' | grep -vx "$U" | sort | tr '\n' ' ' | sed 's/ $//'; }
agent_groups_want() { tr ' ' '\n' <<<"$AGENT_GROUPS" | grep . | sort | tr '\n' ' ' | sed 's/ $//'; }
unit_prop() { systemctl show -p "$1" --value "$S" 2>/dev/null; }
main_pid_env() { local p; p=$(unit_prop MainPID); [[ $p =~ ^[1-9][0-9]*$ ]] && tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep "^$1=" | head -1 | cut -d= -f2-; }

# --- Owner tool: hermes-agent-lib.py owner ... (never follows symlinks; uutils chown -h changed link targets, B25)
owner_tool() { platform owner "$@"; }
# exact mode incl. clearing setgid: a directory created below a setgid directory inherits setgid, and chmod 0700
# keeps it on directories (GNU and uutils); os.chmod sets exactly the given bits
exact_mode() { "$PY" -I -c 'import os, sys; os.chmod(sys.argv[1], int(sys.argv[2], 8))' "$1" "$2"; }

# --- Checks: host layer (lock --host, verify --host) ------------------------------------------------
c_code_owner() {   # whole install tree: root:root, nothing writable for group/other, readable for all
  local out n; WANT="0 entries differ"
  out=$(owner_tool count "$HERMES_INSTALL" 2>&1) || { ACT="check failed: $(head -1 <<<"$out")"; return 1; }
  n=$(head -1 <<<"$out"); ACT="$n entries differ"
  [[ $n == 0 ]] || ACT="$ACT, e.g. uid/mode/path $(sed -n 2p <<<"$out")"
  [[ $n == 0 ]]
}
c_platform() {   # rules of platform.toml (domains, zones, vaults, A2A, ids); warnings do not fail
  local out rc=0; WANT="0 errors"
  out=$(platform check "$PLATFORM" 2>&1) || rc=1
  ACT=$(tail -1 <<<"$out"); (( rc == 0 )) || ACT="$ACT: $(grep -m1 '^ERROR' <<<"$out")"
  return $rc
}
acl_named() { getfacl -cp "$1" 2>/dev/null | grep -cE '^(user|group):[^:]+:' || true; }   # named ACL entries
others_traverse() { (( 8#$ROOT_MODE & 1 )); }   # mode lets every user traverse: ACL entries are not needed
root_dir_state() {   # $1 directory: owner root:ROOT_GROUP, mode ROOT_MODE; no ACL when others may traverse
  local n
  WANT="root:$ROOT_GROUP $ROOT_MODE"; ACT=$(stat -c '%U:%G %a' "$1" 2>/dev/null || echo missing)
  if others_traverse; then
    WANT+=", no ACL"; n=$(acl_named "$1"); [[ $n == 0 ]] && ACT+=", no ACL" || ACT+=", $n ACL entries"
  fi
  [[ $ACT == "$WANT" ]]
}
c_root_dir()     { root_dir_state "$HERMES_ROOT"; }
c_profiles_dir() { root_dir_state "$HERMES_ROOT/profiles"; }
c_kanban_groups() {   # the kanban group of each domain has the defined name at its gid
  local k g gid name want="" act=""
  for k in "${KANBANS[@]}"; do
    read -r _ _ g gid <<<"$k"   # fields: domain home group gid
    name=$(getent group "$gid" | cut -d: -f1 || true)
    want+="$gid=$g "; act+="$gid=${name:-missing} "
  done
  WANT=${want% }; ACT=${act% }; WANT=${WANT:-"(no kanban)"}; ACT=${ACT:-"(no kanban)"}
  [[ $ACT == "$WANT" ]]
}
admin_bad_groups() {   # "admin group" for each forbidden group (agent, vault, kanban) an admin is in
  local a gid k g kgid fg=" "
  # every command may fail without effect: this runs in command substitutions, where the ERR trap would fire
  for g in "${FORBIDDEN[@]}"; do gid=$(getent group "$g" | cut -d: -f3 || true); if [[ -n $gid ]]; then fg+="$gid "; fi; done
  for k in "${KANBANS[@]}"; do read -r _ _ _ kgid <<<"$k"; fg+="$kgid "; done   # fields: domain home group gid
  for a in "${ADMINS[@]}"; do
    for gid in $(id -G "$a" 2>/dev/null || true); do
      if [[ $fg == *" $gid "* ]]; then echo "$a $(getent group "$gid" | cut -d: -f1 || true)"; fi
    done
  done | sort -u
}
c_admin_groups() { local x; WANT="none"; x=$(admin_bad_groups | tr '\n' ',' | sed 's/,$//; s/,/, /g'); ACT=${x:-none}; [[ -z $x ]]; }
c_kanban_owner() {   # nothing in a kanban home belongs to an admin
  local k home a n=0 x
  for k in "${KANBANS[@]}"; do
    read -r _ home _ _ <<<"$k"   # fields: domain home group gid; only home is used
    for a in "${ADMINS[@]}"; do
      id -u "$a" >/dev/null 2>&1 || continue
      x=$(find "$home" -xdev -user "$a" 2>/dev/null | wc -l || true); n=$((n + x))
    done
  done
  WANT="0 entries owned by admins"; ACT="$n entries owned by admins"; (( n == 0 ))
}
kanban_obsolete() {   # obsolete files in the kanban homes, one path per line
  local k home f
  for k in "${KANBANS[@]}"; do
    read -r _ home _ _ <<<"$k"   # fields: domain home group gid; only home is used
    for f in $KANBAN_OBSOLETE; do if [[ -e $home/$f ]]; then echo "$home/$f"; fi; done
  done; return 0
}
service_def() {   # $1 service name: prints "<uid> <home>" from platform.toml, empty if not defined
  local s n u h; for s in "${SERVICES[@]}"; do read -r n u h <<<"$s"; if [[ $n == "$1" ]]; then echo "$u $h"; fi; done; return 0
}
c_signal_service() {   # signal-cli runs as its own user with its data in its home, nothing under a human home
  local uid home unit_user proc_user own
  read -r uid home <<<"$(service_def signal-cli)"
  if [[ -z $uid ]]; then WANT="not defined"; ACT="not defined"; return 0; fi
  WANT="user signal-cli uid $uid, unit signal-cli and process signal-cli, $home signal-cli 700"
  unit_user=$(systemctl show -p User --value signal-cli.service 2>/dev/null || true)
  proc_user=$(stat -c %U "/proc/$(systemctl show -p MainPID --value signal-cli.service 2>/dev/null || echo 0)" 2>/dev/null || echo none)
  own=$(stat -c '%U %a' "$home" 2>/dev/null || echo missing)
  ACT="user signal-cli uid $(id -u signal-cli 2>/dev/null || echo missing), unit ${unit_user:-root} and process $proc_user, $home $own"
  [[ $ACT == "$WANT" ]]
}
c_tirith() {   # tirith system-wide: root-owned, not writable for group/other, runs (Hermes finds it in PATH first)
  local own mode ver
  WANT="$SYS_TIRITH root:root, not group/other writable, runs"
  [[ -f $SYS_TIRITH ]] || { ACT="$SYS_TIRITH missing"; return 1; }
  own=$(stat -c '%U:%G' "$SYS_TIRITH"); mode=$(stat -c '%a' "$SYS_TIRITH")
  ver=$("$SYS_TIRITH" --version 2>/dev/null | head -1 || true)
  ACT="$SYS_TIRITH $own $mode, ${ver:-does not run}"
  [[ $own == root:root ]] && (( (8#$mode & 8#022) == 0 )) && [[ -n $ver ]]
}
c_kanban_obsolete() { local x; WANT="none"; x=$(kanban_obsolete | tr '\n' ' ' | sed 's/ $//'); ACT=${x:-none}; [[ -z $x ]]; }
root_extra() {   # entries in $HERMES_ROOT besides ROOT_ENTRIES, one per line
  local e
  find "$HERMES_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | while read -r e; do
    [[ " $ROOT_ENTRIES " == *" $e "* ]] || echo "$e"
  done
}
c_root_clean() { local x; WANT="only $ROOT_ENTRIES"; x=$(root_extra | tr '\n' ' ' | sed 's/ $//'); ACT=${x:+"also $x"}; ACT=${ACT:-$WANT}; [[ -z $x ]]; }

# --- Checks: L1 identity ------------------------------------------------------------------------
c_user()     { WANT="$U uid=$ID gid=$GID"; ACT=$(getent passwd "$U" | awk -F: '{print $1" uid="$3" gid="$4}'); [[ $ACT == "$WANT" ]]; }
c_shell()    { WANT=/usr/sbin/nologin; ACT=$(getent passwd "$U" | cut -d: -f7); [[ $ACT == "$WANT" ]]; }
c_home()     { WANT=$D; ACT=$(getent passwd "$U" | cut -d: -f6); [[ $ACT == "$WANT" ]]; }
c_no_home()  { WANT="absent"; [[ -e /home/$U ]] && ACT="present" || ACT="absent"; [[ $ACT == "$WANT" ]]; }
c_no_sudo()  { WANT="none"; sudo -l -U "$U" 2>/dev/null | grep -qE '\(ALL|NOPASSWD' && ACT="has sudo rights" || ACT="none"; [[ $ACT == "$WANT" ]]; }
c_groups()   { WANT=$(agent_groups_want); WANT=${WANT:-"(none)"}; ACT=$(agent_groups_actual); ACT=${ACT:-"(none)"}; [[ $ACT == "$WANT" ]]; }

# --- Checks: L2 profile ---------------------------------------------------------------------------
c_profile_dir() { WANT="$U:$U 700"; ACT=$(stat -c '%U:%G %a' "$D" 2>/dev/null || echo missing); [[ $ACT == "$WANT" ]]; }
c_profile_acl() { WANT="0 files with ACL"; ACT="$(ext_acl_files "$D") files with ACL"; [[ $ACT == "$WANT" ]]; }
c_locked()      { WANT="root:$U 640 +i"; ACT=$(file_state "$D/$1"); [[ $ACT == "$WANT" ]]; }
c_foreign() {   # files not owned by the agent, except the locked files
  local lf=() f; for f in $LOCKED_FILES; do lf+=(-e "$f"); done
  WANT="0"; ACT=$(find "$D" -xdev ! -user "$U" -printf '%P\n' 2>/dev/null | grep -vxF "${lf[@]}" | grep -c . || true)
  [[ $ACT == "$WANT" ]]
}
c_profile_bins() {   # none of the programs Hermes manages lies in the profile (the agent could replace them)
  local b x=""
  WANT="none of: $MANAGED_BINS"
  for b in $MANAGED_BINS; do if [[ -e $D/bin/$b || -L $D/bin/$b ]]; then x+="$b "; fi; done
  if [[ -z $x ]]; then ACT=$WANT; return 0; fi
  ACT="bin/: ${x% }"; return 1
}
c_env_names() {  # only allowed variable names in .env (values are never read into the log)
  local extra
  extra=$(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$D/.env" 2>/dev/null \
          | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//' | grep -vxF -f <(tr ' ' '\n' <<<"$ENV_ALLOWED") | tr '\n' ' ' || true)
  WANT="only ENV_ALLOWED"; ACT=${extra:-"only ENV_ALLOWED"}; [[ -z $extra ]]
}

# --- Checks: L3 units -----------------------------------------------------------------------------
c_common_dropin() {
  WANT="10-hardening.conf = template"
  if [[ -f $LEGACY_COMMON_DROPIN ]]; then ACT="legacy 10-haertung.conf present"
  elif [[ ! -f $COMMON_DROPIN ]]; then ACT="10-hardening.conf missing"
  elif cmp -s "$COMMON_DROPIN" "$UNIT_TEMPLATE"; then ACT=$WANT
  else ACT="10-hardening.conf differs"; fi
  [[ $ACT == "$WANT" ]]
}
c_agent_dropin() { WANT="= generated"; dropin_state "$(agent_dropin_path)" want_agent_dropin; }
c_home_dropin()  { WANT="= generated"; dropin_state "$(home_dropin_path)" want_home_dropin; }
c_slice_dropin() { WANT="= generated"; if [[ -z $AUID ]]; then ACT="no uid"; return 1; fi; dropin_state "$(slice_dropin_path)" want_slice_dropin; }
c_linger()       { WANT=$LINGER; ACT=$(loginctl show-user "$U" -p Linger --value 2>/dev/null || echo no); ACT=${ACT:-no}; [[ $ACT == "$WANT" ]]; }
c_unit_user()    { WANT="$U"; ACT=$(unit_prop User); [[ $ACT == "$WANT" ]]; }
c_unit_hardening() {
  WANT="strict tmpfs nnp=yes"
  ACT="$(unit_prop ProtectSystem) $(unit_prop ProtectHome) nnp=$(unit_prop NoNewPrivileges)"
  [[ $ACT == "$WANT" ]]
}
c_unit_rw()      { WANT="profile in ReadWritePaths"; unit_prop ReadWritePaths | tr ' ' '\n' | grep -qx "$D" && ACT="$WANT" || ACT="profile missing"; [[ $ACT == "$WANT" ]]; }
c_unit_mem()     { WANT="gateway $MEM_MAX, slice $SLICE_MEM"; ACT="gateway $(unit_prop MemoryMax), slice $(systemctl show -p MemoryMax --value "user-$AUID.slice" 2>/dev/null)"
  # systemd reports bytes; compare with the wanted values converted to bytes
  [[ $(unit_prop MemoryMax) == "$(to_bytes "$MEM_MAX")" && $(systemctl show -p MemoryMax --value "user-$AUID.slice" 2>/dev/null) == "$(to_bytes "$SLICE_MEM")" ]]
}

# --- Checks: L4 runtime ---------------------------------------------------------------------------
c_active()   { WANT=active; ACT=$(systemctl is-active "$S" 2>/dev/null || true); [[ $ACT == "$WANT" ]]; }
c_proc_home(){ WANT=$D; ACT=$(main_pid_env HOME); ACT=${ACT:-"(not set)"}; [[ $ACT == "$WANT" ]]; }
c_tracebacks() {  # since the current start of the gateway
  local since; since=$(unit_prop ActiveEnterTimestamp)
  WANT=0; [[ -n $since ]] || { ACT="not started"; return 1; }
  ACT=$(journalctl -u "$S" --since "$since" --no-pager -o cat 2>/dev/null | grep -c '^Traceback' || true); [[ $ACT == 0 ]]
}
c_perm_errors() {
  local since; since=$(unit_prop ActiveEnterTimestamp)
  WANT=0; [[ -n $since ]] || { ACT="not started"; return 1; }
  ACT=$(journalctl -u "$S" --since "$since" --no-pager -o cat 2>/dev/null \
        | grep -iE 'permission denied|operation not permitted|read-only file system|could not save' | grep -cvE "$KNOWN_WARNINGS" || true)
  [[ $ACT == 0 ]]
}
# Real file access as the agent (not test -r/-w: those ignore ACLs with some coreutils).
c_agent_reads()  { WANT="readable"; as_agent head -c 1 "$D/$1" >/dev/null 2>&1 && ACT=readable || ACT="NOT readable"; [[ $ACT == "$WANT" ]]; }
c_agent_writes() { WANT="not writable"; as_agent sh -c ': >> "$1"' sh "$D/$1" 2>/dev/null && ACT="WRITABLE" || ACT="not writable"; [[ $ACT == "$WANT" ]]; }
c_agent_renames() {  # rename attempt; a successful rename is undone at once
  WANT="cannot rename"
  if as_agent mv "$D/$1" "$D/$1.locktest" 2>/dev/null; then mv "$D/$1.locktest" "$D/$1"; ACT="RENAMED (restored)"; return 1; fi
  ACT="cannot rename"
}

# --- Checks: isolation and configuration (verify only) ---------------------------------------------
c_cross_read() {  # $1 = other agent name
  WANT="no access"
  if as_agent ls "$HERMES_ROOT/profiles/$1" >/dev/null 2>&1; then ACT="$U reads $1"; return 1; fi
  if getent passwd "$1-agent" >/dev/null && runuser -u "$1-agent" -- ls "$D" >/dev/null 2>&1; then ACT="$1 reads $NAME"; return 1; fi
  ACT="no access"
}
c_admin_home()  {   # the agent must not reach any admin's home (admins come from platform.toml, not hard-coded)
  WANT="no access"; ACT="no access"
  local adm home
  for adm in "${ADMINS[@]}"; do
    home=$(getent passwd "$adm" | cut -d: -f6)
    [[ -n $home ]] || continue
    if as_agent ls "$home" >/dev/null 2>&1; then ACT="reads $home"; break; fi
  done
  [[ $ACT == "$WANT" ]]
}
c_root_ro()     { WANT="not writable"; as_agent sh -c ': > "$1/.locktest" && rm -f "$1/.locktest"' sh "$HERMES_ROOT" 2>/dev/null && ACT=WRITABLE || ACT="not writable"; [[ $ACT == "$WANT" ]]; }
c_sys_owned()   { WANT=0; ACT=$(find /opt /usr/local /etc -xdev \( -user "$U" -o -group "$U" \) 2>/dev/null | grep -c . || true); [[ $ACT == 0 ]]; }
c_sys_writable(){ WANT=0; ACT=$(as_agent find /opt /usr/local /etc -xdev -writable \( -type d -o -type f \) 2>/dev/null | grep -c . || true); [[ $ACT == 0 ]]; }
cfg() { as_agent env HOME="$D" HERMES_HOME="$D" "$HERMES_INSTALL/venv/bin/python" -c "import yaml; c=yaml.safe_load(open('$D/config.yaml')); print($1)" 2>/dev/null; }
c_model()       { WANT="$PROVIDER/$MODEL"; ACT="$(cfg "c['model']['provider']")/$(cfg "c['model']['default']")"; [[ $ACT == "$WANT" ]]; }
c_connections() { WANT="disabled"; [[ $(cfg "'connections' in ((c.get('agent') or {}).get('disabled_toolsets') or [])") == True ]] && ACT=disabled || ACT=enabled; [[ $ACT == "$WANT" ]]; }
c_standalone()  { WANT="not standalone"; [[ $(cfg "(c.get('gateway') or {}).get('standalone') is True") == False ]] && ACT="not standalone" || ACT="standalone"; [[ $ACT == "$WANT" ]]; }
c_dispatch()    { WANT="$NAME"; ACT=$(cfg "(c.get('kanban') or {}).get('dispatch_profiles')"); [[ $ACT == "$WANT" ]]; }
c_a2a() {
  if [[ -z $A2A_PORT ]]; then
    WANT="no A2A server"; grep -qE '^A2A_PORT=' "$D/.env" 2>/dev/null && ACT="A2A_PORT set in .env" || ACT="no A2A server"; [[ $ACT == "$WANT" ]]; return
  fi
  local code addr
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST "http://127.0.0.1:$A2A_PORT/" \
         -d '{"jsonrpc":"2.0","id":1,"method":"tasks/get","params":{"id":"x"}}' 2>/dev/null || true)
  addr=$(ss -ltnH "sport = :$A2A_PORT" 2>/dev/null | awk '{print $4}' | head -1)
  WANT="401 without token, loopback"; ACT="$code without token, ${addr:-not listening}"
  [[ $code == 401 && $addr =~ ^(127\.0\.0\.1|\[::1\]): ]]
}
