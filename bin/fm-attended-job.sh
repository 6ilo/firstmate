#!/usr/bin/env bash
# fm-attended-job.sh - the attended one-job hold for a dedicated, opted-in home.
#
# Usage: fm-attended-job.sh reserve --task <id> --brief <path> [--bound-seconds <n>]
#        fm-attended-job.sh status
#        fm-attended-job.sh stop [--task <id>]
#        fm-attended-job.sh expire
#        fm-attended-job.sh launch-gate --task <id> --gen <spawn-gen> --brief <path>
#        fm-attended-job.sh clear [anything]     (disabled: explains and refuses)
#
# A home opts in by the operator creating config/attended-one-job. The file is a
# caller assertion that this home is dedicated to one attended job; it is not consent,
# authorization, or approval by anyone, and nothing here can tell who created it.
# Nothing here writes that file, and a home without it and without a state/.attended-job record
# is untouched by every command below except `status`. The contract and the record
# format are owned by bin/fm-attended-job-lib.sh and docs/configuration.md
# "Attended one-job hold".
#
#   reserve      Allow exactly one fresh ship task in this home: writes the record
#                (phase reserved) bound to the task id and the brief's digest.
#                Refuses without the opt-in flag, with an existing record or any task
#                record, with config/supervision-host, or while state/.afk or
#                state/.afk-contract exists. The only supported harness is claude and
#                the only supported backend is tmux. --bound-seconds (300 to 28800,
#                default 3600) is a duration; the deadline is this machine's clock now
#                plus that duration, and no caller ever supplies a time.
#   status       Print whether the home is held and what the record says. Read only.
#   stop         Hold the home (phase terminal) under the record mutex, then stop this
#                home's own watcher chain through bin/fm-watch-arm.sh --stop and the
#                worker through bin/fm-control.sh <task> exit. It never tears anything
#                down, never signals a process it did not identify as this home's, and
#                is safe to repeat. Exit 0 only when the outcome is quiescent; exit 3
#                when it is uncertain, and the record keeps holding. A launch claim
#                that no stop has seen the worker for stays uncertain: already-stopped
#                from the control plane does not resolve a claim.
#   expire       Observe the job's deadline against this machine's clock and, only when it
#                is due, run the same sequence as stop with the reason expired. A clock
#                that has gone backward by more than 120 seconds since the highest
#                reading recorded also expires the job, with the reason clock-rollback,
#                because it can no longer say how long the job ran; a rolled-back clock
#                never extends a deadline. Not due is a no-op. The watcher and the Stop
#                hook call it; it takes no time argument.
#   launch-gate  The final gate the staged launch file runs in the worker pane. It
#                claims the launch under the record mutex or refuses; exit 0 only when
#                the claim was written. Not an operator command.
#   clear        DISABLED in this release, pending a separate qualification. It prints an
#                explanation and whether the home is held (a read-only check) and exits 3
#                without taking a lock, writing, removing, or signalling anything,
#                whatever arguments it is given. A hold written by stop, expire, or a refused launch is therefore
#                never left by any command here, and a dedicated one-job home stays held
#                after stop. A record that is missing, invalid, or marked quiescent does
#                not change that: a stored outcome is never trusted to release a hold.
#
# config/attended-one-job, and any flag a caller passes, are assertions by whoever
# supplies them. This script cannot verify them: they are not human approval, not
# consent, and not proof that a worker is stopped.
#
# "quiescent" in a stop result means only that this script's own run saw the existing
# owners report the watcher chain stopped (or no live lock holder) and the worker either
# stopped by fm-control.sh or never launched (vetoed by the hold, not observed). It is
# derived from their output, not independently proven, it releases nothing, and a launch
# claim that no stop has seen the worker for is never quiescent.
#
# Exit codes: 0 done, 1 launch refused, 2 usage or refusal, 3 held or uncertain,
# 4 no record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-attended-job-lib.sh
. "$SCRIPT_DIR/fm-attended-job-lib.sh"

HOME_PHYS=$(fm_attended_physical "$FM_HOME") || HOME_PHYS=$FM_HOME

die() {  # <exit-code> <message>
  echo "attended: $2" >&2
  exit "$1"
}

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

need_value() {  # <flag> <value-count-left>
  [ "$2" -ge 2 ] || die 2 "$1 needs a value"
}

cmd_reserve() {
  local task= brief= digest rc bound=$FM_ATTENDED_BOUND_DEFAULT now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) need_value "$1" "$#"; task=$2; shift 2 ;;
      --brief) need_value "$1" "$#"; brief=$2; shift 2 ;;
      --bound-seconds) need_value "$1" "$#"; bound=$2; shift 2 ;;
      *) die 2 "reserve: unknown argument $1" ;;
    esac
  done
  fm_attended_valid_id "$task" || die 2 "reserve: --task needs a task id of letters, digits, dot, dash, or underscore"
  case "$bound" in
    ''|*[!0-9]*|0[0-9]*) die 2 "reserve: --bound-seconds needs whole seconds from $FM_ATTENDED_BOUND_MIN to $FM_ATTENDED_BOUND_MAX" ;;
  esac
  [ "$bound" -ge "$FM_ATTENDED_BOUND_MIN" ] && [ "$bound" -le "$FM_ATTENDED_BOUND_MAX" ] \
    || die 2 "reserve: --bound-seconds needs whole seconds from $FM_ATTENDED_BOUND_MIN to $FM_ATTENDED_BOUND_MAX"
  [ -f "$brief" ] && [ ! -L "$brief" ] && [ -r "$brief" ] || die 2 "reserve: --brief must name a readable regular file"
  [ -e "$CONFIG/attended-one-job" ] || die 2 "reserve: this home is not opted in (config/attended-one-job is absent)"
  [ ! -e "$CONFIG/supervision-host" ] || die 2 "reserve: refused in a home with config/supervision-host"
  [ ! -e "$STATE/.afk" ] && [ ! -e "$STATE/.afk-contract" ] || die 2 "reserve: refused while the away posture is recorded"
  digest=$(fm_attended_sha256 "$brief") || die 2 "reserve: the brief could not be digested"
  rc=0
  fm_attended_lock "$STATE" || rc=$?
  [ "$rc" -eq 0 ] || die 3 "reserve: the record mutex could not be taken within ${FM_ATTENDED_LOCK_SECONDS}s"
  rc=0
  fm_attended_record_read "$STATE" "$HOME_PHYS" || rc=$?
  if [ "$rc" -ne 1 ]; then
    fm_attended_unlock
    die 2 "reserve: an attended-job record already exists; this home is single-use in this release and no command here releases it"
  fi
  if fm_attended_state_has_meta "$STATE"; then
    fm_attended_unlock
    die 2 "reserve: this home already has a task record"
  fi
  FM_ATT_SEQ=0
  FM_ATT_PHASE=reserved
  FM_ATT_TASK=$task
  FM_ATT_HOME=$HOME_PHYS
  FM_ATT_GEN=
  FM_ATT_WORKTREE=
  FM_ATT_HARNESS=claude
  FM_ATT_BACKEND=tmux
  FM_ATT_BRIEF=$digest
  FM_ATT_LAUNCH=none
  FM_ATT_REASON=
  FM_ATT_OUTCOME=
  # The time fields come from this machine's clock right now. A caller supplies a
  # duration, never a time.
  now=$(date +%s)
  FM_ATT_CREATED=$now
  FM_ATT_BOUND=$bound
  FM_ATT_DEADLINE=$((now + bound))
  FM_ATT_HW=$now
  if ! fm_attended_record_publish "$STATE"; then
    fm_attended_unlock
    die 3 "reserve: the record could not be written"
  fi
  fm_attended_unlock
  echo "attended: reserved task=$task harness=claude backend=tmux"
}

cmd_status() {
  local rc held=no reason=- opted=no
  [ -e "$CONFIG/attended-one-job" ] && opted=yes
  if fm_attended_home_held "$STATE" "$CONFIG" "$HOME_PHYS"; then
    held=yes
    reason=$FM_ATT_HOLD_REASON
  fi
  echo "attended: held=$held reason=$reason opted-in=$opted"
  rc=0
  fm_attended_record_read "$STATE" "$HOME_PHYS" || rc=$?
  case "$rc" in
    1) echo "attended: record=absent" ;;
    2) echo "attended: record=invalid" ;;
    *)
      echo "attended: record=valid phase=$FM_ATT_PHASE task=$FM_ATT_TASK launch=$FM_ATT_LAUNCH reason=${FM_ATT_REASON:--} outcome=${FM_ATT_OUTCOME:--} gen=${FM_ATT_GEN:--} bound=$FM_ATT_BOUND deadline=$FM_ATT_DEADLINE"
      ;;
  esac
}

cmd_launch_gate() {
  local task= gen= brief=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) need_value "$1" "$#"; task=$2; shift 2 ;;
      --gen) need_value "$1" "$#"; gen=$2; shift 2 ;;
      --brief) need_value "$1" "$#"; brief=$2; shift 2 ;;
      *) die 2 "launch-gate: unknown argument $1" ;;
    esac
  done
  fm_attended_valid_id "$task" && [ -n "$gen" ] && [ -n "$brief" ] \
    || die 2 "launch-gate: --task, --gen and --brief are required"
  if fm_attended_launch_gate "$STATE" "$CONFIG" "$HOME_PHYS" "$task" "$gen" "$brief"; then
    echo "attended: launch claimed task=$task gen=$gen"
    return 0
  fi
  echo "attended: launch refused - $FM_ATT_REFUSAL" >&2
  exit 1
}

CHAIN=
WORKER=

# Stop this home's own watcher chain through the existing identity-bound owner, then
# read the lock again: "none running" is accepted only when no live process still
# holds it, and a live holder this script did not stop is never reported quiescent.
stop_chain() {
  local out rc=0 lock_pid
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-watch-arm.sh" --stop 2>&1) || rc=$?
  case "$out" in
    *"watcher: FAILED"*) CHAIN=failed ;;
    *"watcher: stopped pid="*) CHAIN=stopped ;;
    *"watcher: none running"*) CHAIN=none ;;
    *) CHAIN=failed ;;
  esac
  [ "$rc" -eq 0 ] || CHAIN=failed
  lock_pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$lock_pid" ] && fm_pid_alive "$lock_pid"; then
    CHAIN=holder-alive
  fi
}

# Stop the worker through the control plane, which owns lifecycle mechanics and
# preserves the endpoint, the worktree, and every uncommitted change.
stop_worker() {  # <task> <launch>
  local task=$1 launch=$2 out rc=0
  case "$launch" in
    refused) WORKER=refused; return 0 ;;
    none) WORKER=vetoed; return 0 ;;
  esac
  if [ ! -e "$STATE/$task.meta" ]; then
    WORKER=claim-unresolved
    return 0
  fi
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-$FM_HOME/data}" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-control.sh" "$task" exit 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    WORKER=control-failed
    return 0
  fi
  case "$out" in
    "stopped $task "*) WORKER=stopped ;;
    # The agent may simply not have started yet: a claim stays unresolved.
    *) WORKER=claim-unresolved ;;
  esac
}

# do_stop <task or empty> <stop|expire>: the stop sequence both commands share.
do_stop() {
  local want=$1 mode=$2 rc task launch outcome hold_reason=stop verdict
  rc=0
  fm_attended_lock "$STATE" || rc=$?
  [ "$rc" -eq 0 ] || die 3 "$mode: uncertain - the record mutex could not be taken within ${FM_ATTENDED_LOCK_SECONDS}s; nothing was changed"
  rc=0
  fm_attended_record_read "$STATE" "$HOME_PHYS" || rc=$?
  case "$rc" in
    1)
      fm_attended_unlock
      die 4 "$mode: no attended-job record; nothing was changed"
      ;;
    2)
      fm_attended_unlock
      die 3 "$mode: uncertain - the record is unreadable, altered, or foreign, so no process was signalled; the home stays held"
      ;;
  esac
  if [ -n "$want" ] && [ "$want" != "$FM_ATT_TASK" ]; then
    fm_attended_unlock
    die 2 "$mode: the record is bound to task $FM_ATT_TASK, not $want; nothing was changed"
  fi
  if [ "$mode" = expire ] && [ "$FM_ATT_PHASE" != terminal ]; then
    # Only the home's own clock decides, and only against the deadline in the record.
    verdict=$(fm_attended_clock_verdict)
    case "$verdict" in
      due) hold_reason=expired ;;
      rollback) hold_reason=clock-rollback ;;
      *)
        fm_attended_unlock
        echo "attended: expire - not due (clock=$verdict); nothing was changed"
        return 0
        ;;
    esac
  fi
  # Hold first, under the same mutex a launch claim takes: no start can be decided
  # after this point, and a start decided before it is already in the record.
  if ! fm_attended_hold_locked "$STATE" "$hold_reason"; then
    fm_attended_unlock
    die 3 "$mode: uncertain - the hold could not be written"
  fi
  task=$FM_ATT_TASK
  launch=$FM_ATT_LAUNCH
  fm_attended_unlock

  stop_chain
  stop_worker "$task" "$launch"

  outcome=uncertain
  case "$CHAIN:$WORKER" in
    stopped:refused|stopped:vetoed|stopped:stopped|none:refused|none:vetoed|none:stopped) outcome=quiescent ;;
  esac

  rc=0
  fm_attended_lock "$STATE" || rc=$?
  if [ "$rc" -eq 0 ]; then
    if fm_attended_record_read "$STATE" "$HOME_PHYS" && [ "$FM_ATT_TASK" = "$task" ]; then
      FM_ATT_OUTCOME=$outcome
      fm_attended_record_publish "$STATE" || outcome=uncertain
    else
      outcome=uncertain
    fi
    fm_attended_unlock
  else
    outcome=uncertain
  fi
  echo "attended: $mode task=$task hold=terminal reason=$hold_reason chain=$CHAIN worker=$WORKER launch=$launch outcome=$outcome"
  [ "$outcome" = quiescent ] || exit 3
}

cmd_stop() {
  local want=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) need_value "$1" "$#"; want=$2; shift 2 ;;
      *) die 2 "stop: unknown argument $1" ;;
    esac
  done
  do_stop "$want" stop
}

cmd_expire() {
  [ "$#" -eq 0 ] || die 2 "expire: takes no arguments; the deadline and the clock are this home's own"
  do_stop "" expire
}

# clear is disabled. It takes no lock, writes nothing, removes nothing, and signals
# nothing; every argument is ignored and none is treated as approval. The only thing it
# does is ask the read-only predicate whether the home is held, so the message can be
# accurate. A stored outcome, a flag, a note, or a missing, invalid, or
# apparently quiescent record never changes the answer: exit 3 with no state change.
cmd_clear() {
  local held=no reason=
  if fm_attended_home_held "$STATE" "$CONFIG" "$HOME_PHYS"; then
    held=yes
    reason=" ($FM_ATT_HOLD_REASON)"
  fi
  die 3 "clear: DISABLED in this release; nothing was changed and no argument was read or accepted as approval. held=$held$reason. A held home stays HELD after stop or expire, and no command here releases it. config/attended-one-job and any flag are unverified caller assertions, not human approval and not proof that a worker is stopped."
}

case "${1:-}" in
  reserve) shift; cmd_reserve "$@" ;;
  status) shift; cmd_status "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  expire) shift; cmd_expire "$@" ;;
  launch-gate) shift; cmd_launch_gate "$@" ;;
  clear) shift; cmd_clear "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
