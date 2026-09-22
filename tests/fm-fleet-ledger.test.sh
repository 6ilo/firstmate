#!/usr/bin/env bash
# Behavior tests for the opt-in fleet activity ledger (docs/fleet-ledger.md).
#
# Every case drives the real producers - bin/fm-spawn.sh, bin/fm-watch.sh,
# bin/fm-pr-check.sh, the shared merge-outcome publication, bin/fm-teardown.sh,
# and bin/fm-afk-contract.sh - against a hermetic home and asserts the ledger
# file a reader would see: nothing at all while config/fleet-ledger is absent,
# and the task lifecycle in order, as valid versioned JSON Lines, once it exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || {
  printf 'ok - skipped (jq is not installed; ledger records are validated with it)\n'
  exit 0
}

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
WATCH="$ROOT/bin/fm-watch.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
LEDGER_BIN="$ROOT/bin/fm-fleet-ledger.sh"
AFK_CONTRACT="$ROOT/bin/fm-afk-contract.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-ledger)
PR_URL=https://github.com/acme/webapp/pull/7

# A home with a manual backlog, a real project clone with an origin, a pooled
# worktree, and stubs for every tool the spawn path shells out to.
make_home() {  # <name> <task-id> <on|off>
  local name=$1 id=$2 flag=$3 case_dir home fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data/$id" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  [ "$flag" = off ] || touch "$home/config/fleet-ledger"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the fleet ledger for $id.

## Firstmate spec
Record the lifecycle.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes tasks-axi
  fm_git_init_commit "$case_dir/webapp"
  fm_git_add_origin "$case_dir/webapp" "$case_dir/webapp.origin.git"
  git -C "$case_dir/webapp" worktree add --quiet -b pooled "$case_dir/wt"
  printf '%s\n' "$case_dir"
}

home_of() { printf '%s/home\n' "$1"; }
ledger_of() { printf '%s/home/state/fleet-ledger.jsonl\n' "$1"; }

run_spawn() {  # <case-dir> <id>
  local case_dir=$1 id=$2
  mkdir -p "$case_dir/user-home"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" HOME="$case_dir/user-home" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$case_dir/webapp" --mode no-mistakes --yolo off 2>&1
}

# One real watcher run: it picks status lines up at the top of its poll and
# exits once it surfaces the captain-relevant done line.
run_watcher() {  # <case-dir>
  local case_dir=$1 home pid i=0
  home=$(home_of "$case_dir")
  PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$case_dir/watch.out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 1
  fi
  wait "$pid" 2>/dev/null
  return 0
}

run_pr_check() {  # <case-dir> <id>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$1")" PATH="$1/fakebin:$PATH" \
    "$PR_CHECK" "$2" "$PR_URL" 2>&1
}

# The merge poll's publication step, exactly as the watcher calls it.
report_merge() {  # <case-dir> <id>
  local home
  home=$(home_of "$1")
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" bash -c '
    . "$1/bin/fm-merge-outcome-lib.sh"
    fm_merge_outcome_report "$2" "$2/state" "$3" "$4" poll
  ' _ "$ROOT" "$home" "$2" "$PR_URL" 2>&1
}

# Teardown against a recorded worktree that no longer exists, so the landed-work
# gates are no-ops and the case stays about what the ledger records.
run_teardown() {  # <case-dir> <id>
  local case_dir=$1 id=$2 home
  home=$(home_of "$case_dir")
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$case_dir/absent-worktree" "project=$case_dir/webapp" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" "spawn_gen=ledger-$id"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" 2>&1
}

# Spawn, report, surface, record the PR, merge, and clean up one task.
drive_lifecycle() {  # <case-dir> <id>
  local case_dir=$1 id=$2 home out
  home=$(home_of "$case_dir")
  out=$(run_spawn "$case_dir" "$id") || fail "spawn failed: $out"
  printf 'working [at=1790000001]: implementing\n' >> "$home/state/$id.status"
  printf 'done [at=1790000002]: PR %s checks green\n' "$PR_URL" >> "$home/state/$id.status"
  run_watcher "$case_dir" || fail "the watcher never surfaced the done line: $(cat "$case_dir/watch.out")"
  if [ -e "$home/state/fleet-ledger.jsonl" ]; then
    cp "$home/state/fleet-ledger.jsonl" "$case_dir/after-watch.jsonl"
  fi
  out=$(run_pr_check "$case_dir" "$id") || fail "PR recording failed: $out"
  out=$(report_merge "$case_dir" "$id") || fail "merge publication failed: $out"
  out=$(run_teardown "$case_dir" "$id") || fail "teardown failed: $out"
}

test_off_home_writes_nothing_through_the_real_lifecycle() {
  local case_dir id=ledger-off-t1 leftovers
  case_dir=$(make_home off "$id" off)
  drive_lifecycle "$case_dir" "$id"
  leftovers=$(cd "$(home_of "$case_dir")/state" && ls -a | grep 'fleet-ledger' || true)
  assert_equals "" "$leftovers" "an off home wrote ledger state: $leftovers"
  pass "with config/fleet-ledger absent the whole lifecycle writes no ledger state"
}

test_on_home_records_the_lifecycle_end_to_end() {
  local case_dir id=ledger-on-t1 ledger events seqs status_text
  case_dir=$(make_home on "$id" on)
  drive_lifecycle "$case_dir" "$id"
  ledger=$(ledger_of "$case_dir")
  assert_present "$ledger" "an on home wrote no ledger"
  jq -e -s 'all(.[]; .v == 1 and (.seq | type) == "number" and (.ts | type) == "number")' \
    "$ledger" >/dev/null || fail "a ledger line is not a valid version 1 record: $(cat "$ledger")"
  events=$(jq -r '.event' "$ledger" | paste -sd' ' -)
  assert_equals "ledger.started task.dispatched task.status task.status task.pr_recorded task.merged task.cleaned_up" \
    "$events" "the lifecycle was recorded out of order: $(cat "$ledger")"
  assert_equals "ledger.started task.dispatched task.status task.status" \
    "$(jq -r '.event' "$case_dir/after-watch.jsonl" | paste -sd' ' -)" \
    "the watcher did not record the worker's status lines itself"
  seqs=$(jq -r '.seq' "$ledger" | paste -sd' ' -)
  assert_equals "1 2 3 4 5 6 7" "$seqs" "sequence numbers are not contiguous"
  [ "$(jq -r 'select(.event != "ledger.started") | .task' "$ledger" | sort -u)" = "$id" ] \
    || fail "a task record named the wrong task"
  jq -e 'select(.event == "task.dispatched") | .kind == "ship" and .project == "webapp"
    and .harness == "claude" and .mode == "no-mistakes" and .yolo == "off"' "$ledger" >/dev/null \
    || fail "the dispatch record is wrong: $(grep dispatched "$ledger")"
  status_text=$(jq -r 'select(.event == "task.status") | "\(.state)|\(.at)|\(.text)"' "$ledger" | paste -sd';' -)
  assert_equals "working|1790000001|implementing;done|1790000002|PR $PR_URL checks green" \
    "$status_text" "status events were not projected faithfully"
  jq -e 'select(.event == "task.pr_recorded") | .pr == "'"$PR_URL"'"' "$ledger" >/dev/null \
    || fail "the PR record is wrong"
  jq -e 'select(.event == "task.merged") | .via == "pr" and .pr == "'"$PR_URL"'"' "$ledger" >/dev/null \
    || fail "the merge record is wrong"
  assert_no_grep "$TMP_ROOT" "$ledger" "the ledger leaked a local path"
  pass "with config/fleet-ledger present the lifecycle is recorded in order as versioned JSON Lines"
}

run_ledger() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$LEDGER_BIN" "$@"
}

test_opt_in_baselines_history_and_reads_new_logs_whole() {
  local home ledger
  home="$TMP_ROOT/baseline/home"
  mkdir -p "$home/state" "$home/config"
  ledger="$home/state/fleet-ledger.jsonl"
  printf 'working: before opt-in\n' > "$home/state/old.status"
  touch "$home/config/fleet-ledger"
  run_ledger "$home" capture || fail "baseline capture failed"
  assert_equals "ledger.started" "$(jq -r '.event' "$ledger" | paste -sd' ' -)" \
    "opting in replayed history"
  printf 'done: after opt-in\npartial' >> "$home/state/old.status"
  printf 'blocked [key=b1]: new log\n' > "$home/state/new.status"
  run_ledger "$home" capture || fail "capture failed"
  assert_equals "new|new log|b1;old|after opt-in|null" \
    "$(jq -r 'select(.event == "task.status") | "\(.task)|\(.text)|\(.key)"' "$ledger" | sort | paste -sd';' -)" \
    "new lines, or a log created after opt-in, were not read exactly once"
  printf ' line\n' >> "$home/state/old.status"
  run_ledger "$home" capture || fail "capture failed"
  run_ledger "$home" capture || fail "an unchanged capture failed"
  assert_equals "partial line" "$(jq -r 'select(.seq == 4) | .text' "$ledger")" \
    "a partial line was consumed before its newline arrived"
  assert_equals 4 "$(wc -l < "$ledger" | tr -d ' ')" "an unchanged capture appended records"
  pass "opting in skips history, reads new logs from their first line, and waits for whole lines"
}

test_rotation_keeps_sequence_numbers_continuous() {
  local home ledger i
  home="$TMP_ROOT/rotation/home"
  mkdir -p "$home/state" "$home/config"
  ledger="$home/state/fleet-ledger.jsonl"
  touch "$home/config/fleet-ledger"
  for i in 1 2 3 4; do
    FM_FLEET_LEDGER_MAX_BYTES=150 run_ledger "$home" record session.started \
      || fail "record $i failed"
  done
  assert_present "$ledger.1" "the ledger never rotated"
  assert_equals "$(tail -1 "$ledger.1" | jq -r '.seq')" "$(( $(head -1 "$ledger" | jq -r '.seq') - 1 ))" \
    "rotation broke the sequence"
  assert_equals 5 "$(tail -1 "$ledger" | jq -r '.seq')" "rotation lost or repeated a sequence number"
  pass "rotation moves the full ledger aside and the sequence continues"
}

test_away_mode_entry_and_return_are_recorded() {
  local home ledger
  home="$TMP_ROOT/away/home"
  mkdir -p "$home/state" "$home/config"
  ledger="$home/state/fleet-ledger.jsonl"
  touch "$home/config/fleet-ledger"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$AFK_CONTRACT" enter --words 'back soon' >/dev/null 2>&1 \
    || fail "away entry failed"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$AFK_CONTRACT" enter >/dev/null 2>&1 \
    || fail "away refresh failed"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$AFK_CONTRACT" archive >/dev/null 2>&1 \
    || fail "away return failed"
  assert_equals "ledger.started away.entered away.returned" "$(jq -r '.event' "$ledger" | paste -sd' ' -)" \
    "away mode was not recorded once per entry and return"
  assert_no_grep "back soon" "$ledger" "the ledger recorded the captain's away words"
  pass "away entry and return are recorded without the captain's words"
}

test_off_home_writes_nothing_through_the_real_lifecycle
test_on_home_records_the_lifecycle_end_to_end
test_opt_in_baselines_history_and_reads_new_logs_whole
test_rotation_keeps_sequence_numbers_continuous
test_away_mode_entry_and_return_are_recorded
