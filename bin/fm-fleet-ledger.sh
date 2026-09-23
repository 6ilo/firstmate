#!/usr/bin/env bash
# fm-fleet-ledger.sh - the opt-in fleet activity ledger writer.
#
# docs/fleet-ledger.md owns the public record contract: the file location,
# every field and event kind, ordering, durability, rotation, and privacy.
# This header owns only the writer mechanics.
#
# OFF BY DEFAULT. Nothing is written unless the home's config/fleet-ledger
# presence flag exists. Producers never invoke this script while the flag is
# absent: each tests that flag with a shell builtin and only then loads
# bin/fm-fleet-ledger-lib.sh, so those builtin tests are the entire cost of the
# feature when it is off. This script repeats the test so a direct invocation
# on an off home is a silent no-op.
#
# Producers (each is an existing single choke point, never chat):
#   bin/fm-watch.sh            capture, once per poll cycle
#   bin/fm-spawn.sh            record task.dispatched / task.relaunched
#   bin/fm-pr-check.sh         record task.pr_recorded
#   bin/fm-merge-outcome-lib.sh record task.merged (a PR merge, once per PR)
#   bin/fm-merge-local.sh      record task.merged (a local-only landing that
#                              moved the branch, so a re-run records nothing)
#   bin/fm-teardown.sh         capture, then record task.cleaned_up
#   bin/fm-session-start.sh    record session.started
#   bin/fm-afk-contract.sh     record away.entered / away.returned
#
# Usage:
#   fm-fleet-ledger.sh enable
#     Turn the ledger on for this home in one locked transition: baseline every
#     existing status log at its current end, then create the presence flag.
#     Already on is a no-op that keeps the baseline. Neither step records
#     anything: the ledger carries fleet activity only.
#   fm-fleet-ledger.sh disable
#     Remove the presence flag and then the read positions, under the same lock,
#     so once it returns no record can still be written and nothing appended
#     while the ledger is off can be recorded later.
#     Each command changes the flag on the side of the transition that leaves a
#     failure recoverable, reports one with a non-zero exit, and re-running it
#     completes what a failure left half done.
#   fm-fleet-ledger.sh record <event> [--task <id>] [--pr <url>] [--via pr|local]
#     Append one record. A --task record first captures that task's unread
#     status lines, so the task's own status events always precede it.
#   fm-fleet-ledger.sh capture
#     Append a task.status record for every complete status line appended to
#     any state/<id>.status since the last capture. A cheap unlocked stat
#     comparison returns early when no status log changed.
#
# State (all under state/, all created only by enable or while the flag is on):
#   fleet-ledger.jsonl     the ledger
#   fleet-ledger.jsonl.1   the previous generation after one rotation
#   .fleet-ledger-cursors  "<task>\t<dev:inode>\t<offset>" per status log read
#   .fleet-ledger.lock     serializes every append, rotation, cursor write, and
#                          flag change, and is what record and capture recheck
#                          the flag under, so nothing lands after disable
# enable writes the baseline cursors and disable discards them. A flag created
# by hand leaves none, so the first locked write baselines every existing status
# log at its current size then; status lines appended between that bare touch
# and that first write are not recorded. Either way opting in never replays
# history, including any off period. A status log first seen after the baseline
# is read from byte 0. A changed inode or a log shorter than its cursor is read
# from byte 0.
# The ledger is bounded at 8 MiB: the write that finds it at or over that size
# renames it to fleet-ledger.jsonl.1, replacing any earlier one, and starts a
# new file, so the pair is the whole history kept.
# A write that was cut off mid-record leaves the ledger's last line without its
# newline; the next write ends that line with one instead of rewriting the file,
# so a follower's bytes never change under it and the fragment is one malformed
# line. It closes no object, so it spends no sequence number.
# Only newline-terminated lines are consumed; a partial tail waits for the
# next capture. Records are appended before cursors are saved, so a crash in
# between repeats those status records on the next capture (at-least-once),
# never loses one; a capture interrupted there repeatedly repeats them again.
#
# Exit status: 0 on success or when off, 2 on a usage error, 1 when a record
# could not be written. Callers treat any failure as non-fatal.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

LEDGER="$STATE/fleet-ledger.jsonl"
ROTATED="$LEDGER.1"
CURSORS="$STATE/.fleet-ledger-cursors"
LOCK="$STATE/.fleet-ledger.lock"
SCHEMA_VERSION=1
MAX_BYTES=8388608
TEXT_MAX_BYTES=2000

usage() {
  echo "usage: fm-fleet-ledger.sh enable | disable | record <event> [--task <id>] [--pr <url>] [--via pr|local] | capture" >&2
  exit 2
}

case "${1:-}" in
  enable|disable) [ "$#" -eq 1 ] || usage ;;
  record|capture) [ -e "$CONFIG/fleet-ledger" ] || exit 0 ;;
  *) usage ;;
esac

[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1

task_id_ok() {
  case "$1" in ''|*[!A-Za-z0-9._-]*|.*) return 1 ;; esac
}

# Every string a record carries is filtered here, so whatever bytes a status
# log, a task record, or a URL holds, a ledger line stays valid UTF-8: invalid
# sequences are dropped, and where iconv is missing or fails every non-ASCII
# byte is, including a character a byte bound cut in half.
utf8_only() { # <text>
  local converted
  if command -v iconv >/dev/null 2>&1 \
    && converted=$(printf '%s' "$1" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null); then
    printf '%s' "$converted"
  else
    printf '%s' "$1" | LC_ALL=C tr -d '\200-\377'
  fi
}

json_escape() { # <text> -> escaped JSON string content on stdout
  utf8_only "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      gsub(/[\001-\010\013\014\016-\037\177]/, "", line)
      print line
    }'
}

json_text() { # <text> -> JSON string, empty text included
  printf '"%s"' "$(json_escape "$1")"
}

json_str() { # <text> -> JSON string, or null when empty
  if [ -z "$1" ]; then printf 'null'; else json_text "$1"; fi
}

# Bound free text in bytes. utf8_only then drops whatever character the cut
# split, so the bound can never leave a half character behind.
bound_text() { # <text>
  local text=$1
  if [ "$(LC_ALL=C; printf '%s' "${#text}")" -gt "$TEXT_MAX_BYTES" ]; then
    text=$(LC_ALL=C; printf '%s' "${text:0:$TEXT_MAX_BYTES}")
  fi
  printf '%s' "$text"
}

file_size() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %z "$1" 2>/dev/null
  else
    stat -c %s "$1" 2>/dev/null
  fi
}

# A write cut off mid-record, by a full disk or a killed writer, leaves the
# ledger without a closing newline. A follower has already read those bytes, so
# end that line rather than rewrite the file: the fragment stays one malformed
# line for a reader to skip, and the next record starts on a line of its own.
# Caller holds the lock.
terminate_partial_tail() {
  local size
  size=$(file_size "$LEDGER") || return 0
  case $size in ''|0) return 0 ;; esac
  [ -n "$(tail -c 1 "$LEDGER" 2>/dev/null)" ] || return 0
  printf '\n' >> "$LEDGER"
}

# One stat call for every regular status log: "<task>\t<dev:inode>\t<size>".
status_listing() {
  local f id line
  local -a files=()
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    id=${f##*/}
    id=${id%.status}
    task_id_ok "$id" || continue
    files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f '%N	%d:%i	%z' "${files[@]}" 2>/dev/null
  else
    stat -c '%n	%d:%i	%s' "${files[@]}" 2>/dev/null
  fi | while IFS=$'\t' read -r f ident size; do
    id=${f##*/}
    line="${id%.status}	$ident	$size"
    printf '%s\n' "$line"
  done
}

last_seq() {
  local f seq
  for f in "$LEDGER" "$ROTATED"; do
    [ -s "$f" ] || continue
    seq=$(tail -n 8 "$f" 2>/dev/null | sed -n 's/^{"v":[0-9]*,"seq":\([0-9][0-9]*\),.*}$/\1/p' | tail -1)
    if [ -n "$seq" ]; then printf '%s\n' "$seq"; return 0; fi
  done
  printf '0\n'
}

NEXT_SEQ=

# Append one record whose event-specific members are the JSON fragment $3
# (empty or starting with a comma). Caller holds the lock.
append() { # <event> <task-or-empty> <fragment>
  local event=$1 task=$2 fragment=$3 size
  if [ -z "$NEXT_SEQ" ]; then
    terminate_partial_tail || return 1
    NEXT_SEQ=$(last_seq)
    NEXT_SEQ=$((NEXT_SEQ + 1))
  fi
  size=$(file_size "$LEDGER" 2>/dev/null || true)
  if [ -n "$size" ] && [ "$size" -ge "$MAX_BYTES" ]; then
    mv -f "$LEDGER" "$ROTATED" || return 1
  fi
  printf '{"v":%s,"seq":%s,"ts":%s,"event":"%s","task":%s%s}\n' \
    "$SCHEMA_VERSION" "$NEXT_SEQ" "$(date +%s)" "$event" "$(json_str "$task")" \
    "$fragment" >> "$LEDGER" || return 1
  NEXT_SEQ=$((NEXT_SEQ + 1))
}

# fm-classify-lib.sh owns the status-line grammar; this only projects it.
status_fragment() { # <status-line>
  local line=$1 verb at key note
  verb=''
  case "$line" in *:*) status_line_verb "$line" verb ;; esac
  case "$verb" in [a-z]*) case "$verb" in *[!a-z-]*) verb='' ;; esac ;; *) verb='' ;; esac
  _fm_status_at_epoch "$line" at || at=''
  key=$(_fm_decision_key "$line" 2>/dev/null) || key=''
  [ "$key" != default ] || key=''
  note=$(status_line_note "$line")
  printf ',"state":%s,"at":%s,"key":%s,"text":%s' \
    "$(json_str "$verb")" "${at:-null}" "$(json_str "$key")" \
    "$(json_text "$(bound_text "$note")")"
}

# Emit every complete line of <file> from <offset> and set CAPTURE_OFFSET to
# the offset after the last consumed line. Runs in the caller's shell so the
# sequence counter advances.
CAPTURE_OFFSET=0
capture_file() { # <task> <file> <offset> <size>
  local task=$1 file=$2 offset=$3 size=$4 line consumed=0 len
  CAPTURE_OFFSET=$offset
  [ "$offset" -lt "$size" ] || return 0
  while IFS= read -r line; do
    len=$(LC_ALL=C; printf '%s' "${#line}")
    consumed=$((consumed + len + 1))
    case "$line" in
      *[![:space:]]*) append task.status "$task" "$(status_fragment "$line")" || return 1 ;;
    esac
  done < <(tail -c +"$((offset + 1))" "$file" 2>/dev/null | head -c "$((size - offset))")
  CAPTURE_OFFSET=$((offset + consumed))
}

# Opt in from this instant: every existing status log is baselined at its
# current end, so nothing already in one is replayed and nothing appended once
# the flag exists is skipped. The flag is created here, under the lock, so the
# whole transition is atomic against every writer and against disable.
enable_locked() {
  local listing
  [ ! -e "$CONFIG/fleet-ledger" ] || return 0
  listing=$(status_listing)
  : > "$CURSORS.tmp.$$" || return 1
  [ -z "$listing" ] || printf '%s\n' "$listing" > "$CURSORS.tmp.$$" || return 1
  mv -f "$CURSORS.tmp.$$" "$CURSORS" || return 1
  touch "$CONFIG/fleet-ledger"
}

# Opt out from this instant: the read positions go with the flag, so a status
# line appended while the ledger is off is behind the baseline whichever way it
# is turned on again, and can never be recorded. The ledger files stay, so the
# sequence continues.
disable_locked() {
  rm -f "$CONFIG/fleet-ledger" || return 1
  rm -f "$CURSORS"
}

cursor_lookup() { # <cursor-data> <task> -> "<ident>\t<offset>"
  printf '%s\n' "$1" | awk -F'\t' -v t="$2" '$1 == t { print $2 "\t" $3; exit }'
}

# Capture status logs under the lock. With <only-task>, capture just that one
# and keep every other cursor as it was.
capture_locked() { # [only-task]
  local only=${1:-} listing cursors='' new='' task ident size prev prev_ident prev_off offset baseline=0
  [ -e "$CONFIG/fleet-ledger" ] || return 0
  listing=$(status_listing)
  if [ -f "$CURSORS" ]; then
    cursors=$(cat "$CURSORS" 2>/dev/null) || return 1
  else
    baseline=1
  fi
  while IFS=$'\t' read -r task ident size; do
    [ -n "$task" ] || continue
    if [ "$baseline" = 1 ]; then
      new="$new$task	$ident	$size"$'\n'
      continue
    fi
    prev=$(cursor_lookup "$cursors" "$task")
    prev_ident=${prev%%$'\t'*}
    prev_off=${prev#*$'\t'}
    if [ -n "$only" ] && [ "$task" != "$only" ]; then
      [ -n "$prev" ] && new="$new$task	$prev"$'\n'
      continue
    fi
    offset=0
    if [ -n "$prev" ] && [ "$prev_ident" = "$ident" ]; then
      case "$prev_off" in ''|*[!0-9]*) ;; *) [ "$prev_off" -gt "$size" ] || offset=$prev_off ;; esac
    fi
    capture_file "$task" "$STATE/$task.status" "$offset" "$size" || return 1
    new="$new$task	$ident	$CAPTURE_OFFSET"$'\n'
  done <<< "$listing"
  printf '%s' "$new" > "$CURSORS.tmp.$$" && mv -f "$CURSORS.tmp.$$" "$CURSORS"
}

# Unlocked early exit: nothing to do when every status log still matches the
# identity and size its cursor recorded.
capture_needed() {
  local listing cursors
  [ -f "$CURSORS" ] || return 0
  listing=$(status_listing)
  cursors=$(cat "$CURSORS" 2>/dev/null) || return 0
  [ "$listing" != "$cursors" ]
}

locked() { # <command> [args...]
  local rc=0
  fm_lock_acquire_wait "$LOCK" || return 1
  "$@" || rc=$?
  fm_lock_release "$LOCK" || true
  return "$rc"
}

record_locked() { # <event> <task> <fragment>
  [ -e "$CONFIG/fleet-ledger" ] || return 0
  if [ -n "$2" ] || [ ! -f "$CURSORS" ]; then
    capture_locked "$2" || return 1
  fi
  append "$1" "$2" "$3"
}

cmd=$1
shift
if [ "$cmd" = capture ]; then
  [ "$#" -eq 0 ] || usage
  capture_needed || exit 0
fi

# The lock primitives and the status grammar are loaded only once a write is
# actually due.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

case "$cmd" in
  enable)
    locked enable_locked || exit 1
    printf 'fleet activity ledger on; its records are at %s\n' "$LEDGER"
    ;;
  disable)
    locked disable_locked || exit 1
    printf 'fleet activity ledger off; %s is left in place\n' "$LEDGER"
    ;;
  capture)
    locked capture_locked || exit 1
    ;;
  record)
    event=${1:-}
    shift || usage
    task='' pr='' via=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) task=${2:-}; shift 2 || usage ;;
        --pr) pr=${2:-}; shift 2 || usage ;;
        --via) via=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -z "$task" ] || task_id_ok "$task" || usage
    fragment=
    case "$event" in
      session.started|away.entered|away.returned)
        [ -z "$task" ] || usage
        ;;
      task.dispatched|task.relaunched)
        [ -n "$task" ] || usage
        meta="$STATE/$task.meta"
        field() {
          local line
          line=$(LC_ALL=C grep "^$1=" "$meta" 2>/dev/null | LC_ALL=C tail -1)
          printf '%s' "${line#*=}"
        }
        kind=$(field kind)
        project=$(field project)
        [ "$kind" != secondmate ] || project=$(field home)
        project=${project%/}
        project=${project##*/}
        model=$(field model)
        effort=$(field effort)
        [ -n "$model" ] || model=default
        [ -n "$effort" ] || effort=default
        fragment=$(printf ',"kind":%s,"project":%s,"harness":%s,"model":%s,"effort":%s,"mode":%s,"yolo":%s' \
          "$(json_str "$kind")" "$(json_str "$project")" "$(json_str "$(field harness)")" \
          "$(json_str "$model")" "$(json_str "$effort")" \
          "$(json_str "$(field mode)")" "$(json_str "$(field yolo)")")
        ;;
      task.pr_recorded)
        [ -n "$task" ] && [ -n "$pr" ] || usage
        fragment=$(printf ',"pr":%s' "$(json_str "$pr")")
        ;;
      task.merged)
        [ -n "$task" ] || usage
        case "$via" in pr) [ -n "$pr" ] || usage ;; local) [ -z "$pr" ] || usage ;; *) usage ;; esac
        fragment=$(printf ',"via":"%s","pr":%s' "$via" "$(json_str "$pr")")
        ;;
      task.cleaned_up)
        [ -n "$task" ] || usage
        ;;
      *) usage ;;
    esac
    locked record_locked "$event" "$task" "$fragment" || exit 1
    ;;
esac
