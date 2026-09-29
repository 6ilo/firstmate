#!/usr/bin/env bash
# Reap orphaned processes a no-mistakes run left behind in its own run copy.
#
# Usage: fm-nm-reap-run-orphans.sh [--dry-run] [--branch <name>]
#   --dry-run        reports what would be reaped and signals nothing.
#   --branch <name>  only considers runs whose structured status names this
#                    branch (teardown passes the task's own branch).
#
# A no-mistakes test step runs the project's suite inside the run's per-run
# copy (<NM_HOME>/worktrees/<repo id>/<run id>, NM_HOME defaulting to
# ~/.no-mistakes). A test runner that forks workers - vitest's "node (vitest N)"
# pool is the observed case, several GB each - can leave them reparented to
# init when the step ends, still holding memory while the run moves on to CI.
# Firstmate teardown's own worktree reap never sees them, because their working
# directory is the run copy rather than the task worktree, and teardown comes
# long after the step ended anyway.
#
# The reap condition is all of:
#   - the process belongs to this user and its parent is 1 (a process with a
#     live parent is somebody's current work, never a candidate);
#   - its current working directory is inside a run copy under
#     <NM_HOME>/worktrees/<repo id>/<run id>;
#   - that run's structured status (`no-mistakes axi status --run <id>`, read
#     from inside the run copy, bounded) reports that same run id and shows it
#     past every step that runs tests or fixes: the run is terminal (completed,
#     failed, cancelled), or it is running with its test step completed or
#     skipped, every step completed or skipped except push, pr, or ci, and those
#     only pending or running - a fixing round, an approval gate, or any status
#     word this sweep does not know keeps the run's processes untouched.
# A run whose status cannot be read, or reads ambiguously, is left alone.
# Process age is never evidence.
#
# This process, its own process group, and every ancestor are never signalled.
# Each candidate gets TERM, and KILL follows only for a survivor whose identity
# (start time and command) still matches what was scanned, so a recycled pid is
# never signalled.
#
# Prints one line per reaped or surviving candidate and nothing when there is
# nothing to do. Exits 0 unless the process scan itself could not run, so a
# caller can sweep without risking its own outcome.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

DRY_RUN=0
ONLY_BRANCH=
STATUS_TIMEOUT=${FM_NM_REAP_STATUS_TIMEOUT:-10}
case "$STATUS_TIMEOUT" in ''|*[!0-9]*|0) STATUS_TIMEOUT=10 ;; esac
KILL_GRACE_SECS=2

reap_die() { printf 'fm-nm-reap-run-orphans: %s\n' "$1" >&2; exit 2; }

reap_usage() {
  cat <<'TXT'
Usage: fm-nm-reap-run-orphans.sh [--dry-run] [--branch <name>]

Stop orphaned processes (parent 1) whose working directory is inside a
no-mistakes run copy, only when that run's structured status shows it past
every step that runs tests or fixes. A run that cannot be read is left alone.
--dry-run reports the candidates and signals nothing; --branch limits the
sweep to runs on that branch. Read this script's header for the full rule.
TXT
}

reap_is_self_or_ancestor() { # <pid>
  local pid=$1 walk=$$ i=0
  while [ "$walk" -gt 1 ] && [ "$i" -lt 64 ]; do
    [ "$walk" != "$pid" ] || return 0
    walk=$(ps -p "$walk" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 0
    case "$walk" in ''|*[!0-9]*) return 1 ;; esac
    i=$((i + 1))
  done
  return 1
}

# Start time plus command: stable for one process, different for a recycled pid.
reap_identity() { # <pid>
  local out
  out=$(LC_ALL=C ps -p "$1" -o lstart=,command= 2>/dev/null) || return 1
  out=$(fm_nm_trim "$out")
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

reap_ppid() { # <pid>
  ps -p "$1" -o ppid= 2>/dev/null | tr -d '[:space:]'
}

# pid<TAB>cwd for each pid in $@, one line each; pids whose cwd cannot be read
# are omitted.
reap_cwds() { # <pid>...
  local pid line list
  [ "$#" -gt 0 ] || return 0
  if command -v lsof >/dev/null 2>&1; then
    list=$(printf '%s,' "$@")
    list=${list%,}
    pid=
    # lsof exits non-zero when any listed pid has already gone; the rest of its
    # output is still exact, so the status is deliberately ignored.
    while IFS= read -r line; do
      case "$line" in
        p*) pid=${line#p} ;;
        n*) [ -n "$pid" ] && printf '%s\t%s\n' "$pid" "${line#n}" ;;
      esac
    done <<EOF
$(lsof -a -p "$list" -d cwd -Fpn 2>/dev/null)
EOF
    return 0
  fi
  for pid in "$@"; do
    line=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
    printf '%s\t%s\n' "$pid" "$line"
  done
}

# Echo "<run copy dir>" when $2 is inside a run copy under worktrees root $1.
reap_run_copy_of() { # <worktrees-root> <cwd>
  local root=$1 cwd=$2 rest repo run
  case "$cwd" in "$root"/*) ;; *) return 1 ;; esac
  rest=${cwd#"$root"/}
  repo=${rest%%/*}
  [ "$repo" != "$rest" ] || return 1
  rest=${rest#"$repo"/}
  run=${rest%%/*}
  case "$repo" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$run" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/%s/%s\n' "$root" "$repo" "$run"
}

# 0 when captured `axi status` output $1 for run $2 shows the run past every
# step that runs tests or fixes; see the header for the exact rule.
reap_run_is_past_tests() { # <toon-output> <run-id>
  local out=$1 run_id=$2 id status branch
  id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ "$id" = "$run_id" ] || return 1
  if [ -n "$ONLY_BRANCH" ]; then
    branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
    [ "$branch" = "$ONLY_BRANCH" ] || return 1
  fi
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  case "$status" in
    completed|failed|cancelled) return 0 ;;
    running|ci) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$out" | awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); gsub(/^"|"$/, "", s); return s }
    !in_steps && /^[[:space:]]*steps\[[0-9]+\]\{[^}]*\}:[[:space:]]*$/ {
      line = $0
      match(line, /^[[:space:]]*/); indent = RLENGTH
      want = line; sub(/^[[:space:]]*steps\[/, "", want); sub(/\].*/, "", want)
      hdr = line; sub(/^[^{]*\{/, "", hdr); sub(/\}.*/, "", hdr)
      n = split(hdr, cols, ",")
      for (i = 1; i <= n; i++) { if (cols[i] == "step") sc = i; if (cols[i] == "status") tc = i }
      if (!sc || !tc) { bad = 1; exit }
      in_steps = 1; seen_table = 1; next
    }
    in_steps {
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= indent || $0 ~ /^[[:space:]]*$/) { in_steps = 0; next }
      m = split($0, f, ",")
      if (m < n) { bad = 1; exit }
      rows++
      s = trim(f[sc]); st = trim(f[tc])
      if (s == "test") { if (st == "completed" || st == "skipped") test_ok = 1; else { bad = 1; exit } }
      if (st == "completed" || st == "skipped") next
      if ((s == "push" || s == "pr" || s == "ci") && (st == "pending" || st == "running")) next
      bad = 1; exit
    }
    END { exit (bad || !seen_table || rows != want + 0 || !test_ok) ? 1 : 0 }
  '
}

RUN_VERDICTS=

# 0 when run copy $1's run may have its orphans reaped; cached per sweep.
reap_run_allows() { # <run-copy-dir>
  local dir=$1 run_id out verdict
  case "$RUN_VERDICTS" in
    *"|$dir=yes|"*) return 0 ;;
    *"|$dir=no|"*) return 1 ;;
  esac
  run_id=${dir##*/}
  verdict=no
  if [ -d "$dir" ] && out=$(fm_nm_run_checked "$dir" "$STATUS_TIMEOUT" axi status --run "$run_id") \
     && reap_run_is_past_tests "$out" "$run_id"; then
    verdict=yes
  fi
  RUN_VERDICTS="${RUN_VERDICTS:-|}$dir=$verdict|"
  [ "$verdict" = yes ]
}

reap_orphans() {
  local uid nm_home root scan pid ppid own_pgid pgid cwd dir identity
  local -a orphans=() cand_pids=() cand_ids=() cand_dirs=()
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) reap_die "cannot resolve the current uid" ;; esac
  nm_home=${NM_HOME:-$HOME/.no-mistakes}
  [ -d "$nm_home/worktrees" ] || return 0
  root=$(cd "$nm_home/worktrees" && pwd -P) || return 0
  scan=$(ps -u "$uid" -o pid=,ppid= 2>/dev/null) ||
    reap_die "cannot scan this account's processes"
  while read -r pid ppid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$ppid" = 1 ] || continue
    [ "$pid" != "$$" ] || continue
    orphans+=("$pid")
  done <<EOF
$scan
EOF
  [ "${#orphans[@]}" -gt 0 ] || return 0
  own_pgid=$(ps -p "$$" -o pgid= 2>/dev/null | tr -d '[:space:]')

  while IFS=$'\t' read -r pid cwd; do
    [ -n "$pid" ] || continue
    dir=$(reap_run_copy_of "$root" "$cwd") || continue
    reap_is_self_or_ancestor "$pid" && continue
    if [ -n "$own_pgid" ]; then
      pgid=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]')
      [ "$pgid" != "$own_pgid" ] || continue
    fi
    reap_run_allows "$dir" || continue
    identity=$(reap_identity "$pid") || continue
    # Re-check the parent after the (slow) status read: a process adopted by a
    # live parent in the meantime is no longer an orphan.
    [ "$(reap_ppid "$pid")" = 1 ] || continue
    cand_pids+=("$pid")
    cand_ids+=("$identity")
    cand_dirs+=("$dir")
  done <<EOF
$(reap_cwds "${orphans[@]}")
EOF
  [ "${#cand_pids[@]}" -gt 0 ] || return 0

  local i waited=0 alive
  for i in "${!cand_pids[@]}"; do
    pid=${cand_pids[$i]}
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would reap orphaned no-mistakes run process %s (run copy %s)\n' "$pid" "${cand_dirs[$i]}"
      continue
    fi
    [ "$(reap_identity "$pid" 2>/dev/null)" = "${cand_ids[$i]}" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  [ "$DRY_RUN" -eq 0 ] || return 0

  while :; do
    alive=0
    for i in "${!cand_pids[@]}"; do
      [ "$(reap_identity "${cand_pids[$i]}" 2>/dev/null)" = "${cand_ids[$i]}" ] && alive=1
    done
    [ "$alive" -eq 1 ] || break
    [ "$waited" -lt $((KILL_GRACE_SECS * 10)) ] || break
    sleep 0.1
    waited=$((waited + 1))
  done
  for i in "${!cand_pids[@]}"; do
    pid=${cand_pids[$i]}
    if [ "$(reap_identity "$pid" 2>/dev/null)" = "${cand_ids[$i]}" ]; then
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.1
    fi
    if [ "$(reap_identity "$pid" 2>/dev/null)" = "${cand_ids[$i]}" ]; then
      printf 'warning: orphaned no-mistakes run process %s survived reaping (run copy %s)\n' "$pid" "${cand_dirs[$i]}" >&2
    else
      printf 'reaped orphaned no-mistakes run process %s (run copy %s)\n' "$pid" "${cand_dirs[$i]}"
    fi
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --branch)
      [ "$#" -ge 2 ] && [ -n "$2" ] || reap_die "--branch needs a branch name"
      ONLY_BRANCH=$2
      shift
      ;;
    -h|--help) reap_usage; exit 0 ;;
    *) reap_die "unexpected argument: $1" ;;
  esac
  shift
done

reap_orphans
