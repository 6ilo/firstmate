#!/usr/bin/env bash
# fm-backlog-plan.sh - the planning record firstmate keeps for each backlog item.
#
# Usage: fm-backlog-plan.sh set <id> [--size S|M|L] [--type feature|fix|upkeep]
#                                    [--order <1-9999>] [--target YYYY-MM-DD]
#                                    [--waits-on "<outside event>"]...
#        fm-backlog-plan.sh check [<plan flags>...]
#        fm-backlog-plan.sh get <id>
#        fm-backlog-plan.sh list
#        fm-backlog-plan.sh rm <id>
#        fm-backlog-plan.sh --help
#
# tasks-axi's row format carries a priority (0-4, which firstmate reads as
# urgency) and blocked-by edges, but no size, type tag, order rank, target date,
# or named outside event. This command keeps those five in one firstmate-owned
# sidecar, `<data>/backlog-plan.json`, keyed by task id, so the backlog rows
# stay the tool's own format. It is the only writer and the only reader of that
# file; bin/fm-bearings-snapshot.sh reads it through `list`.
#
# Fields (every one optional; a value of `-` clears it):
#   --size      S, M, or L (case-insensitive, stored upper-case)
#   --type      feature, fix, or upkeep (the kind tag stays ship/scout/docs)
#   --order     positive integer rank; lower goes first
#   --target    a real calendar date, YYYY-MM-DD, for ordinary work
#   --waits-on  a named outside event, one line of at most 120 characters;
#               repeatable, added to any already recorded; `-` clears them all.
#               Waiting on another task or on a captain call is a tasks-axi
#               blocked-by edge instead (`add --blocked-by`, `block <id> --by`).
#
# `set` merges the given fields into the item's record and refuses an id that
# is not in this home's backlog. An item whose every field is cleared is
# dropped from the file. `check` validates plan flags without writing anything,
# so bin/fm-tasks-axi.sh can refuse bad values before tasks-axi runs.
# `get` prints one record as JSON ({} when none); `list` prints the whole file
# as a JSON object ({} when absent). `rm` drops a record.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/. Writes are atomic (temp file + rename) under a per-home lock.
# Exit 2 on a refused value or unknown id with nothing written; exit 1 when the
# sidecar exists but is not a JSON object.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PLAN="$DATA/backlog-plan.json"
WAITS_MAX=120

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

refuse() {
  printf 'fm-backlog-plan: %s\n' "$*" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || { echo "fm-backlog-plan: jq not found" >&2; exit 1; }

read_plan() {
  if [ ! -e "$PLAN" ]; then
    printf '{}\n'
    return 0
  fi
  jq -e 'if type == "object" then . else error("not an object") end' "$PLAN" 2>/dev/null || {
    printf 'fm-backlog-plan: %s is not a JSON object; fix or remove it\n' "$PLAN" >&2
    return 1
  }
}

valid_date() {  # <YYYY-MM-DD>
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  # A round trip through jq rejects impossible dates such as 2026-02-30.
  [ "$(jq -nr --arg d "$1" 'try (($d + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) catch ""')" = "$1" ]
}

# Parse plan flags into PATCH (a jq object of fields to set, null to clear)
# and WAITS_ADD/WAITS_CLEAR. Refuses anything else.
PATCH='{}'
WAITS_ADD='[]'
WAITS_CLEAR=0
parse_flags() {
  local flag value
  while [ $# -gt 0 ]; do
    flag=$1
    case "$flag" in
      --*=*) value=${flag#*=}; flag=${flag%%=*} ;;
      --size|--type|--order|--target|--waits-on)
        [ $# -ge 2 ] || refuse "$flag needs a value"
        value=$2
        shift
        ;;
      *) refuse "unknown flag: $flag (plan flags: --size, --type, --order, --target, --waits-on)" ;;
    esac
    shift
    case "$flag" in
      --size)
        case "$value" in
          -) PATCH=$(jq -c '.size = null' <<<"$PATCH") ;;
          [sSmMlL]) PATCH=$(jq -c --arg v "$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]')" '.size = $v' <<<"$PATCH") ;;
          *) refuse "--size must be S, M, or L (got: $value)" ;;
        esac
        ;;
      --type)
        case "$value" in
          -) PATCH=$(jq -c '.type = null' <<<"$PATCH") ;;
          feature|fix|upkeep) PATCH=$(jq -c --arg v "$value" '.type = $v' <<<"$PATCH") ;;
          *) refuse "--type must be feature, fix, or upkeep (got: $value)" ;;
        esac
        ;;
      --order)
        case "$value" in
          -) PATCH=$(jq -c '.order = null' <<<"$PATCH") ;;
          [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9])
            PATCH=$(jq -c --argjson v "$value" '.order = $v' <<<"$PATCH") ;;
          *) refuse "--order must be a whole number from 1 to 9999, lower first (got: $value)" ;;
        esac
        ;;
      --target)
        if [ "$value" = - ]; then
          PATCH=$(jq -c '.target = null' <<<"$PATCH")
        elif valid_date "$value"; then
          PATCH=$(jq -c --arg v "$value" '.target = $v' <<<"$PATCH")
        else
          refuse "--target must be a real date as YYYY-MM-DD (got: $value)"
        fi
        ;;
      --waits-on)
        case "$value" in
          -) WAITS_CLEAR=1; WAITS_ADD='[]' ;;
          *$'\n'*|*$'\r'*) refuse "--waits-on must be one line" ;;
          *)
            [ -n "${value//[[:space:]]/}" ] || refuse "--waits-on needs the name of an outside event"
            [ "${#value}" -le "$WAITS_MAX" ] || refuse "--waits-on must be at most $WAITS_MAX characters"
            WAITS_ADD=$(jq -c --arg v "$value" '. + [$v]' <<<"$WAITS_ADD")
            ;;
        esac
        ;;
    esac
  done
}

require_id() {  # <id>
  case "$1" in
    ''|-*) refuse "a task id is required" ;;
    *[!A-Za-z0-9._-]*) refuse "not a task id: $1" ;;
  esac
}

require_backlog_item() {  # <id>
  "$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" >/dev/null 2>&1 \
    || refuse "no backlog item $1 in this home; add it with bin/fm-tasks-axi.sh add first"
}

write_plan() {  # <json>
  local tmp
  mkdir -p "$DATA" || return 1
  tmp=$(mktemp "$DATA/.backlog-plan.json.XXXXXX") || return 1
  if printf '%s\n' "$1" | jq -S . > "$tmp" && mv -f "$tmp" "$PLAN"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

with_lock() {  # <fn> [args...]
  local rc
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh" || return 1
  mkdir -p "$STATE" || return 1
  fm_lock_acquire_wait "$STATE/.backlog-plan.lock" || return 1
  "$@"
  rc=$?
  fm_lock_release "$STATE/.backlog-plan.lock"
  return "$rc"
}

do_set() {  # <id>
  local current next
  current=$(read_plan) || return 1
  next=$(jq -c --arg id "$1" --argjson patch "$PATCH" --argjson add "$WAITS_ADD" \
    --argjson clear "$WAITS_CLEAR" '
    . as $plan
    | (($plan[$id] // {}) + $patch) as $r
    | (if $clear == 1 then [] else ($r.waits_on // []) end) as $w
    | ($r + {waits_on: (($w + $add) | reduce .[] as $e ([]; if index([$e]) then . else . + [$e] end))})
    | with_entries(select(.value != null and .value != [])) as $rec
    | $plan | if ($rec | length) == 0 then del(.[$id]) else .[$id] = $rec end
    ' <<<"$current") || return 1
  write_plan "$next" || return 1
  jq --arg id "$1" '.[$id] // {}' <<<"$next"
}

do_rm() {  # <id>
  local current
  current=$(read_plan) || return 1
  jq -e --arg id "$1" 'has($id)' <<<"$current" >/dev/null || return 0
  write_plan "$(jq -c --arg id "$1" 'del(.[$id])' <<<"$current")"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  -h|--help|'') usage; [ -n "$cmd" ] || exit 2; exit 0 ;;
  check)
    parse_flags "$@"
    ;;
  set)
    id=${1:-}
    require_id "$id"
    shift
    parse_flags "$@"
    [ "$PATCH" != '{}' ] || [ "$WAITS_ADD" != '[]' ] || [ "$WAITS_CLEAR" = 1 ] \
      || refuse "set needs at least one of --size, --type, --order, --target, --waits-on"
    require_backlog_item "$id"
    with_lock do_set "$id"
    ;;
  get)
    id=${1:-}
    require_id "$id"
    plan=$(read_plan) || exit 1
    jq --arg id "$id" '.[$id] // {}' <<<"$plan"
    ;;
  list)
    read_plan
    ;;
  rm)
    id=${1:-}
    require_id "$id"
    with_lock do_rm "$id"
    ;;
  *)
    refuse "unknown command: $cmd (set, check, get, list, rm)"
    ;;
esac
