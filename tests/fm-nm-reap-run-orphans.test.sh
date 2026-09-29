#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-reap-run-orphans.sh.
#
# The leak this pins: a no-mistakes test step's runner forks workers (vitest's
# "node (vitest N)" pool) that end up at parent 1 with their working directory
# in the run's own copy under <NM_HOME>/worktrees/<repo>/<run>, holding GBs of
# memory while the run has moved on to CI.
#
# Real processes stand in for those workers. Only the no-mistakes CLI is faked,
# at its system boundary: it answers `axi status --run <id>` with a fixture
# TOON document for that run, or fails for a run with no fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-nm-reap-run-orphans)
REAPER="$ROOT/bin/fm-nm-reap-run-orphans.sh"

TRACKED_PIDS=()
reap_test_cleanup() {
  local pid
  for pid in "${TRACKED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap reap_test_cleanup EXIT

alive() { kill -0 "$1" 2>/dev/null; }
ppid_of() { ps -p "$1" -o ppid= 2>/dev/null | tr -d '[:space:]'; }

wait_gone() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    alive "$pid" || return 0
    sleep 0.1
  done
  ! alive "$pid"
}

wait_ppid1() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(ppid_of "$pid")" = 1 ] && return 0
    sleep 0.1
  done
  return 1
}

NM_HOME="$TMP_ROOT/nm-home"
export NM_HOME
WT_ROOT="$NM_HOME/worktrees/repo0001"
STATUS_DIR="$TMP_ROOT/status"
mkdir -p "$WT_ROOT" "$STATUS_DIR" "$TMP_ROOT/elsewhere"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/no-mistakes" <<SH
#!/usr/bin/env bash
# Fake no-mistakes: 'axi status --run <id>' prints the fixture for that run,
# only when invoked from inside that run's copy.
[ "\$1 \$2 \$3" = "axi status --run" ] || exit 2
run=\$4
[ "\$(basename "\$PWD")" = "\$run" ] || exit 3
[ -f "$STATUS_DIR/\$run.toon" ] || { echo "error: run not found" >&2; exit 1; }
cat "$STATUS_DIR/\$run.toon"
SH
chmod +x "$FAKEBIN/no-mistakes"
export PATH="$FAKEBIN:$PATH"

# write_status <run> <run-status> <branch> <step,status>...
write_status() {
  local run=$1 status=$2 branch=$3 row
  shift 3
  {
    printf 'run:\n  id: "%s"\n  branch: %s\n  status: %s\n  findings: none\n' "$run" "$branch" "$status"
    printf '  steps[%s]{step,status,findings,duration_ms}:\n' "$#"
    for row in "$@"; do printf '    %s,0,1\n' "$row"; done
  } > "$STATUS_DIR/$run.toon"
}

PAST_TEST=('intent,completed' 'rebase,completed' 'review,completed' 'test,completed' 'document,completed' 'lint,completed' 'push,completed' 'pr,completed' 'ci,running')
IN_TEST=('intent,completed' 'rebase,completed' 'review,completed' 'test,running' 'document,pending' 'lint,pending' 'push,pending' 'pr,pending' 'ci,pending')

# start_orphan <dir> <seconds>: a real process with <dir> as its working
# directory, in its own process group the way a runner's worker pool is (never
# the sweeping process's group), reparented to init once its launching subshell
# exits; echoes its pid. Callers add it to TRACKED_PIDS, because an append
# inside this command substitution would never reach the cleanup trap.
start_orphan() {
  ( cd "$1" && { perl -e 'setpgrp(0, 0); exec @ARGV' sleep "$2" </dev/null >/dev/null 2>&1 & echo $!; } )
}

mkdir -p "$WT_ROOT/RUNPAST/node_modules" "$WT_ROOT/RUNTEST" "$WT_ROOT/RUNGONE"
write_status RUNPAST running fm/a "${PAST_TEST[@]}"
write_status RUNTEST running fm/b "${IN_TEST[@]}"
# RUNGONE deliberately has no status fixture: its run cannot be read.

PAST=$(start_orphan "$WT_ROOT/RUNPAST/node_modules" 3001)
INTEST=$(start_orphan "$WT_ROOT/RUNTEST" 3002)
GONE=$(start_orphan "$WT_ROOT/RUNGONE" 3003)
OUTSIDE=$(start_orphan "$TMP_ROOT/elsewhere" 3004)
TRACKED_PIDS+=("$PAST" "$INTEST" "$GONE" "$OUTSIDE")
for pid in "$PAST" "$INTEST" "$GONE" "$OUTSIDE"; do
  if ! wait_ppid1 "$pid" 5; then
    # A host whose orphans go to a subreaper rather than init cannot build the
    # parent-1 shape this sweep targets.
    echo "skip: orphaned fixture processes are not reparented to pid 1 on this host (parent $(ppid_of "$pid"))"
    exit 0
  fi
done

# A process with a live parent in the same past-test run copy.
( cd "$WT_ROOT/RUNPAST" && exec bash -c 'sleep 3005 & wait' ) &
PARENTED_SHELL=$!
disown "$PARENTED_SHELL" 2>/dev/null || true
TRACKED_PIDS+=("$PARENTED_SHELL")
sleep 0.3
PARENTED=$(pgrep -P "$PARENTED_SHELL" | head -n 1)
[ -n "$PARENTED" ] || fail "the parented fixture child did not start"
TRACKED_PIDS+=("$PARENTED")

out=$("$REAPER" --dry-run 2>&1) || fail "dry run failed: $out"
assert_contains "$out" "would reap orphaned no-mistakes run process $PAST " "dry run did not report the past-test orphan"
for pid in "$PAST" "$INTEST" "$GONE" "$OUTSIDE" "$PARENTED"; do
  alive "$pid" || fail "--dry-run signalled process $pid"
done
pass "--dry-run reports the candidate and signals nothing"

out=$("$REAPER" --branch fm/other 2>&1) || fail "branch-scoped sweep failed: $out"
alive "$PAST" || fail "a sweep scoped to another branch reaped the run's orphan"
pass "--branch leaves runs on other branches alone"

out=$("$REAPER" 2>&1) || fail "sweep failed: $out"
wait_gone "$PAST" 5 || fail "the orphan in a run past its test step survived: $out"
assert_contains "$out" "reaped orphaned no-mistakes run process $PAST " "the reap was not reported"
pass "an orphan at parent 1 in a run copy past its test step is reaped"

alive "$INTEST" || fail "an orphan in a run still in its test step was reaped"
assert_not_contains "$out" " $INTEST " "the in-test orphan was reported"
pass "the same orphan while its run is in the test step is left alone"

alive "$PARENTED" || fail "a process with a live parent in a run copy was reaped"
pass "a process with a live parent in a run copy is left alone"

alive "$OUTSIDE" || fail "a process outside every run copy was reaped"
pass "a process outside any run copy is left alone"

alive "$GONE" || fail "an orphan in an unreadable run was reaped"
pass "an orphan in a run whose status cannot be read is left alone"

# Fixing, gates, and unknown status words keep a run's processes untouched even
# past the test step.
write_status RUNTEST running fm/b intent,completed review,completed test,completed document,completed lint,completed push,completed pr,completed ci,fixing
"$REAPER" >/dev/null 2>&1 || fail "sweep failed on a fixing run"
alive "$INTEST" || fail "an orphan in a run whose CI step is fixing was reaped"
write_status RUNTEST awaiting_approval fm/b intent,completed review,completed test,completed document,awaiting_approval
"$REAPER" >/dev/null 2>&1 || fail "sweep failed on a parked run"
alive "$INTEST" || fail "an orphan in a run parked at an approval gate was reaped"
pass "a fixing round or an approval gate keeps the run's orphans"

# A terminal run is past every test step, and the branch scope teardown uses matches it.
write_status RUNTEST cancelled fm/b intent,completed test,running
"$REAPER" --branch fm/b >/dev/null 2>&1 || fail "branch sweep failed on a cancelled run"
wait_gone "$INTEST" 5 || fail "the orphan of a cancelled run on the named branch survived"
pass "a terminal run's orphans are reaped by a sweep scoped to its branch"
