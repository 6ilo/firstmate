#!/usr/bin/env bash
# Behavior tests for the opt-in fleet activity ledger (docs/fleet-ledger.md).
#
# Every case drives the real producers - bin/fm-spawn.sh, bin/fm-watch.sh,
# bin/fm-pr-check.sh, the shared merge-outcome publication, bin/fm-teardown.sh,
# and bin/fm-afk-contract.sh - against a hermetic home and asserts the ledger
# file a reader would see: nothing at all while config/fleet-ledger is absent,
# and the task lifecycle in order, as valid versioned JSON Lines, once it exists.
# One case drives the shared producer gate directly, with a stand-in writer, to
# assert that an off home never starts the writer at all.
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
  leftovers=$(find "$(home_of "$case_dir")/state" -maxdepth 1 -name '*fleet-ledger*' 2>/dev/null)
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

# The producer gate itself, with a writer that records being started. An off
# home must never reach it; an on home must.
test_the_producer_gate_starts_no_writer_while_the_flag_is_absent() {
  local dir home out
  dir="$TMP_ROOT/gate"
  home="$dir/home"
  mkdir -p "$home/state" "$home/config" "$dir/bin"
  cp "$ROOT/bin/fm-fleet-ledger-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/"
  cat > "$dir/bin/fm-fleet-ledger.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_STATE_OVERRIDE/writer-started"
SH
  chmod +x "$dir/bin/fm-fleet-ledger.sh"
  call_gate() {
    bash -c 'set -u
      . "$1/bin/fm-fleet-ledger-lib.sh"
      fm_fleet_ledger "$2" "$2/state" record session.started
      fm_fleet_ledger "$2" "$2/state" capture' _ "$dir" "$home" 2>&1
  }
  out=$(call_gate) || fail "the off gate reported failure: $out"
  assert_equals "" "$out" "the off gate wrote output: $out"
  assert_absent "$home/state/writer-started" "an off home started the ledger writer"
  touch "$home/config/fleet-ledger"
  out=$(call_gate) || fail "the on gate reported failure: $out"
  assert_present "$home/state/writer-started" "an on home did not start the ledger writer"
  assert_equals "record session.started;capture" \
    "$(paste -sd';' - < "$home/state/writer-started")" \
    "the on gate did not pass each producer's arguments through"
  pass "with config/fleet-ledger absent the producer gate starts no ledger writer at all"
}

test_enable_records_everything_after_it_and_disable_stops() {
  local home ledger
  home="$TMP_ROOT/enable/home"
  mkdir -p "$home/state" "$home/config"
  ledger="$home/state/fleet-ledger.jsonl"
  printf 'working: before opt-in\n' > "$home/state/old.status"
  run_ledger "$home" enable >/dev/null || fail "enable failed"
  assert_present "$home/config/fleet-ledger" "enable did not turn the ledger on"
  printf 'done: after opt-in\n' >> "$home/state/old.status"
  run_ledger "$home" capture || fail "the first capture after enable failed"
  assert_equals "ledger.started task.status" "$(jq -r '.event' "$ledger" | paste -sd' ' -)" \
    "the first capture after enable did not record exactly the post-enable line: $(cat "$ledger")"
  assert_equals "after opt-in" "$(jq -r 'select(.event == "task.status") | .text' "$ledger")" \
    "enable replayed history instead of baselining it"
  run_ledger "$home" disable >/dev/null || fail "disable failed"
  assert_absent "$home/config/fleet-ledger" "disable did not turn the ledger off"
  printf 'done: after disable\n' >> "$home/state/old.status"
  run_ledger "$home" capture || fail "a capture on a disabled home failed"
  assert_equals 2 "$(wc -l < "$ledger" | tr -d ' ')" "a disabled ledger kept recording"
  run_ledger "$home" enable >/dev/null || fail "re-enable failed"
  printf 'done: after re-enable\n' >> "$home/state/old.status"
  run_ledger "$home" capture || fail "the first capture after re-enable failed"
  assert_equals "after opt-in after re-enable" \
    "$(jq -r 'select(.event == "task.status") | .text' "$ledger" | paste -sd' ' -)" \
    "re-enabling replayed the lines appended while the ledger was off"
  assert_equals "1 2 3 4" "$(jq -r '.seq' "$ledger" | paste -sd' ' -)" \
    "the sequence did not continue across disable and enable"
  pass "enable baselines history and records from that moment, and disable stops the ledger"
}

# Hold the ledger's own lock the way the writer does, from a live process, so
# the lock's stale-owner recovery cannot reclaim it. Returns once it is held.
HOLDER_PID=
hold_ledger_lock() {  # <home> <held-marker> <release-marker>
  local home=$1 held=$2 release=$3 i=0
  rm -f "$held" "$release"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2/state/.fleet-ledger.lock" || exit 1
    : > "$3"
    i=0
    while [ ! -e "$4" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
    fm_lock_release "$2/state/.fleet-ledger.lock"
  ' _ "$ROOT" "$home" "$held" "$release" &
  HOLDER_PID=$!
  while [ ! -e "$held" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$held" ] || fail "the ledger lock could not be taken for the test"
}

release_ledger_lock() {  # <release-marker>
  : > "$1"
  wait "$HOLDER_PID" 2>/dev/null || true
}

test_flag_changes_wait_for_the_ledger_lock() {
  local home flag pid
  home="$TMP_ROOT/serialize/home"
  mkdir -p "$home/state" "$home/config"
  flag="$home/config/fleet-ledger"
  run_ledger "$home" enable >/dev/null || fail "enable failed"
  hold_ledger_lock "$home" "$TMP_ROOT/off.held" "$TMP_ROOT/off.release"
  run_ledger "$home" disable >/dev/null &
  pid=$!
  sleep 0.5
  assert_present "$flag" "disable turned the ledger off without holding the ledger lock"
  release_ledger_lock "$TMP_ROOT/off.release"
  wait "$pid" || fail "disable failed"
  assert_absent "$flag" "disable left the ledger on"
  hold_ledger_lock "$home" "$TMP_ROOT/on.held" "$TMP_ROOT/on.release"
  run_ledger "$home" enable >/dev/null &
  pid=$!
  sleep 0.5
  assert_absent "$flag" "enable turned the ledger on without holding the ledger lock"
  release_ledger_lock "$TMP_ROOT/on.release"
  wait "$pid" || fail "re-enable failed"
  assert_present "$flag" "enable left the ledger off"
  pass "enable and disable change the flag only while they hold the ledger lock"
}

# The reported race: a producer passes the flag test, queues behind the lock,
# and only reaches the ledger after the ledger was turned off. The flag is
# removed here while the writer is parked, which is the state disable leaves
# behind once it has returned.
test_a_record_that_reaches_the_lock_after_opt_out_writes_nothing() {
  local home ledger pid
  home="$TMP_ROOT/optout/home"
  mkdir -p "$home/state" "$home/config"
  ledger="$home/state/fleet-ledger.jsonl"
  run_ledger "$home" enable >/dev/null || fail "enable failed"
  hold_ledger_lock "$home" "$TMP_ROOT/optout.held" "$TMP_ROOT/optout.release"
  run_ledger "$home" record session.started &
  pid=$!
  sleep 0.5
  assert_equals 1 "$(wc -l < "$ledger" | tr -d ' ')" \
    "a record was appended while another process held the ledger lock"
  rm -f "$home/config/fleet-ledger"
  release_ledger_lock "$TMP_ROOT/optout.release"
  wait "$pid" || fail "the queued record reported a failure"
  assert_equals 1 "$(wc -l < "$ledger" | tr -d ' ')" \
    "a record landed after the ledger was turned off: $(cat "$ledger")"
  pass "a record that reaches the lock after opt-out writes nothing"
}

test_a_blocked_writer_does_not_block_its_producer() {
  local home ledger out
  home="$TMP_ROOT/bound/home"
  mkdir -p "$home/state" "$home/config"
  ledger="$home/state/fleet-ledger.jsonl"
  run_ledger "$home" enable >/dev/null || fail "enable failed"
  hold_ledger_lock "$home" "$TMP_ROOT/bound.held" "$TMP_ROOT/bound.release"
  out=$(FM_FLEET_LEDGER_TIMEOUT=1 bash -c '
    . "$1/bin/fm-fleet-ledger-lib.sh"
    fm_fleet_ledger "$2" "$2/state" record session.started
    printf "producer-continued\n"' _ "$ROOT" "$home" 2>&1)
  release_ledger_lock "$TMP_ROOT/bound.release"
  assert_contains "$out" "producer-continued" \
    "a ledger writer that could not proceed stopped its producer"
  assert_contains "$out" "did not finish within 1s" \
    "the dropped event was not reported to the producer"
  assert_equals 1 "$(wc -l < "$ledger" | tr -d ' ')" \
    "the bounded writer appended a record after it was stopped"
  pass "a producer whose ledger write cannot proceed is bounded, told, and carries on"
}

test_invalid_utf8_status_text_is_dropped_with_and_without_iconv() {
  local home ledger fakebin
  home="$TMP_ROOT/utf8/home"
  mkdir -p "$home/state" "$home/config"
  ledger="$home/state/fleet-ledger.jsonl"
  run_ledger "$home" enable >/dev/null || fail "enable failed"
  printf 'done: caf\xc3\xa9 \xff ok\n' >> "$home/state/t1.status"
  run_ledger "$home" capture || fail "capture failed"
  assert_equals "café  ok" "$(jq -r 'select(.task == "t1") | .text' "$ledger")" \
    "an invalid byte survived, or valid UTF-8 did not"
  fakebin=$(fm_fakebin "$TMP_ROOT/utf8")
  cat > "$fakebin/iconv" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/iconv"
  printf 'done: plain \xff bytes\n' >> "$home/state/t2.status"
  ( PATH="$fakebin:$PATH"; run_ledger "$home" capture ) || fail "capture without iconv failed"
  assert_equals "plain  bytes" "$(jq -r 'select(.task == "t2") | .text' "$ledger")" \
    "the fallback kept bytes it cannot prove are valid UTF-8"
  iconv -f UTF-8 -t UTF-8 "$ledger" >/dev/null 2>&1 \
    || fail "the ledger is not valid UTF-8: $(cat "$ledger")"
  pass "invalid UTF-8 in a status line is dropped whether or not iconv works"
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
test_the_producer_gate_starts_no_writer_while_the_flag_is_absent
test_enable_records_everything_after_it_and_disable_stops
test_flag_changes_wait_for_the_ledger_lock
test_a_record_that_reaches_the_lock_after_opt_out_writes_nothing
test_a_blocked_writer_does_not_block_its_producer
test_invalid_utf8_status_text_is_dropped_with_and_without_iconv
test_rotation_keeps_sequence_numbers_continuous
test_away_mode_entry_and_return_are_recorded
