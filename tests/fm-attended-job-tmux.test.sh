#!/usr/bin/env bash
# Opt-in real-tmux fixture for the attended one-job hold: the staged launch gate in a
# real tmux pane (bin/fm-attended-job.sh launch-gate, bin/fm-spawn.sh).
#
# It runs only when FM_ATTENDED_TMUX=1 is set and tmux is installed, and otherwise
# prints one skip line naming the gate (tests/lib.sh fm_live_gate). Requested with tmux
# absent it fails rather than passing over nothing. It is NOT admitted to run until the
# coordinator qualifies this exact script (work/chief-92-fixture-driver-plan.md stage 2).
#
# Isolation, all under this run's own temp root:
#   - HOME is never replaced for any process this script starts. The private tmux
#     server, the spawn, and every pane keep the caller's HOME. Nothing here reads or
#     writes a home-directory store, because every writer on the path is a stub below.
#   - a private tmux server: TMUX_TMPDIR points at a directory this run creates, TMUX is
#     unset, and every tmux command here runs with that environment, so the default
#     socket is a path inside the temp root and no ambient tmux server is addressed;
#   - the server starts with `-f /dev/null` and its windows run
#     `bash --noprofile --norc`, so no shell or tmux startup file is read;
#   - a pane inherits the SERVER's environment, not the spawn's, so the server is started
#     with this run's stub directory first on PATH: the agent a pane resolves is the stub
#     `claude`, never an installed one;
#   - the trust writer is a fixture-owned stub in a script farm that does not link the
#     real bin/fm-claude-trust.sh; it logs its arguments and writes nothing else. It is
#     not authentication, consent, or proof about the real trust writer;
#   - the agent is a stub script named claude that only records that it started, next to
#     the worktree, and no model or provider is reached;
#   - cleanup stops only the private server, by its own socket, and removes exactly the
#     temp root and the staged launch directories this run preflighted as absent.
#
# What a pass establishes: in a real pane, a gate that refuses means the agent command
# never ran, a gate that passes means the stub agent ran, and the real control plane's
# answer for an exited stub agent does not make a claimed launch quiescent. It does NOT
# establish anything about a real Claude process, real harness trust prompts, provider
# behavior, or any pane shell other than bash.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_ATTENDED_TMUX tmux

TMP_ROOT=$(fm_test_tmproot fm-attended-tmux)
fm_git_identity fmtest fmtest@example.invalid
unset LAVISH_AXI_HOST TMUX
RAN=0

TMUX_DIR="$TMP_ROOT/tmux-private"
mkdir -p "$TMUX_DIR"
chmod 700 "$TMUX_DIR"
OWNED_LAUNCH_DIRS="$TMP_ROOT/owned-launch-dirs"
: > "$OWNED_LAUNCH_DIRS"
SHARED_FAKEBIN="$TMP_ROOT/fakebin"
SPAWN_FARM="$TMP_ROOT/spawn-farm"

ptmux() {
  env -u TMUX TMUX_TMPDIR="$TMUX_DIR" PATH="$SHARED_FAKEBIN:$PATH" tmux -f /dev/null "$@"
}

cleanup_private() {
  local d
  [ ! -d "$TMUX_DIR" ] || ptmux kill-server >/dev/null 2>&1 || true
  [ -f "$OWNED_LAUNCH_DIRS" ] || return 0
  while IFS= read -r d; do
    case "$d" in /tmp/fm-attended-tmux-[0-9]*+*) ;; *) continue ;; esac
    if [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ]; then
      rm -rf -- "$d"
    fi
  done < "$OWNED_LAUNCH_DIRS"
}
trap 'cleanup_private; fm_test_cleanup' EXIT
trap 'cleanup_private; fm_test_cleanup; exit 129' HUP
trap 'cleanup_private; fm_test_cleanup; exit 130' INT
trap 'cleanup_private; fm_test_cleanup; exit 143' TERM

done_case() {
  RAN=$((RAN + 1))
  pass "$1"
}

wait_for() {  # <polls> <command...>: iteration-counted, not wall-clock
  local polls=$1 i=0
  shift
  while [ "$i" -lt "$polls" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The stub directory every process of this run resolves first. The sleep stub fires a
# case's hook once, at the moment the spawn has staged the launch file and has not typed
# it yet; it reads its instructions from the SPAWN's environment only, so a pane never
# runs a hook.
make_run_stubs() {
  mkdir -p "$SHARED_FAKEBIN"
  fm_fake_exit0 "$SHARED_FAKEBIN" treehouse
  cat > "$SHARED_FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
# Stub agent: records that it started in a file beside the worktree it runs in.
printf '%s\n' "$$" >> "$(dirname "$PWD")/agent-started"
exit 0
SH
  cat > "$SHARED_FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_ATT_HOOK_ACTION:-}" ] && [ ! -e "$FM_ATT_HOOK_DIR/fired" ]; then
  for f in /tmp/fm-"$FM_ATT_HOOK_TASK"+*/launch.*.sh; do
    if [ -e "$f" ]; then
      : > "$FM_ATT_HOOK_DIR/fired"
      eval "$FM_ATT_HOOK_ACTION"
      break
    fi
  done
fi
exec /bin/sleep "$@"
SH
  chmod +x "$SHARED_FAKEBIN/claude" "$SHARED_FAKEBIN/sleep"
}

# A firstmate root whose bin/ links every script EXCEPT the real Claude trust writer,
# which is replaced by a logging stub, so no symlink can reach the real one.
make_farm() {
  local f name
  mkdir -p "$SPAWN_FARM/bin"
  for f in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$f" ] || continue
    name=${f##*/}
    case "$name" in .git|bin|tests|state|config|data|projects|.no-mistakes|work|node_modules) continue ;; esac
    ln -s "$f" "$SPAWN_FARM/$name"
  done
  for f in "$ROOT"/bin/*; do
    [ "${f##*/}" != fm-claude-trust.sh ] || continue
    ln -s "$f" "$SPAWN_FARM/bin/${f##*/}"
  done
  cat > "$SPAWN_FARM/bin/fm-claude-trust.sh" <<'SH'
#!/usr/bin/env bash
# Fixture-owned stub: records that it was called, touches no trust store.
printf 'trust %s\n' "$*" >> "${FM_STUB_TRUST_LOG:?}"
exit 0
SH
  chmod +x "$SPAWN_FARM/bin/fm-claude-trust.sh"
}

# fm-spawn.sh stages launch files at /tmp/fm-<task id>+<SHA-256 of the physical home
# path>, ignoring TMPDIR. Every world's path is computable now (its home is the
# deterministic $TMP_ROOT/<name>/home and its task id is attended-tmux-<pid>-<name>), so
# all of them are required ABSENT before the private tmux server or any fixture exists.
# One that exists stops the run with nothing touched; nothing is reused or stolen.
WORLD_NAMES="refuse pass claim"

launch_dir_for() {  # <world name>
  local hash
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$TMP_ROOT/$1/home" | shasum -a 256 | awk '{print $1}')
  else
    hash=$(printf '%s' "$TMP_ROOT/$1/home" | sha256sum | awk '{print $1}')
  fi
  [ -n "$hash" ] || return 1
  printf '/tmp/fm-attended-tmux-%s-%s+%s\n' "$$" "$1" "$hash"
}

for name in $WORLD_NAMES; do
  d=$(launch_dir_for "$name") || fail "cannot compute the staged launch path for $name"
  if [ -e "$d" ] || [ -L "$d" ]; then
    fail "the staged launch path $d already exists; refusing to continue (nothing is reused, stolen, or deleted)"
  fi
  printf '%s\n' "$d" >> "$OWNED_LAUNCH_DIRS"
  printf 'info - staged launch path, absent at preflight and owned by this run: %s\n' "$d"
done

make_run_stubs
make_farm
# Panes run `bash --noprofile --norc` and the stub PATH; set before any window exists.
ptmux new-session -d -s firstmate -x 120 -y 40 "bash --noprofile --norc" \
  || fail "could not start the private tmux server"
ptmux set-option -g default-command "bash --noprofile --norc" || fail "could not pin the pane shell"

make_world() {  # <name> <hook-action or empty>
  local name=$1 hook=$2
  W_ID="attended-tmux-$$-$name"
  W_DIR="$TMP_ROOT/$name"
  W_HOME="$W_DIR/home"
  W_PROJ="$W_DIR/project"
  W_WT="$W_DIR/wt"
  W_MARK="$W_DIR/agent-started"
  W_HOOK="$W_DIR/hook"
  W_STUB_TRUST="$W_DIR/trust-calls"
  mkdir -p "$W_HOOK"
  fm_test_spawn_home "$W_HOME" claude
  printf 'tmux\n' > "$W_HOME/config/backend"
  fm_git_worktree "$W_PROJ" "$W_WT" "wt-$name"
  fm_test_spawn_brief "$W_HOME" "$W_ID"
  : > "$W_HOME/config/attended-one-job"
  W_HOOK_ACTION=${hook//@HOME@/$W_HOME}
  grep -qxF "$(launch_dir_for "$name")" "$OWNED_LAUNCH_DIRS" \
    || fail "world $name is not in WORLD_NAMES, so its staged launch path was never preflighted"
}

world_att() {
  FM_HOME="$W_HOME" FM_STATE_OVERRIDE="$W_HOME/state" FM_CONFIG_OVERRIDE="$W_HOME/config" \
    FM_DATA_OVERRIDE="$W_HOME/data" TMUX_TMPDIR="$TMUX_DIR" PATH="$SHARED_FAKEBIN:$PATH" \
    "$SPAWN_FARM/bin/fm-attended-job.sh" "$@"
}

world_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$W_HOME" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$W_HOME/state" FM_DATA_OVERRIDE="$W_HOME/data" \
    FM_PROJECTS_OVERRIDE="$W_HOME/projects" FM_CONFIG_OVERRIDE="$W_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX_TMPDIR="$TMUX_DIR" PATH="$SHARED_FAKEBIN:$PATH" \
    FM_STUB_TRUST_LOG="$W_STUB_TRUST" FM_ATT_HOOK_DIR="$W_HOOK" FM_ATT_HOOK_TASK="$W_ID" \
    FM_ATT_HOOK_ACTION="$W_HOOK_ACTION" \
    "$SPAWN_FARM/bin/fm-spawn.sh" "$W_ID" "$W_PROJ" --mode no-mistakes --yolo off 2>&1
}

rec_field() {
  sed -n "s/^$1=//p" "$W_HOME/state/.attended-job" 2>/dev/null | tail -n 1
}

pane_text() {
  ptmux capture-pane -p -t "firstmate:fm-$W_ID" 2>/dev/null
}

pane_has() {  # <fixed string>
  pane_text | grep -qF -- "$1"
}

test_gate_refusal_in_a_real_pane_starts_no_agent() {
  local out rc
  make_world refuse 'rm -f "@HOME@/config/attended-one-job"'
  world_att reserve --task "$W_ID" --brief "$W_HOME/data/$W_ID/brief.md" >/dev/null || fail "reserve failed"
  out=$(world_spawn); rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn succeeded although its opt-in flag was removed before the gate: $out"
  # The pane prints the gate's refusal once it has run; waiting for that line makes the
  # absence of the agent marker below mean "the gate ran and refused", not "not yet".
  wait_for 100 pane_has 'launch refused' || fail "the pane never showed the gate's refusal: $(pane_text)"
  assert_absent "$W_MARK" "the stub agent started although the pane gate refused"
  assert_equals refused "$(rec_field launch)" "the refusal was not recorded"
  done_case "real tmux: a gate that refuses in the pane means the agent command never runs"
}

test_gate_pass_in_a_real_pane_starts_the_agent() {
  local out rc
  make_world pass ''
  world_att reserve --task "$W_ID" --brief "$W_HOME/data/$W_ID/brief.md" >/dev/null || fail "reserve failed"
  out=$(world_spawn); rc=$?
  expect_code 0 "$rc" "a reserved fresh ship task must spawn in a real pane: $out"
  wait_for 100 test -e "$W_MARK" || fail "the stub agent never started: $(pane_text)"
  assert_equals claimed "$(rec_field launch)" "the launch was not claimed"
  assert_present "$W_STUB_TRUST" "the spawn never reached the stub trust step"
  done_case "real tmux: a gate that passes in the pane claims the launch and the agent command runs"
}

test_already_stopped_does_not_resolve_a_real_claim() {
  local out rc
  make_world claim ''
  world_att reserve --task "$W_ID" --brief "$W_HOME/data/$W_ID/brief.md" >/dev/null || fail "reserve failed"
  world_spawn >/dev/null || fail "setup spawn failed"
  wait_for 100 test -e "$W_MARK" || fail "the stub agent never started"
  out=$(world_att stop 2>&1); rc=$?
  expect_code 3 "$rc" "the real control plane cannot resolve a launch claim for an agent that already exited: $out"
  assert_not_equals quiescent "$(rec_field outcome)" "a claimed launch was reported quiescent"
  done_case "real tmux: the real control plane's answer for an exited stub agent leaves a claimed launch uncertain"
}

test_gate_refusal_in_a_real_pane_starts_no_agent
test_gate_pass_in_a_real_pane_starts_the_agent
test_already_stopped_does_not_resolve_a_real_claim

[ "$RAN" -eq 3 ] || fail "$RAN cases ran, expected 3; a silent partial pass is not a pass"
