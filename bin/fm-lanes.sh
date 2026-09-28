#!/usr/bin/env bash
# Backlog-lane gate: decides, with no model call, whether scheduled backlog
# work may run on this machine right now (docs/configuration.md "Work lanes"
# owns the operator-facing rule and the calendar cache schema).
#
# Usage: fm-lanes.sh gate          print one verdict line
#        fm-lanes.sh check         dry run: log the verdict, print nothing
#        fm-lanes.sh idle-seconds  print keyboard/mouse idle seconds or "unknown"
#
# Active home: $FM_HOME, else this script's repository root. Its optional
# config/lanes.json is read with jq and never created.
#
# gate prints one line of space-separated key=value tokens:
#   verdict=open|closed branch=night-idle|calendar|daytime-quiet|- reason=<token>|-
#   followed by every input read. Closed reasons, first match wins:
#   config-invalid, ledger-unreadable, load-ceiling, memory, ask-waiting,
#   no-window. The lane is open only when the load ceiling is not tripped, no
#   memory gate of bin/fm-heavy-slot.sh refuses, no ask waiter is recorded in
#   its ledger, and one branch holds (checked in this order):
#     night-idle     local time in night_window and idle >= idle_secs
#     calendar       the calendar cache is fresh and now is inside a busy interval
#     daytime-quiet  outside night_window with 1- and 5-minute load both < quiet_load
#   Memory and ask-waiter readings come from `fm-heavy-slot.sh gates`, which
#   owns those readings, limits, and the ledger location.
# Load ceiling: a sample with the 1-minute load >= load_ceiling counts toward a
#   trip; two consecutive such samples trip the lane closed. A tripped lane
#   reopens once every sample has stayed under both reopen_load and
#   load_ceiling for reopen_secs.
#   Samples and trip state persist in <home>/state/lanes-load.state (replaced
#   atomically; concurrent gate calls may drop a sample, never corrupt it). An
#   unknown load reading records no sample.
# Calendar cache: $FM_LANES_CALENDAR_CACHE, else calendar_cache from
#   config/lanes.json, else ~/.local/state/firstmate/calendar-busy.json.
#   Missing, malformed, or older than calendar_max_age_secs reads as not busy.
# check: runs gate and appends "<epoch> <verdict line>" to
#   <home>/state/lanes-dryrun.log (trimmed to the newest
#   FM_LANES_LOG_MAX_LINES lines, default 2000). Prints nothing and exits 0,
#   so it is safe as a registered watcher check.
# Test injection: FM_LANES_NOW (epoch), FM_LANES_IDLE_SECS, FM_LANES_LOAD5, and
#   bin/fm-heavy-slot.sh's FM_HEAVY_SLOT_* readings (FM_HEAVY_SLOT_LOAD1 is the
#   1-minute load here too); "unknown" forces an unknown reading.
# Exit codes: gate and idle-seconds exit 0 on any verdict; 2 is a usage error.
set -eu

SCRIPT_NAME=${0##*/}
BIN_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ACTIVE_HOME=${FM_HOME:-$(dirname "$BIN_DIR")}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

usage_error() {
  echo "error: $*" >&2
  echo "run '$SCRIPT_NAME --help' for usage" >&2
  exit 2
}

number_or_unknown() {
  case "$1" in
  '' | *[!0-9.]* | .* | *.*.*) echo unknown ;;
  *) printf '%s\n' "$1" ;;
  esac
}

num_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }
num_lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }

# --- configuration -----------------------------------------------------------

NIGHT_WINDOW=23:00-07:00
IDLE_SECS=3600
QUIET_LOAD=6
LOAD_CEILING=16
REOPEN_LOAD=12
REOPEN_SECS=900
CAL_MAX_AGE=28800
CAL_CACHE=$HOME/.local/state/firstmate/calendar-busy.json
CONFIG_ERROR=''

hhmm_minutes() {  # <HH:MM> -> minutes since midnight, or fails
  case "$1" in
  [0-9][0-9]:[0-9][0-9]) ;;
  *) return 1 ;;
  esac
  local h=${1%%:*} m=${1##*:}
  h=$((10#$h))
  m=$((10#$m))
  [ "$h" -le 23 ] && [ "$m" -le 59 ] || return 1
  echo $((h * 60 + m))
}

load_config() {
  local file="$ACTIVE_HOME/config/lanes.json" key val
  if [ -n "${FM_LANES_CALENDAR_CACHE:-}" ]; then CAL_CACHE=$FM_LANES_CALENDAR_CACHE; fi
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1 || ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    CONFIG_ERROR="config/lanes.json is not a readable JSON object"
    return 0
  fi
  for key in idle_secs quiet_load max_load load_ceiling reopen_load reopen_secs calendar_max_age_secs; do
    val=$(jq -r --arg k "$key" '.[$k] // empty' "$file")
    [ -n "$val" ] || continue
    if [ "$(number_or_unknown "$val")" = unknown ]; then
      CONFIG_ERROR="config/lanes.json $key must be a non-negative number"
      return 0
    fi
    case "$key" in
    idle_secs) IDLE_SECS=$val ;;
    quiet_load) QUIET_LOAD=$val ;;
    max_load | load_ceiling) LOAD_CEILING=$val ;;
    reopen_load) REOPEN_LOAD=$val ;;
    reopen_secs) REOPEN_SECS=$val ;;
    calendar_max_age_secs) CAL_MAX_AGE=$val ;;
    esac
  done
  val=$(jq -r '.night_window // empty' "$file")
  if [ -n "$val" ]; then
    if ! hhmm_minutes "${val%%-*}" >/dev/null || ! hhmm_minutes "${val#*-}" >/dev/null; then
      CONFIG_ERROR="config/lanes.json night_window must be HH:MM-HH:MM"
      return 0
    fi
    NIGHT_WINDOW=$val
  fi
  val=$(jq -r '.calendar_cache // empty' "$file")
  if [ -n "$val" ] && [ -z "${FM_LANES_CALENDAR_CACHE:-}" ]; then CAL_CACHE=$val; fi
}

# --- readings ----------------------------------------------------------------

now_epoch() {
  case "${FM_LANES_NOW:-}" in
  '') date +%s ;;
  *[!0-9]*) usage_error "FM_LANES_NOW must be epoch seconds" ;;
  *) printf '%s\n' "$FM_LANES_NOW" ;;
  esac
}

local_hhmm() {  # <epoch>
  date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M
}

in_night_window() {  # <HH:MM>
  local t start end
  t=$(hhmm_minutes "$1") || return 1
  start=$(hhmm_minutes "${NIGHT_WINDOW%%-*}")
  end=$(hhmm_minutes "${NIGHT_WINDOW#*-}")
  if [ "$start" -le "$end" ]; then
    [ "$t" -ge "$start" ] && [ "$t" -lt "$end" ]
  else
    [ "$t" -ge "$start" ] || [ "$t" -lt "$end" ]
  fi
}

read_idle() {
  local v=''
  if [ -n "${FM_LANES_IDLE_SECS+x}" ]; then
    number_or_unknown "$FM_LANES_IDLE_SECS"
    return 0
  fi
  if command -v ioreg >/dev/null 2>&1; then
    v=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ { printf "%d\n", $NF / 1000000000; exit }')
  fi
  number_or_unknown "$v"
}

read_loadavg() {  # <field: 1 or 2> -> 1- or 5-minute load
  local v=''
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    v=$(sysctl -n vm.loadavg 2>/dev/null | awk -v f="$1" '{ print $(f + 1) }')
  elif [ -r /proc/loadavg ]; then
    v=$(awk -v f="$1" '{ print $f }' /proc/loadavg)
  fi
  number_or_unknown "$v"
}

read_load1() {
  if [ -n "${FM_HEAVY_SLOT_LOAD1+x}" ]; then number_or_unknown "$FM_HEAVY_SLOT_LOAD1"; else read_loadavg 1; fi
}

read_load5() {
  if [ -n "${FM_LANES_LOAD5+x}" ]; then number_or_unknown "$FM_LANES_LOAD5"; else read_loadavg 2; fi
}

# Prints busy, free, stale, missing, or malformed.
calendar_state() {  # <now>
  local now=$1
  [ -f "$CAL_CACHE" ] || { echo missing; return 0; }
  command -v jq >/dev/null 2>&1 || { echo malformed; return 0; }
  jq -r --argjson now "$now" --argjson maxage "$CAL_MAX_AGE" '
    if type == "object" and (.fetched_at | type) == "number" and (.busy | type) == "array"
       and all(.busy[]; type == "object" and (.start | type) == "number" and (.end | type) == "number")
    then
      if $now - .fetched_at > $maxage or .fetched_at > $now then "stale"
      elif any(.busy[]; .start <= $now and $now < .end) then "busy"
      else "free" end
    else "malformed" end' "$CAL_CACHE" 2>/dev/null || echo malformed
}

# --- load ceiling hysteresis -------------------------------------------------

LOAD_STATE_FILE=''
TRIPPED=0 HIGH_STREAK=0 BELOW_SINCE=''

state_get() {  # <key>
  awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$LOAD_STATE_FILE" 2>/dev/null || true
}

update_load_state() {  # <now> <load1>
  local now=$1 load=$2 tmp
  LOAD_STATE_FILE="$ACTIVE_HOME/state/lanes-load.state"
  TRIPPED=$(state_get tripped)
  HIGH_STREAK=$(state_get high_streak)
  BELOW_SINCE=$(state_get below_since)
  case "$TRIPPED" in 1) ;; *) TRIPPED=0 ;; esac
  case "$HIGH_STREAK" in '' | *[!0-9]*) HIGH_STREAK=0 ;; esac
  case "$BELOW_SINCE" in *[!0-9]*) BELOW_SINCE='' ;; esac
  [ "$load" != unknown ] || return 0
  if num_ge "$load" "$LOAD_CEILING"; then
    HIGH_STREAK=$((HIGH_STREAK + 1))
  else
    HIGH_STREAK=0
  fi
  if [ "$HIGH_STREAK" -ge 2 ]; then
    TRIPPED=1
  fi
  if [ "$TRIPPED" = 1 ]; then
    if num_lt "$load" "$REOPEN_LOAD" && num_lt "$load" "$LOAD_CEILING"; then
      [ -n "$BELOW_SINCE" ] || BELOW_SINCE=$now
      if [ $((now - BELOW_SINCE)) -ge "${REOPEN_SECS%%.*}" ]; then
        TRIPPED=0
        BELOW_SINCE=''
      fi
    else
      BELOW_SINCE=''
    fi
  else
    BELOW_SINCE=''
  fi
  mkdir -p "$ACTIVE_HOME/state" 2>/dev/null || return 0
  tmp="$LOAD_STATE_FILE.tmp.$$"
  if ! { printf 'tripped=%s\nhigh_streak=%s\nbelow_since=%s\nlast_sample=%s\nlast_load1=%s\n' \
    "$TRIPPED" "$HIGH_STREAK" "$BELOW_SINCE" "$now" "$load" >"$tmp" \
    && mv -f "$tmp" "$LOAD_STATE_FILE"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# --- verdict -----------------------------------------------------------------

gate_line() {
  local now hhmm night idle load1 load5 cal ledger gates mem waiters
  local verdict=closed branch=- reason=-
  now=$(now_epoch)
  load_config
  hhmm=$(local_hhmm "$now")
  night=0
  in_night_window "$hhmm" && night=1
  idle=$(read_idle)
  load1=$(read_load1)
  load5=$(read_load5)
  cal=$(calendar_state "$now")
  update_load_state "$now" "$load1"

  gates='' mem='' waiters=''
  if ledger=$(FM_HOME=$ACTIVE_HOME "$BIN_DIR/fm-heavy-slot.sh" gates --home "$ACTIVE_HOME" 2>/dev/null); then
    gates=$(printf '%s\n' "$ledger" | sed -n 's/^gates: //p')
    mem=$(printf '%s\n' "$ledger" | sed -n 's/^memory_refusal: //p')
    waiters=$(printf '%s\n' "$ledger" | sed -n 's/^ask_waiters: //p')
  fi
  case "$waiters" in '' | *[!0-9]*) waiters='' ;; esac

  if [ -n "$CONFIG_ERROR" ]; then
    reason="config-invalid"
  elif [ -z "$mem" ] || [ -z "$waiters" ]; then
    reason="ledger-unreadable"
  elif [ "$TRIPPED" = 1 ]; then
    reason="load-ceiling"
  elif [ "$mem" != none ]; then
    reason=memory
  elif [ "$waiters" -gt 0 ]; then
    reason="ask-waiting"
  elif [ "$night" = 1 ] && [ "$idle" != unknown ] && num_ge "$idle" "$IDLE_SECS"; then
    branch="night-idle"
  elif [ "$cal" = busy ]; then
    branch=calendar
  elif [ "$night" = 0 ] && [ "$load1" != unknown ] && [ "$load5" != unknown ] \
    && num_lt "$load1" "$QUIET_LOAD" && num_lt "$load5" "$QUIET_LOAD"; then
    branch="daytime-quiet"
  else
    reason="no-window"
  fi
  [ "$branch" = - ] || verdict=open

  printf 'verdict=%s branch=%s reason=%s now=%s local=%s night_window=%s in_night=%s idle_secs=%s/%s calendar=%s load1=%s load5=%s quiet_load=%s load_ceiling=%s reopen=%s/%ss tripped=%s high_streak=%s below_since=%s ask_waiters=%s memory=%s ledger_gates=[%s]' \
    "$verdict" "$branch" "$reason" "$now" "$hhmm" "$NIGHT_WINDOW" "$night" \
    "$idle" "$IDLE_SECS" "$cal" "$load1" "$load5" "$QUIET_LOAD" "$LOAD_CEILING" \
    "$REOPEN_LOAD" "$REOPEN_SECS" "$TRIPPED" "$HIGH_STREAK" "${BELOW_SINCE:--}" \
    "${waiters:-unknown}" "$(printf '%s' "${mem:-unknown}" | tr ' ' '_')" "$gates"
  [ -z "$CONFIG_ERROR" ] || printf ' config_error=%s' "$(printf '%s' "$CONFIG_ERROR" | tr ' ' '_')"
  printf '\n'
}

cmd_check() {
  local line log max tmp
  log="$ACTIVE_HOME/state/lanes-dryrun.log"
  max=${FM_LANES_LOG_MAX_LINES:-2000}
  case "$max" in '' | *[!0-9]*) max=2000 ;; esac
  line=$(gate_line 2>/dev/null) || line="verdict=closed branch=- reason=gate-error"
  mkdir -p "$ACTIVE_HOME/state" 2>/dev/null || return 0
  printf '%s %s\n' "$(now_epoch 2>/dev/null || date +%s)" "$line" >>"$log" 2>/dev/null || return 0
  if [ "$(wc -l <"$log" 2>/dev/null || echo 0)" -gt "$max" ]; then
    tmp="$log.tmp.$$"
    if ! { tail -n "$max" "$log" >"$tmp" && mv -f "$tmp" "$log"; } 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  return 0
}

case "${1:-}" in
-h | --help | help)
  usage
  exit 0
  ;;
gate)
  [ "$#" -eq 1 ] || usage_error "gate takes no arguments"
  gate_line
  ;;
check)
  [ "$#" -eq 1 ] || usage_error "check takes no arguments"
  cmd_check >/dev/null 2>&1 || true
  exit 0
  ;;
idle-seconds)
  [ "$#" -eq 1 ] || usage_error "idle-seconds takes no arguments"
  read_idle
  ;;
'') usage_error "a subcommand is required" ;;
*) usage_error "unknown subcommand: $1" ;;
esac
