#!/usr/bin/env bash
# Behavior tests for the attended one-job hold (bin/fm-attended-job.sh,
# bin/fm-attended-job-lib.sh, docs/configuration.md "Attended one-job hold").
#
# Every case drives a public interface: the CLI, the library functions the other
# scripts source, the real arm and watcher scripts, or the real fm-spawn.sh against
# a fake tmux. The fixtures are fresh directories under the suite's own temp root, and
# no case replaces HOME, reads or writes a real Claude store, or signals a process it
# did not start. The spawn cases do not use tests/fixtures.sh's fm_test_run_spawn,
# because that helper assigns HOME; they run a spawn from a script farm whose
# fm-claude-trust.sh is a fixture-owned stub that only logs its arguments. The stub is
# not authentication, consent, or proof about the real trust writer, and the real
# trust writer is never run by this suite.
#
# What this suite does and does not establish:
#   - The fm-watch-arm.sh and fm-watch.sh cases run the real scripts and real processes.
#   - The stop cases that need a control-plane or arm outcome use a stub of
#     fm-control.sh or fm-watch-arm.sh to pin THIS script's classification of those
#     outcomes. They say nothing about the real control plane's behavior.
#   - The spawn cases run the real fm-spawn.sh against a fake tmux whose wrapper really
#     executes the typed launch line in a child shell and whose agent is a stub that
#     only records that it started. That proves the staged gate runs before the agent
#     command in a bash pane. It is not harness, tmux, or provider proof; the real-tmux
#     fixture is tests/fm-attended-job-tmux.test.sh, which is opt-in.
#   - A spawn's PATH is the fixture stub directory plus fixed system directories only,
#     and each stub (claude, tmux, timeout, treehouse) is proved to be the file the bare
#     name resolves to before any spawn; the suite fails closed otherwise. Nothing here
#     starts, resolves, or reads a real claude, its trust store, or a provider.
#   - Every fixed /tmp path a spawn can create (the launch directory and the task temp
#     root, per world) is preflighted absent before any spawn and removed only by exact
#     recorded path; see the notes above cleanup_owned_launch_dirs.
#   - Settle failure uses the real record mutex, held by a fixture-owned process.
#   - Hold-versus-claim concurrency is barrier-synchronized: both processes wait for
#     one release file, and the assertions are about the invariant between the
#     outcomes, never about which one won or how long anything took.
set -u

# Nothing the caller exported may run code in, or reroute, a bash this suite starts:
# BASH_ENV and ENV are read by every non-interactive shell. The sweep of fm-* roots in
# tests/lib.sh is also off, because this suite removes only the exact paths it listed
# as absent before it created them and never matches by prefix.
unset BASH_ENV ENV
export FM_TEST_SKIP_ORPHAN_REAP=1
HOME_AT_LOAD=${HOME-}

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-attended-job)
fm_git_identity fmtest fmtest@example.invalid
unset LAVISH_AXI_HOST
RAN=0

done_case() {
  RAN=$((RAN + 1))
  pass "$1"
}

# --- script directories --------------------------------------------------------------
#
# Each directory is a farm of symlinks to the real bin/, so every script resolves its
# siblings beside itself exactly as it does in a checkout. STUB_BIN replaces the arm
# wrapper and the control plane with stubs that log their calls and read their answer
# from a file in the home; REAL_BIN keeps the real arm and watcher and stubs only the
# control plane.

make_bin_farm() {  # <dir> <stub|real arm>
  local dir=$1 arm=$2 f
  mkdir -p "$dir"
  for f in "$ROOT"/bin/*; do
    # The Claude trust writer is never linked, so no farm can reach it through a
    # symlink; the spawn farm installs its own stub in its place.
    [ "${f##*/}" != fm-claude-trust.sh ] || continue
    ln -s "$f" "$dir/${f##*/}"
  done
  rm -f "$dir/fm-control.sh"
  cat > "$dir/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'control %s\n' "$*" >> "$FM_HOME/control-calls"
mode=$(cat "$FM_HOME/stub-control-mode" 2>/dev/null || echo already-stopped)
case "$mode" in
  fail) echo 'error: stub control failure' >&2; exit 1 ;;
  *) echo "$mode $1 harness=claude backend=tmux endpoint=stub:win worktree=/stub/worktree"; exit 0 ;;
esac
SH
  chmod +x "$dir/fm-control.sh"
  [ "$arm" = stub ] || return 0
  rm -f "$dir/fm-watch-arm.sh"
  cat > "$dir/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm %s\n' "$*" >> "$FM_HOME/arm-calls"
case "$(cat "$FM_HOME/stub-arm-mode" 2>/dev/null || echo none)" in
  stopped) echo 'watcher: stopped pid=1'; exit 0 ;;
  failed) echo 'watcher: FAILED - pid=1 did not stop'; exit 1 ;;
  *) echo 'watcher: none running'; exit 0 ;;
esac
SH
  chmod +x "$dir/fm-watch-arm.sh"
}

STUB_BIN="$TMP_ROOT/bin-stub"
REAL_BIN="$TMP_ROOT/bin-real"
make_bin_farm "$STUB_BIN" stub
make_bin_farm "$REAL_BIN" real

# --- home fixtures -------------------------------------------------------------------

make_case() {  # <name> <yes|no opted in> -> the home directory
  local c="$TMP_ROOT/$1"
  mkdir -p "$c/state" "$c/config" "$c/data" "$c/projects"
  [ "$2" != yes ] || : > "$c/config/attended-one-job"
  printf 'brief for %s\n' "$1" > "$c/brief.md"
  printf '%s\n' "$c"
}

ATT_BIN=$STUB_BIN
att() {  # <home> <args...>: the CLI against that home, from $ATT_BIN
  local c=$1
  shift
  FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" FM_CONFIG_OVERRIDE="$c/config" FM_DATA_OVERRIDE="$c/data" \
    "$ATT_BIN/fm-attended-job.sh" "$@"
}

write_job_meta() {  # <home> <id> <gen>
  fm_write_meta "$1/state/$2.meta" "window=firstmate:fm-$2" "endpoint_task_id=$2" \
    "worktree=$1/wt" "harness=claude" "kind=ship" "spawn_gen=$3"
}

# The spawn's bind step, through the library function the real spawn calls.
bind_job() {  # <home> <id> <gen>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/fm-attended-job-lib.sh"
    fm_attended_spawn_bind "$2" "$3" "$4" "$5" "$6" "$7" "$8"
  ' _ "$STUB_BIN" "$1/state" "$1/config" "$1" "$2" "$3" "$1/wt" "$1/brief.md"
}

# A home that reserved, bound, and published a task record for one job.
armed_case() {  # <name> <id> <gen> -> the home directory
  local c
  c=$(make_case "$1" yes)
  att "$c" reserve --task "$2" --brief "$c/brief.md" >/dev/null || fail "armed_case: reserve failed for $1"
  bind_job "$c" "$2" "$3" || fail "armed_case: bind failed for $1"
  write_job_meta "$c" "$2" "$3"
  printf '%s\n' "$c"
}

# Write a record with any phase, launch value, and home through the library's writer.
write_record() {  # <home> <phase> <launch> <record-home> [task] [gen]
  FM_HOME="$1" bash -c '
    . "$1/fm-attended-job-lib.sh"
    FM_ATT_SEQ=0
    FM_ATT_PHASE=$3
    FM_ATT_TASK=$6
    FM_ATT_HOME=$5
    FM_ATT_GEN=$7
    FM_ATT_WORKTREE=$2/wt
    FM_ATT_HARNESS=claude
    FM_ATT_BACKEND=tmux
    FM_ATT_BRIEF=digest
    FM_ATT_LAUNCH=$4
    FM_ATT_REASON=
    [ "$3" != terminal ] || FM_ATT_REASON=stop
    FM_ATT_OUTCOME=
    FM_ATT_CREATED=$(date +%s)
    FM_ATT_BOUND=$FM_ATTENDED_BOUND_MAX
    FM_ATT_DEADLINE=$((FM_ATT_CREATED + FM_ATT_BOUND))
    FM_ATT_HW=$FM_ATT_CREATED
    fm_attended_record_publish "$2/state"
  ' _ "$STUB_BIN" "$1" "$2" "$3" "$4" "${5:-job-1}" "${6:-g1}"
}

# Hold without any signal: the record write a stop starts with, and nothing else.
hold_only() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/fm-attended-job-lib.sh"
    fm_attended_lock "$2" || exit 1
    fm_attended_record_read "$2" "$3" || { fm_attended_unlock; exit 1; }
    fm_attended_hold_locked "$2" stop
    rc=$?
    fm_attended_unlock
    exit "$rc"
  ' _ "$STUB_BIN" "$1/state" "$1"
}

rec_field() {  # <home> <key>
  sed -n "s/^$2=//p" "$1/state/.attended-job" 2>/dev/null | tail -n 1
}

sup_view() {  # <home> -> needed=<true|false> held=<true|false>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" bash -c '
    . "$1/fm-supervision-lib.sh"
    fm_supervision_status "$2"
    printf "needed=%s held=%s\n" "$FM_SUP_NEEDED" "$FM_SUP_ATTENDED_HELD"
  ' _ "$STUB_BIN" "$1/state"
}

gate() {  # <home> <id> <gen>
  att "$1" launch-gate --task "$2" --gen "$3" --brief "$1/brief.md"
}

# Everything `clear` could touch, as one comparable string: the names in state/ and
# config/, the record's bytes (followed through a symlink) and link target, and the
# calls the stub arm wrapper and control plane logged.
home_snapshot() {  # <home>
  local c=$1
  {
    ls -A "$c/state" "$c/config"
    [ ! -f "$c/state/.attended-job" ] || cat "$c/state/.attended-job"
    [ ! -L "$c/state/.attended-job" ] || readlink "$c/state/.attended-job"
    cat "$c/arm-calls" "$c/control-calls" 2>/dev/null
  } 2>&1
}

# `clear` is disabled: with or without the old flags it explains, reports whether the
# home is held, exits 3, and changes nothing, so no record, flag, or call log moves.
assert_clear_refused() {  # <home> <expected held yes|no> <label>
  local c=$1 want=$2 label=$3 before out rc
  printf 'a note nobody verified\n' > "$c/review.txt"
  before=$(home_snapshot "$c")
  out=$(att "$c" clear 2>&1); rc=$?
  expect_code 3 "$rc" "$label: clear must refuse: $out"
  assert_contains "$out" "DISABLED" "$label: the refusal did not say clear is disabled"
  assert_contains "$out" "held=$want" "$label: the refusal misreported the hold"
  assert_equals "$before" "$(home_snapshot "$c")" "$label: a bare clear changed the home"
  out=$(att "$c" clear --review-note-file "$c/review.txt" --accept-unresolved-worker 2>&1); rc=$?
  expect_code 3 "$rc" "$label: clear with the old flags must still refuse: $out"
  assert_contains "$out" "DISABLED" "$label: the flagged refusal did not say clear is disabled"
  assert_equals "$before" "$(home_snapshot "$c")" "$label: clear with the old flags changed the home"
  assert_absent "$c/state/.attended-job.cleared" "$label: clear left a receipt"
}

# --- control: a home that never opted in --------------------------------------------

test_non_opted_in_home_is_untouched() {
  local c out rc
  c=$(make_case control no)
  write_job_meta "$c" some-task g1
  out=$(att "$c" status 2>&1)
  assert_contains "$out" "held=no" "a non-opted-in home read as held"
  assert_contains "$out" "opted-in=no" "status did not report the missing opt-in"
  assert_contains "$out" "record=absent" "status invented a record"
  assert_equals "needed=true held=false" "$(sup_view "$c")" "a non-opted-in home's supervision need changed"
  out=$(att "$c" reserve --task job-1 --brief "$c/brief.md" 2>&1); rc=$?
  expect_code 2 "$rc" "reserve must refuse in a home that did not opt in"
  assert_absent "$c/state/.attended-job" "reserve wrote a record in a non-opted-in home"
  out=$(att "$c" stop 2>&1); rc=$?
  expect_code 4 "$rc" "stop must find no record in a non-opted-in home"
  assert_absent "$c/arm-calls" "stop signalled the watcher chain of a non-opted-in home"
  assert_absent "$c/control-calls" "stop reached the control plane of a non-opted-in home"
  assert_clear_refused "$c" no "non-opted-in"
  done_case "a home with neither the opt-in flag nor a record is untouched: not held, same supervision need, nothing signalled"
}

# --- reserve -------------------------------------------------------------------------

test_reserve_refusals_and_success() {
  local c out rc
  c=$(make_case reserve yes)
  : > "$c/config/supervision-host"
  out=$(att "$c" reserve --task job-1 --brief "$c/brief.md" 2>&1); rc=$?
  expect_code 2 "$rc" "reserve must refuse beside config/supervision-host"
  rm -f "$c/config/supervision-host"
  : > "$c/state/.afk"
  out=$(att "$c" reserve --task job-1 --brief "$c/brief.md" 2>&1); rc=$?
  expect_code 2 "$rc" "reserve must refuse while the away posture is recorded"
  rm -f "$c/state/.afk"
  write_job_meta "$c" other-task g0
  out=$(att "$c" reserve --task job-1 --brief "$c/brief.md" 2>&1); rc=$?
  expect_code 2 "$rc" "reserve must refuse while a task record exists"
  rm -f "$c/state/other-task.meta"
  out=$(att "$c" reserve --task 'bad id' --brief "$c/brief.md" 2>&1); rc=$?
  expect_code 2 "$rc" "reserve must refuse a task id with a space"
  out=$(att "$c" reserve --task job-1 --brief "$c/missing.md" 2>&1); rc=$?
  expect_code 2 "$rc" "reserve must refuse a missing brief"
  assert_absent "$c/state/.attended-job" "a refused reserve left a record"

  out=$(att "$c" reserve --task job-1 --brief "$c/brief.md" 2>&1); rc=$?
  expect_code 0 "$rc" "reserve must succeed in a clean opted-in home: $out"
  assert_equals reserved "$(rec_field "$c" phase)" "the reservation phase"
  assert_equals job-1 "$(rec_field "$c" task)" "the reservation task"
  assert_equals claude "$(rec_field "$c" harness)" "the reservation harness"
  assert_equals tmux "$(rec_field "$c" backend)" "the reservation backend"
  assert_equals none "$(rec_field "$c" launch)" "the reservation launch field"
  out=$(att "$c" status 2>&1)
  assert_contains "$out" "held=no" "a fresh reservation read as held"
  out=$(att "$c" reserve --task job-2 --brief "$c/brief.md" 2>&1); rc=$?
  expect_code 2 "$rc" "a second reserve must be refused while a record exists"
  assert_equals job-1 "$(rec_field "$c" task)" "a refused second reserve changed the record"
  assert_clear_refused "$c" no "reserved"
  assert_equals reserved "$(rec_field "$c" phase)" "clear released or advanced a reservation"
  done_case "reserve: refuses an unsafe home or brief, writes one bound reservation, and refuses a second"
}

# --- hold, supervision predicate, and stop ------------------------------------------

test_stop_unlaunched_job_is_quiescent_and_holds() {
  local c out rc
  c=$(armed_case unlaunched job-1 g1)
  assert_equals "needed=true held=false" "$(sup_view "$c")" "an armed job must be supervised"
  out=$(att "$c" stop 2>&1); rc=$?
  expect_code 0 "$rc" "stopping an unlaunched job is quiescent: $out"
  assert_contains "$out" "outcome=quiescent" "stop did not report quiescent"
  assert_contains "$out" "worker=vetoed" "an unlaunched job is vetoed by the hold"
  assert_equals terminal "$(rec_field "$c" phase)" "stop did not hold"
  assert_equals quiescent "$(rec_field "$c" outcome)" "the outcome was not recorded"
  assert_absent "$c/control-calls" "stop signalled a worker that was never launched"
  assert_equals "arm --stop" "$(cat "$c/arm-calls")" "stop must use only the arm wrapper's --stop"
  assert_equals "needed=false held=true" "$(sup_view "$c")" "a held home must not need supervision"
  out=$(att "$c" status 2>&1)
  assert_contains "$out" "held=yes reason=terminal" "status did not report the hold"
  out=$(att "$c" stop 2>&1); rc=$?
  expect_code 0 "$rc" "a repeated stop must stay quiescent"
  assert_clear_refused "$c" yes "quiescent"
  assert_equals quiescent "$(rec_field "$c" outcome)" "clear changed a stored quiescent outcome"
  assert_equals "needed=false held=true" "$(sup_view "$c")" "a stored quiescent outcome rearmed supervision"
  out=$(att "$c" reserve --task job-2 --brief "$c/brief.md" 2>&1); rc=$?
  expect_code 2 "$rc" "a dedicated one-job home must stay single-use after a quiescent stop"
  done_case "stop: a job whose launch was never claimed is vetoed, the home is held and stays held after stop, supervision stands down, a repeat is safe, and clear refuses"
}

test_stop_with_wrong_binding_changes_nothing() {
  local c before out rc
  c=$(armed_case wrong-binding job-1 g1)
  before=$(cat "$c/state/.attended-job")
  out=$(att "$c" stop --task another-job 2>&1); rc=$?
  expect_code 2 "$rc" "stop must refuse a task the record is not bound to"
  assert_equals "$before" "$(cat "$c/state/.attended-job")" "a refused stop changed the record"
  assert_absent "$c/arm-calls" "a refused stop signalled the watcher chain"
  assert_absent "$c/control-calls" "a refused stop reached the control plane"
  assert_clear_refused "$c" no "armed"
  assert_equals armed "$(rec_field "$c" phase)" "clear changed an armed record"
  done_case "stop: a task other than the bound one is refused before anything changes"
}

test_invalid_records_hold_and_signal_nothing() {
  local variant c out rc
  for variant in tamper append symlink dir foreign; do
    c=$(armed_case "invalid-$variant" job-1 g1)
    case "$variant" in
      tamper)
        sed 's/^task=.*/task=someone-else/' "$c/state/.attended-job" > "$c/state/.rec.tmp"
        mv "$c/state/.rec.tmp" "$c/state/.attended-job"
        ;;
      append) printf 'extra=1\n' >> "$c/state/.attended-job" ;;
      symlink)
        mv "$c/state/.attended-job" "$c/state/.attended-job.real"
        ln -s .attended-job.real "$c/state/.attended-job"
        ;;
      dir)
        rm -f "$c/state/.attended-job"
        mkdir "$c/state/.attended-job"
        ;;
      foreign)
        rm -f "$c/state/.attended-job"
        write_record "$c" armed none /somewhere/else/home job-1 g1 || fail "could not write the foreign record"
        ;;
    esac
    out=$(att "$c" status 2>&1)
    assert_contains "$out" "held=yes reason=record-invalid" "$variant: an untrustworthy record did not hold the home"
    assert_contains "$out" "record=invalid" "$variant: status did not report the record as invalid"
    assert_equals "needed=false held=true" "$(sup_view "$c")" "$variant: supervision still needed"
    out=$(att "$c" reserve --task job-2 --brief "$c/brief.md" 2>&1); rc=$?
    expect_code 2 "$rc" "$variant: reserve must refuse beside an untrustworthy record"
    out=$(att "$c" stop 2>&1); rc=$?
    expect_code 3 "$rc" "$variant: stop must report uncertain for an untrustworthy record"
    assert_absent "$c/arm-calls" "$variant: stop signalled the watcher chain on an untrustworthy record"
    assert_absent "$c/control-calls" "$variant: stop reached the control plane on an untrustworthy record"
    out=$(gate "$c" job-1 g1 2>&1); rc=$?
    expect_code 1 "$rc" "$variant: the launch gate must refuse an untrustworthy record"
    assert_clear_refused "$c" yes "invalid-$variant"
    assert_contains "$(att "$c" status 2>&1)" "held=yes reason=record-invalid" "$variant: clear changed how the record reads"
  done
  done_case "an unreadable, altered, symlinked, directory, or foreign record holds the home, refuses reserve, the launch gate, and clear, and signals nothing"
}

test_deleted_record_stays_held_and_clear_is_refused() {
  local c out rc
  c=$(armed_case deleted job-1 g1)
  rm -f "$c/state/.attended-job"
  out=$(att "$c" status 2>&1)
  assert_contains "$out" "held=yes reason=record-missing" "a deleted record with a task record did not hold the home"
  assert_equals "needed=false held=true" "$(sup_view "$c")" "supervision resumed after the record was deleted"
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" FM_CONFIG_OVERRIDE="$c/config" "$REAL_BIN/fm-watch-arm.sh" 2>&1); rc=$?
  expect_code 3 "$rc" "the arm wrapper must refuse a held home"
  assert_contains "$out" "watcher: HELD" "the arm refusal was not announced as a hold"
  assert_absent "$c/state/.watch.lock" "a held home started a watcher"
  out=$(gate "$c" job-1 g1 2>&1); rc=$?
  expect_code 1 "$rc" "the launch gate must refuse when the record was deleted"

  assert_clear_refused "$c" yes "deleted-record"
  assert_absent "$c/state/.attended-job" "clear recreated a deleted record"
  assert_equals "needed=false held=true" "$(sup_view "$c")" "clear released a home whose record was deleted"
  out=$(att "$c" reserve --task job-2 --brief "$c/brief.md" 2>&1); rc=$?
  expect_code 2 "$rc" "reserve must refuse beside the first job's task record"
  done_case "a deleted record with a task record holds the home, refuses arm, launch, and reserve, and clear refuses without changing anything"
}

test_record_presence_dominates_the_flag() {
  local c out rc
  c=$(armed_case flag-removed job-1 g1)
  att "$c" stop >/dev/null 2>&1 || fail "setup stop failed"
  rm -f "$c/config/attended-one-job"
  out=$(att "$c" status 2>&1)
  assert_contains "$out" "held=yes reason=terminal" "deleting the flag released a terminal hold"
  assert_equals "needed=false held=true" "$(sup_view "$c")" "supervision resumed after the flag was deleted"
  out=$(att "$c" reserve --task job-2 --brief "$c/brief.md" 2>&1); rc=$?
  expect_code 2 "$rc" "reserve must refuse without the flag"
  assert_clear_refused "$c" yes "flag-removed"
  assert_absent "$c/config/attended-one-job" "clear recreated the removed flag"
  done_case "deleting config/attended-one-job does not release a hold that has a record, and clear neither releases it nor restores the flag"
}

# --- launch gate ---------------------------------------------------------------------

test_launch_gate_claims_exactly_once() {
  local c out rc
  c=$(armed_case gate-once job-1 g1)
  out=$(gate "$c" job-1 wrong-gen 2>&1); rc=$?
  expect_code 1 "$rc" "a gate with the wrong generation must refuse"
  assert_equals none "$(rec_field "$c" launch)" "a wrong-generation refusal changed the claim"
  out=$(gate "$c" job-1 g1 2>&1); rc=$?
  expect_code 0 "$rc" "the bound generation must claim the launch: $out"
  assert_equals claimed "$(rec_field "$c" launch)" "the claim was not recorded"
  out=$(gate "$c" job-1 g1 2>&1); rc=$?
  expect_code 1 "$rc" "a second claim for one generation must be refused"
  assert_equals claimed "$(rec_field "$c" launch)" "a refused second claim changed the first"
  done_case "launch-gate: only the bound task and generation claim the launch, and only once"
}

test_launch_gate_refuses_after_a_hold_and_says_so() {
  local c out rc
  c=$(armed_case gate-held job-1 g1)
  att "$c" stop >/dev/null 2>&1 || fail "setup stop failed"
  out=$(gate "$c" job-1 g1 2>&1); rc=$?
  expect_code 1 "$rc" "no launch may be claimed after a hold"
  assert_contains "$out" "held" "the refusal did not name the hold"
  assert_equals refused "$(rec_field "$c" launch)" "the refusal was not recorded"
  assert_equals terminal "$(rec_field "$c" phase)" "the hold was lost"
  done_case "launch-gate: a launch after a hold is refused and the refusal is recorded"
}

test_launch_gate_refuses_changed_bindings() {
  local c out rc what
  for what in brief-changed meta-gen-changed meta-removed flag-removed; do
    c=$(armed_case "gate-$what" job-1 g1)
    case "$what" in
      brief-changed) printf 'changed after the reservation\n' >> "$c/brief.md" ;;
      meta-gen-changed) write_job_meta "$c" job-1 other-gen ;;
      meta-removed) rm -f "$c/state/job-1.meta" ;;
      flag-removed) rm -f "$c/config/attended-one-job" ;;
    esac
    out=$(gate "$c" job-1 g1 2>&1); rc=$?
    expect_code 1 "$rc" "$what: the gate must refuse a changed binding"
    assert_not_equals claimed "$(rec_field "$c" launch)" "$what: a changed binding still claimed the launch"
    assert_equals terminal "$(rec_field "$c" phase)" "$what: a refused bound job must hold the home"
    assert_equals refused "$(rec_field "$c" launch)" "$what: the refusal was not recorded"
  done
  c=$(armed_case gate-record-deleted job-1 g1)
  rm -f "$c/state/.attended-job"
  out=$(gate "$c" job-1 g1 2>&1); rc=$?
  expect_code 1 "$rc" "the gate must refuse when the record was deleted"
  assert_absent "$c/state/.attended-job" "the gate recreated a deleted record"
  done_case "launch-gate: a changed brief, generation, task record, flag, or a deleted record is refused and holds the home"
}

# --- stop classification -------------------------------------------------------------

test_claimed_launch_stays_uncertain_until_the_worker_is_stopped() {
  local c out rc
  c=$(armed_case claim-stop job-1 g1)
  gate "$c" job-1 g1 >/dev/null 2>&1 || fail "setup claim failed"

  printf 'already-stopped\n' > "$c/stub-control-mode"
  out=$(att "$c" stop 2>&1); rc=$?
  expect_code 3 "$rc" "already-stopped must not resolve a launch claim: $out"
  assert_contains "$out" "worker=claim-unresolved" "the unresolved claim was not named"
  assert_contains "$out" "outcome=uncertain" "an unresolved claim was reported as resolved"
  assert_equals uncertain "$(rec_field "$c" outcome)" "the uncertain outcome was not recorded"
  assert_equals "needed=false held=true" "$(sup_view "$c")" "an uncertain stop must not resume supervision"
  assert_clear_refused "$c" yes "claim-uncertain"
  assert_equals uncertain "$(rec_field "$c" outcome)" "clear, even with the old worker flag, changed an uncertain claim"

  printf 'endpoint-gone\n' > "$c/stub-control-mode"
  out=$(att "$c" stop 2>&1); rc=$?
  expect_code 3 "$rc" "endpoint-gone must not resolve a launch claim either"

  printf 'fail\n' > "$c/stub-control-mode"
  out=$(att "$c" stop 2>&1); rc=$?
  expect_code 3 "$rc" "a failed control plane must be uncertain"
  assert_contains "$out" "worker=control-failed" "a control failure was not named"

  printf 'stopped\n' > "$c/stub-control-mode"
  out=$(att "$c" stop 2>&1); rc=$?
  expect_code 0 "$rc" "a replay that stops the worker must resolve the claim: $out"
  assert_contains "$out" "worker=stopped" "the resolved worker was not named"
  assert_equals quiescent "$(rec_field "$c" outcome)" "the resolved outcome was not recorded"
  assert_equals claimed "$(rec_field "$c" launch)" "resolving the claim rewrote the claim itself"
  assert_clear_refused "$c" yes "claim-quiescent"
  assert_equals "needed=false held=true" "$(sup_view "$c")" "a stored quiescent claim outcome rearmed supervision"
  done_case "stop: a launch claim stays uncertain through already-stopped, endpoint-gone, and control failure, only a stop that observes the worker records quiescent, and clear refuses either way"
}

test_stop_chain_failure_is_uncertain() {
  local c out rc
  c=$(armed_case chain-failed job-1 g1)
  printf 'failed\n' > "$c/stub-arm-mode"
  out=$(att "$c" stop 2>&1); rc=$?
  expect_code 3 "$rc" "a watcher that did not stop must be uncertain"
  assert_contains "$out" "chain=failed" "the failed chain was not named"
  assert_equals terminal "$(rec_field "$c" phase)" "a failed stop released the hold"
  printf 'stopped\n' > "$c/stub-arm-mode"
  out=$(att "$c" stop 2>&1); rc=$?
  expect_code 0 "$rc" "a replay that stops the chain must be quiescent: $out"
  assert_clear_refused "$c" yes "chain-replayed"
  done_case "stop: a watcher chain that did not stop is uncertain and a replay can resolve it"
}

test_foreign_lock_holder_is_never_signalled_or_accepted() {
  local c out rc foreign
  c=$(armed_case foreign-holder job-1 g1)
  sleep 120 &
  foreign=$!
  mkdir -p "$c/state/.watch.lock"
  printf '%s\n' "$foreign" > "$c/state/.watch.lock/pid"
  printf '%s\n' /some/other/home > "$c/state/.watch.lock/fm-home"
  ATT_BIN=$REAL_BIN
  out=$(att "$c" stop 2>&1); rc=$?
  ATT_BIN=$STUB_BIN
  if ! kill -0 "$foreign" 2>/dev/null; then
    fail "stop signalled a lock holder that is not this home's watcher"
  fi
  kill "$foreign" 2>/dev/null || true
  wait "$foreign" 2>/dev/null || true
  expect_code 3 "$rc" "a live foreign lock holder must make the outcome uncertain: $out"
  assert_contains "$out" "chain=holder-alive" "the live holder was not named"
  assert_equals terminal "$(rec_field "$c" phase)" "the hold was lost"
  done_case "stop: a live lock holder that is not this home's identity-matched watcher is not signalled and is never reported quiescent"
}

test_stubborn_watcher_is_uncertain() {
  local c out rc stubborn identity previous i
  c=$(armed_case stubborn job-1 g1)
  bash -c 'trap "" TERM; while :; do sleep 1; done' &
  stubborn=$!
  # Wait for the child to finish exec so its identity is the one the lock must record.
  previous=
  i=0
  while [ "$i" -lt 50 ]; do
    identity=$(fm_test_pid_identity "$stubborn" 2>/dev/null || true)
    [ -z "$identity" ] || [ "$identity" != "$previous" ] || break
    previous=$identity
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "$identity" ] || fail "could not read the stubborn process identity"
  mkdir -p "$c/state/.watch.lock"
  printf '%s\n' "$stubborn" > "$c/state/.watch.lock/pid"
  printf '%s\n' "$c" > "$c/state/.watch.lock/fm-home"
  printf '%s\n' "$REAL_BIN/fm-watch.sh" > "$c/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$c/state/.watch.lock/pid-identity"
  ATT_BIN=$REAL_BIN
  out=$(att "$c" stop 2>&1); rc=$?
  ATT_BIN=$STUB_BIN
  kill -KILL "$stubborn" 2>/dev/null || true
  wait "$stubborn" 2>/dev/null || true
  expect_code 3 "$rc" "a watcher that ignores the stop must be uncertain: $out"
  assert_contains "$out" "chain=" "stop did not report the chain"
  assert_not_equals quiescent "$(rec_field "$c" outcome)" "a stubborn watcher was reported quiescent"
  done_case "stop: an identity-matched watcher that ignores TERM is reported uncertain, never quiescent"
}

# --- the real watcher and arm --------------------------------------------------------

start_real_watcher() {  # <home> -> sets WATCHER_PID
  local c=$1 i=0
  FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" FM_CONFIG_OVERRIDE="$c/config" FM_DATA_OVERRIDE="$c/data" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$REAL_BIN/fm-watch.sh" > "$c/watch.out" 2>&1 &
  WATCHER_PID=$!
  fm_test_track_watcher_state "$c/state"
  while [ "$i" -lt 100 ]; do
    [ "$(cat "$c/state/.watch.lock/pid" 2>/dev/null || true)" = "$WATCHER_PID" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$c/state/.watch.lock/pid" 2>/dev/null || true)" = "$WATCHER_PID" ] \
    || fail "the real watcher did not take the lock: $(cat "$c/watch.out")"
}

test_hold_ends_a_running_watcher_without_a_signal() {
  local c i
  WATCHER_PID=
  c=$(armed_case watcher-selfexit job-1 g1)
  # No task record: a record naming an endpoint no tmux has would make the real watcher
  # wake on its own, and this case is about the hold ending it.
  rm -f "$c/state/job-1.meta"
  start_real_watcher "$c"
  hold_only "$c" || fail "could not write the hold"
  i=0
  while [ "$i" -lt 600 ] && kill -0 "$WATCHER_PID" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$WATCHER_PID" 2>/dev/null; then
    fail "a running watcher did not stand down after the hold was written"
  fi
  wait "$WATCHER_PID" 2>/dev/null || true
  assert_contains "$(cat "$c/watch.out")" "attended one-job hold is in force" "the watcher did not say why it stood down"
  done_case "watcher: a hold written while it runs ends it at the next poll, with no signal sent"
}

test_held_home_starts_no_watcher() {
  local c out rc
  c=$(armed_case watcher-no-start job-1 g1)
  hold_only "$c" || fail "could not write the hold"
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" FM_CONFIG_OVERRIDE="$c/config" FM_DATA_OVERRIDE="$c/data" \
    "$REAL_BIN/fm-watch.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "a direct watcher start in a held home must exit cleanly: $out"
  assert_contains "$out" "not starting" "the direct start did not say it was held"
  assert_absent "$c/state/.watch.lock" "a held home took the watcher lock"
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" FM_CONFIG_OVERRIDE="$c/config" "$REAL_BIN/fm-watch-arm.sh" --restart 2>&1); rc=$?
  expect_code 3 "$rc" "the arm wrapper must refuse --restart in a held home"
  assert_absent "$c/state/.watch.lock" "a refused restart left a lock"
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" FM_CONFIG_OVERRIDE="$c/config" "$REAL_BIN/fm-watch-arm.sh" --stop 2>&1); rc=$?
  expect_code 0 "$rc" "--stop must stay available in a held home: $out"
  done_case "watcher and arm: a held home starts no watcher, refuses arm and restart, and keeps --stop"
}

test_stop_ends_a_real_watcher() {
  local c out rc
  WATCHER_PID=
  c=$(armed_case watcher-stop job-1 g1)
  rm -f "$c/state/job-1.meta"
  start_real_watcher "$c"
  ATT_BIN=$REAL_BIN
  out=$(att "$c" stop 2>&1); rc=$?
  ATT_BIN=$STUB_BIN
  expect_code 0 "$rc" "stopping a real identity-matched watcher must be quiescent: $out"
  assert_contains "$out" "chain=stopped" "the stopped watcher was not named"
  if kill -0 "$WATCHER_PID" 2>/dev/null; then
    fail "the watcher outlived a quiescent stop"
  fi
  wait "$WATCHER_PID" 2>/dev/null || true
  done_case "stop: the real identity-matched watcher is stopped through the arm wrapper and the outcome is quiescent"
}

# --- gate functions the spawn calls --------------------------------------------------

test_spawn_gate_refusals() {
  local c out
  c=$(make_case gate-fn yes)
  att "$c" reserve --task job-1 --brief "$c/brief.md" >/dev/null || fail "setup reserve failed"
  gate_fn() {  # <kind> <relaunch> <backend> <harness> <id>
    FM_HOME="$c" bash -c '
      . "$1/fm-attended-job-lib.sh"
      fm_attended_spawn_gate "$2" "$3" "$4" "$9" "$5" "$6" "$7" "$8" "$4/brief.md"
      rc=$?
      printf "%s\n" "$FM_ATT_REFUSAL"
      exit "$rc"
    ' _ "$STUB_BIN" "$c/state" "$c/config" "$c" "$1" "$2" "$3" "$4" "$5"
  }
  gate_fn ship 0 tmux claude job-1 >/dev/null || fail "the reserved fresh ship task was refused"
  out=$(gate_fn secondmate 0 tmux claude job-1) && fail "a secondmate spawn was admitted"
  assert_contains "$out" "only a fresh ship task" "the secondmate refusal reason"
  out=$(gate_fn scout 0 tmux claude job-1) && fail "a scout spawn was admitted"
  out=$(gate_fn ship 1 tmux claude job-1) && fail "a relaunch was admitted"
  assert_contains "$out" "relaunch" "the relaunch refusal reason"
  out=$(gate_fn ship 0 herdr claude job-1) && fail "another backend was admitted"
  out=$(gate_fn ship 0 tmux codex job-1) && fail "another harness was admitted"
  out=$(gate_fn ship 0 tmux claude job-2) && fail "a task other than the reserved one was admitted"
  assert_contains "$out" "names task job-1" "the wrong-task refusal reason"
  write_job_meta "$c" job-1 g1
  out=$(gate_fn ship 0 tmux claude job-1) && fail "a second task record was admitted"
  rm -f "$c/state/job-1.meta"
  printf 'edited\n' >> "$c/brief.md"
  out=$(gate_fn ship 0 tmux claude job-1) && fail "a changed brief was admitted"
  assert_contains "$out" "brief changed" "the changed-brief refusal reason"
  done_case "spawn gate: only the reserved fresh tmux claude ship task passes, and each other kind, axis, task, or brief change is refused"
}

test_bind_refuses_a_lapsed_or_changed_reservation() {
  local c
  c=$(make_case bind-flag yes)
  att "$c" reserve --task job-1 --brief "$c/brief.md" >/dev/null || fail "setup reserve failed"
  rm -f "$c/config/attended-one-job"
  bind_job "$c" job-1 g1 && fail "bind accepted a reservation after the flag was removed"
  assert_equals reserved "$(rec_field "$c" phase)" "a refused bind changed the record"

  c=$(make_case bind-record yes)
  att "$c" reserve --task job-1 --brief "$c/brief.md" >/dev/null || fail "setup reserve failed"
  rm -f "$c/state/.attended-job" "$c/config/attended-one-job"
  bind_job "$c" job-1 g1 && fail "bind passed after both the flag and the record vanished"

  c=$(make_case bind-held yes)
  att "$c" reserve --task job-1 --brief "$c/brief.md" >/dev/null || fail "setup reserve failed"
  att "$c" stop >/dev/null 2>&1 || fail "setup stop failed"
  bind_job "$c" job-1 g1 && fail "bind accepted a reservation that was already held"
  assert_equals terminal "$(rec_field "$c" phase)" "a refused bind released the hold"
  done_case "bind: a removed flag, a vanished record, or a held reservation is refused before any task record is published"
}

# --- barrier-synchronized hold versus launch claim ----------------------------------

test_hold_and_claim_linearize() {
  local round c go gate_pid stop_pid gate_rc stop_rc launch claimed=0 refused=0
  for round in 1 2 3 4 5 6 7 8 9 10; do
    c=$(armed_case "race-$round" job-1 g1)
    printf 'already-stopped\n' > "$c/stub-control-mode"
    go="$c/go"
    bash -c '
      go=$1; shift
      i=0
      while [ ! -e "$go" ] && [ "$i" -lt 3000 ]; do sleep 0.01; i=$((i + 1)); done
      exec "$@"
    ' _ "$go" env FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" FM_CONFIG_OVERRIDE="$c/config" FM_DATA_OVERRIDE="$c/data" \
      "$STUB_BIN/fm-attended-job.sh" launch-gate --task job-1 --gen g1 --brief "$c/brief.md" > "$c/gate.out" 2>&1 &
    gate_pid=$!
    bash -c '
      go=$1; shift
      i=0
      while [ ! -e "$go" ] && [ "$i" -lt 3000 ]; do sleep 0.01; i=$((i + 1)); done
      exec "$@"
    ' _ "$go" env FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" FM_CONFIG_OVERRIDE="$c/config" FM_DATA_OVERRIDE="$c/data" \
      "$STUB_BIN/fm-attended-job.sh" stop > "$c/stop.out" 2>&1 &
    stop_pid=$!
    : > "$go"
    gate_rc=0
    wait "$gate_pid" || gate_rc=$?
    stop_rc=0
    wait "$stop_pid" || stop_rc=$?
    launch=$(rec_field "$c" launch)
    assert_equals terminal "$(rec_field "$c" phase)" "round $round: the hold was not written"
    case "$gate_rc" in
      0)
        claimed=$((claimed + 1))
        assert_equals claimed "$launch" "round $round: a passed gate must leave the claim in the record"
        assert_equals 3 "$stop_rc" "round $round: a claim that beat the hold must leave the stop uncertain"
        ;;
      1)
        refused=$((refused + 1))
        assert_equals refused "$launch" "round $round: a refused gate must be recorded as refused"
        assert_equals 0 "$stop_rc" "round $round: a hold that beat the claim must be quiescent"
        ;;
      *) fail "round $round: the launch gate exited $gate_rc" ;;
    esac
  done
  printf 'info - hold/claim rounds: %s claimed first, %s held first\n' "$claimed" "$refused"
  done_case "hold versus launch claim: over 10 barrier-released rounds exactly one wins, the record agrees with the gate's exit, and a claim that beat the hold is never reported quiescent"
}

# --- spawn world: the real fm-spawn.sh against a fake tmux --------------------------
#
# The fixture tmux wraps tests/fixtures.sh's spawn tmux. When the spawn types the
# launch-file source line and presses Enter, the wrapper runs that line in a child bash
# - the pane shell - optionally after a release file appears. The stub claude only
# records that it started. Every background child waits at most 90 seconds and then
# exits on its own, so nothing here needs a signal to stop.

make_pane_tmux() {  # <fakebin>
  local fakebin=$1
  mv "$fakebin/tmux" "$fakebin/tmux-base"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
base=$(dirname "$0")/tmux-base
if [ "${1:-}" = send-keys ] && [ -n "${FM_PANE_DIR:-}" ]; then
  payload=
  prev=
  last=
  for a in "$@"; do
    [ "$prev" != -l ] || payload=$a
    prev=$a
    last=$a
  done
  case "$payload" in
    ". '"*"'") printf '%s' "$payload" > "$FM_PANE_DIR/typed" ;;
  esac
  if [ "$last" = Enter ] && [ -s "$FM_PANE_DIR/typed" ]; then
    typed=$(cat "$FM_PANE_DIR/typed")
    rm -f "$FM_PANE_DIR/typed"
    if [ -n "${FM_PANE_HOLD_SCRIPT:-}" ]; then
      # Contention seam: before the spawn starts waiting for its launch receipt, a
      # fixture-owned process takes the REAL record mutex through the library and holds
      # it until a release file appears (at most 30 seconds). This script proceeds only
      # once the holder says it has the mutex, so the order is fixed by construction.
      (bash "$FM_PANE_HOLD_SCRIPT" "$FM_PANE_HOLD_LIBDIR" "$FM_PANE_HOLD_STATE" \
        "$FM_PANE_HOLD_READY" "$FM_PANE_HOLD_RELEASE" >/dev/null 2>&1 </dev/null) &
      held=0
      i=0
      while [ "$i" -lt 100 ]; do
        [ -e "$FM_PANE_HOLD_READY" ] && { held=1; break; }
        sleep 0.1
        i=$((i + 1))
      done
      [ "$held" = 1 ] || { echo "fixture: the mutex holder never became ready" >&2; exit 1; }
    fi
    (
      : > "$FM_PANE_DIR/pane-waiting"
      i=0
      while [ -n "${FM_PANE_GO:-}" ] && [ ! -e "$FM_PANE_GO" ] && [ "$i" -lt 900 ]; do
        sleep 0.1
        i=$((i + 1))
      done
      cd "${FM_FAKE_PANE_PATH:-/}" 2>/dev/null || true
      bash -c "$typed" >> "$FM_PANE_DIR/pane.log" 2>&1 </dev/null
      echo "$?" > "$FM_PANE_DIR/pane-rc"
    ) >/dev/null 2>&1 </dev/null &
  fi
fi
exec "$base" "$@"
SH
  chmod +x "$fakebin/tmux"
}

# fm-spawn.sh writes two kinds of fixed location under /tmp that ignore TMPDIR:
#   launch   /tmp/fm-<task id>+<home hash>   the staged launch file's directory
#   taskroot /tmp/fm-<task id>               the per-task temp root; the spawn makes
#                                            gotmp inside it and reuses a private one
# Each world computes both exact paths from its own unique task id and fresh home and
# requires each to be ABSENT before anything is created, including as a dangling
# symlink (an existing or ambiguous path stops the suite at load; nothing is reused,
# stolen, or deleted). Each pair is recorded with this run's generation, the test shell
# pid that is part of every task id, and the exit trap removes only a recorded path that
# still has the exact shape for its kind and this generation, is a real directory and
# not a symlink, and is owned by the user. It never globs, matches a prefix, or removes
# anything it did not list. A run killed too hard to reach its trap leaves the record
# and the paths in place for inventory.
OWNED_LAUNCH_DIRS="$TMP_ROOT/owned-launch-dirs"
: > "$OWNED_LAUNCH_DIRS"

cleanup_owned_launch_dirs() {
  local kind d gen label rest
  [ -f "$OWNED_LAUNCH_DIRS" ] || return 0
  while IFS=$'\t' read -r kind d gen label; do
    [ "$gen" = "$$" ] || continue
    rest=${d#/tmp/fm-attended-"$$"-}
    [ "$rest" != "$d" ] || continue
    case "$rest" in ''|*/*) continue ;; esac
    case "$kind" in
      launch)
        case "$rest" in "$label"+*) ;; *) continue ;; esac
        rest=${rest#"$label"+}
        case "$rest" in ''|*[!0-9a-f]*) continue ;; esac
        [ "${#rest}" -eq 64 ] || continue
        ;;
      taskroot)
        [ "$rest" = "$label" ] || continue
        ;;
      *) continue ;;
    esac
    if [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ]; then
      rm -rf -- "$d"
    fi
  done < "$OWNED_LAUNCH_DIRS"
}
trap 'cleanup_owned_launch_dirs; fm_test_cleanup' EXIT
trap 'cleanup_owned_launch_dirs; fm_test_cleanup; exit 129' HUP
trap 'cleanup_owned_launch_dirs; fm_test_cleanup; exit 130' INT
trap 'cleanup_owned_launch_dirs; fm_test_cleanup; exit 143' TERM

# Every spawn world this suite will create, as <directory name>:<task id label>. Both
# fixed paths of each (see above) are computable now, because a world's home is the
# deterministic path $TMP_ROOT/<name>/home (TMP_ROOT is already physical) and the task
# id is attended-<pid>-<label>. All of them are required ABSENT here, before any case
# runs and before anything is created under /tmp; one that exists stops the suite with
# nothing touched. spawn_launch_home_token in bin/fm-spawn.sh hashes the physical home
# path with SHA-256, the launch path is /tmp/fm-<task id>+<that hash>, and the task temp
# root is /tmp/fm-<task id> (TASK_TMP in bin/fm-spawn.sh).
SPAWN_WORLD_TABLE="spawn-refuse:attended-refuse-1 spawn-pass:attended-pass-1 spawn-hold:attended-hold-1 spawn-mid-flag:attended-mid-flag-1 spawn-mid-record:attended-mid-record-1 spawn-claim:attended-claim-1 spawn-preserve:preserve spawn-control:attended-control-1 spawn-settle:attended-settle-1"

launch_dir_for() {  # <world directory name> <label>
  local hash
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$TMP_ROOT/$1/home" | shasum -a 256 | awk '{print $1}')
  else
    hash=$(printf '%s' "$TMP_ROOT/$1/home" | sha256sum | awk '{print $1}')
  fi
  [ -n "$hash" ] || return 1
  printf '/tmp/fm-attended-%s-%s+%s\n' "$$" "$2" "$hash"
}

task_root_for() {  # <label>
  printf '/tmp/fm-attended-%s-%s\n' "$$" "$1"
}

# Preflight every exact path of every world in one pass, and record each as a
# kind/path/generation/label row. Nothing is created until all of them were absent.
preflight_all_launch_dirs() {
  local entry d t label
  for entry in $SPAWN_WORLD_TABLE; do
    label=${entry#*:}
    d=$(launch_dir_for "${entry%%:*}" "$label") || fail "cannot compute the staged launch path for $entry"
    t=$(task_root_for "$label")
    if [ -e "$d" ] || [ -L "$d" ]; then
      fail "the staged launch path $d already exists; refusing to continue (this suite never reuses, steals, or deletes a path it did not create)"
    fi
    if [ -e "$t" ] || [ -L "$t" ]; then
      fail "the task temp root $t already exists; refusing to continue (this suite never reuses, steals, or deletes a path it did not create)"
    fi
  done
  for entry in $SPAWN_WORLD_TABLE; do
    label=${entry#*:}
    d=$(launch_dir_for "${entry%%:*}" "$label")
    t=$(task_root_for "$label")
    printf 'launch\t%s\t%s\t%s\n' "$d" "$$" "$label" >> "$OWNED_LAUNCH_DIRS"
    printf 'taskroot\t%s\t%s\t%s\n' "$t" "$$" "$label" >> "$OWNED_LAUNCH_DIRS"
    printf 'info - staged launch path, absent at preflight and owned by this run: %s\n' "$d"
    printf 'info - staged task root, absent at preflight and owned by this run: %s\n' "$t"
  done
}
preflight_all_launch_dirs

# A spawn never sees the caller's PATH. The agent command is the bare name `claude`, so
# a PATH that fell through to the caller's directories could start a real Claude under
# the real HOME. The spawn world's PATH is the fixture stub directory first and then
# these fixed system directories only, and before ANY spawn the fixture proves, under
# exactly that environment, that every tool a launch could reach by bare name that has
# a stub resolves to the stub file, and that no fixed system directory has a claude at
# all. A missing guard fails the case closed; it never falls back.
STRICT_SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin

assert_strict_tool_resolution() {  # <fakebin>
  local fb=$1 d tool got
  for d in ${STRICT_SYSTEM_PATH//:/ }; do
    [ ! -e "$d/claude" ] && [ ! -L "$d/claude" ] \
      || fail "strict claude: $d/claude exists, so the system-only fallback could start a real claude"
  done
  for tool in claude tmux timeout treehouse; do
    [ -f "$fb/$tool" ] && [ ! -L "$fb/$tool" ] && [ -x "$fb/$tool" ] \
      || fail "strict $tool: the fixture stub $fb/$tool is missing, a symlink, or not executable"
    got=$(PATH="$fb:$STRICT_SYSTEM_PATH" FM_PANE_DIR=/nonexistent "$BASH" -c 'command -v "$1"' _ "$tool" 2>/dev/null) || got=
    [ "$got" = "$fb/$tool" ] \
      || fail "strict $tool: it resolves to '$got' under the spawn environment, not to the stub $fb/$tool"
  done
}

# Fixture-owned process that takes the REAL record mutex through the library and holds
# it until a release file appears or 30 seconds pass, whichever is first, then releases
# it by the library's own unlock. It never steals, clears, or forces anything.
# Arguments: <lib dir> <state dir> <ready file> <release file>; FM_HOME and
# FM_STATE_OVERRIDE come from the environment.
HOLD_MUTEX_SCRIPT="$TMP_ROOT/hold-mutex.sh"
cat > "$HOLD_MUTEX_SCRIPT" <<'SH'
#!/usr/bin/env bash
. "$1/fm-attended-job-lib.sh"
fm_attended_lock "$2" || exit 1
: > "$3"
i=0
while [ ! -e "$4" ] && [ "$i" -lt 300 ]; do
  sleep 0.1
  i=$((i + 1))
done
fm_attended_unlock
SH

# One firstmate root shared by the spawn worlds: every top-level entry of the checkout
# except .git, bin/, tests/, and the private-home directories is linked in, and bin/ is
# a script farm (make_bin_farm) in which fm-claude-trust.sh is NOT linked. The stub
# installed in its place logs its arguments and writes nothing else. It is a
# fixture-owned stand-in: it is not authentication, consent, or proof about the real
# trust writer, which this suite never runs.
SPAWN_FARM="$TMP_ROOT/spawn-farm"

ensure_spawn_farm() {
  local f name
  [ ! -d "$SPAWN_FARM/bin" ] || return 0
  mkdir -p "$SPAWN_FARM"
  for f in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$f" ] || continue
    name=${f##*/}
    case "$name" in .git|bin|tests|state|config|data|projects|.no-mistakes|work|node_modules) continue ;; esac
    ln -s "$f" "$SPAWN_FARM/$name"
  done
  make_bin_farm "$SPAWN_FARM/bin" real
  cat > "$SPAWN_FARM/bin/fm-claude-trust.sh" <<'SH'
#!/usr/bin/env bash
# Fixture-owned stub: records that it was called, touches no trust store.
printf 'trust %s\n' "$*" >> "${FM_STUB_TRUST_LOG:?}"
exit 0
SH
  chmod +x "$SPAWN_FARM/bin/fm-claude-trust.sh"
}

make_spawn_world() {  # <name> <label> <yes|no opted in>
  W_DIR="$TMP_ROOT/$1"
  W_HOME="$W_DIR/home"
  W_PROJ="$W_DIR/project"
  W_WT="$W_DIR/wt"
  W_ID="attended-$$-$2"
  grep -qxF "$(printf 'launch\t%s\t%s\t%s' "$(launch_dir_for "$1" "$2")" "$$" "$2")" "$OWNED_LAUNCH_DIRS" \
    || fail "spawn world $1:$2 is not in SPAWN_WORLD_TABLE, so its staged launch path was never preflighted"
  grep -qxF "$(printf 'taskroot\t%s\t%s\t%s' "$(task_root_for "$2")" "$$" "$2")" "$OWNED_LAUNCH_DIRS" \
    || fail "spawn world $1:$2 is not in SPAWN_WORLD_TABLE, so its task temp root was never preflighted"
  W_PANE="$W_DIR/pane"
  W_STUB_TRUST="$W_DIR/trust-calls"
  ensure_spawn_farm
  mkdir -p "$W_PANE"
  W_FAKEBIN=$(fm_test_make_spawn_fakebin "$W_DIR/fake")
  printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$W_FAKEBIN/timeout"
  cat > "$W_FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$$" "$0" >> "${FM_PANE_DIR:?}/agent-started"
exit 0
SH
  chmod +x "$W_FAKEBIN/timeout" "$W_FAKEBIN/claude"
  make_pane_tmux "$W_FAKEBIN"
  assert_strict_tool_resolution "$W_FAKEBIN"
  fm_test_spawn_home "$W_HOME" claude
  fm_git_worktree "$W_PROJ" "$W_WT" "wt-$1"
  fm_test_spawn_brief "$W_HOME" "$W_ID"
  mkdir -p "$W_HOME/config"
  [ "$3" != yes ] || : > "$W_HOME/config/attended-one-job"
}

world_att() {  # <args...>: the farm's CLI against the spawn world's home
  FM_HOME="$W_HOME" FM_STATE_OVERRIDE="$W_HOME/state" FM_CONFIG_OVERRIDE="$W_HOME/config" \
    FM_DATA_OVERRIDE="$W_HOME/data" "$SPAWN_FARM/bin/fm-attended-job.sh" "$@"
}

world_reserve() {
  world_att reserve --task "$W_ID" --brief "$W_HOME/data/$W_ID/brief.md" >/dev/null \
    || fail "could not reserve $W_ID in the spawn world"
}

# The real fm-spawn.sh from the farm, with the same environment overrides
# tests/fixtures.sh's fm_test_run_spawn passes EXCEPT that HOME is left exactly as the
# caller has it, CLAUDE_CONFIG_DIR is pinned empty, and PATH is the stub directory plus
# STRICT_SYSTEM_PATH only (never the caller's PATH). Nothing in the tmux and claude path
# of the spawn reads HOME (its other references are in harness branches this suite does
# not take). A caller may export FM_PANE_GO before calling. The launch wait is counted
# in polls, so a world whose pane never claims fails after about 20 seconds at most
# rather than the default 30; the count is a bound and not an assertion about timing.
world_spawn() {  # [extra fm-spawn args]
  FM_ROOT_OVERRIDE='' FM_HOME="$W_HOME" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$W_HOME/state" FM_DATA_OVERRIDE="$W_HOME/data" \
    FM_PROJECTS_OVERRIDE="$W_HOME/projects" FM_CONFIG_OVERRIDE="$W_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$W_WT" TMUX="fake,1,0" \
    FM_ATTENDED_LAUNCH_WAIT_POLLS="${FM_ATTENDED_LAUNCH_WAIT_POLLS:-200}" \
    FM_PANE_DIR="$W_PANE" FM_STUB_TRUST_LOG="$W_STUB_TRUST" PATH="$W_FAKEBIN:$STRICT_SYSTEM_PATH" \
    "$SPAWN_FARM/bin/fm-spawn.sh" "$W_ID" "$W_PROJ" --mode no-mistakes --yolo off "$@" 2>&1
}

wait_for_file() {  # <path> <polls>
  local i=0
  while [ "$i" -lt "$2" ] && [ ! -e "$1" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$1" ]
}

test_spawn_refusals_leave_nothing_behind() {
  local out rc
  make_spawn_world spawn-refuse attended-refuse-1 yes
  out=$(world_spawn 2>&1); rc=$?
  assert_not_equals 0 "$rc" "a spawn with no reservation must be refused"
  assert_contains "$out" "no job is reserved" "the missing reservation was not named: $out"
  [ -z "$(ls "$W_HOME"/state/*.meta 2>/dev/null)" ] || fail "a refused spawn left a task record"
  assert_absent "$W_STUB_TRUST" "a refused spawn reached the trust step"
  assert_absent "$W_PANE/typed" "a refused spawn typed a launch line"

  world_reserve
  printf 'edited after the reservation\n' >> "$W_HOME/data/$W_ID/brief.md"
  out=$(world_spawn 2>&1); rc=$?
  assert_not_equals 0 "$rc" "a changed brief must be refused"
  assert_contains "$out" "brief changed" "the changed brief was not named: $out"
  assert_equals reserved "$(rec_field "$W_HOME" phase)" "a refused spawn consumed the reservation"
  assert_absent "$W_STUB_TRUST" "a refused spawn reached the trust step"
  done_case "spawn: no reservation or a changed brief is refused before any endpoint, task record, or trust step exists"
}

test_spawn_claims_the_launch_then_starts_the_agent() {
  local out rc
  make_spawn_world spawn-pass attended-pass-1 yes
  world_reserve
  out=$(world_spawn 2>&1); rc=$?
  expect_code 0 "$rc" "a reserved fresh ship task must spawn: $out"
  assert_contains "$out" "spawned $W_ID" "the spawn did not report success"
  assert_equals armed "$(rec_field "$W_HOME" phase)" "the reservation was not bound"
  assert_equals claimed "$(rec_field "$W_HOME" launch)" "the launch was not claimed"
  assert_equals "$(sed -n 's/^spawn_gen=//p' "$W_HOME/state/$W_ID.meta")" "$(rec_field "$W_HOME" gen)" \
    "the record is not bound to the published generation"
  wait_for_file "$W_PANE/agent-started" 100 || fail "the stub agent never started after a claimed launch: $(cat "$W_PANE/pane.log" 2>/dev/null)"
  assert_equals "$W_FAKEBIN/claude" "$(awk 'NR == 1 { print $2 }' "$W_PANE/agent-started")" \
    "the agent that started was not the fixture stub, so a real claude may have run"
  assert_equals "needed=true held=false" "$(sup_view "$W_HOME")" "a bound running job must be supervised"
  assert_present "$W_STUB_TRUST" "an admitted spawn never reached the stub trust step"
  done_case "spawn: a reserved fresh ship task is bound, the pane gate claims the launch before the agent command, and the agent then starts"
}

test_hold_before_the_pane_gate_prevents_the_agent() {
  local go spawn_pid rc
  make_spawn_world spawn-hold attended-hold-1 yes
  world_reserve
  go="$W_DIR/pane-go"
  ( FM_PANE_GO="$go" world_spawn > "$W_DIR/spawn.out" 2>&1; echo "$?" > "$W_DIR/spawn.rc" ) &
  spawn_pid=$!
  wait_for_file "$W_PANE/pane-waiting" 300 || fail "the launch line never reached the pane"
  # The pane is parked before its gate runs: the spawn has bound, published, staged,
  # typed, and pressed Enter, and is now waiting for the launch receipt.
  world_att stop > "$W_DIR/stop.out" 2>&1; rc=$?
  expect_code 0 "$rc" "stopping a job whose launch was not yet claimed: $(cat "$W_DIR/stop.out")"
  : > "$go"
  wait "$spawn_pid"
  wait_for_file "$W_PANE/pane-rc" 300 || fail "the pane never finished"
  assert_not_equals 0 "$(cat "$W_DIR/spawn.rc")" "a spawn whose launch was held must fail"
  assert_contains "$(cat "$W_DIR/spawn.out")" "attended one-job hold" "the failed spawn did not name the hold"
  assert_absent "$W_PANE/agent-started" "the agent started after the hold was written"
  assert_equals terminal "$(rec_field "$W_HOME" phase)" "the hold was lost"
  assert_equals refused "$(rec_field "$W_HOME" launch)" "the refused launch was not recorded"
  assert_absent "$W_HOME/state/$W_ID.meta" "the failed spawn left its task record"
  done_case "spawn: a hold written after the bind but before the pane gate means the gate refuses, no agent starts, and the spawn unwinds its record"
}

test_flag_or_record_removed_mid_spawn_prevents_the_agent() {
  local what go spawn_pid
  for what in flag record; do
    make_spawn_world "spawn-mid-$what" "attended-mid-$what-1" yes
    world_reserve
    go="$W_DIR/pane-go"
    ( FM_PANE_GO="$go" world_spawn > "$W_DIR/spawn.out" 2>&1; echo "$?" > "$W_DIR/spawn.rc" ) &
    spawn_pid=$!
    wait_for_file "$W_PANE/pane-waiting" 300 || fail "$what: the launch line never reached the pane"
    case "$what" in
      flag) rm -f "$W_HOME/config/attended-one-job" ;;
      record) rm -f "$W_HOME/state/.attended-job" ;;
    esac
    : > "$go"
    wait "$spawn_pid"
    wait_for_file "$W_PANE/pane-rc" 300 || fail "$what: the pane never finished"
    assert_not_equals 0 "$(cat "$W_DIR/spawn.rc")" "$what: the spawn must fail"
    assert_absent "$W_PANE/agent-started" "$what: the agent started although its authority was removed mid-spawn"
  done
  done_case "spawn: removing the opt-in flag or deleting the record between the bind and the pane gate means no agent starts"
}

test_claim_before_hold_leaves_the_stop_uncertain_until_replayed() {
  local out rc
  make_spawn_world spawn-claim attended-claim-1 yes
  world_reserve
  out=$(world_spawn 2>&1); rc=$?
  expect_code 0 "$rc" "setup spawn: $out"
  wait_for_file "$W_PANE/agent-started" 100 || fail "the stub agent never started"
  ATT_BIN=$STUB_BIN
  printf 'already-stopped\n' > "$W_HOME/stub-control-mode"
  out=$(att "$W_HOME" stop 2>&1); rc=$?
  expect_code 3 "$rc" "stop after a claim must be uncertain while the worker is unobserved: $out"
  printf 'stopped\n' > "$W_HOME/stub-control-mode"
  out=$(att "$W_HOME" stop 2>&1); rc=$?
  expect_code 0 "$rc" "a replay that stops the worker must resolve it: $out"
  done_case "spawn: after a launch claim the stop is uncertain through already-stopped and quiescent only when a replay stops the worker"
}

# Scope, stated plainly: the control plane here is the farm's STUB. This case shows that
# the attended CLI itself never removes, resets, or rewrites the worktree or the task
# record, and that it reaches the control plane with the single verb `exit` and no
# teardown. It does NOT show that the real fm-control.sh exit preserves uncommitted work;
# that is that script's documented contract (its header, "Stop the agent, preserving its
# terminal endpoint, worktree, and every uncommitted change") and is not tested here.
test_stop_leaves_uncommitted_work_and_calls_only_exit() {
  local out rc before after
  make_spawn_world spawn-preserve preserve yes
  world_reserve
  out=$(world_spawn 2>&1); rc=$?
  expect_code 0 "$rc" "setup spawn: $out"
  wait_for_file "$W_PANE/agent-started" 100 || fail "the stub agent never started"
  printf 'work in progress\n' > "$W_WT/uncommitted.txt"
  printf 'unstaged edit\n' >> "$W_WT/README.md"
  before=$( { git -C "$W_WT" status --porcelain; cksum "$W_WT/uncommitted.txt" "$W_WT/README.md"; cat "$W_HOME/state/$W_ID.meta"; } 2>&1)
  printf 'stopped\n' > "$W_HOME/stub-control-mode"
  ATT_BIN=$STUB_BIN
  out=$(att "$W_HOME" stop 2>&1); rc=$?
  expect_code 0 "$rc" "stop with a stub control plane that reports stopped: $out"
  after=$( { git -C "$W_WT" status --porcelain; cksum "$W_WT/uncommitted.txt" "$W_WT/README.md"; cat "$W_HOME/state/$W_ID.meta"; } 2>&1)
  assert_equals "$before" "$after" "stop changed the worktree's uncommitted state or the task record"
  assert_equals "control $W_ID exit" "$(cat "$W_HOME/control-calls")" "stop reached the control plane with something other than the single verb exit"
  assert_present "$W_WT" "stop removed the worktree"
  assert_present "$W_HOME/state/$W_ID.meta" "stop removed the task record"
  done_case "stop: the uncommitted worktree state and the task record are untouched and only the control verb exit is used (stub control plane; real preservation is not shown)"
}

test_non_opted_in_spawn_is_unchanged() {
  local out rc
  make_spawn_world spawn-control attended-control-1 no
  out=$(world_spawn 2>&1); rc=$?
  expect_code 0 "$rc" "a home that did not opt in must spawn as before: $out"
  assert_absent "$W_HOME/state/.attended-job" "a non-opted-in spawn wrote an attended record"
  assert_present "$W_HOME/state/$W_ID.meta" "the control spawn wrote no task record"
  wait_for_file "$W_PANE/agent-started" 100 || fail "the control agent never started"
  done_case "spawn: a home without the flag or a record spawns exactly as before and writes no attended record"
}

# --- settle failure: the public failure path ---------------------------------------
#
# The spawn's settle (fm_attended_launch_receipt ... settle, bin/fm-attended-job-lib.sh)
# makes one bounded attempt at the real record mutex. The cases here make that attempt
# fail through the real mutex: a fixture-owned process takes it through the library and
# holds it, the order is fixed by construction (the holder reports ready before the
# spawn starts waiting, and before the direct settle call), and the assertions are about
# what is reported and recorded, never about which side was faster.

settle_for() {  # <home> <id> <gen>: the settle the spawn runs, against that home
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/fm-attended-job-lib.sh"
    fm_attended_launch_receipt "$2" "$3" "$4" "$5" settle
  ' _ "$STUB_BIN" "$1/state" "$1" "$2" "$3"
}

test_settle_failure_is_uncertain_and_never_claims_held() {
  local out rc go
  make_spawn_world spawn-settle attended-settle-1 yes
  world_reserve
  go="$W_DIR/pane-go"
  out=$(FM_PANE_GO="$go" FM_PANE_HOLD_SCRIPT="$HOLD_MUTEX_SCRIPT" FM_PANE_HOLD_LIBDIR="$SPAWN_FARM/bin" \
    FM_PANE_HOLD_STATE="$W_HOME/state" FM_PANE_HOLD_READY="$W_DIR/hold-ready" \
    FM_PANE_HOLD_RELEASE="$W_DIR/hold-release" FM_ATTENDED_LAUNCH_WAIT_POLLS=3 FM_ATTENDED_LOCK_SECONDS=2 \
    world_spawn 2>&1); rc=$?
  assert_present "$W_DIR/hold-ready" "the fixture's mutex holder never became ready, so the settle path was not exercised: $out"
  assert_not_equals 0 "$rc" "a spawn whose settle failed must exit nonzero"
  assert_contains "$out" "UNCERTAIN" "the failed settle was not reported as uncertain: $out"
  assert_contains "$out" "NOT confirmed held" "the failed settle did not say the home is not confirmed held"
  assert_not_contains "$out" "stays held" "a failed settle claimed the home stays held"
  assert_not_contains "$out" "no worker is expected" "a failed settle claimed no worker is expected"
  assert_not_contains "$out" "quiescent" "a failed settle claimed quiescence"
  assert_not_contains "$out" "is recorded as refused" "a failed settle claimed a refusal was recorded"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^UNCERTAIN: ')" "the failure was reported more than once, so the settle was retried"
  assert_equals armed "$(rec_field "$W_HOME" phase)" "the record claims a hold that could not be written"
  assert_equals none "$(rec_field "$W_HOME" launch)" "the record claims a launch outcome that was never written"
  assert_contains "$(world_att status 2>&1)" "held=no" "status reported a hold that was never written"

  # The repair path the message names: once the holder lets go, stop holds and vetoes.
  : > "$W_DIR/hold-release"
  out=$(world_att stop 2>&1); rc=$?
  expect_code 0 "$rc" "stop after the holder released must hold and report the unlaunched job: $out"
  assert_equals terminal "$(rec_field "$W_HOME" phase)" "stop did not write the hold"
  # The pane that was parked all along now runs; whatever it does, no agent may start.
  : > "$go"
  wait_for_file "$W_PANE/pane-rc" 300 || fail "the parked pane never finished"
  assert_absent "$W_PANE/agent-started" "an agent started after the hold was written"
  done_case "settle failure: a mutex that cannot be taken makes the spawn exit nonzero UNCERTAIN once, with nothing recorded as held, and stop afterwards holds and no agent starts"
}

test_settle_reports_each_outcome_and_never_overrides_a_claim() {
  local c out rc before holder variant
  c=$(armed_case settle-claimed job-1 g1)
  gate "$c" job-1 g1 >/dev/null 2>&1 || fail "setup claim failed"
  before=$(cat "$c/state/.attended-job")
  out=$(settle_for "$c" job-1 g1); rc=$?
  assert_equals claimed "$out" "a settle over a claimed launch must report claimed"
  expect_code 0 "$rc" "a settle over a claimed launch is not a failure"
  assert_equals "$before" "$(cat "$c/state/.attended-job")" "a settle rewrote a record whose launch was already claimed"
  assert_equals armed "$(rec_field "$c" phase)" "a settle made a claimed launch terminal"

  c=$(armed_case settle-open job-1 g1)
  out=$(settle_for "$c" job-1 g1); rc=$?
  assert_equals refused "$out" "a settle over an open launch must report refused"
  expect_code 0 "$rc" "a settle that wrote the refusal succeeded"
  assert_equals terminal "$(rec_field "$c" phase)" "the settle did not write the hold"
  assert_equals refused "$(rec_field "$c" launch)" "the settle did not record the refusal"
  assert_equals launch-unconfirmed "$(rec_field "$c" reason)" "the settle recorded the wrong reason"

  c=$(armed_case settle-wrong-id job-1 g1)
  before=$(cat "$c/state/.attended-job")
  out=$(settle_for "$c" other-job g1); rc=$?
  assert_equals uncertain "$out" "a settle for a task the record is not bound to must be uncertain"
  expect_code 3 "$rc" "an unresolved settle must exit nonzero"
  assert_equals "$before" "$(cat "$c/state/.attended-job")" "an uncertain settle changed the record"

  c=$(armed_case settle-no-record job-1 g1)
  rm -f "$c/state/.attended-job"
  out=$(settle_for "$c" job-1 g1); rc=$?
  assert_equals uncertain "$out" "a settle with no record must be uncertain"
  expect_code 3 "$rc" "an unresolved settle must exit nonzero"
  assert_absent "$c/state/.attended-job" "a failed settle recreated a deleted record"

  for variant in then-settle then-claim; do
    c=$(armed_case "settle-busy-$variant" job-1 g1)
    before=$(cat "$c/state/.attended-job")
    FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" bash "$HOLD_MUTEX_SCRIPT" "$STUB_BIN" "$c/state" \
      "$c/hold-ready" "$c/hold-release" >/dev/null 2>&1 </dev/null &
    holder=$!
    wait_for_file "$c/hold-ready" 100 || fail "$variant: the fixture's mutex holder never became ready"
    out=$(FM_ATTENDED_LOCK_SECONDS=1 settle_for "$c" job-1 g1); rc=$?
    assert_equals uncertain "$out" "$variant: a settle that cannot take the mutex must be uncertain"
    expect_code 3 "$rc" "$variant: a settle that cannot take the mutex must exit nonzero"
    assert_equals "$before" "$(cat "$c/state/.attended-job")" "$variant: a failed settle changed the record"
    assert_contains "$(att "$c" status 2>&1)" "held=no" "$variant: a failed settle left a record that reads as held"
    : > "$c/hold-release"
    wait "$holder" 2>/dev/null || true
    case "$variant" in
      then-settle)
        out=$(settle_for "$c" job-1 g1); rc=$?
        assert_equals refused "$out" "$variant: once the mutex is free the settle must be able to hold"
        assert_equals terminal "$(rec_field "$c" phase)" "$variant: the later settle did not write the hold"
        ;;
      then-claim)
        # The reason the failed settle may not say "held": a pane gate that runs later
        # can still claim, and the stop then has an unresolved claim to report.
        gate "$c" job-1 g1 >/dev/null 2>&1; rc=$?
        expect_code 0 "$rc" "$variant: the late pane gate could not claim although nothing was held"
        out=$(att "$c" stop 2>&1); rc=$?
        expect_code 3 "$rc" "$variant: a claim that landed after a failed settle must leave the stop uncertain: $out"
        assert_contains "$out" "outcome=uncertain" "$variant: the stop did not report uncertain"
        ;;
    esac
  done
  done_case "settle: claimed is left alone, an open launch becomes a recorded refusal, and a wrong task, no record, or a busy mutex is a nonzero uncertain that writes nothing and does not read as held"
}

# --- deadline observation with a dummy clock -----------------------------------------
#
# The code under test reads time only through `date +%s`. These cases put a stub date
# first on PATH that answers `date +%s` from a per-case file, so the clock is a number
# the case sets and nothing production-side is a test seam. Every value is the real
# time at the start of the suite plus an offset, which keeps the rest of the lock
# machinery's age arithmetic close to real time.

CLOCK_BIN="$TMP_ROOT/clock-bin"
mkdir -p "$CLOCK_BIN"
REAL_DATE=$(command -v date)
cat > "$CLOCK_BIN/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = '+%s' ] && [ -n "\${FM_TEST_CLOCK_FILE:-}" ] && [ -f "\$FM_TEST_CLOCK_FILE" ]; then
  cat "\$FM_TEST_CLOCK_FILE"
  exit 0
fi
exec "$REAL_DATE" "\$@"
SH
chmod +x "$CLOCK_BIN/date"
CLOCK_BASE=$("$REAL_DATE" +%s)

set_clock() {  # <home> <offset from the suite's base reading>
  printf '%s\n' $((CLOCK_BASE + $2)) > "$1/clock"
}

with_clock() {  # <home> <command...>
  local c=$1
  shift
  PATH="$CLOCK_BIN:$PATH" FM_TEST_CLOCK_FILE="$c/clock" "$@"
}

observe_job() {  # <home> -> the observation's exit status
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/fm-attended-job-lib.sh"
    fm_attended_observe "$2" "$3" "$4"
  ' _ "$STUB_BIN" "$1/state" "$1/config" "$1"
}

spawn_gate_for() {  # <home> <id>: the early gate for a fresh ship task; prints the refusal
  FM_HOME="$1" bash -c '
    . "$1/fm-attended-job-lib.sh"
    fm_attended_spawn_gate "$2" "$3" "$4" "$5" ship 0 tmux claude "$4/brief.md"
    rc=$?
    printf "%s\n" "$FM_ATT_REFUSAL"
    exit "$rc"
  ' _ "$STUB_BIN" "$1/state" "$1/config" "$1" "$2"
}

test_expire_is_a_noop_until_the_deadline_then_holds() {
  local c out rc
  c=$(make_case expire yes)
  set_clock "$c" 0
  with_clock "$c" att "$c" reserve --task job-1 --brief "$c/brief.md" --bound-seconds 600 >/dev/null \
    || fail "reserve with a bound failed"
  with_clock "$c" bind_job "$c" job-1 g1 || fail "bind failed"
  write_job_meta "$c" job-1 g1
  assert_equals 600 "$(rec_field "$c" bound)" "the bound was not recorded"
  assert_equals "$((CLOCK_BASE + 600))" "$(rec_field "$c" deadline)" "the deadline is not the clock reading plus the bound"

  set_clock "$c" 599
  out=$(with_clock "$c" att "$c" expire 2>&1); rc=$?
  expect_code 0 "$rc" "expire before the deadline must be a no-op: $out"
  assert_contains "$out" "not due" "expire did not say it was not due"
  assert_equals armed "$(rec_field "$c" phase)" "a not-due expire changed the record"
  assert_absent "$c/arm-calls" "a not-due expire signalled the watcher chain"

  set_clock "$c" 600
  out=$(with_clock "$c" att "$c" expire 2>&1); rc=$?
  expect_code 0 "$rc" "expire at the deadline must hold and stop quiescently: $out"
  assert_contains "$out" "reason=expired" "expire did not name the reason"
  assert_equals terminal "$(rec_field "$c" phase)" "expire did not hold"
  assert_equals expired "$(rec_field "$c" reason)" "the hold reason was not recorded"
  assert_equals "needed=false held=true" "$(sup_view "$c")" "an expired job still needed supervision"
  out=$(with_clock "$c" att "$c" expire 2>&1); rc=$?
  expect_code 0 "$rc" "a repeated expire must stay quiescent: $out"
  out=$(att "$c" expire extra 2>&1); rc=$?
  expect_code 2 "$rc" "expire must refuse a time argument"
  done_case "expire: not due is a no-op, due holds with the reason expired and stops quiescently, and a time argument is refused"
}

test_lapsed_reservation_is_refused_and_held_at_each_gate() {
  local c out rc
  c=$(make_case lapsed-early yes)
  set_clock "$c" 0
  with_clock "$c" att "$c" reserve --task job-1 --brief "$c/brief.md" --bound-seconds 300 >/dev/null || fail "reserve failed"
  set_clock "$c" 301
  out=$(with_clock "$c" spawn_gate_for "$c" job-1) && fail "the early gate admitted a lapsed reservation"
  assert_contains "$out" "time bound" "the early gate did not name the time bound"
  assert_equals reserved "$(rec_field "$c" phase)" "the early gate wrote to the record"
  with_clock "$c" bind_job "$c" job-1 g1 && fail "the bind admitted a lapsed reservation"
  assert_equals terminal "$(rec_field "$c" phase)" "the bind did not hold a lapsed reservation"
  assert_equals expired "$(rec_field "$c" reason)" "the bind recorded the wrong reason"
  assert_absent "$c/state/job-1.meta" "a lapsed bind left a task record"

  c=$(make_case lapsed-gate yes)
  set_clock "$c" 0
  with_clock "$c" att "$c" reserve --task job-1 --brief "$c/brief.md" --bound-seconds 300 >/dev/null || fail "reserve failed"
  with_clock "$c" bind_job "$c" job-1 g1 || fail "bind failed"
  write_job_meta "$c" job-1 g1
  set_clock "$c" 301
  out=$(with_clock "$c" gate "$c" job-1 g1 2>&1); rc=$?
  expect_code 1 "$rc" "the launch gate must refuse a lapsed job: $out"
  assert_equals terminal "$(rec_field "$c" phase)" "the launch gate did not hold a lapsed job"
  assert_equals expired "$(rec_field "$c" reason)" "the launch gate recorded the wrong reason"
  assert_equals refused "$(rec_field "$c" launch)" "the launch refusal was not recorded"
  done_case "deadline: a lapsed reservation is refused by the early gate and held by the bind and the launch gate, with the reason expired"
}

test_clock_rollback_expires_and_never_extends() {
  local c out rc
  c=$(make_case rollback yes)
  set_clock "$c" 0
  with_clock "$c" att "$c" reserve --task job-1 --brief "$c/brief.md" --bound-seconds 600 >/dev/null || fail "reserve failed"
  with_clock "$c" bind_job "$c" job-1 g1 || fail "bind failed"
  write_job_meta "$c" job-1 g1

  set_clock "$c" 300
  with_clock "$c" observe_job "$c"; rc=$?
  expect_code 0 "$rc" "observing an open job must report nothing to do"
  assert_equals "$((CLOCK_BASE + 300))" "$(rec_field "$c" hw)" "the high-water mark did not advance"

  set_clock "$c" 200
  out=$(with_clock "$c" att "$c" expire 2>&1); rc=$?
  expect_code 0 "$rc" "a step back inside the tolerance must be a no-op: $out"
  assert_contains "$out" "not due" "a small step back expired the job"
  assert_equals armed "$(rec_field "$c" phase)" "a small step back held the job"

  set_clock "$c" 100
  with_clock "$c" observe_job "$c"; rc=$?
  expect_code 10 "$rc" "a step back beyond the tolerance must ask for an expire"
  out=$(with_clock "$c" att "$c" expire 2>&1); rc=$?
  expect_code 0 "$rc" "a rolled-back clock must expire the job: $out"
  assert_contains "$out" "reason=clock-rollback" "the rollback reason was not named"
  assert_equals clock-rollback "$(rec_field "$c" reason)" "the rollback reason was not recorded"
  assert_equals "needed=false held=true" "$(sup_view "$c")" "a rolled-back clock resumed supervision"
  done_case "clock rollback: a small step back is tolerated, a large one expires the job with clock-rollback, and no rollback extends a deadline"
}

test_bound_must_be_a_whole_number_in_range() {
  local c bad out rc
  c=$(make_case bound-range yes)
  for bad in 299 28801 abc 0600 -5 ''; do
    out=$(att "$c" reserve --task job-1 --brief "$c/brief.md" --bound-seconds "$bad" 2>&1); rc=$?
    expect_code 2 "$rc" "reserve must refuse --bound-seconds '$bad'"
    assert_absent "$c/state/.attended-job" "a refused bound '$bad' left a record"
  done
  out=$(att "$c" reserve --task job-1 --brief "$c/brief.md" --bound-seconds 300 2>&1); rc=$?
  expect_code 0 "$rc" "the lower bound must be accepted: $out"
  assert_equals 300 "$(rec_field "$c" bound)" "the lower bound was not recorded"
  c=$(make_case bound-range-max yes)
  out=$(att "$c" reserve --task job-1 --brief "$c/brief.md" --bound-seconds 28800 2>&1); rc=$?
  expect_code 0 "$rc" "the upper bound must be accepted: $out"
  c=$(make_case bound-tampered yes)
  att "$c" reserve --task job-1 --brief "$c/brief.md" >/dev/null || fail "setup reserve failed"
  assert_equals 3600 "$(rec_field "$c" bound)" "the default bound is not 3600"
  done_case "reserve: the bound must be whole seconds from 300 to 28800 and defaults to 3600"
}

test_non_opted_in_home_is_untouched
test_reserve_refusals_and_success
test_stop_unlaunched_job_is_quiescent_and_holds
test_stop_with_wrong_binding_changes_nothing
test_invalid_records_hold_and_signal_nothing
test_deleted_record_stays_held_and_clear_is_refused
test_record_presence_dominates_the_flag
test_launch_gate_claims_exactly_once
test_launch_gate_refuses_after_a_hold_and_says_so
test_launch_gate_refuses_changed_bindings
test_claimed_launch_stays_uncertain_until_the_worker_is_stopped
test_stop_chain_failure_is_uncertain
test_foreign_lock_holder_is_never_signalled_or_accepted
test_stubborn_watcher_is_uncertain
test_hold_ends_a_running_watcher_without_a_signal
test_held_home_starts_no_watcher
test_stop_ends_a_real_watcher
test_spawn_gate_refusals
test_bind_refuses_a_lapsed_or_changed_reservation
test_hold_and_claim_linearize
test_spawn_refusals_leave_nothing_behind
test_spawn_claims_the_launch_then_starts_the_agent
test_hold_before_the_pane_gate_prevents_the_agent
test_flag_or_record_removed_mid_spawn_prevents_the_agent
test_claim_before_hold_leaves_the_stop_uncertain_until_replayed
test_stop_leaves_uncommitted_work_and_calls_only_exit
test_non_opted_in_spawn_is_unchanged
test_settle_failure_is_uncertain_and_never_claims_held
test_settle_reports_each_outcome_and_never_overrides_a_claim
test_expire_is_a_noop_until_the_deadline_then_holds
test_lapsed_reservation_is_refused_and_held_at_each_gate
test_clock_rollback_expires_and_never_extends
test_bound_must_be_a_whole_number_in_range

[ "${HOME-}" = "$HOME_AT_LOAD" ] || fail "HOME changed during the suite; no case may replace it"
[ "$RAN" -eq 33 ] || fail "$RAN cases ran, expected 33; a silent partial pass is not a pass"
