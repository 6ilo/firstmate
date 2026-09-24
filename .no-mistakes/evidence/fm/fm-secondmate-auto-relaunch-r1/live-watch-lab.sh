#!/usr/bin/env bash
set -u
ROOT=$PWD
EVIDENCE=/Users/kunchen/.no-mistakes/evidence/01M38TF2KZXC1QXX3WV5GG523P
LAB="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$LAB" name livewatch)
ORIGINAL_PATH=$PATH
HOME_LAB="$ROOT/.test-live-secondmate-$$"
cleanup() {
  rc=$?
  env PATH="$ORIGINAL_PATH" "$LAB" teardown "$SESSION" || rc=1
  rm -rf -- "$HOME_LAB"
  echo "cleanup_status=$rc"; exit "$rc"
}
trap cleanup EXIT
"$LAB" provision "$SESSION" || exit 1
mkdir -p "$HOME_LAB/primary/state" "$HOME_LAB/primary/config" "$HOME_LAB/mate/state" "$HOME_LAB/mate/data" "$HOME_LAB/mate/config" "$HOME_LAB/mate/projects" "$HOME_LAB/fakebin"
printf 'pi\n' > "$HOME_LAB/primary/config/crew-harness"
printf 'pi\n' > "$HOME_LAB/primary/config/secondmate-harness"
printf 'sm1\n' > "$HOME_LAB/mate/.fm-secondmate-home"
printf '# mate\n' > "$HOME_LAB/mate/AGENTS.md"
printf 'charter\n' > "$HOME_LAB/mate/data/charter.md"
printf 'window=%s:pane-nonexistent\nkind=secondmate\nharness=pi\nbackend=herdr\nherdr_session=%s\nhome=%s\n' "$SESSION" "$SESSION" "$HOME_LAB/mate" > "$HOME_LAB/primary/state/sm1.meta"
cat > "$HOME_LAB/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = "$HERDR_LAB_SESSION" ]; then
  unset 'args[n-1]' 'args[n-2]'
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
SH
chmod +x "$HOME_LAB/fakebin/herdr"
export HERDR_LAB_SESSION="$SESSION" HERDR_LAB_HELPER="$LAB" HERDR_ORIGINAL_PATH="$ORIGINAL_PATH"
export PATH="$HOME_LAB/fakebin:$ORIGINAL_PATH" FM_HOME="$HOME_LAB/primary" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_LAB/primary/state" FM_BACKEND=herdr HERDR_SESSION="$SESSION"
export FM_SECONDMATE_LIVENESS_SECS=1 FM_SECONDMATE_LIVENESS_TIMEOUT=30 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH TMUX TMUX_PANE
printf 'session=%s\ninitial_meta:\n' "$SESSION"
cat "$HOME_LAB/primary/state/sm1.meta"
"$ROOT/bin/fm-watch.sh" > "$EVIDENCE/live-watch.out" 2> "$EVIDENCE/live-watch.err" &
watchpid=$!
for ((i=0; i<100; i++)); do
  kill -0 "$watchpid" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$watchpid" 2>/dev/null; then kill -TERM "$watchpid"; fi
wait "$watchpid"; rc=$?
echo "watch_exit=$rc"
printf 'captain_output:\n'; cat "$EVIDENCE/live-watch.out"
printf 'watch_errors:\n'; cat "$EVIDENCE/live-watch.err"
printf 'ledger:\n'; cat "$HOME_LAB/primary/state/.secondmate-relaunch-sm1" 2>/dev/null || :
printf 'queue:\n'; cat "$HOME_LAB/primary/state/.wake-queue" 2>/dev/null || :
printf 'final_meta:\n'; cat "$HOME_LAB/primary/state/sm1.meta"
printf 'lab_tabs:\n'; env PATH="$ORIGINAL_PATH" "$LAB" run "$SESSION" tab list || :
exit "$rc"
