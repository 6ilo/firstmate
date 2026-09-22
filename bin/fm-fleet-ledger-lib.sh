#!/usr/bin/env bash
# fm-fleet-ledger-lib.sh - the producer-side gate for the opt-in fleet ledger.
#
# Every ledger producer calls fm_fleet_ledger instead of running
# bin/fm-fleet-ledger.sh directly. Sourcing this resolves the home's paths once,
# in four plain assignments with no fork and no command substitution, and the
# gate's first statement is a single shell-builtin test of the resulting
# FM_FLEET_LEDGER_FLAG. With the flag absent (the default) that test is the
# whole cost of the feature: no argument handling, no path resolution, no child
# process, no write, and none of our libraries loaded. A caller on a hot path
# spends that same builtin itself and skips even the call.
#
# Source this once FM_HOME, and any FM_STATE_OVERRIDE or FM_CONFIG_OVERRIDE, are
# set: the gate always records this home, which is why nothing is passed per
# call.
#
# With the flag present the writer runs under a hard bound
# (FM_FLEET_LEDGER_TIMEOUT seconds, 10 by default), because a producer must
# never wait on the ledger: a stopped or hung writer, or one queued behind a
# lock owner that never finishes, costs the bound and then the event is
# dropped. Every failure, bound included, is reported on stderr and never
# changes the caller's outcome. The writer runs inside a subshell, so neither
# fm-timeout-lib.sh's shell options nor its functions reach the producer, and
# the writer's own environment is handed to it on the spot. The writer's header owns the mechanics and docs/fleet-ledger.md the
# record contract.
#
# Sourced; no side effects on source.

_FM_FLEET_LEDGER_LIB_SOURCE=${BASH_SOURCE[0]}
_FM_FLEET_LEDGER_HOME=${FM_HOME:-}
_FM_FLEET_LEDGER_STATE=${FM_STATE_OVERRIDE:-$_FM_FLEET_LEDGER_HOME/state}
_FM_FLEET_LEDGER_CONFIG=${FM_CONFIG_OVERRIDE:-$_FM_FLEET_LEDGER_HOME/config}
FM_FLEET_LEDGER_FLAG=$_FM_FLEET_LEDGER_CONFIG/fleet-ledger

# fm_fleet_ledger <fm-fleet-ledger.sh arguments...>
fm_fleet_ledger() {
  [ -e "$FM_FLEET_LEDGER_FLAG" ] || return 0
  local dir bound rc=0
  dir=${_FM_FLEET_LEDGER_LIB_SOURCE%/*}
  bound=${FM_FLEET_LEDGER_TIMEOUT:-10}
  case $bound in ''|*[!0-9]*|0) bound=10 ;; esac
  (
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$dir/fm-timeout-lib.sh" || exit 1
    fm_run_timed "$bound" env \
      FM_HOME="$_FM_FLEET_LEDGER_HOME" \
      FM_STATE_OVERRIDE="$_FM_FLEET_LEDGER_STATE" \
      FM_CONFIG_OVERRIDE="$_FM_FLEET_LEDGER_CONFIG" \
      "$dir/fm-fleet-ledger.sh" "$@"
  ) </dev/null >/dev/null || rc=$?
  case $rc in
    0) ;;
    124) echo "fm-fleet-ledger: recording $* did not finish within ${bound}s and was stopped; that event is missing from the ledger" >&2 ;;
    *) echo "fm-fleet-ledger: could not record $*; that event is missing from the ledger" >&2 ;;
  esac
  return 0
}
