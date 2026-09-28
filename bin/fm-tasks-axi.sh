#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# Planning fields: on `add`/`create` and `update`/`edit` the wrapper also takes
# --size, --type, --order, --target, and --waits-on, which tasks-axi's row format
# does not carry. It validates them before tasks-axi runs, strips them from the
# tasks-axi arguments, and after tasks-axi succeeds records them through
# bin/fm-backlog-plan.sh (that script's header owns the fields and values).
# --urgency <0-4> is an alias for tasks-axi's own --priority, which firstmate
# reads as urgency. The plan record is keyed by the command's first positional
# argument (the task id), wherever the flags sit. A successful `rm <id>` (or its
# `delete` alias) also drops that item's plan record. When tasks-axi wrote the
# row but the plan record could not be written, the wrapper says so and exits 1
# rather than dropping the fields silently.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a planning field with a bad value, a planning field on any command other
#     than add/create/update/edit, or planning fields with `add --mint` (the id
#     is not known until tasks-axi mints it; add, then `update <id>`), or
#     planning fields with no task id;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
# Otherwise the exit status is tasks-axi's own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

SUBCMD=${1:-}
ARGS=()
PLAN_ARGS=()
MINT=0
POS_ID=
path_value_next=0
plan_value_next=
value_next=0
for arg in "$@"; do
  if [ "$value_next" = 1 ]; then
    ARGS+=("$arg")
    value_next=0
    continue
  fi
  if [ -n "$plan_value_next" ]; then
    if [ "$plan_value_next" = --urgency ]; then
      ARGS+=("$arg")
    else
      PLAN_ARGS+=("$plan_value_next" "$arg")
    fi
    plan_value_next=
    continue
  fi
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --size|--type|--order|--target|--waits-on|--urgency|--size=*|--type=*|--order=*|--target=*|--waits-on=*|--urgency=*)
      case "$SUBCMD" in
        add|create|update|edit) ;;
        *) fail "${arg%%=*} is a planning field; it goes on add or update" ;;
      esac
      case "$arg" in
        --urgency=*) ARGS+=(--priority "${arg#*=}") ;;
        --urgency) ARGS+=(--priority); plan_value_next=--urgency ;;
        *=*) PLAN_ARGS+=("${arg%%=*}" "${arg#*=}") ;;
        *) plan_value_next=$arg ;;
      esac
      ;;
    --mint)
      MINT=1
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    --kind|--repo|--body|--blocked-by|--pr|--report|--priority|--prefix|--title)
      ARGS+=("$arg")
      value_next=1
      ;;
    -*)
      ARGS+=("$arg")
      ;;
    *)
      [ ${#ARGS[@]} -eq 0 ] || [ -n "$POS_ID" ] || POS_ID=$arg
      ARGS+=("$arg")
      ;;
  esac
done

[ -z "$plan_value_next" ] || fail "$plan_value_next needs a value"
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  if [ "${ARGS[$i]}" = --priority ]; then
    case "${ARGS[$((i + 1))]:-}" in
      [0-4]) ;;
      *) fail "urgency (--priority/--urgency) must be 0 to 4 (got: ${ARGS[$((i + 1))]:-nothing})" ;;
    esac
  fi
done
PLAN_ID=
if [ ${#PLAN_ARGS[@]} -gt 0 ]; then
  [ "$MINT" = 0 ] || fail "planning fields cannot ride on add --mint; add the item, then run update <id> with them"
  [ -n "$POS_ID" ] || fail "planning fields need the task id: $SUBCMD <id> ..."
  PLAN_ID=$POS_ID
  "$SCRIPT_DIR/fm-backlog-plan.sh" check "${PLAN_ARGS[@]}" || exit 2
fi

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

case "$SUBCMD" in
  rm|delete) PLAN_ID=$POS_ID ;;
esac
if [ -z "$PLAN_ID" ]; then
  cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
  exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
fi

# The planning record is written only after tasks-axi succeeded, so a refused
# row never leaves a plan behind; the subshell keeps this process's working
# directory for the relative paths the plan script may resolve.
# An update carrying only planning fields has nothing for tasks-axi to change;
# the plan script itself refuses an id this backlog does not hold.
TASKS_RAN=0
case "$SUBCMD:${#ARGS[@]}" in
  update:2|edit:2) ;;
  *) (cd "$FM_BACKLOG_AXI_ROOT" && exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}) || exit $?; TASKS_RAN=1 ;;
esac
case "$SUBCMD" in
  rm|delete)
    "$SCRIPT_DIR/fm-backlog-plan.sh" rm "$PLAN_ID" \
      || { printf 'fm-tasks-axi: removed %s but could not drop its planning record\n' "$PLAN_ID" >&2; exit 1; }
    exit 0
    ;;
esac
"$SCRIPT_DIR/fm-backlog-plan.sh" set "$PLAN_ID" "${PLAN_ARGS[@]}" >/dev/null
rc=$?
[ "$rc" -ne 0 ] || exit 0
# A refusal with no tasks-axi change is the plan script's own clear message.
# Once tasks-axi has written the row, any plan failure is loud and nonzero so
# the fields are never dropped silently.
[ "$TASKS_RAN" = 1 ] || exit "$rc"
printf 'fm-tasks-axi: %s wrote the backlog row, but planning fields for %s were not recorded; rerun update %s with them\n' \
  "$SUBCMD" "$PLAN_ID" "$PLAN_ID" >&2
exit 1
