#!/usr/bin/env bash
# Behavior tests for bin/fm-lanes.sh, the backlog-lane gate: the open/closed
# truth table across the night-idle, calendar, and daytime-quiet branches and
# every closing condition; calendar cache freshness and malformed input; the
# load-ceiling trip and timed reopen; the night window crossing midnight; and
# the dry-run check printing nothing while appending one log line.
# Every reading is injected (clock, idle, load, memory, ask waiters, calendar),
# so the host machine's real state never decides a verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LANES="$ROOT/bin/fm-lanes.sh"
TMP_ROOT=$(fm_test_tmproot fm-lanes)

# 2026-01-05 00:00:00 UTC; clock times below are offsets from this midnight.
DAY0=1767571200
export TZ=UTC

at() {  # <HH> <MM> -> epoch on DAY0
  echo $((DAY0 + 10#$1 * 3600 + 10#$2 * 60))
}

new_world() {  # <name>: fresh home, ledger, and calm readings
  HOME_DIR="$TMP_ROOT/$1/home"
  LEDGER_DIR="$TMP_ROOT/$1/ledger"
  CAL="$TMP_ROOT/$1/calendar-busy.json"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  export FM_HOME="$HOME_DIR" FM_HEAVY_SLOT_DIR="$LEDGER_DIR" FM_LANES_CALENDAR_CACHE="$CAL"
  export FM_LANES_NOW
  FM_LANES_NOW=$(at 12 00)
  export FM_LANES_IDLE_SECS=0 FM_HEAVY_SLOT_LOAD1=8 FM_LANES_LOAD5=8 \
    FM_HEAVY_SLOT_PRESSURE_LEVEL=1 FM_HEAVY_SLOT_SWAP_USED_MB=100 FM_HEAVY_SLOT_BROWSER_PAGES=4
  rm -f "$CAL"
}

calendar() {  # <fetched_at> <start> <end>
  printf '{"fetched_at": %s, "busy": [{"start": %s, "end": %s}]}\n' "$1" "$2" "$3" >"$CAL"
}

add_ask_waiter() {
  mkdir -p "$LEDGER_DIR/waiters"
  printf 'home=/elsewhere\ntask=ask1\npid=1\nsince=1\n' >"$LEDGER_DIR/waiters/1-ask1.wait"
}

expect_gate() {  # <expected verdict prefix> <label>
  local out
  out=$("$LANES" gate 2>&1) || fail "$2: gate exited non-zero: $out"
  assert_contains "$out" "$1" "$2: unexpected verdict"
}

test_branches_open() {
  new_world night
  FM_LANES_NOW=$(at 23 30) FM_LANES_IDLE_SECS=3600
  expect_gate "verdict=open branch=night-idle reason=-" "night with an hour idle"
  FM_LANES_IDLE_SECS=3599
  expect_gate "verdict=closed branch=- reason=no-window" "night with under an hour idle"
  FM_LANES_IDLE_SECS=unknown
  expect_gate "reason=no-window" "night with unknown idle"

  new_world cal
  calendar "$((FM_LANES_NOW - 60))" "$((FM_LANES_NOW - 600))" "$((FM_LANES_NOW + 600))"
  expect_gate "verdict=open branch=calendar reason=- " "fresh busy calendar"
  assert_contains "$("$LANES" gate)" "calendar=busy" "calendar input not reported"

  new_world quiet
  FM_HEAVY_SLOT_LOAD1=5.9 FM_LANES_LOAD5=5.9
  expect_gate "verdict=open branch=daytime-quiet" "daytime with low load"
  FM_LANES_LOAD5=6
  expect_gate "verdict=closed branch=- reason=no-window" "daytime with 5-minute load at 6"
  FM_HEAVY_SLOT_LOAD1=6 FM_LANES_LOAD5=2
  expect_gate "reason=no-window" "daytime with 1-minute load at 6"
  FM_HEAVY_SLOT_LOAD1=2 FM_LANES_NOW=$(at 02 00)
  expect_gate "reason=no-window" "low load at night without idle is not daytime"
  pass "fm-lanes: each branch opens the lane only on its own condition"
}

test_calendar_cache_states() {
  local now
  new_world calstates
  now=$FM_LANES_NOW
  calendar "$((now - 60))" "$((now + 60))" "$((now + 600))"
  expect_gate "calendar=free" "fresh cache with no current interval"
  expect_gate "reason=no-window" "fresh free calendar opened the lane"
  calendar "$((now - 28801))" "$((now - 600))" "$((now + 600))"
  expect_gate "calendar=stale" "cache older than 8 hours"
  expect_gate "reason=no-window" "stale busy calendar opened the lane"
  rm -f "$CAL"
  expect_gate "calendar=missing" "missing cache"
  printf '{"fetched_at": "soon", "busy": []}\n' >"$CAL"
  expect_gate "calendar=malformed" "wrong field types"
  printf 'not json' >"$CAL"
  expect_gate "calendar=malformed" "unparseable cache"
  expect_gate "reason=no-window" "malformed calendar opened the lane"
  pass "fm-lanes: a stale, missing, or malformed calendar never opens the lane"
}

test_closing_conditions() {
  new_world closers
  FM_LANES_NOW=$(at 23 30) FM_LANES_IDLE_SECS=7200 FM_HEAVY_SLOT_LOAD1=2 FM_LANES_LOAD5=2
  expect_gate "verdict=open" "baseline"
  FM_HEAVY_SLOT_SWAP_USED_MB=8000
  expect_gate "verdict=closed branch=- reason=memory" "swap over the ledger's memory gate"
  FM_HEAVY_SLOT_SWAP_USED_MB=100 FM_HEAVY_SLOT_PRESSURE_LEVEL=4
  expect_gate "reason=memory" "critical memory pressure"
  FM_HEAVY_SLOT_PRESSURE_LEVEL=unknown FM_HEAVY_SLOT_SWAP_USED_MB=unknown
  expect_gate "verdict=open" "unknown memory readings closed the lane"
  add_ask_waiter
  expect_gate "verdict=closed branch=- reason=ask-waiting" "an ask waiting for a heavy slot"
  assert_contains "$("$LANES" gate)" "ask_waiters=1" "waiter count not reported"
  printf '{"max_swap_used_mb": 50}\n' >"$HOME_DIR/config/lanes.json"
  rm -rf "$LEDGER_DIR/waiters"
  FM_HEAVY_SLOT_SWAP_USED_MB=60
  expect_gate "reason=memory" "the ledger's memory threshold from config/lanes.json"
  printf '{"night_window": "late"}\n' >"$HOME_DIR/config/lanes.json"
  expect_gate "verdict=closed branch=- reason=config-invalid" "invalid config"
  assert_absent "$LEDGER_DIR/holders" "gate created the heavy-slot ledger"
  pass "fm-lanes: memory, an ask waiter, and invalid config each close the lane"
}

test_load_ceiling_hysteresis() {
  local t
  new_world hyst
  t=$(at 23 00)
  FM_LANES_IDLE_SECS=7200 FM_HEAVY_SLOT_LOAD1=17 FM_LANES_NOW=$t
  expect_gate "verdict=open branch=night-idle" "one sample over the ceiling"
  FM_HEAVY_SLOT_LOAD1=10 FM_LANES_NOW=$((t + 300))
  expect_gate "verdict=open" "a dip resets the streak"
  FM_HEAVY_SLOT_LOAD1=16 FM_LANES_NOW=$((t + 600))
  expect_gate "verdict=open" "first sample of a new streak"
  FM_HEAVY_SLOT_LOAD1=16.5 FM_LANES_NOW=$((t + 900))
  expect_gate "verdict=closed branch=- reason=load-ceiling" "two consecutive samples at or above 16"
  FM_HEAVY_SLOT_LOAD1=11 FM_LANES_NOW=$((t + 1200))
  expect_gate "reason=load-ceiling" "just under reopen load"
  FM_HEAVY_SLOT_LOAD1=12 FM_LANES_NOW=$((t + 1500))
  expect_gate "reason=load-ceiling" "back at 12 resets the reopen timer"
  FM_HEAVY_SLOT_LOAD1=11 FM_LANES_NOW=$((t + 1800))
  expect_gate "reason=load-ceiling" "reopen timer restarted"
  FM_HEAVY_SLOT_LOAD1=unknown FM_LANES_NOW=$((t + 2100))
  expect_gate "reason=load-ceiling" "an unknown reading neither trips nor reopens"
  FM_HEAVY_SLOT_LOAD1=11 FM_LANES_NOW=$((t + 2640))
  expect_gate "reason=load-ceiling" "under 12 for 14 minutes"
  FM_LANES_NOW=$((t + 2700))
  expect_gate "verdict=open branch=night-idle" "under 12 for 15 minutes reopens"
  pass "fm-lanes: two samples at 16 trip the lane; 15 minutes under 12 reopen it"
}

test_night_window_crosses_midnight() {
  new_world window
  FM_LANES_IDLE_SECS=7200 FM_HEAVY_SLOT_LOAD1=8 FM_LANES_LOAD5=8
  FM_LANES_NOW=$(at 22 59); expect_gate "in_night=0" "22:59"
  FM_LANES_NOW=$(at 23 00); expect_gate "in_night=1" "23:00"
  FM_LANES_NOW=$(at 00 00); expect_gate "in_night=1" "midnight"
  FM_LANES_NOW=$(at 06 59); expect_gate "branch=night-idle" "06:59"
  FM_LANES_NOW=$(at 07 00); expect_gate "in_night=0" "07:00"
  printf '{"night_window": "01:00-05:00"}\n' >"$HOME_DIR/config/lanes.json"
  FM_LANES_NOW=$(at 23 30); expect_gate "in_night=0" "configured window excludes 23:30"
  FM_LANES_NOW=$(at 04 59); expect_gate "branch=night-idle" "configured window includes 04:59"
  pass "fm-lanes: the night window spans midnight and follows config/lanes.json"
}

test_check_is_silent_and_logs() {
  local out status log
  new_world check
  FM_LANES_NOW=$(at 23 30) FM_LANES_IDLE_SECS=7200
  log="$HOME_DIR/state/lanes-dryrun.log"
  out=$("$LANES" check 2>&1); status=$?
  expect_code 0 "$status" "check must exit 0"
  assert_equals "" "$out" "check printed output and would wake firstmate"
  assert_equals 1 "$(wc -l <"$log" | tr -d ' ')" "check did not append exactly one line"
  assert_grep "$FM_LANES_NOW verdict=open branch=night-idle " "$log" "log line lacks timestamp and verdict"
  printf '{"night_window": "late"}\n' >"$HOME_DIR/config/lanes.json"
  out=$("$LANES" check 2>&1); status=$?
  expect_code 0 "$status" "check must exit 0 on invalid config"
  assert_equals "" "$out" "check printed output on invalid config"
  assert_equals 2 "$(wc -l <"$log" | tr -d ' ')" "second check did not append one line"
  FM_LANES_LOG_MAX_LINES=2 "$LANES" check
  assert_equals 2 "$(wc -l <"$log" | tr -d ' ')" "the log was not size-capped"
  pass "fm-lanes: check prints nothing, exits 0, and appends one capped log line"
}

test_usage() {
  local status
  "$LANES" bogus >/dev/null 2>&1; status=$?
  expect_code 2 "$status" "an unknown subcommand should be a usage error"
  new_world usage
  assert_equals 42 "$(FM_LANES_IDLE_SECS=42 "$LANES" idle-seconds)" "idle-seconds did not print the reading"
  pass "fm-lanes: usage errors and idle-seconds"
}

test_branches_open
test_calendar_cache_states
test_closing_conditions
test_load_ceiling_hysteresis
test_night_window_crosses_midnight
test_check_is_silent_and_logs
test_usage
