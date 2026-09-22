#!/usr/bin/env bash
# fm-fleet-ledger-lib.sh - the producer-side gate for the opt-in fleet ledger.
#
# Every ledger producer calls fm_fleet_ledger instead of running
# bin/fm-fleet-ledger.sh directly. With the home's config/fleet-ledger flag
# absent (the default) the call is one file test and returns: no process, no
# write. With the flag present it runs the writer, whose header owns the
# mechanics and docs/fleet-ledger.md the record contract. A ledger failure is
# reported on stderr and never changes the caller's outcome.
#
# Sourced; no side effects on source.

_FM_FLEET_LEDGER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fm_fleet_ledger <home> <state-dir> <fm-fleet-ledger.sh arguments...>
fm_fleet_ledger() {
  local home=$1 state=$2 config
  shift 2
  config=${FM_CONFIG_OVERRIDE:-$home/config}
  [ -e "$config/fleet-ledger" ] || return 0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    "$_FM_FLEET_LEDGER_LIB_DIR/fm-fleet-ledger.sh" "$@" </dev/null >/dev/null \
    || echo "fm-fleet-ledger: could not record $*; that event is missing from the ledger" >&2
  return 0
}
