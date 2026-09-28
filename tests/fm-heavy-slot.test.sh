#!/usr/bin/env bash
# Behavior tests for bin/fm-heavy-slot.sh, the machine-scoped heavy-validation
# slot ledger: lane reservation math, contention between two homes sharing one
# ledger, each memory/load/browser gate refusing on an injected reading,
# unknown readings never refusing, ask waiters, and evidence-only reaping.
# Every reading is injected through the script's FM_HEAVY_SLOT_* variables so
# the host machine's real load never decides a verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLOT="$ROOT/bin/fm-heavy-slot.sh"
TMP_ROOT=$(fm_test_tmproot fm-heavy-slot)

# Calm readings by default; each gate test overrides one.
export FM_HEAVY_SLOT_LOAD1=1.5 FM_HEAVY_SLOT_PRESSURE_LEVEL=1 \
  FM_HEAVY_SLOT_SWAP_USED_MB=100 \
  FM_HEAVY_SLOT_BROWSER_PAGES=4 FM_HEAVY_SLOT_POLL=1

new_world() {  # <name>: sets LEDGER_DIR, HOME_A, HOME_B
  LEDGER_DIR="$TMP_ROOT/$1/ledger"
  HOME_A="$TMP_ROOT/$1/home-a"
  HOME_B="$TMP_ROOT/$1/home-b"
  mkdir -p "$HOME_A/state" "$HOME_A/config" "$HOME_B/state" "$HOME_B/config"
  HOME_A=$(cd "$HOME_A" && pwd -P)
  HOME_B=$(cd "$HOME_B" && pwd -P)
}

slot() {
  FM_HEAVY_SLOT_DIR="$LEDGER_DIR" "$SLOT" "$@"
}

acquire() {  # <home> <task> <lane> [extra...]
  local home=$1 task=$2 lane=$3
  shift 3
  slot acquire --home "$home" --task "$task" --lane "$lane" --pid "$$" --worktree "$home" "$@" 2>&1
}

dead_pid() {
  local pid
  sleep 0 &
  pid=$!
  wait "$pid" 2>/dev/null
  printf '%s\n' "$pid"
}

test_reservation_math() {
  local out status
  new_world reserve
  out=$(acquire "$HOME_A" b1 backlog); status=$?
  expect_code 0 "$status" "the first backlog holder should get the shared slot"
  out=$(acquire "$HOME_A" b2 backlog); status=$?
  expect_code 3 "$status" "a second backlog holder must be refused"
  assert_contains "$out" "refused: backlog work may hold at most 1 of 3" "backlog refusal did not name the reservation"
  out=$(acquire "$HOME_A" a1 ask); status=$?
  expect_code 0 "$status" "an ask should take a reserved slot"
  out=$(acquire "$HOME_A" a2 ask); status=$?
  expect_code 0 "$status" "a second ask should take the last slot"
  out=$(acquire "$HOME_A" a3 ask); status=$?
  expect_code 3 "$status" "a fourth heavy run must be refused"
  assert_contains "$out" "all 3 heavy slots are held" "full-ledger refusal did not name the cap"

  # Asks alone may use every slot, including the shared one.
  new_world reserve-asks
  acquire "$HOME_A" a1 ask >/dev/null || fail "ask 1 refused"
  acquire "$HOME_A" a2 ask >/dev/null || fail "ask 2 refused"
  acquire "$HOME_A" a3 ask >/dev/null || fail "an ask was refused the shared slot"
  out=$(acquire "$HOME_A" b1 backlog); status=$?
  expect_code 3 "$status" "backlog work took a slot while asks held all three"

  # A holder refreshing its record (to add the run id) takes no second slot.
  new_world refresh
  acquire "$HOME_A" a1 ask >/dev/null || fail "ask refused"
  out=$(acquire "$HOME_A" a1 ask --run run-123); status=$?
  expect_code 0 "$status" "refreshing an existing hold should succeed"
  out=$(slot list)
  assert_contains "$out" "held=1/3" "a refresh consumed a second slot"
  assert_contains "$out" ",a1,ask,$$,run-123," "the refresh did not record the run id"
  pass "fm-heavy-slot: asks may use all 3 slots and backlog work at most 1"
}

test_capacity_from_home_config() {
  local out status
  new_world config
  printf '%s\n' '{"heavy_total": 4, "ask_reserve": 2}' > "$HOME_A/config/lanes.json"
  acquire "$HOME_A" b1 backlog >/dev/null || fail "backlog 1 refused under a 4/2 config"
  acquire "$HOME_A" b2 backlog >/dev/null || fail "backlog 2 refused under a 4/2 config"
  out=$(acquire "$HOME_A" b3 backlog); status=$?
  expect_code 3 "$status" "a third backlog holder must be refused under a 4/2 config"
  assert_contains "$out" "at most 2 of 4" "refusal did not use the configured capacity"
  assert_absent "$HOME_B/config/lanes.json" "the script created a lanes.json"
  pass "fm-heavy-slot: capacity comes from the home's config/lanes.json"
}

# Two homes racing one ledger never overfill it.
test_contention_between_two_homes() {
  local i n pids=()
  new_world contend
  for i in 1 2 3 4 5 6; do
    acquire "$HOME_A" "a$i" ask > "$TMP_ROOT/contend/a$i.out" &
    pids+=("$!")
    acquire "$HOME_B" "b$i" ask > "$TMP_ROOT/contend/b$i.out" &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i"; done
  n=$(cat "$TMP_ROOT"/contend/*.out | grep -c '^acquired')
  assert_equals 3 "$n" "concurrent acquires from two homes did not fill exactly 3 slots"
  n=$(cat "$TMP_ROOT"/contend/*.out | grep -c '^refused:')
  assert_equals 9 "$n" "every losing acquire should report one refusal line"
  assert_contains "$(slot list)" "held=3/3" "the ledger does not show 3 holders"
  pass "fm-heavy-slot: two homes racing one ledger fill exactly the cap"
}

test_each_gate_refuses() {
  local label var value expect out status n=0
  while IFS='|' read -r label var value expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    new_world "gate-$n"
    out=$(env "$var=$value" FM_HEAVY_SLOT_DIR="$LEDGER_DIR" "$SLOT" acquire --home "$HOME_A" --task t1 --lane ask --pid "$$" 2>&1)
    status=$?
    expect_code 3 "$status" "$label: expected a refusal"
    assert_contains "$out" "$expect" "$label: refusal did not name the gate"
    assert_contains "$(slot list)" "held=0/3" "$label: a refused acquire still took a slot"
  done <<'ROWS'
load at the cap|FM_HEAVY_SLOT_LOAD1|16.0|load average 16.0 is at or above 16
critical memory pressure|FM_HEAVY_SLOT_PRESSURE_LEVEL|4|memory pressure level 4 is at or above 4
swap nearly full|FM_HEAVY_SLOT_SWAP_USED_MB|7168|swap used 7168MB is at or above 7168MB
too many browser pages|FM_HEAVY_SLOT_BROWSER_PAGES|31|31 browser page processes exceed 30
ROWS
  # Just under each threshold passes.
  new_world gate-under
  out=$(env FM_HEAVY_SLOT_LOAD1=15.9 FM_HEAVY_SLOT_PRESSURE_LEVEL=2 FM_HEAVY_SLOT_SWAP_USED_MB=7167 \
    FM_HEAVY_SLOT_BROWSER_PAGES=30 FM_HEAVY_SLOT_DIR="$LEDGER_DIR" \
    "$SLOT" acquire --home "$HOME_A" --task t1 --lane ask --pid "$$" 2>&1) \
    || fail "readings just under every threshold were refused: $out"
  # Thresholds are overridable from config/lanes.json.
  new_world gate-config
  printf '%s\n' '{"max_load": 8}' > "$HOME_A/config/lanes.json"
  out=$(env FM_HEAVY_SLOT_LOAD1=9 FM_HEAVY_SLOT_DIR="$LEDGER_DIR" \
    "$SLOT" acquire --home "$HOME_A" --task t1 --lane ask --pid "$$" 2>&1)
  status=$?
  expect_code 3 "$status" "a configured max_load was not applied"
  assert_contains "$out" "at or above 8" "refusal did not use the configured load cap"
  new_world gate-swap-config
  printf '%s\n' '{"max_swap_used_mb": 2048}' > "$HOME_A/config/lanes.json"
  out=$(env FM_HEAVY_SLOT_SWAP_USED_MB=2800 FM_HEAVY_SLOT_DIR="$LEDGER_DIR" \
    "$SLOT" acquire --home "$HOME_A" --task t1 --lane ask --pid "$$" 2>&1)
  status=$?
  expect_code 3 "$status" "a configured max_swap_used_mb was not applied"
  assert_contains "$out" "at or above 2048MB" "refusal did not use the configured swap cap"
  pass "fm-heavy-slot: load, memory pressure, swap, and browser pages each refuse a heavy start"
}

test_macos_swap_reading_is_absolute() {
  local bin out status
  new_world macos-swap
  bin="$TMP_ROOT/macos-swap/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\necho Darwin\n' > "$bin/uname"
  # shellcheck disable=SC2016 # $2 is expanded by the generated sysctl stub, not here
  printf '#!/bin/sh\n[ "$2" = vm.swapusage ] && echo "%s"\n' \
    'total = 3072.00M  used = 2800.00M  free = 272.00M  (encrypted)' > "$bin/sysctl"
  chmod +x "$bin/uname" "$bin/sysctl"
  out=$(env -u FM_HEAVY_SLOT_SWAP_USED_MB PATH="$bin:$PATH" FM_HEAVY_SLOT_DIR="$LEDGER_DIR" \
    "$SLOT" acquire --home "$HOME_A" --task t1 --lane ask --pid "$$" 2>&1)
  status=$?
  expect_code 0 "$status" "a small, 91%-full macOS swap refused a heavy start: $out"
  out=$(env -u FM_HEAVY_SLOT_SWAP_USED_MB PATH="$bin:$PATH" FM_HEAVY_SLOT_DIR="$LEDGER_DIR" "$SLOT" list)
  assert_contains "$out" "swap_used_mb=2800.00/7168" "list did not report the parsed swap used"
  pass "fm-heavy-slot: the swap gate reads absolute used swap, not a percent of a growing total"
}

test_unknown_readings_never_refuse() {
  local out status
  new_world unknown
  out=$(env FM_HEAVY_SLOT_PRESSURE_LEVEL=unknown FM_HEAVY_SLOT_SWAP_USED_MB=unknown \
    FM_HEAVY_SLOT_BROWSER_PAGES=unknown FM_HEAVY_SLOT_DIR="$LEDGER_DIR" \
    "$SLOT" acquire --home "$HOME_A" --task t1 --lane ask --pid "$$" 2>&1)
  status=$?
  expect_code 0 "$status" "unknown readings refused a heavy start: $out"
  out=$(env FM_HEAVY_SLOT_PRESSURE_LEVEL=unknown FM_HEAVY_SLOT_SWAP_USED_MB=unknown \
    FM_HEAVY_SLOT_BROWSER_PAGES=unknown FM_HEAVY_SLOT_DIR="$LEDGER_DIR" "$SLOT" list)
  assert_contains "$out" "pressure=unknown/4 swap_used_mb=unknown/7168 browser_pages=unknown/30" \
    "list did not report the unknown readings"
  # Load and the slot count still apply when the other readings are unknown.
  out=$(env FM_HEAVY_SLOT_LOAD1=20 FM_HEAVY_SLOT_PRESSURE_LEVEL=unknown FM_HEAVY_SLOT_DIR="$LEDGER_DIR" \
    "$SLOT" acquire --home "$HOME_A" --task t2 --lane ask --pid "$$" 2>&1)
  status=$?
  expect_code 3 "$status" "load did not refuse when memory readings were unknown"
  pass "fm-heavy-slot: an unknown reading is reported and never refuses"
}

test_ask_waiters() {
  local out status
  new_world waiters
  acquire "$HOME_A" a1 ask >/dev/null
  acquire "$HOME_A" a2 ask >/dev/null
  acquire "$HOME_A" a3 ask >/dev/null
  out=$(acquire "$HOME_B" a4 ask); status=$?
  expect_code 3 "$status" "the fourth ask should be refused"
  out=$(acquire "$HOME_B" b1 backlog); status=$?
  expect_code 3 "$status" "backlog work should be refused"
  out=$(slot list)
  assert_contains "$out" "ask_waiters[1]" "a refused ask did not record exactly one waiter"
  assert_contains "$out" "$HOME_B,a4," "the waiter does not name the refused ask"
  assert_not_contains "$out" "$HOME_B,b1," "refused backlog work recorded an ask waiter"

  # A waiting ask acquires as soon as a slot frees, and its waiter is removed.
  ( sleep 2; slot release --home "$HOME_A" --task a1 >/dev/null ) &
  out=$(acquire "$HOME_B" a4 ask --wait 20); status=$?
  wait
  expect_code 0 "$status" "a waiting ask did not acquire the freed slot: $out"
  assert_contains "$(slot list)" "ask_waiters[0]" "the waiter was not removed on acquire"

  # Release clears a waiter that gives up.
  out=$(acquire "$HOME_A" a5 ask); status=$?
  expect_code 3 "$status" "ask a5 should be refused"
  slot release --home "$HOME_A" --task a5 >/dev/null
  assert_contains "$(slot list)" "ask_waiters[0]" "release did not clear a waiter that gave up"
  pass "fm-heavy-slot: a refused or waiting ask is visible as a waiter until it acquires or gives up"
}

lock_owned_by() {  # <lock path> <pid>
  local owner
  owner=$(mktemp -d "$1.owner.XXXXXX")
  printf '%s\n' "$2" > "$owner/pid"
  ln -s "$owner" "$1"
}

test_ledger_lock() {
  local out status holder
  new_world lock
  mkdir -p "$LEDGER_DIR"
  LEDGER_DIR=$(cd "$LEDGER_DIR" && pwd -P)
  lock_owned_by "$LEDGER_DIR/.lock" "$(dead_pid)"
  out=$(acquire "$HOME_A" t1 ask); status=$?
  expect_code 0 "$status" "a lock left by a dead process was not broken: $out"
  [ ! -e "$LEDGER_DIR/.lock" ] && [ ! -L "$LEDGER_DIR/.lock" ] \
    || fail "the ledger lock was not released after acquire"

  sleep 30 &
  holder=$!
  lock_owned_by "$LEDGER_DIR/.lock" "$holder"
  ( sleep 2; kill "$holder" 2>/dev/null ) &
  out=$(acquire "$HOME_A" t2 ask); status=$?
  wait
  expect_code 0 "$status" "acquire did not proceed once the lock holder exited: $out"
  assert_contains "$(slot list)" "held=2/3" "acquire under a contested lock did not take exactly one slot"

  mkdir "$LEDGER_DIR/.lock"
  touch -t 202001010000 "$LEDGER_DIR/.lock"
  out=$(acquire "$HOME_A" t3 ask); status=$?
  expect_code 0 "$status" "a lock left with no owner pid wedged the ledger: $out"

  lock_owned_by "$LEDGER_DIR/.lock" "$(dead_pid)"
  lock_owned_by "$LEDGER_DIR/.lock.steal" "$(dead_pid)"
  out=$(slot release --home "$HOME_A" --task t3); status=$?
  expect_code 0 "$status" "a steal marker left by a killed contender wedged the lock: $out"
  assert_contains "$(slot list)" "held=2/3" "release under a recovered lock did not free exactly one slot"
  sleep 30 &
  holder=$!
  lock_owned_by "$LEDGER_DIR/.lock" "$holder"
  out=$(FM_HEAVY_SLOT_LOCK_WAIT=1 acquire "$HOME_A" t4 ask); status=$?
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  expect_code 1 "$status" "acquire under a lock held past the deadline did not fail: $out"
  assert_contains "$out" "cannot lock heavy-slot ledger" "the lock deadline failure was not reported"
  assert_contains "$(slot list)" "held=2/3" "acquire that could not lock still took a slot"
  pass "fm-heavy-slot: the ledger lock waits for a live owner and recovers a dead or interrupted one"
}

test_release() {
  local out
  new_world release
  acquire "$HOME_A" t1 ask >/dev/null
  acquire "$HOME_B" t1 ask >/dev/null
  out=$(slot release --home "$HOME_A" --task t1)
  assert_contains "$out" "released heavy slot task=t1" "release did not report the freed slot"
  out=$(slot list)
  assert_contains "$out" "held=1/3" "release freed the wrong number of slots"
  assert_contains "$out" "$HOME_B,t1," "release freed another home's equal task id"
  out=$(slot release --home "$HOME_A" --task t1) || fail "a repeated release should succeed"
  assert_contains "$out" "no heavy slot held" "a repeated release was not a no-op"
  out=$(FM_HEAVY_SLOT_DIR="$TMP_ROOT/release/none" "$SLOT" release --home "$HOME_A" --task t1) \
    || fail "release without a ledger should succeed"
  assert_absent "$TMP_ROOT/release/none" "release created a ledger that did not exist"
  # Teardown releases after a retired secondmate home (and its state dir) is
  # already removed; the release must not recreate that home.
  acquire "$HOME_A" t2 ask >/dev/null
  out=$(FM_HOME="$TMP_ROOT/release/retired-home" FM_STATE_OVERRIDE="$TMP_ROOT/release/retired-home/state" \
    FM_HEAVY_SLOT_DIR="$LEDGER_DIR" "$SLOT" release --home "$HOME_A" --task t2)
  assert_contains "$out" "released heavy slot task=t2" "release did not free the slot of a retired home's task"
  assert_absent "$TMP_ROOT/release/retired-home" "release recreated a retired home's state dir"
  pass "fm-heavy-slot: release frees only this home's task and is idempotent"
}

test_reap_frees_only_on_positive_evidence() {
  local out dead
  new_world reap
  dead=$(dead_pid)
  # dead pid, task record gone -> freed
  slot acquire --home "$HOME_A" --task gone --lane ask --pid "$dead" --worktree "$HOME_A" >/dev/null
  # dead pid, task record still present -> kept
  slot acquire --home "$HOME_A" --task alive-meta --lane ask --pid "$dead" --worktree "$HOME_A" >/dev/null
  printf 'kind=ship\n' > "$HOME_A/state/alive-meta.meta"
  # live pid, task record gone -> kept
  slot acquire --home "$HOME_B" --task live-pid --lane ask --pid "$$" --worktree "$HOME_B" >/dev/null
  out=$(slot reap)
  assert_contains "$out" "reaped task=gone home=$HOME_A" "a dead holder with no task record was not reaped"
  assert_contains "$out" "freed=1 kept=2" "reap freed a slot without positive evidence"
  out=$(slot list)
  assert_contains "$out" ",alive-meta," "reap freed a slot whose task record still exists"
  assert_contains "$out" ",live-pid," "reap freed a slot whose holder process is alive"
  pass "fm-heavy-slot: reap frees a dead holder and keeps unknown evidence"
}

# A recorded validation run that reached its ci step or finished frees the slot;
# a run still reviewing, or an unreadable status, keeps it.
test_reap_by_validation_run() {
  local out fakebin
  new_world reap-run
  fakebin="$TMP_ROOT/reap-run/bin"
  mkdir -p "$fakebin" "$TMP_ROOT/reap-run/wt"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
run=${4:-}
case "$run" in
at-ci) printf 'id: "at-ci"\nstatus: running\nsteps[2]{step,status,findings,duration_ms}:\n  review,completed,0,1\n  ci,running,0,1\n' ;;
done-run) printf 'id: "done-run"\nstatus: completed\noutcome: passed\n' ;;
reviewing) printf 'id: "reviewing"\nstatus: running\nsteps[2]{step,status,findings,duration_ms}:\n  review,running,0,1\n  ci,pending,0,0\n' ;;
*) exit 1 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' '{"heavy_total": 4}' > "$HOME_A/config/lanes.json"
  for run in at-ci done-run reviewing unreadable; do
    slot acquire --home "$HOME_A" --task "t-$run" --lane ask --pid "$$" --run "$run" \
      --worktree "$TMP_ROOT/reap-run/wt" >/dev/null || fail "acquire for $run refused"
    printf 'kind=ship\n' > "$HOME_A/state/t-$run.meta"
  done
  out=$(PATH="$fakebin:$PATH" FM_HEAVY_SLOT_DIR="$LEDGER_DIR" "$SLOT" reap)
  assert_contains "$out" "reaped task=t-at-ci" "a run at its ci step was not reaped"
  assert_contains "$out" "reaped task=t-done-run" "a finished run was not reaped"
  assert_contains "$out" "freed=2 kept=2" "reap freed a run still reviewing or unreadable"
  out=$(slot list)
  assert_contains "$out" ",t-reviewing," "a run still reviewing lost its slot"
  assert_contains "$out" ",t-unreadable," "an unreadable run lost its slot"
  pass "fm-heavy-slot: reap frees a slot whose validation run reached ci or finished"
}

test_reap_keeps_a_slot_reacquired_during_its_check() {
  local out fakebin wt
  new_world reap-race
  fakebin="$TMP_ROOT/reap-race/bin"
  wt="$TMP_ROOT/reap-race/wt"
  mkdir -p "$fakebin" "$wt"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
"$SLOT" release --home "$RACE_HOME" --task t1 >/dev/null
"$SLOT" acquire --home "$RACE_HOME" --task t1 --lane ask --pid "$RACE_PID" --run next-run \
  --worktree "$RACE_WT" >/dev/null
printf 'id: "%s"\nstatus: completed\noutcome: passed\n' "$4"
SH
  chmod +x "$fakebin/no-mistakes"
  slot acquire --home "$HOME_A" --task t1 --lane ask --pid "$$" --run first-run --worktree "$wt" >/dev/null
  printf 'kind=ship\n' > "$HOME_A/state/t1.meta"
  out=$(export SLOT; PATH="$fakebin:$PATH" RACE_HOME="$HOME_A" RACE_PID="$$" RACE_WT="$wt" \
    FM_HEAVY_SLOT_DIR="$LEDGER_DIR" "$SLOT" reap)
  assert_contains "$out" "freed=0 kept=1" "reap deleted a slot re-acquired while its evidence was checked"
  assert_contains "$(slot list)" "held=1/3" "the re-acquired slot is missing from the ledger"
  pass "fm-heavy-slot: reap keeps a slot whose record changed while its evidence was checked"
}

test_usage_errors() {
  local out status
  new_world usage
  out=$(slot acquire --home "$HOME_A" --lane ask 2>&1); status=$?
  expect_code 2 "$status" "acquire without --task should be a usage error"
  out=$(slot acquire --home "$HOME_A" --task t1 --lane overnight 2>&1); status=$?
  expect_code 2 "$status" "an unknown lane should be a usage error"
  printf 'lane=backlog\n' > "$HOME_A/state/from-meta.meta"
  acquire "$HOME_A" b0 backlog >/dev/null
  out=$(slot acquire --home "$HOME_A" --task from-meta --pid "$$" 2>&1); status=$?
  expect_code 3 "$status" "a task without --lane did not take its lane from the task record"
  pass "fm-heavy-slot: usage errors are distinct and the lane defaults to the task record"
}

test_reservation_math
test_capacity_from_home_config
test_contention_between_two_homes
test_each_gate_refuses
test_macos_swap_reading_is_absolute
test_unknown_readings_never_refuse
test_ask_waiters
test_ledger_lock
test_release
test_reap_frees_only_on_positive_evidence
test_reap_by_validation_run
test_reap_keeps_a_slot_reacquired_during_its_check
test_usage_errors
