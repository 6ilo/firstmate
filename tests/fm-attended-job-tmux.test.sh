#!/usr/bin/env bash
# Opt-in real-tmux fixture for the attended one-job hold: the staged launch gate in a
# real tmux pane (bin/fm-attended-job.sh launch-gate, bin/fm-spawn.sh).
#
# It runs only when FM_ATTENDED_TMUX=1 is set and tmux is installed, and otherwise
# prints one skip line naming the gate (tests/lib.sh fm_live_gate). Requested with tmux
# absent it fails rather than passing over nothing. It is NOT admitted to run until the
# coordinator qualifies this exact script (work/chief-92-fixture-driver-plan.md stage 4).
#
# Isolation:
#   - HOME is never replaced for any process this script starts. Nothing here reads or
#     writes a home-directory store, because every writer on the path is a stub below.
#   - BASH_ENV and ENV are unset before anything is sourced, so no caller-exported
#     startup file runs in a shell this script starts.
#   - The private tmux server lives in a SHORT, fresh, owned directory /tmp/fmtx-<pid>,
#     preflighted absent and created with a plain mkdir. The socket is
#     $TMUX_DIR/tmux-<uid>/default, and its length is measured from the constructed path
#     against the 104-byte macOS limit before the server starts. TMUX is unset, TMUX_TMPDIR
#     is that directory, and the server starts with `-f /dev/null`, so no ambient server
#     or configuration is addressed.
#   - Every tmux this script or the spawn runs is the stub `tmux` in the stub directory,
#     which refuses unless TMUX_TMPDIR is exactly the private directory and otherwise
#     execs the one real tmux that was resolved before the PATH was narrowed.
#   - PATH for the server, the spawn, and every pane is the stub directory first and
#     then fixed system directories only. Before any spawn, a probe pane inside the
#     private server proves that `claude` and `tmux` resolve to the stub files, and no
#     fixed system directory has a claude. A missing guard fails the run closed.
#   - The trust writer is a fixture-owned stub in a script farm that does not link the
#     real bin/fm-claude-trust.sh; it logs its arguments and writes nothing else. It is
#     not authentication, consent, or proof about the real trust writer.
#   - The agent is a stub script named claude that only records that it started, next to
#     the worktree, and no model or provider is reached.
#   - Fixed /tmp paths: per world the launch directory /tmp/fm-<id>+<hash> and the task
#     temp root /tmp/fm-<id> (the spawn makes gotmp inside it), plus the tmux directory.
#     All are preflighted absent before anything is created and recorded with this run's
#     generation. Cleanup stops only the private server, by its own socket, and removes
#     only a recorded path of the exact shape for its kind, with this run's pid, that is
#     a real directory owned by the user and not a symlink. It never globs a prefix.
#
# What a pass establishes: in a real pane, a gate that refuses means the agent command
# never ran, a gate that passes means the stub agent ran, and the real control plane's
# answer for an exited stub agent does not make a claimed launch quiescent. It does NOT
# establish anything about a real Claude process, real harness trust prompts, provider
# behavior, or any pane shell other than bash.
set -u

unset BASH_ENV ENV
export FM_TEST_SKIP_ORPHAN_REAP=1
HOME_AT_LOAD=${HOME-}

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_ATTENDED_TMUX tmux

# The one real tmux, resolved from the caller's PATH once and only to be exec'd by the
# stub below; nothing else ever resolves tmux through the caller's PATH.
REAL_TMUX=$(command -v tmux) || fail "tmux is not resolvable"
case "$REAL_TMUX" in /*) ;; *) fail "tmux did not resolve to an absolute path: $REAL_TMUX" ;; esac
[ -x "$REAL_TMUX" ] || fail "tmux at $REAL_TMUX is not executable"

STRICT_SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin

TMP_ROOT=$(fm_test_tmproot fm-attended-tmux)
fm_git_identity fmtest fmtest@example.invalid
unset LAVISH_AXI_HOST TMUX
RAN=0

TMUX_DIR=/tmp/fmtx-$$
TMUX_DIR_MADE=0
OWNED_LAUNCH_DIRS="$TMP_ROOT/owned-launch-dirs"
: > "$OWNED_LAUNCH_DIRS"
SHARED_FAKEBIN="$TMP_ROOT/fakebin"
SPAWN_FARM="$TMP_ROOT/spawn-farm"

real_tmux_private() {
  env -u TMUX TMUX_TMPDIR="$TMUX_DIR" "$REAL_TMUX" -f /dev/null "$@"
}

# SHELL is pinned so the server's default shell, which runs every window command, is
# bash and not whatever shell the caller uses with its own startup files.
ptmux() {
  env -u TMUX TMUX_TMPDIR="$TMUX_DIR" SHELL=/bin/bash PATH="$SHARED_FAKEBIN:$STRICT_SYSTEM_PATH" tmux "$@"
}

# Remove only a recorded exact path: right kind-specific shape, this run's pid, a real
# directory (not a symlink) owned by the user.
cleanup_owned_paths() {
  local kind d gen label rest
  [ -f "$OWNED_LAUNCH_DIRS" ] || return 0
  while IFS=$'\t' read -r kind d gen label; do
    [ "$gen" = "$$" ] || continue
    case "$kind" in
      tmuxdir)
        [ "$d" = "/tmp/fmtx-$$" ] || continue
        ;;
      launch | taskroot)
        rest=${d#/tmp/fm-attended-tmux-"$$"-}
        [ "$rest" != "$d" ] || continue
        case "$rest" in '' | */*) continue ;; esac
        if [ "$kind" = launch ]; then
          case "$rest" in "$label"+*) ;; *) continue ;; esac
          rest=${rest#"$label"+}
          case "$rest" in '' | *[!0-9a-f]*) continue ;; esac
          [ "${#rest}" -eq 64 ] || continue
        else
          [ "$rest" = "$label" ] || continue
        fi
        ;;
      *) continue ;;
    esac
    if [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ]; then
      rm -rf -- "$d"
    fi
  done < "$OWNED_LAUNCH_DIRS"
}

cleanup_private() {
  # The server is addressed only through the private directory this run made.
  if [ "$TMUX_DIR_MADE" = 1 ] && [ -d "$TMUX_DIR" ] && [ ! -L "$TMUX_DIR" ]; then
    real_tmux_private kill-server >/dev/null 2>&1 || true
  fi
  cleanup_owned_paths
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
# runs a hook. The tmux stub is the only way any process here reaches a tmux binary.
make_run_stubs() {
  mkdir -p "$SHARED_FAKEBIN"
  fm_fake_exit0 "$SHARED_FAKEBIN" treehouse
  cat > "$SHARED_FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
# Stub agent: records that it started in a file beside the worktree it runs in.
printf '%s\n' "$$" >> "$(dirname "$PWD")/agent-started"
exit 0
SH
  cat > "$SHARED_FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
# Fixture stub: only ever the private server's socket directory, never an ambient one.
unset TMUX
[ "\${TMUX_TMPDIR:-}" = "$TMUX_DIR" ] || { echo "fixture tmux stub: TMUX_TMPDIR is not the private directory" >&2; exit 97; }
exec "$REAL_TMUX" -f /dev/null "\$@"
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
  cat > "$SHARED_FAKEBIN/probe.sh" <<'SH'
#!/usr/bin/env bash
# Run inside a pane of the private server: report what the bare names resolve to there.
{
  printf 'claude=%s\n' "$(command -v claude)"
  printf 'tmux=%s\n' "$(command -v tmux)"
  printf 'treehouse=%s\n' "$(command -v treehouse)"
} > "$1.tmp"
mv "$1.tmp" "$1"
SH
  chmod +x "$SHARED_FAKEBIN/claude" "$SHARED_FAKEBIN/tmux" "$SHARED_FAKEBIN/sleep" "$SHARED_FAKEBIN/probe.sh"
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

# fm-spawn.sh writes two fixed paths per task under /tmp that ignore TMPDIR: the staged
# launch directory /tmp/fm-<task id>+<SHA-256 of the physical home path> and the task
# temp root /tmp/fm-<task id>. Every world's two paths are computable now (its home is
# the deterministic $TMP_ROOT/<name>/home and its task id is attended-tmux-<pid>-<name>),
# and so is the short tmux directory. All are required ABSENT, including as a dangling
# symlink, before the tmux directory, the private server, or any fixture exists. One that
# exists stops the run with nothing touched; nothing is reused, stolen, or deleted.
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

task_root_for() {  # <world name>
  printf '/tmp/fm-attended-tmux-%s-%s\n' "$$" "$1"
}

for name in $WORLD_NAMES; do
  d=$(launch_dir_for "$name") || fail "cannot compute the staged launch path for $name"
  t=$(task_root_for "$name")
  if [ -e "$d" ] || [ -L "$d" ]; then
    fail "the staged launch path $d already exists; refusing to continue (nothing is reused, stolen, or deleted)"
  fi
  if [ -e "$t" ] || [ -L "$t" ]; then
    fail "the task temp root $t already exists; refusing to continue (nothing is reused, stolen, or deleted)"
  fi
done
if [ -e "$TMUX_DIR" ] || [ -L "$TMUX_DIR" ]; then
  fail "the private tmux directory $TMUX_DIR already exists; refusing to continue (nothing is reused, stolen, or deleted)"
fi
for name in $WORLD_NAMES; do
  d=$(launch_dir_for "$name")
  t=$(task_root_for "$name")
  printf 'launch\t%s\t%s\t%s\n' "$d" "$$" "$name" >> "$OWNED_LAUNCH_DIRS"
  printf 'taskroot\t%s\t%s\t%s\n' "$t" "$$" "$name" >> "$OWNED_LAUNCH_DIRS"
  printf 'info - staged launch path, absent at preflight and owned by this run: %s\n' "$d"
  printf 'info - staged task root, absent at preflight and owned by this run: %s\n' "$t"
done
printf 'tmuxdir\t%s\t%s\t%s\n' "$TMUX_DIR" "$$" tmuxdir >> "$OWNED_LAUNCH_DIRS"
printf 'info - private tmux directory, absent at preflight and owned by this run: %s\n' "$TMUX_DIR"

# Plain mkdir, no -p: a race that made the path exist since the preflight fails here.
mkdir -m 700 "$TMUX_DIR" || fail "could not create the private tmux directory $TMUX_DIR"
TMUX_DIR_MADE=1
TMUX_SOCKET="$TMUX_DIR/tmux-$(id -u)/default"
# The socket path is built from the real constructed directory and uid, not assumed from
# a short cwd; the macOS sun_path limit is 104 bytes including the terminating NUL.
[ "${#TMUX_SOCKET}" -le 100 ] \
  || fail "the private tmux socket path is ${#TMUX_SOCKET} bytes, over the 100-byte budget: $TMUX_SOCKET"
printf 'info - private tmux socket path, %s bytes: %s\n' "${#TMUX_SOCKET}" "$TMUX_SOCKET"

make_run_stubs
make_farm

# Fail closed before the server exists: no fixed system directory may hold a claude, and
# each stub must be a regular executable file.
for d in ${STRICT_SYSTEM_PATH//:/ }; do
  [ ! -e "$d/claude" ] && [ ! -L "$d/claude" ] \
    || fail "strict claude: $d/claude exists, so the system-only fallback could start a real claude"
done
for tool in claude tmux sleep treehouse probe.sh; do
  [ -f "$SHARED_FAKEBIN/$tool" ] && [ ! -L "$SHARED_FAKEBIN/$tool" ] && [ -x "$SHARED_FAKEBIN/$tool" ] \
    || fail "strict $tool: the fixture stub $SHARED_FAKEBIN/$tool is missing, a symlink, or not executable"
done

# Panes run `bash --noprofile --norc` and the stub PATH; set before any window exists.
ptmux new-session -d -s firstmate -x 120 -y 40 "bash --noprofile --norc" \
  || fail "could not start the private tmux server"
ptmux set-option -g default-command "bash --noprofile --norc" || fail "could not pin the pane shell"

# The probe: a pane of the private server reports what `claude`, `tmux` and `treehouse`
# resolve to in the SERVER's environment, which every pane inherits. Nothing is spawned
# and no gate can pass before this has matched the stub files exactly.
PROBE_OUT="$TMP_ROOT/probe-out"
ptmux new-window -d -t firstmate -n fm-attended-probe "$SHARED_FAKEBIN/probe.sh $PROBE_OUT" \
  || fail "could not open the probe pane"
wait_for 100 test -e "$PROBE_OUT" || fail "the probe pane never reported"
[ "$(sed -n 's/^claude=//p' "$PROBE_OUT")" = "$SHARED_FAKEBIN/claude" ] \
  || fail "a pane resolves claude to '$(sed -n 's/^claude=//p' "$PROBE_OUT")', not the stub $SHARED_FAKEBIN/claude"
[ "$(sed -n 's/^tmux=//p' "$PROBE_OUT")" = "$SHARED_FAKEBIN/tmux" ] \
  || fail "a pane resolves tmux to '$(sed -n 's/^tmux=//p' "$PROBE_OUT")', not the stub $SHARED_FAKEBIN/tmux"
[ "$(sed -n 's/^treehouse=//p' "$PROBE_OUT")" = "$SHARED_FAKEBIN/treehouse" ] \
  || fail "a pane resolves treehouse to '$(sed -n 's/^treehouse=//p' "$PROBE_OUT")', not the stub"
printf 'info - probe pane resolved claude and tmux to the fixture stubs\n'

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
  grep -qxF "$(printf 'launch\t%s\t%s\t%s' "$(launch_dir_for "$name")" "$$" "$name")" "$OWNED_LAUNCH_DIRS" \
    || fail "world $name is not in WORLD_NAMES, so its staged launch path was never preflighted"
  grep -qxF "$(printf 'taskroot\t%s\t%s\t%s' "$(task_root_for "$name")" "$$" "$name")" "$OWNED_LAUNCH_DIRS" \
    || fail "world $name is not in WORLD_NAMES, so its task temp root was never preflighted"
}

world_att() {
  FM_HOME="$W_HOME" FM_STATE_OVERRIDE="$W_HOME/state" FM_CONFIG_OVERRIDE="$W_HOME/config" \
    FM_DATA_OVERRIDE="$W_HOME/data" TMUX_TMPDIR="$TMUX_DIR" PATH="$SHARED_FAKEBIN:$STRICT_SYSTEM_PATH" \
    "$SPAWN_FARM/bin/fm-attended-job.sh" "$@"
}

world_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$W_HOME" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$W_HOME/state" FM_DATA_OVERRIDE="$W_HOME/data" \
    FM_PROJECTS_OVERRIDE="$W_HOME/projects" FM_CONFIG_OVERRIDE="$W_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX_TMPDIR="$TMUX_DIR" PATH="$SHARED_FAKEBIN:$STRICT_SYSTEM_PATH" \
    FM_ATTENDED_LAUNCH_WAIT_POLLS=200 \
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

[ "${HOME-}" = "$HOME_AT_LOAD" ] || fail "HOME changed during the suite; nothing here may replace it"
[ "$RAN" -eq 3 ] || fail "$RAN cases ran, expected 3; a silent partial pass is not a pass"
