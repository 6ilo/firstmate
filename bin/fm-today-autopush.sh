#!/usr/bin/env bash
# fm-today-autopush.sh - send the Today snapshot automatically, from the
# watcher, whenever the fleet it describes changes, plus a periodic top-up.
#
# Usage:
#   fm-today-autopush.sh tick
#   fm-today-autopush.sh take-notice
#   fm-today-autopush.sh --help
#
# tick         One scheduling decision, then at most one push through
#              bin/fm-today-bridge.sh push. bin/fm-watch.sh starts it detached
#              every FM_TODAY_PUSH_CHECK_SECS, so nothing here can delay the
#              watcher's beacon. It always exits 0 and prints nothing.
#              - It does nothing unless the bridge is configured in this home:
#                FM_TODAY_PORTAL_URL and FM_TODAY_BRIDGE_TOKEN both set, in the
#                environment or in $FM_HOME/.env, read the same way the bridge
#                reads them. A secondmate home (.fm-secondmate-home) never
#                pushes, because the portal keeps one snapshot per bridge. Only
#                the presence of the token is checked here; the bridge alone
#                reads its value, and it is never printed or copied.
#              - One tick runs at a time: a tick that finds another holding
#                state/.today-push.lock exits at once.
#              - No attempt starts within FM_TODAY_PUSH_MIN_SECS of the end of
#                the previous attempt, successful or not; that is the debounce, and it is
#                also the whole retry policy.
#              - Past that interval it builds the snapshot and fingerprints it,
#                ignoring the build and text-check stamps (generated_at,
#                checked_at). A fingerprint that differs from the last pushed
#                one pushes; an unchanged one pushes only once
#                FM_TODAY_PUSH_TOPUP_SECS have passed since that attempt ended,
#                so the portal keeps hearing from the fleet.
#              - The snapshot build and the push are each bounded by
#                FM_TODAY_PUSH_TIMEOUT. The push rebuilds the snapshot before
#                its own bounded send, so the one bound covers a slow build
#                plus that send. Nothing outside bounds a tick: the watcher
#                starts it detached and only waits for it before the next.
#              - A failed attempt (build, check, refusal, unreachable portal,
#                or timeout) records state/.today-push-notice with one line,
#                `check: today-push failed (<reason>)`, only when it starts a
#                failure episode; later failures in the same episode record
#                nothing. The next successful push ends the episode and drops
#                a notice not yet taken.
# take-notice  Print the pending failure notice line, if any, and remove it.
#              bin/fm-watch.sh calls this when the notice file exists and wakes
#              firstmate with the line.
#
# Settings (environment; defaults in brackets):
#   FM_TODAY_PUSH_MIN_SECS    [180] least time between two attempts
#   FM_TODAY_PUSH_TOPUP_SECS  [900] push an unchanged snapshot after this long
#   FM_TODAY_PUSH_TIMEOUT     [180] bound on the build and on the push, each
#   FM_TODAY_PUSH_CHECK_SECS  [60]  read by bin/fm-watch.sh: how often it
#                                   starts a tick
#
# State (this home's state/, all private to this script):
#   .today-push.state   last attempt and last successful push epochs, the
#                       pushed fingerprint, and whether an episode is open
#   .today-push-notice  the one pending notice line
#   .today-push.lock    single-flight lock
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BRIDGE="$SCRIPT_DIR/fm-today-bridge.sh"
STATE_FILE="$STATE/.today-push.state"
NOTICE_FILE="$STATE/.today-push-notice"
LOCK="$STATE/.today-push.lock"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

setting() {  # <value> <default>
  case "$1" in ''|*[!0-9]*|0) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
MIN_SECS=$(setting "${FM_TODAY_PUSH_MIN_SECS:-}" 180)
TOPUP_SECS=$(setting "${FM_TODAY_PUSH_TOPUP_SECS:-}" 900)
TIMEOUT=$(setting "${FM_TODAY_PUSH_TIMEOUT:-}" 180)

configured() {
  local key
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || return 1
  for key in FM_TODAY_PORTAL_URL FM_TODAY_BRIDGE_TOKEN; do
    if [ -z "${!key:-}" ] && [ -z "$(fmx_env_get "$key" "$FM_HOME/.env")" ]; then
      return 1
    fi
  done
}

ATTEMPTED_AT=0 PUSHED_AT=0 PUSHED_FP='' FAILING=0
read_state() {
  local key value
  [ -f "$STATE_FILE" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      attempted_at) case "$value" in ''|*[!0-9]*) ;; *) ATTEMPTED_AT=$value ;; esac ;;
      pushed_at) case "$value" in ''|*[!0-9]*) ;; *) PUSHED_AT=$value ;; esac ;;
      pushed_fp) PUSHED_FP=$value ;;
      failing) [ "$value" != 1 ] || FAILING=1 ;;
    esac
  done < "$STATE_FILE"
}

write_state() {
  local tmp="$STATE_FILE.tmp.$$"
  printf 'attempted_at=%s\npushed_at=%s\npushed_fp=%s\nfailing=%s\n' \
    "$ATTEMPTED_AT" "$PUSHED_AT" "$PUSHED_FP" "$FAILING" > "$tmp" \
    && mv -f "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}

# The reason a bridge run failed: its own last diagnostic line when it left
# one, otherwise its exit status. One line, capped, never the token (the bridge
# never prints it).
failure_reason() {  # <status> <stderr-file>
  local line
  if fm_timed_out "$1"; then
    printf 'timed out after %ss' "$TIMEOUT"
    return
  fi
  line=$(grep '^fm-today-bridge: ' "$2" 2>/dev/null | tail -n1 | tr -d '\000-\037\177' | cut -c1-200)
  line=${line#fm-today-bridge: }
  printf 'exit %s%s' "$1" "${line:+: $line}"
}

record_failure() {  # <reason>
  local tmp="$NOTICE_FILE.tmp.$$"
  if [ "$FAILING" -ne 1 ]; then
    printf 'check: today-push failed (%s)\n' "$1" > "$tmp" && mv -f "$tmp" "$NOTICE_FILE"
    rm -f "$tmp"
  fi
  FAILING=1
}

tick() {
  local now fp snap err status=0
  configured || return 0
  [ -d "$STATE" ] || return 0
  fm_lock_try_acquire "$LOCK" || return 0
  # shellcheck disable=SC2064 # Bind the lock path now.
  trap "fm_lock_release '$LOCK'; rm -f '$STATE/.today-push.'*'.$$'" EXIT
  read_state
  now=$(date +%s)
  [ $((now - ATTEMPTED_AT)) -ge "$MIN_SECS" ] || return 0

  snap="$STATE/.today-push.snap.$$"
  err="$STATE/.today-push.err.$$"
  fm_run_timed "$TIMEOUT" "$BRIDGE" snapshot > "$snap" 2> "$err" || status=$?
  if [ "$status" -eq 0 ]; then
    fp=$(jq -cS 'del(.generated_at) | walk(if type == "object" then del(.checked_at) else . end)' "$snap" 2>/dev/null | cksum)
    [ -n "$fp" ] || status=1
  fi
  if [ "$status" -eq 0 ] && [ "$fp" = "$PUSHED_FP" ] && [ $((now - ATTEMPTED_AT)) -lt "$TOPUP_SECS" ]; then
    return 0
  fi

  if [ "$status" -eq 0 ]; then
    fm_run_timed "$TIMEOUT" "$BRIDGE" push > /dev/null 2> "$err" || status=$?
  fi
  # Both intervals run from the end of this attempt, however long it took.
  ATTEMPTED_AT=$(date +%s)
  if [ "$status" -eq 0 ]; then
    PUSHED_AT=$ATTEMPTED_AT PUSHED_FP=$fp FAILING=0
    rm -f "$NOTICE_FILE"
  else
    record_failure "$(failure_reason "$status" "$err")"
  fi
  write_state
}

take_notice() {
  local taken="$NOTICE_FILE.taken.$$"
  mv -f "$NOTICE_FILE" "$taken" 2>/dev/null || return 0
  head -n1 "$taken"
  rm -f "$taken"
}

case "${1:-}" in
  tick) tick; exit 0 ;;
  take-notice) take_notice; exit 0 ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
