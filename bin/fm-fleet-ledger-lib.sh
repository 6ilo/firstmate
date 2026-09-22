#!/usr/bin/env bash
# fm-fleet-ledger-lib.sh - the producer-side gate for the opt-in fleet ledger.
#
# Every ledger producer calls fm_fleet_ledger instead of running
# bin/fm-fleet-ledger.sh directly. With the home's config/fleet-ledger flag
# absent (the default) the call is one file test and returns: no process, no
# write, no path resolution, and no library of ours loaded. All of that happens
# on the enabled path only, inside a subshell, so neither fm-timeout-lib.sh's
# shell options nor the writer's environment reach the producer.
#
# With the flag present the writer runs under a hard bound
# (FM_FLEET_LEDGER_TIMEOUT seconds, 10 by default), because a producer must
# never wait on the ledger: a stopped or hung writer, or one queued behind a
# lock owner that never finishes, costs the bound and then the event is
# dropped. Every failure, bound included, is reported on stderr and never
# changes the caller's outcome. The writer's header owns the mechanics and
# docs/fleet-ledger.md the record contract.
#
# Callers must pass an already-resolved state directory, never a substitution
# computed at the call site: that would fork on the off path too.
#
# Sourced; no side effects on source.

_FM_FLEET_LEDGER_LIB_SOURCE=${BASH_SOURCE[0]}

# fm_fleet_ledger <home> <state-dir> <fm-fleet-ledger.sh arguments...>
fm_fleet_ledger() {
  local home=$1 state=$2 config dir bound rc=0
  shift 2
  config=${FM_CONFIG_OVERRIDE:-$home/config}
  [ -e "$config/fleet-ledger" ] || return 0
  dir=${_FM_FLEET_LEDGER_LIB_SOURCE%/*}
  bound=${FM_FLEET_LEDGER_TIMEOUT:-10}
  case $bound in ''|*[!0-9]*|0) bound=10 ;; esac
  (
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$dir/fm-timeout-lib.sh" || exit 1
    export FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config"
    fm_run_timed "$bound" "$dir/fm-fleet-ledger.sh" "$@"
  ) </dev/null >/dev/null || rc=$?
  case $rc in
    0) ;;
    124) echo "fm-fleet-ledger: recording $* did not finish within ${bound}s and was stopped; that event is missing from the ledger" >&2 ;;
    *) echo "fm-fleet-ledger: could not record $*; that event is missing from the ledger" >&2 ;;
  esac
  return 0
}
