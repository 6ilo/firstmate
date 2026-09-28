#!/usr/bin/env bash
# Machine-scoped heavy-validation slot ledger shared by every local firstmate
# home, so the heavy runs on one machine (docs/configuration.md "Heavy
# validation slots" owns the heavy list and the operator-facing contract).
#
# Usage: fm-heavy-slot.sh acquire --task <id> --home <path> [--lane <ask|backlog>] [--run <id>] [--pid <pid>] [--worktree <path>] [--wait <secs>]
#        fm-heavy-slot.sh release --task <id> --home <path>
#        fm-heavy-slot.sh list [--home <path>]
#        fm-heavy-slot.sh reap [--home <path>]
#
# Ledger: $FM_HEAVY_SLOT_DIR, default ~/.local/state/firstmate/heavy-slots/.
#   holders/<key>.slot and waiters/<key>.wait are key=value records, keyed by
#   the canonical home path plus task id. Every mutation runs under one lock
#   at <ledger>/.lock, taken with bin/fm-wake-lib.sh's
#   fm_lock_acquire_wait_bounded, which owns stale-owner recovery; a live
#   holder that keeps it past FM_HEAVY_SLOT_LOCK_WAIT seconds (default 30)
#   fails the command with exit 1.
# Capacity: heavy_total (default 3) and ask_reserve (default 2) from the active
#   home's config/lanes.json when present (read with jq; the file is never
#   created here). An ask may take any free slot. A backlog holder may take one
#   only while backlog holders are fewer than heavy_total - ask_reserve.
# Gates, checked on every new acquire (defaults overridable in config/lanes.json):
#   max_load 16            refuse while the 1-minute load average is >= this
#   max_pressure_level 4   refuse while kern.memorystatus_vm_pressure_level >= this
#   max_swap_used_mb 7168  refuse while swap used (MB) is >= this
#   max_browser_pages 30   refuse while WebKit WebContent processes are > this
#   A reading this platform cannot take is reported as unknown and never
#   refuses. Tests inject readings with FM_HEAVY_SLOT_LOAD1,
#   FM_HEAVY_SLOT_PRESSURE_LEVEL, FM_HEAVY_SLOT_SWAP_USED_MB, and
#   FM_HEAVY_SLOT_BROWSER_PAGES; the value "unknown" forces an unknown reading.
# acquire:
#   --lane defaults to the lane= recorded in <home>/state/<task>.meta, else ask.
#   A task that already holds a slot refreshes its record (e.g. to add --run)
#   and succeeds without taking a second slot or re-checking the gates.
#   --pid defaults to the caller's parent process; --worktree defaults to the
#   current git top level. --wait polls every FM_HEAVY_SLOT_POLL seconds
#   (default 15) until the deadline.
#   An ask that is refused, or still waiting, records a waiter entry that list
#   shows so backlog work can see an ask needs a slot; it is removed when the
#   ask acquires, is released, or is reaped.
#   Exit 0 prints one "acquired ..." line; exit 3 prints one "refused: <reason>"
#   line, a declared wait rather than a failure; exit 2 is a usage error and
#   exit 1 any other error.
# release: frees the task's slot and waiter entry; idempotent (exit 0 when
#   nothing was held). bin/fm-teardown.sh calls it for every task it cleans up.
# list: compact agent-readable ledger, capacity, gate readings, and waiters.
# reap: frees a slot only on positive evidence - the holder pid is gone and
#   <home>/state/<task>.meta no longer exists, or the recorded no-mistakes run
#   has reached its ci step or a terminal outcome (`no-mistakes axi status
#   --run <id>` read in the recorded worktree). Unknown evidence keeps the
#   slot. Waiters are reaped on the same pid-and-meta evidence.
set -eu

SCRIPT_NAME=${0##*/}
LEDGER=${FM_HEAVY_SLOT_DIR:-$HOME/.local/state/firstmate/heavy-slots}
EXIT_REFUSED=3
CALLER_FM_HOME=${FM_HOME:-}
# shellcheck source=bin/fm-wake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  echo "error: $*" >&2
  exit 1
}

usage_error() {
  echo "error: $*" >&2
  echo "run '$SCRIPT_NAME --help' for usage" >&2
  exit 2
}

task_id_valid() {
  case "$1" in
  '' | *[!A-Za-z0-9._-]* | .*) return 1 ;;
  esac
}

canonical_home() {
  local h=$1
  (CDPATH='' cd -- "$h" 2>/dev/null && pwd -P) || printf '%s\n' "$h"
}

slot_key() {  # <home> <task>
  local sum
  sum=$(printf '%s' "$1" | cksum | awk '{print $1}')
  printf '%s-%s' "$sum" "$2"
}

record_get() {  # <file> <key>
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1" 2>/dev/null || true
}

pid_alive() {
  local pid=$1
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && return 0
  ps -p "$pid" >/dev/null 2>&1
}

# --- ledger lock -------------------------------------------------------------

LOCK_HELD=0
lock_acquire() {
  mkdir -p "$LEDGER/holders" "$LEDGER/waiters" || die "cannot create ledger $LEDGER"
  fm_lock_acquire_wait_bounded "$LEDGER/.lock" "${FM_HEAVY_SLOT_LOCK_WAIT:-30}" \
    || die "cannot lock heavy-slot ledger $LEDGER (held by pid ${FM_LOCK_HELD_PID:-unknown})"
  LOCK_HELD=1
}

lock_release() {
  [ "$LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$LEDGER/.lock" || true
  LOCK_HELD=0
}
trap lock_release EXIT

# --- configuration -----------------------------------------------------------

HEAVY_TOTAL=3
ASK_RESERVE=2
MAX_LOAD=16
MAX_PRESSURE=4
MAX_SWAP_MB=7168
MAX_PAGES=30

load_config() {  # <home or empty>
  local home=$1 file val key
  [ -n "$home" ] || return 0
  file="$home/config/lanes.json"
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || die "jq is required to read $file"
  jq -e 'type == "object"' "$file" >/dev/null 2>&1 || die "$file is not a JSON object"
  for key in heavy_total ask_reserve max_load max_pressure_level max_swap_used_mb max_browser_pages; do
    val=$(jq -r --arg k "$key" '.[$k] // empty' "$file")
    [ -n "$val" ] || continue
    case "$val" in
    *[!0-9.]* | .* | *.*.*) die "$file: $key must be a non-negative number (got '$val')" ;;
    esac
    case "$key" in
    heavy_total) HEAVY_TOTAL=$val ;;
    ask_reserve) ASK_RESERVE=$val ;;
    max_load) MAX_LOAD=$val ;;
    max_pressure_level) MAX_PRESSURE=$val ;;
    max_swap_used_mb) MAX_SWAP_MB=$val ;;
    max_browser_pages) MAX_PAGES=$val ;;
    esac
  done
  case "$HEAVY_TOTAL$ASK_RESERVE" in *.*) die "$file: heavy_total and ask_reserve must be whole numbers" ;; esac
  [ "$ASK_RESERVE" -le "$HEAVY_TOTAL" ] || die "$file: ask_reserve ($ASK_RESERVE) exceeds heavy_total ($HEAVY_TOTAL)"
}

# --- gate readings -----------------------------------------------------------

is_darwin() { [ "$(uname -s 2>/dev/null)" = Darwin ]; }

# Each reader prints a number or "unknown".
read_injected() {  # <var-name>
  local v=${!1-__unset__}
  [ "$v" != __unset__ ] || return 1
  printf '%s\n' "$v"
}

read_load1() {
  local v
  read_injected FM_HEAVY_SLOT_LOAD1 && return 0
  if is_darwin; then
    v=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
  elif [ -r /proc/loadavg ]; then
    v=$(awk '{print $1}' /proc/loadavg)
  fi
  number_or_unknown "${v:-}"
}

read_pressure() {
  local v
  read_injected FM_HEAVY_SLOT_PRESSURE_LEVEL && return 0
  is_darwin && v=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
  number_or_unknown "${v:-}"
}

read_swap_used_mb() {
  local v
  read_injected FM_HEAVY_SLOT_SWAP_USED_MB && return 0
  is_darwin && v=$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
  number_or_unknown "${v:-}"
}

read_browser_pages() {
  read_injected FM_HEAVY_SLOT_BROWSER_PAGES && return 0
  if is_darwin && command -v pgrep >/dev/null 2>&1; then
    pgrep -f 'com.apple.WebKit.WebContent' 2>/dev/null | awk 'END { print NR }'
    return 0
  fi
  echo unknown
}

number_or_unknown() {
  case "$1" in
  '' | *[!0-9.]* | .* | *.*.*) echo unknown ;;
  *) printf '%s\n' "$1" ;;
  esac
}

num_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }
num_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

GATE_LOAD='' GATE_PRESSURE='' GATE_SWAP_MB='' GATE_PAGES=''
read_gates() {
  GATE_LOAD=$(read_load1)
  GATE_PRESSURE=$(read_pressure)
  GATE_SWAP_MB=$(read_swap_used_mb)
  GATE_PAGES=$(read_browser_pages)
}

gates_line() {
  printf 'load1=%s/%s pressure=%s/%s swap_used_mb=%s/%s browser_pages=%s/%s' \
    "$GATE_LOAD" "$MAX_LOAD" "$GATE_PRESSURE" "$MAX_PRESSURE" \
    "$GATE_SWAP_MB" "$MAX_SWAP_MB" "$GATE_PAGES" "$MAX_PAGES"
}

# Prints the first refusing gate's reason, or nothing when every gate passes.
gate_refusal() {
  read_gates
  if [ "$GATE_LOAD" != unknown ] && num_ge "$GATE_LOAD" "$MAX_LOAD"; then
    echo "load average $GATE_LOAD is at or above $MAX_LOAD"
  elif [ "$GATE_PRESSURE" != unknown ] && num_ge "$GATE_PRESSURE" "$MAX_PRESSURE"; then
    echo "memory pressure level $GATE_PRESSURE is at or above $MAX_PRESSURE"
  elif [ "$GATE_SWAP_MB" != unknown ] && num_ge "$GATE_SWAP_MB" "$MAX_SWAP_MB"; then
    echo "swap used ${GATE_SWAP_MB}MB is at or above ${MAX_SWAP_MB}MB"
  elif [ "$GATE_PAGES" != unknown ] && num_gt "$GATE_PAGES" "$MAX_PAGES"; then
    echo "$GATE_PAGES browser page processes exceed $MAX_PAGES; close finished Playwright browsers and preview or Lavish tabs"
  fi
}

# --- ledger reads ------------------------------------------------------------

count_holders() {  # [lane]
  local f n=0
  for f in "$LEDGER"/holders/*.slot; do
    [ -f "$f" ] || continue
    if [ -z "${1:-}" ] || [ "$(record_get "$f" lane)" = "$1" ]; then
      n=$((n + 1))
    fi
  done
  echo "$n"
}

capacity_refusal() {  # <lane>
  local total backlog backlog_cap
  total=$(count_holders)
  if [ "$total" -ge "$HEAVY_TOTAL" ]; then
    echo "all $HEAVY_TOTAL heavy slots are held"
    return 0
  fi
  if [ "$1" = backlog ]; then
    backlog=$(count_holders backlog)
    backlog_cap=$((HEAVY_TOTAL - ASK_RESERVE))
    if [ "$backlog" -ge "$backlog_cap" ]; then
      echo "backlog work may hold at most $backlog_cap of $HEAVY_TOTAL heavy slots; $ASK_RESERVE are reserved for asks"
    fi
  fi
}

write_record() {  # <path> <lines...>
  local path=$1 tmp
  shift
  tmp="$path.tmp.$$"
  printf '%s\n' "$@" >"$tmp"
  mv -f "$tmp" "$path"
}

# --- subcommands -------------------------------------------------------------

TASK='' HOME_ARG='' LANE='' RUN='' PID='' WORKTREE='' WAIT=0
parse_args() {
  local sub=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --task | --home | --lane | --run | --pid | --worktree | --wait)
      [ "$#" -ge 2 ] || usage_error "$1 requires a value"
      case "$1" in
      --task) TASK=$2 ;;
      --home) HOME_ARG=$2 ;;
      --lane) LANE=$2 ;;
      --run) RUN=$2 ;;
      --pid) PID=$2 ;;
      --worktree) WORKTREE=$2 ;;
      --wait) WAIT=$2 ;;
      esac
      shift 2
      ;;
    *) usage_error "unknown argument for $sub: $1" ;;
    esac
  done
}

need_task_home() {
  task_id_valid "$TASK" || usage_error "--task <id> is required and must be a plain task id"
  [ -n "$HOME_ARG" ] || usage_error "--home <path> is required"
  HOME_ARG=$(canonical_home "$HOME_ARG")
}

try_acquire() {  # sets ACQ_REASON on refusal; returns 0 acquired, 3 refused
  local key slot waiter reason
  key=$(slot_key "$HOME_ARG" "$TASK")
  slot="$LEDGER/holders/$key.slot"
  waiter="$LEDGER/waiters/$key.wait"
  lock_acquire
  if [ -f "$slot" ]; then
    # Refresh an existing hold (e.g. to add the run id) without a second slot.
    [ -n "$RUN" ] || RUN=$(record_get "$slot" run)
    write_record "$slot" "home=$HOME_ARG" "task=$TASK" "lane=$(record_get "$slot" lane)" \
      "pid=$PID" "run=$RUN" "worktree=$WORKTREE" "started=$(record_get "$slot" started)"
    rm -f "$waiter"
    lock_release
    ACQ_MSG="acquired heavy slot (refreshed) task=$TASK lane=$(record_get "$slot" lane) held=$(count_holders)/$HEAVY_TOTAL"
    return 0
  fi
  reason=$(capacity_refusal "$LANE")
  [ -n "$reason" ] || reason=$(gate_refusal)
  if [ -n "$reason" ]; then
    if [ "$LANE" = ask ]; then
      [ -f "$waiter" ] || write_record "$waiter" "home=$HOME_ARG" "task=$TASK" "pid=$PID" "since=$(date +%s)"
    fi
    lock_release
    ACQ_REASON=$reason
    return "$EXIT_REFUSED"
  fi
  write_record "$slot" "home=$HOME_ARG" "task=$TASK" "lane=$LANE" "pid=$PID" \
    "run=$RUN" "worktree=$WORKTREE" "started=$(date +%s)"
  rm -f "$waiter"
  ACQ_MSG="acquired heavy slot task=$TASK lane=$LANE held=$(count_holders)/$HEAVY_TOTAL"
  lock_release
  return 0
}

cmd_acquire() {
  local deadline rc meta poll
  parse_args acquire "$@"
  need_task_home
  [ -d "$HOME_ARG" ] || usage_error "--home $HOME_ARG is not a directory"
  if [ -z "$LANE" ]; then
    meta="$HOME_ARG/state/$TASK.meta"
    LANE=$(record_get "$meta" lane)
    [ -n "$LANE" ] || LANE=ask
  fi
  case "$LANE" in ask | backlog) ;; *) usage_error "--lane must be ask or backlog (got '$LANE')" ;; esac
  case "$WAIT" in '' | *[!0-9]*) usage_error "--wait takes whole seconds" ;; esac
  [ -n "$PID" ] || PID=$PPID
  case "$PID" in *[!0-9]*) usage_error "--pid must be a process id" ;; esac
  [ -n "$WORKTREE" ] || WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
  load_config "$HOME_ARG"
  poll=${FM_HEAVY_SLOT_POLL:-15}
  deadline=$(($(date +%s) + WAIT))
  while :; do
    ACQ_REASON='' ACQ_MSG=''
    rc=0
    try_acquire || rc=$?
    if [ "$rc" = 0 ]; then
      echo "$ACQ_MSG"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep "$poll"
  done
  echo "refused: $ACQ_REASON"
  return "$EXIT_REFUSED"
}

cmd_release() {
  local key had=0
  parse_args release "$@"
  need_task_home
  key=$(slot_key "$HOME_ARG" "$TASK")
  if [ ! -d "$LEDGER/holders" ]; then
    echo "no heavy slot held by task=$TASK"
    return 0
  fi
  lock_acquire
  [ ! -f "$LEDGER/holders/$key.slot" ] || had=1
  rm -f "$LEDGER/holders/$key.slot" "$LEDGER/waiters/$key.wait"
  lock_release
  if [ "$had" = 1 ]; then
    echo "released heavy slot task=$TASK"
  else
    echo "no heavy slot held by task=$TASK"
  fi
}

cmd_list() {
  local f n ask backlog w
  parse_args list "$@"
  [ -z "$HOME_ARG" ] || HOME_ARG=$(canonical_home "$HOME_ARG")
  [ -n "$HOME_ARG" ] || HOME_ARG=$CALLER_FM_HOME
  load_config "$HOME_ARG"
  mkdir -p "$LEDGER/holders" "$LEDGER/waiters" || die "cannot create ledger $LEDGER"
  n=$(count_holders)
  ask=$(count_holders ask)
  backlog=$(count_holders backlog)
  read_gates
  echo "ledger: $LEDGER"
  echo "slots: held=$n/$HEAVY_TOTAL ask=$ask backlog=$backlog/$((HEAVY_TOTAL - ASK_RESERVE))"
  echo "gates: $(gates_line)"
  echo "holders[$n]{home,task,lane,pid,run,worktree,started}:"
  for f in "$LEDGER"/holders/*.slot; do
    [ -f "$f" ] || continue
    printf '  %s,%s,%s,%s,%s,%s,%s\n' "$(record_get "$f" home)" "$(record_get "$f" task)" \
      "$(record_get "$f" lane)" "$(record_get "$f" pid)" "$(record_get "$f" run)" \
      "$(record_get "$f" worktree)" "$(record_get "$f" started)"
  done
  w=0
  for f in "$LEDGER"/waiters/*.wait; do [ -f "$f" ] && w=$((w + 1)); done
  echo "ask_waiters[$w]{home,task,pid,since}:"
  for f in "$LEDGER"/waiters/*.wait; do
    [ -f "$f" ] || continue
    printf '  %s,%s,%s,%s\n' "$(record_get "$f" home)" "$(record_get "$f" task)" \
      "$(record_get "$f" pid)" "$(record_get "$f" since)"
  done
}

# 0 when the record's pid is gone AND its task meta no longer exists.
holder_gone() {  # <record>
  local f=$1 pid home task
  pid=$(record_get "$f" pid)
  home=$(record_get "$f" home)
  task=$(record_get "$f" task)
  [ -n "$pid" ] && [ -n "$home" ] && [ -n "$task" ] || return 1
  pid_alive "$pid" && return 1
  [ ! -e "$home/state/$task.meta" ]
}

# 0 when the recorded no-mistakes run has reached ci or a terminal outcome.
run_past_heavy() {  # <record>
  local f=$1 run wt out status outcome ci
  run=$(record_get "$f" run)
  wt=$(record_get "$f" worktree)
  [ -n "$run" ] && [ -n "$wt" ] && [ -d "$wt" ] || return 1
  command -v no-mistakes >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then
    out=$(cd "$wt" && timeout 30 no-mistakes axi status --run "$run" 2>/dev/null) || return 1
  else
    out=$(cd "$wt" && no-mistakes axi status --run "$run" 2>/dev/null) || return 1
  fi
  # Only this run's own record counts as evidence.
  printf '%s\n' "$out" | grep -Eq "^ *id: \"?$run\"?$" || return 1
  status=$(printf '%s\n' "$out" | sed -n 's/^ *status: *"\{0,1\}\([a-z_]*\)"\{0,1\}$/\1/p' | head -1)
  outcome=$(printf '%s\n' "$out" | sed -n 's/^outcome: *\(.*\)$/\1/p' | head -1)
  ci=$(printf '%s\n' "$out" | awk -F, '$1 ~ /^ *ci$/ { print $2; exit }')
  [ -n "$outcome" ] && return 0
  case "$status" in completed | failed | cancelled | ci) return 0 ;; esac
  case "$ci" in running | completed | failed | cancelled) return 0 ;; esac
  return 1
}

remove_if_unchanged() {  # <record> <content read before its evidence was checked>
  local removed=1
  lock_acquire
  if [ "$(cat "$1" 2>/dev/null || true)" = "$2" ]; then
    rm -f "$1"
    removed=0
  fi
  lock_release
  return "$removed"
}

cmd_reap() {
  local f who snap freed=0 kept=0
  parse_args reap "$@"
  mkdir -p "$LEDGER/holders" "$LEDGER/waiters" || die "cannot create ledger $LEDGER"
  for f in "$LEDGER"/holders/*.slot; do
    snap=$(cat "$f" 2>/dev/null) || continue
    who="task=$(record_get "$f" task) home=$(record_get "$f" home)"
    if holder_gone "$f" && remove_if_unchanged "$f" "$snap"; then
      echo "reaped $who: holder and task record are gone"
      freed=$((freed + 1))
    elif run_past_heavy "$f" && remove_if_unchanged "$f" "$snap"; then
      echo "reaped $who: its validation run reached ci or finished"
      freed=$((freed + 1))
    else
      kept=$((kept + 1))
    fi
  done
  for f in "$LEDGER"/waiters/*.wait; do
    snap=$(cat "$f" 2>/dev/null) || continue
    if holder_gone "$f"; then
      remove_if_unchanged "$f" "$snap" || true
    fi
  done
  echo "reap: freed=$freed kept=$kept"
}

case "${1:-}" in
-h | --help | help)
  usage
  exit 0
  ;;
acquire | release | list | reap)
  sub=$1
  shift
  "cmd_$sub" "$@"
  ;;
'') usage_error "a subcommand is required" ;;
*) usage_error "unknown subcommand: $1" ;;
esac
