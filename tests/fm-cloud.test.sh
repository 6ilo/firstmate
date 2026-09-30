#!/usr/bin/env bash
# tests/fm-cloud.test.sh - a cloud task from launch to cleanup.
#
# bin/fm-cloud.sh launch runs `claude --cloud` inside its own private tmux
# server. Here `claude` is a PATH stub that stops at a folder-trust prompt,
# waits for the launcher to answer it, records the prompt it was given, and
# prints a session URL, so no real cloud session starts. `gh` is a PATH stub
# whose `pr list` answer each case chooses, and the registered check file runs
# as the watcher runs it. The clone source is a local bare repository. Everything else - the backlog gate, the task record, the custom
# check registration, bin/fm-pr-check.sh, bin/fm-crew-state.sh, and
# bin/fm-teardown.sh - is the real code.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { pass "fm-cloud: tmux unavailable; skipped"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { pass "fm-cloud: tasks-axi unavailable; skipped"; exit 0; }
command -v jq >/dev/null 2>&1 || { pass "fm-cloud: jq unavailable; skipped"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-cloud)
CLOUD="$ROOT/bin/fm-cloud.sh"
SESSION_URL=https://claude.ai/code/session_TESTabc123
PR_URL=https://github.com/example/widgets/pull/42

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/config" "$home/data/$1" "$home/remote/example"
  fakebin=$(fm_fakebin "$home")
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf 'Build the widget counter.\n' > "$home/data/$1/brief.md"

  fm_git_init_commit "$home/src" >/dev/null
  git clone -q --bare "$home/src" "$home/remote/example/widgets.git"

  # The stub stops at the folder-trust prompt until the launcher answers it,
  # then saves its prompt and prints the session URL.
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = --cloud ] || exit 64
echo "Do you trust the files in this folder?"
echo "  1. No, exit"
echo "  2. Yes, I trust this folder"
IFS= read -r _answer
printf '%s' "\$2" > "$home/claude-prompt"
pwd -P > "$home/claude-cwd"
echo "Session started: $SESSION_URL"
sleep 30
SH
  # gh answers `pr list` from \$home/gh-pr-list (TSV rows as the --jq filter
  # would print them) and reports every viewed pull request as not a draft.
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr list") cat "$home/gh-pr-list" 2>/dev/null; exit 0 ;;
  "pr view") printf '{"isDraft":false}\n'; exit 0 ;;
esac
exit 0
SH
  fm_fake_exit0 "$fakebin" treehouse
  chmod +x "$fakebin/claude" "$fakebin/gh"
  printf '%s\n' "$home"
}

in_home() {  # <home> <command...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  FM_CLOUD_GIT_BASE="file://$home/remote" FM_CLOUD_LAUNCH_DIR="$home/launch" FM_CLOUD_LAUNCH_WAIT_SECS=20 \
  PATH="$home/fakebin:$PATH" "$@"
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}

launch() {  # <home> <id>
  in_home "$1" "$CLOUD" launch "$2" example/widgets --mode direct-PR --yolo off \
    --brief "$1/data/$(basename "$1")/brief.md"
}

test_launch_refuses_without_a_backlog_item_or_explicit_posture() {
  local home out rc
  home=$(make_home cloud-refuse)
  set +e
  out=$(launch "$home" cloud-refuse 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "launch succeeded with no backlog item"
  assert_contains "$out" "has no backlog item" "launch refusal did not name the missing backlog item"
  assert_absent "$home/claude-prompt" "a refused launch still started a cloud session"
  assert_absent "$home/state/cloud-refuse.meta" "a refused launch still wrote a task record"

  tasks-axi add cloud-refuse "cloud fixture" --kind ship --file "$home/data/backlog.md" >/dev/null
  set +e
  out=$(in_home "$home" "$CLOUD" launch cloud-refuse example/widgets --mode no-mistakes --yolo off 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "launch accepted mode no-mistakes"
  assert_contains "$out" "direct-PR only" "mode refusal did not explain the cloud delivery mode"
  set +e
  out=$(in_home "$home" "$CLOUD" launch cloud-refuse example/widgets --mode direct-PR 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "launch guessed a merge posture"
  assert_absent "$home/claude-prompt" "a refused launch still started a cloud session"
  pass "launch refuses before starting anything without a backlog item, a cloud delivery mode, or a merge posture"
}

test_cloud_task_from_launch_to_cleanup() {
  local home id=cloud-e2e meta out rc
  home=$(make_home "$id")
  meta="$home/state/$id.meta"
  tasks-axi add "$id" "cloud fixture" --kind ship --file "$home/data/backlog.md" >/dev/null

  out=$(launch "$home" "$id") || fail "cloud launch failed: $out"
  assert_contains "$out" "session=$SESSION_URL" "launch did not report the session URL"
  assert_contains "$(cat "$home/claude-prompt")" "Build the widget counter." "the session was not given the written brief"
  assert_contains "$(cat "$home/claude-prompt")" "branch named exactly fm/$id" "the session was not told its task branch"
  assert_contains "$(cat "$home/claude-cwd")" "$home/launch/example__widgets" "the session did not start in the launcher's scratch clone"
  for kv in kind=ship backend=cloud mode=direct-PR yolo=off cloud_repo=example/widgets base=main \
    "branch=fm/$id" "cloud_session=$SESSION_URL"; do
    grep -qxF -- "$kv" "$meta" || fail "task record lacks $kv"
  done
  grep -q '^spawn_gen=s' "$meta" || fail "task record lacks a spawn incarnation"
  ! grep -q '^window=\|^worktree=' "$meta" || fail "a cloud task record named a local endpoint or copy"
  [ "$(row_state "$home" "$id")" = in_flight ] || fail "launch did not move the backlog item to In flight: $(row_state "$home" "$id")"
  # shellcheck disable=SC2016  # the inner script expands its own positional args.
  in_home "$home" bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"; fm_custom_check_registered "$2" "$3"' _ \
    "$ROOT" "$home/state" "$id" || fail "launch did not register the pull-request check"

  out=$(in_home "$home" "$ROOT/bin/fm-crew-state.sh" "$id")
  assert_contains "$out" "state: working · source: cloud-session · $SESSION_URL" "an under-way cloud task did not read as working"
  out=$(in_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json \
    | jq -r --arg id "$id" '.tasks[] | select(.id == $id) | [.backend, .current_state.state, .project, .actions.watch] | @tsv')
  assert_equals "cloud"$'\t'"working"$'\t'"example/widgets"$'\t'"open the cloud session $SESSION_URL" "$out" \
    "the fleet view did not show the cloud task under way with its session"

  # Cleanup before any pull request would lose track of work only the session holds.
  set +e
  out=$(in_home "$home" "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown removed a cloud task that has no pull request"
  assert_contains "$out" "no recorded pull request" "teardown refusal did not name the missing pull request"
  assert_present "$meta" "a refused teardown removed the task record"

  : > "$home/gh-pr-list"
  out=$(in_home "$home" bash "$home/state/$id.check.sh")
  assert_equals "" "$out" "the check spoke before any pull request existed"

  printf '%s\tOPEN\ttrue\n' "$PR_URL" > "$home/gh-pr-list"
  out=$(in_home "$home" bash "$home/state/$id.check.sh")
  assert_contains "$out" "draft pull request $PR_URL" "a draft pull request was not noticed"
  out=$(in_home "$home" bash "$home/state/$id.check.sh")
  assert_equals "" "$out" "the same draft pull request was announced twice"
  assert_absent "$home/state/$id.status" "a draft pull request became the ready report"

  printf '%s\tOPEN\tfalse\n' "$PR_URL" > "$home/gh-pr-list"
  out=$(in_home "$home" bash "$home/state/$id.check.sh")
  assert_equals "" "$out" "the ready report also printed a check line"
  grep -Eqx "done \[at=[0-9]+\]: PR $PR_URL" "$home/state/$id.status" || fail "the pull request did not arrive as the ready report"
  grep -qxF "pr=$PR_URL" "$meta" || fail "merge monitoring did not record the pull request"
  cmp -s "$ROOT/bin/fm-pr-poll.sh" "$home/state/$id.check.sh" || fail "the task check is not the merge poll after the ready report"
  assert_absent "$home/state/$id.check-trust" "the discovery check's trust binding outlived it"
  out=$(in_home "$home" "$ROOT/bin/fm-crew-state.sh" "$id")
  assert_contains "$out" "state: done · source: status-log · PR $PR_URL" "a cloud task with its pull request did not read as done"

  out=$(in_home "$home" "$ROOT/bin/fm-teardown.sh" "$id" 2>&1) || fail "teardown of a cloud task with its pull request failed: $out"
  assert_contains "$out" "cloud task" "teardown did not report a cloud cleanup"
  assert_absent "$meta" "teardown kept the cloud task record"
  assert_absent "$home/state/$id.check.sh" "teardown kept the merge poll"
  assert_absent "$home/state/$id.cloud-draft" "teardown kept the draft notice record"
  [ "$(row_state "$home" "$id")" = "done" ] || fail "teardown did not close the backlog item: $(row_state "$home" "$id")"
  assert_grep "$PR_URL" "$home/data/backlog.md" "the closed backlog item did not record the pull request"
  pass "a cloud task launches from its brief, reports its pull request as ready, and is cleaned up with no local copy"
}

test_ready_report_names_only_the_recorded_repository() {
  local home id=cloud-foreign out rc
  home=$(make_home "$id")
  tasks-axi add "$id" "cloud fixture" --kind ship --file "$home/data/backlog.md" >/dev/null
  launch "$home" "$id" >/dev/null || fail "cloud launch failed"
  set +e
  out=$(in_home "$home" "$ROOT/bin/fm-pr-check.sh" "$id" https://github.com/other/repo/pull/9 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge monitoring accepted a pull request on another repository"
  assert_contains "$out" "recorded repository example/widgets" "the refusal did not name the recorded repository"
  pass "a cloud task's ready report is accepted only for its recorded repository"
}

test_launch_refuses_without_a_backlog_item_or_explicit_posture
test_cloud_task_from_launch_to_cleanup
test_ready_report_names_only_the_recorded_repository
