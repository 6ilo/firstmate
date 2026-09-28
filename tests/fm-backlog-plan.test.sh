#!/usr/bin/env bash
# Behavior tests for bin/fm-backlog-plan.sh and the planning fields that
# bin/fm-tasks-axi.sh accepts on add and update: they are written to the
# firstmate-owned sidecar, read back, merged and cleared, refused with nothing
# written when a value is bad, kept off the tasks-axi row, and dropped with the
# item on rm or delete, keyed by the task id wherever the flags sit. Urgency rides tasks-axi's own priority.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLAN="$ROOT/bin/fm-backlog-plan.sh"
WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-plan)

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

in_home() {  # <home> <command...>; runs from an unrelated directory
  local home=$1
  shift
  (cd "$TMP_ROOT" && FM_HOME="$home" "$@")
}

test_add_and_update_record_planning_fields() {
  local home rec
  home=$(make_home add-update)
  in_home "$home" "$WRAPPER" add fm-a "alpha" --kind ship --size m --type fix \
    --order 2 --target 2026-10-01 --waits-on "vendor release" --urgency 1 >/dev/null \
    || fail "add with planning fields was refused"
  assert_grep "fm-a - alpha" "$home/data/backlog.md" "add did not write the row"
  assert_grep "(priority: 1)" "$home/data/backlog.md" "--urgency did not land as the row's priority"
  assert_no_grep "vendor release" "$home/data/backlog.md" "a planning field leaked into the tasks-axi row"
  rec=$(in_home "$home" "$PLAN" get fm-a)
  printf '%s' "$rec" | jq -e '. == {size:"M",type:"fix",order:2,target:"2026-10-01",waits_on:["vendor release"]}' \
    >/dev/null || fail "recorded plan does not match what add was given: $rec"

  in_home "$home" "$WRAPPER" update fm-a --waits-on "TFC calendar share" --size - --order=5 >/dev/null \
    || fail "update carrying only planning fields was refused"
  rec=$(in_home "$home" "$PLAN" get fm-a)
  printf '%s' "$rec" | jq -e '. == {type:"fix",order:5,target:"2026-10-01",waits_on:["vendor release","TFC calendar share"]}' \
    >/dev/null || fail "update did not merge, clear, and append as asked: $rec"

  in_home "$home" "$WRAPPER" update --json fm-a --order 4 >/dev/null \
    || fail "update carrying only planning fields and --json was refused"
  rec=$(in_home "$home" "$PLAN" get fm-a)
  printf '%s' "$rec" | jq -e '.order == 4' >/dev/null \
    || fail "planning-only update with --json did not record the plan: $rec"
  in_home "$home" "$WRAPPER" update fm-a --json --order=5 >/dev/null \
    || fail "update with --json after the id and only planning fields was refused"

  in_home "$home" "$WRAPPER" update fm-a --title "alpha two" --waits-on - --type upkeep >/dev/null \
    || fail "update mixing tasks-axi and planning fields was refused"
  assert_grep "fm-a - alpha two" "$home/data/backlog.md" "the tasks-axi half of a mixed update was lost"
  rec=$(in_home "$home" "$PLAN" get fm-a)
  printf '%s' "$rec" | jq -e '. == {type:"upkeep",order:5,target:"2026-10-01"}' \
    >/dev/null || fail "--waits-on - did not clear the events: $rec"
  pass "add and update record, merge, and clear planning fields beside the tasks-axi row"
}

test_flags_before_the_id_key_the_plan_by_the_id() {
  local home rec out
  home=$(make_home flags-first)
  in_home "$home" "$WRAPPER" add --kind ship fm-z "zeta" --size S >/dev/null \
    || fail "add with flags before the id was refused"
  assert_grep "fm-z - zeta" "$home/data/backlog.md" "flag-first add did not write the row"
  rec=$(in_home "$home" "$PLAN" get fm-z)
  printf '%s' "$rec" | jq -e '. == {size:"S"}' >/dev/null \
    || fail "flag-first add did not record the plan under fm-z: $rec"
  in_home "$home" "$WRAPPER" update --type fix fm-z >/dev/null \
    || fail "update with planning fields before the id was refused"
  rec=$(in_home "$home" "$PLAN" get fm-z)
  printf '%s' "$rec" | jq -e '. == {size:"S",type:"fix"}' >/dev/null \
    || fail "flag-first update did not merge under fm-z: $rec"
  out=$(in_home "$home" "$WRAPPER" add --kind ship --size S 2>&1)
  assert_equals 2 "$?" "planning fields with no task id were not refused"
  assert_contains "$out" "task id" "missing-id refusal is unclear: $out"
  in_home "$home" "$WRAPPER" rm --json fm-z >/dev/null || fail "rm with a flag before the id failed"
  out=$(in_home "$home" "$PLAN" list)
  assert_equals "{}" "$(printf '%s' "$out" | jq -c .)" "flag-first rm did not drop the plan record"
  pass "the plan is keyed by the first positional id wherever the flags sit, and a missing id is refused"
}

test_a_row_written_without_its_plan_fails_loudly() {
  local home out rc
  home=$(make_home plan-write-fails)
  printf 'not json\n' > "$home/data/backlog-plan.json"
  out=$(in_home "$home" "$WRAPPER" add --kind ship fm-q "queued" --size S 2>&1)
  rc=$?
  assert_equals 1 "$rc" "an add whose plan could not be recorded must exit nonzero"
  assert_grep "fm-q - queued" "$home/data/backlog.md" "the tasks-axi row should still be written"
  assert_contains "$out" "planning fields for fm-q were not recorded" "the dropped plan was not reported: $out"
  pass "a row written without its planning fields exits 1 and names the fields to re-record"
}

test_bad_values_are_refused_with_nothing_written() {
  local home args out rc
  home=$(make_home refusals)
  for args in "--size XL" "--type chore" "--order 0" "--order 10000" "--order two" \
    "--target 2026-02-30" "--target 10/01/2026" "--urgency 5"; do
    # shellcheck disable=SC2086 # Each case is a flag and its value.
    out=$(in_home "$home" "$WRAPPER" add fm-bad "bad" $args 2>&1)
    rc=$?
    assert_equals 2 "$rc" "add $args was not refused"
    assert_contains "$out" "must" "add $args was refused without saying what is allowed: $out"
    assert_no_grep "fm-bad" "$home/data/backlog.md" "a refused add $args still wrote its row"
  done
  out=$(in_home "$home" "$WRAPPER" add fm-bad "bad" --waits-on "$(printf 'x%.0s' $(seq 121))" 2>&1)
  assert_equals 2 "$?" "an over-long waits-on event was not refused"
  out=$(in_home "$home" "$WRAPPER" add fm-bad "bad" --waits-on "   " 2>&1)
  assert_equals 2 "$?" "a blank waits-on event was not refused"
  out=$(in_home "$home" "$WRAPPER" add "minted title" --mint --size S 2>&1)
  assert_equals 2 "$?" "planning fields on add --mint were not refused"
  out=$(in_home "$home" "$WRAPPER" list --size S 2>&1)
  assert_equals 2 "$?" "a planning field on list was not refused"
  out=$(in_home "$home" "$WRAPPER" update fm-missing --size S 2>&1)
  assert_equals 2 "$?" "planning fields for an unknown item were not refused"
  assert_contains "$out" "no backlog item fm-missing" "unknown-item refusal is unclear: $out"
  assert_absent "$home/data/backlog-plan.json" "a refusal wrote the plan sidecar"
  pass "bad planning values, --mint, stray commands, and unknown items are refused with nothing written"
}

test_list_rm_and_empty_records() {
  local home out
  home=$(make_home list-rm)
  out=$(in_home "$home" "$PLAN" list)
  assert_equals "{}" "$out" "list with no sidecar must print an empty object"
  in_home "$home" "$WRAPPER" add fm-a "alpha" --size S >/dev/null || fail "add fm-a failed"
  in_home "$home" "$WRAPPER" add fm-b "beta" --type feature >/dev/null || fail "add fm-b failed"
  out=$(in_home "$home" "$PLAN" list)
  printf '%s' "$out" | jq -e '. == {"fm-a":{size:"S"},"fm-b":{type:"feature"}}' >/dev/null \
    || fail "list does not hold both records: $out"
  in_home "$home" "$PLAN" set fm-b --type - >/dev/null || fail "clearing the last field failed"
  out=$(in_home "$home" "$PLAN" list)
  printf '%s' "$out" | jq -e 'has("fm-b") | not' >/dev/null \
    || fail "an item with every field cleared must drop out of the sidecar: $out"
  in_home "$home" "$WRAPPER" rm fm-a >/dev/null || fail "rm fm-a failed"
  out=$(in_home "$home" "$PLAN" list)
  assert_equals "{}" "$(printf '%s' "$out" | jq -c .)" "rm did not drop the item's plan record"
  in_home "$home" "$WRAPPER" add fm-c "gamma" --order 3 >/dev/null || fail "add fm-c failed"
  in_home "$home" "$WRAPPER" delete fm-c >/dev/null || fail "delete fm-c failed"
  out=$(in_home "$home" "$PLAN" list)
  assert_equals "{}" "$(printf '%s' "$out" | jq -c .)" "delete did not drop the item's plan record"
  printf 'not json\n' > "$home/data/backlog-plan.json"
  out=$(in_home "$home" "$PLAN" list 2>&1)
  assert_equals 1 "$?" "an unreadable sidecar must fail list"
  assert_contains "$out" "is not a JSON object" "unreadable-sidecar error is unclear: $out"
  pass "list reads every record, cleared items drop out, rm follows the row, and a corrupt sidecar is named"
}

test_add_and_update_record_planning_fields
test_flags_before_the_id_key_the_plan_by_the_id
test_a_row_written_without_its_plan_fails_loudly
test_bad_values_are_refused_with_nothing_written
test_list_rm_and_empty_records
