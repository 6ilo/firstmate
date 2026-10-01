#!/usr/bin/env bash
# Today answers process-event adapter: keeps bin/fm-today-bridge.sh's answers
# long-poll running outside firstmate's turn and wakes firstmate when the
# captain's answers from the admin portal's Today page have been carried.
#
# Usage:
#   fm-procevent-today-answers.sh arm [--wait <1-25>]
#   fm-procevent-today-answers.sh read <result-file>
#   fm-procevent-today-answers.sh classify <result-file>
#   fm-procevent-today-answers.sh terminal <result-file>
#   fm-procevent-today-answers.sh source-id
#   fm-procevent-today-answers.sh retire
#
# arm        Check the bridge's settings (bin/fm-today-bridge.sh answers
#            check), bind the bridge's reconcile source id `today-bridge` so a
#            Today reconcile answer can file a reconcile request, then register
#            the `today-answers` source, whose blocking child is
#            `bin/fm-today-bridge.sh answers poll`. The bridge header owns what
#            that child does. A missing or unusable setting exits 2 and
#            registers nothing.
# read       Print the captured result as one JSON document: status, detail,
#            answers (one object per answer carried: answer_id, owner,
#            task_id, kind, value, later_until, note, outcome, action, reason,
#            and announce for an applied passkey-signed word), and enrolments
#            (one object per passkey enrolment the portal handed back: enrol_id,
#            credential_id, check, errors, file, and the confirm command the
#            captain runs at the machine).
# classify   Print answers, error, or unknown.
# terminal   Exit 0 for an error result, which retires the source; a round of
#            answers keeps it armed so the runner polls again.
# source-id  Print the canonical source id, `today-answers`.
# retire     Stop polling and drop the registration. The bridge's answer store
#            is kept, so re-arming never carries an answer twice.
#
# The runner's keyed-answer feed is deliberately not used: the procevent
# source id is never bound, and this adapter has no `answers` or `reconciles`
# command. The bridge feeds bin/fm-captain-hold.sh's intake itself, one answer
# at a time, because each answer needs its own receipt and its card checked
# first. Every captured round stays unacknowledged, so firstmate is woken to
# act on what the captain answered, and acknowledges it with
# `bin/fm-procevent.sh handled today-answers <sequence>` once it has.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ID=today-answers
ADAPTER=today-answers
RECONCILE_SOURCE_ID=today-bridge

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'fm-procevent-today-answers: %s\n' "$1" >&2; exit "${2:-1}"; }

result_field() {  # <file> <field>
  awk -v f="$2: " 'index($0, f) == 1 { print substr($0, length(f) + 1); exit }' "$1"
}

cmd_arm() {
  local wait=25 portal
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wait) case "${2-}" in ''|*[!0-9]*) die "--wait needs 1 to 25 seconds" 2 ;; esac
              { [ "$2" -ge 1 ] && [ "$2" -le 25 ]; } || die "--wait needs 1 to 25 seconds" 2
              wait=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  portal=$("$SCRIPT_DIR/fm-today-bridge.sh" answers check) || exit 2
  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$RECONCILE_SOURCE_ID" >/dev/null || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" register "$ADAPTER" "$SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-today-bridge.sh" answers poll --wait "$wait" || exit 1
  printf 'armed: %s\n' "$SOURCE_ID"
  printf '%s\n' "$portal"
}

cmd_classify() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(result_field "$file" status)" in
    answers|error) result_field "$file" status ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_terminal() {
  [ -n "${1-}" ] || usage
  [ "$(cmd_classify "$1")" = error ]
}

cmd_read() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  jq -n --arg status "$(result_field "$file" status)" --arg detail "$(result_field "$file" detail)" \
    --rawfile body "$file" '
    {status: $status,
     detail: (if $detail == "" then null else $detail end),
     answers: [$body | split("\n")[] | select(startswith("answer-json: "))
               | ltrimstr("answer-json: ") | fromjson],
     enrolments: [$body | split("\n")[] | select(startswith("enrolment-json: "))
                  | ltrimstr("enrolment-json: ") | fromjson]}'
}

case "${1-}" in
  arm)        shift; cmd_arm "$@" ;;
  read)       shift; cmd_read "$@" ;;
  classify)   shift; cmd_classify "$@" ;;
  terminal)   shift; cmd_terminal "$@" ;;
  source-id)  printf '%s\n' "$SOURCE_ID" ;;
  retire)     "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" 2 ;;
esac
