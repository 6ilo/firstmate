#!/usr/bin/env bash
# Opt-in credentialed live guard for bin/fm-worker-git-guard.sh inside the real
# installed Claude Code.
#
# The guard's verdict depends on Claude's PreToolUse contract: the hook payload
# carrying .tool_input.command, and exit 2 refusing the Bash call. A fake can
# only restate that assumption, so this guard installs the hook the way
# bin/fm-spawn.sh does (a per-project .claude/settings.local.json), asks a real
# print-mode session to push to a local bare remote, and asserts both that the
# remote stayed empty and that the transcript carries the guard's refusal.
# The divergence check first proves the same push succeeds with no hook, so an
# empty remote cannot come from a push that could never have worked.
# It submits a prompt and spends tokens, so it stays opt-in; run it after every
# Claude upgrade and before trusting the "Worker git guard" entry in
# docs/verification/runtime-backends.md.
# shellcheck disable=SC2016 # command strings under test are literal, never expanded here
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_WORKER_GIT_GUARD_LIVE_E2E claude jq git

TMP_ROOT=$(fm_test_tmproot fm-worker-git-guard-live)
VERSION=$(claude --version 2>/dev/null | head -1)
fm_git_identity fmtest fmtest@example.invalid

git init -q --bare "$TMP_ROOT/remote.git"
git init -q "$TMP_ROOT/wt"
git -C "$TMP_ROOT/wt" commit -q --allow-empty -m init
git -C "$TMP_ROOT/wt" remote add origin "$TMP_ROOT/remote.git"

git -C "$TMP_ROOT/wt" push -q origin HEAD:refs/heads/probe ||
  fail "a plain push to the local bare remote failed, so the guarded case below would prove nothing"
git -C "$TMP_ROOT/remote.git" update-ref -d refs/heads/probe

mkdir -p "$TMP_ROOT/wt/.claude"
jq -cn --arg c "'$ROOT/bin/fm-worker-git-guard.sh'" \
  '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$c}]}]}}' \
  >"$TMP_ROOT/wt/.claude/settings.local.json"

(cd "$TMP_ROOT/wt" && claude -p --dangerously-skip-permissions --output-format stream-json --verbose \
  "Use the Bash tool to run exactly this command once: git push origin HEAD:refs/heads/main . Then stop.") \
  >"$TMP_ROOT/claude.jsonl" 2>&1 </dev/null ||
  fail "claude $VERSION: the print-mode session failed: $(tail -5 "$TMP_ROOT/claude.jsonl")"

[ -z "$(git -C "$TMP_ROOT/remote.git" for-each-ref)" ] ||
  fail "claude $VERSION: the push reached the remote despite the PreToolUse git guard"
grep -q 'firstmate worker git guard: `git push` is blocked' "$TMP_ROOT/claude.jsonl" ||
  fail "claude $VERSION: the transcript does not carry the guard's refusal, so the hook may never have run"
pass "claude $VERSION: the PreToolUse git guard refuses git push and the remote stays empty"
