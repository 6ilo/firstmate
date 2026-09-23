#!/usr/bin/env bash
# fm-fleet-ledger-lib.sh - the producer-side gate for the opt-in fleet ledger.
#
# Nothing here is loaded while the ledger is off. Every producer tests the
# home's config/fleet-ledger flag with a shell builtin, on a path it already
# knows, and sources this file inside that test, so a home with the ledger off
# pays those builtin tests and nothing else: no sourcing, no path resolution,
# no child process, no write. How many of them a producer performs is its own
# business; that none of this runs is the contract.
#
# Sourcing resolves this home's paths once and defines fm_fleet_ledger, which
# runs bin/fm-fleet-ledger.sh under a hard ten-second bound, because a producer
# must never wait on the ledger: a stopped or hung writer, or one queued behind
# a lock owner that never finishes, costs the bound and then the event is
# dropped. Every failure, bound included, is reported on stderr and never
# changes the caller's outcome. The writer runs inside a subshell, so neither
# fm-timeout-lib.sh's shell options nor its functions reach the producer, and
# the writer's own environment is handed to it on the spot. The writer's header
# owns the mechanics and docs/fleet-ledger.md the record contract.
#
# Source this once FM_HOME, and any FM_STATE_OVERRIDE or FM_CONFIG_OVERRIDE,
# are set: the gate always records this home, which is why nothing is passed
# per call.
#
# Sourced; no side effects on source.

_FM_FLEET_LEDGER_LIB_SOURCE=${BASH_SOURCE[0]}
_FM_FLEET_LEDGER_HOME=${FM_HOME:-}
_FM_FLEET_LEDGER_STATE=${FM_STATE_OVERRIDE:-$_FM_FLEET_LEDGER_HOME/state}
_FM_FLEET_LEDGER_CONFIG=${FM_CONFIG_OVERRIDE:-$_FM_FLEET_LEDGER_HOME/config}
_FM_FLEET_LEDGER_BOUND=10

# fm_fleet_ledger <fm-fleet-ledger.sh arguments...>
fm_fleet_ledger() {
  local dir rc=0
  dir=${_FM_FLEET_LEDGER_LIB_SOURCE%/*}
  (
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$dir/fm-timeout-lib.sh" || exit 1
    fm_run_timed "$_FM_FLEET_LEDGER_BOUND" env \
      FM_HOME="$_FM_FLEET_LEDGER_HOME" \
      FM_STATE_OVERRIDE="$_FM_FLEET_LEDGER_STATE" \
      FM_CONFIG_OVERRIDE="$_FM_FLEET_LEDGER_CONFIG" \
      "$dir/fm-fleet-ledger.sh" "$@"
  ) </dev/null >/dev/null || rc=$?
  case $rc in
    0) ;;
    124) echo "fm-fleet-ledger: recording $* did not finish within ${_FM_FLEET_LEDGER_BOUND}s and was stopped; that event is missing from the ledger" >&2 ;;
    *) echo "fm-fleet-ledger: could not record $*; that event is missing from the ledger" >&2 ;;
  esac
  return 0
}
