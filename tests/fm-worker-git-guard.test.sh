#!/usr/bin/env bash
# Behavior tests for bin/fm-worker-git-guard.sh, the Claude PreToolUse hook that
# bin/fm-spawn.sh installs on scout and local-only Claude lanes. Each case feeds
# a Claude-shaped hook payload through the real executable and checks the exit
# status and stderr. The spawn wiring is covered in
# tests/fm-busy-adapter-wiring.test.sh.
# shellcheck disable=SC2016 # command strings under test are literal, never expanded here
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-worker-git-guard.sh"

run_guard() {  # <command>; sets RC and ERR
  local payload
  payload=$(jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')
  RC=0
  ERR=$(printf '%s' "$payload" | "$GUARD" 2>&1 >/dev/null) || RC=$?
}

expect_block() {  # <command> <form>
  run_guard "$1"
  [ "$RC" -eq 2 ] || fail "expected exit 2 for: $1 (got $RC)"
  assert_contains "$ERR" "\`$2\`" "refusal for '$1' must name $2"
  assert_contains "$ERR" 'brief Rule 1' "refusal for '$1' must name the brief rule"
}

expect_allow() {  # <command>
  run_guard "$1"
  [ "$RC" -eq 0 ] || fail "expected exit 0 for: $1 (got $RC: $ERR)"
  [ -z "$ERR" ] || fail "allowed command must print nothing: $1 -> $ERR"
}

test_blocks_forbidden_forms() {
  expect_block 'git push' 'git push'
  expect_block 'git push --force-with-lease origin HEAD' 'git push'
  expect_block 'git reset --hard HEAD~1' 'git reset --hard'
  expect_block 'git clean -fdx' 'git clean -f'
  expect_block 'git clean --force' 'git clean -f'
  expect_block 'git branch -D topic' 'git branch -D'
  expect_block 'git checkout .' 'git checkout .'
  expect_block 'git checkout -- .' 'git checkout .'
  expect_block 'git restore .' 'git restore .'
  pass "blocks push, reset --hard, clean -f, branch -D, checkout ., and restore ."
}

test_blocks_wrapped_and_chained_forms() {
  expect_block 'git add -A && git commit -m wip && git push origin HEAD' 'git push'
  expect_block 'git status; git push' 'git push'
  expect_block 'GIT_TRACE=1 git push' 'git push'
  expect_block 'env FOO=1 /usr/bin/git push' 'git push'
  expect_block 'git -C /tmp/x -c user.name=a push' 'git push'
  expect_block 'out=$(git push 2>&1)' 'git push'
  pass "blocks forbidden forms behind chains, env assignments, a path, global options, and a subshell"
}

test_allows_everything_else() {
  expect_allow 'git status'
  expect_allow 'git commit -m "prepare the push path"'
  expect_allow 'git reset --soft HEAD~1'
  expect_allow 'git clean -n'
  expect_allow 'git branch -d topic'
  expect_allow 'git checkout -b fm/topic --'
  expect_allow 'git restore src/file.c'
  expect_allow 'echo push'
  expect_allow 'npm run push'
  expect_allow 'grep -rn "git push" docs'
  pass "allows ordinary git calls and non-git commands that mention push"
}

test_fails_open_on_bad_payload() {
  local rc=0
  printf '' | "$GUARD" || rc=$?
  [ "$rc" -eq 0 ] || fail "empty stdin must allow, got $rc"
  rc=0
  printf 'not json' | "$GUARD" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "malformed stdin must allow, got $rc"
  pass "empty or malformed payloads allow"
}

command -v jq >/dev/null 2>&1 || { echo "skip - jq not installed"; exit 0; }
test_blocks_forbidden_forms
test_blocks_wrapped_and_chained_forms
test_allows_everything_else
test_fails_open_on_bad_payload
echo "all fm-worker-git-guard tests passed"
