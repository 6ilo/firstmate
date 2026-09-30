#!/usr/bin/env bash
set -u
WT=$PWD
EV=/Users/anwulikaanigbodesktop/.no-mistakes/evidence/01M3RNGNHRT6ZNTF4NNTF9YZ0F
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"; bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
STUB=$(mktemp -d); mkdir -p "$STUB/requests"; echo 200 > "$STUB/status"
sed -n '/^cat > "\$STUB\/server.py" <<.PY.$/,/^PY$/p' tests/fm-today-autopush.test.sh | sed '1d;$d' > "$STUB/server.py"
sed -i '' 's/time.sleep(float(open(os.path.join(d, "delay")).read()))//' "$STUB/server.py"
STUB_DIR=$STUB python3 "$STUB/server.py" & SP=$!
for i in $(seq 50); do [ -s "$STUB/port" ] && break; sleep 0.1; done
URL="http://127.0.0.1:$(cat $STUB/port)"
TOKEN="livetok-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
printf 'FM_TODAY_PORTAL_URL=%s\nFM_TODAY_BRIDGE_TOKEN=%s\n' "$URL" "$TOKEN" > "$LAB/.env"
printf '## In flight\n\n## Queued\n- [ ] alpha - Alpha thing (kind: ship)\n\n## Done\n' > "$LAB/data/backlog.md"
req() { find "$STUB/requests" -type f | wc -l | tr -d ' '; }
LOG=$EV/live-watcher-transcript.txt; : > "$LOG"
say() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }
WOUT=$STUB/watch.out
start() { env -u TMUX -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" FM_POLL=1 FM_TODAY_PUSH_CHECK_SECS=2 FM_TODAY_PUSH_MIN_SECS=6 FM_TODAY_PUSH_TOPUP_SECS=20 \
  FM_HOME_SUMMARY_INTERVAL=9999999 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  bin/fm-watch.sh >> "$WOUT" 2>>"$WOUT.err" & WP=$!; }
ensure() { kill -0 "$WP" 2>/dev/null || { say "watcher exited; wake output so far: $(tr '\n' '|' < $WOUT)"; start; }; }
waitfor() { local n=$1 t=$2; for i in $(seq $((t*10))); do ensure; [ "$(req)" -ge "$n" ] && return 0; sleep 0.1; done; return 1; }
start
say "S1 start watcher in configured lab home $LAB"
waitfor 1 15 && say "S1 PASS: first push arrived ($(req) req), auth header is bearer w/ .env token: $( [ "$(jq -r .auth $STUB/requests/req-0.json)" = "Bearer $TOKEN" ] && echo yes || echo NO)"
jq -r .body $STUB/requests/req-0.json | jq '{generated_at, charted: [.sections.charted_next[]?.id]}' | tee -a "$LOG"
sleep 3; say "S2 fleet change: add queued item beta at ~3s after push (inside 6s debounce)"
awk '/^## Done/{print "- [ ] beta - Beta thing (kind: ship)\n"}{print}' "$LAB/data/backlog.md" > "$LAB/b.tmp" && mv "$LAB/b.tmp" "$LAB/data/backlog.md"
sleep 1; ensure; say "S2 requests 1s after change (still debounced): $(req)"
waitfor 2 15 && say "S2 PASS: change pushed after debounce ($(req) req); charted=$(jq -r .body $STUB/requests/req-1.json | jq -c '[.sections.charted_next[]?.id]')"
T2=$(date +%s)
for i in $(seq 120); do ensure; sleep 0.1; done
say "S3 12s later, unchanged fleet, requests=$(req) (expect 2: no push before top-up)"
waitfor 3 20 && say "S3 PASS: top-up push of unchanged fleet after $(( $(date +%s)-T2 ))s (req=$(req))"
say "S4 portal answers 500"; echo 500 > "$STUB/status"
waitfor 4 30; for i in $(seq 50); do ensure; grep -q today-push "$WOUT" && break; sleep 0.1; done
say "S4 watcher wake lines: $(grep today-push "$WOUT")"
B1=$(stat -f %m "$LAB/state/.last-watcher-beat" 2>/dev/null)
waitfor 6 30; say "S4 after 2 more failed attempts (req=$(req)), today-push wake lines count: $(grep -c today-push "$WOUT") (expect 1)"
say "S4 beacon mtime moved during failures: $B1 -> $(stat -f %m "$LAB/state/.last-watcher-beat")"
echo 200 > "$STUB/status"; waitfor 7 20; say "S5 recovery push req=$(req); state: $(grep -v fp "$LAB/state/.today-push.state" | tr '\n' ' ')"
say "S6 token leak grep over watcher output, state, and transcript: $(grep -rlF "$TOKEN" "$WOUT" "$WOUT.err" "$LAB/state" "$LOG" 2>/dev/null | wc -l | tr -d ' ') files (expect 0)"
kill $WP 2>/dev/null; wait $WP 2>/dev/null
# unconfigured
LAB2=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB2"; bin/fm-lab-home.sh create "$LAB2" >/dev/null; mkdir -p "$LAB2/tmux"
cp "$LAB/data/backlog.md" "$LAB2/data/"; B=$(req)
env -u TMUX -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE TMUX_TMPDIR="$LAB2/tmux" FM_HOME="$LAB2" FM_POLL=1 FM_TODAY_PUSH_CHECK_SECS=1 FM_TODAY_PUSH_MIN_SECS=1 FM_HOME_SUMMARY_INTERVAL=9999999 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 bin/fm-watch.sh > /dev/null 2>&1 & WP=$!
sleep 6; kill $WP 2>/dev/null; wait $WP 2>/dev/null
say "S7 unconfigured lab home, watcher 6s: new requests=$(( $(req)-B )), today-push state files=$(ls -A $LAB2/state | grep -c today-push)"
cat "$WOUT.err" | tail -5 > "$EV/live-watcher-stderr-tail.txt"
TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null; TMUX_TMPDIR="$LAB2/tmux" tmux kill-server 2>/dev/null
kill $SP; rm -rf "$LAB" "$LAB2" "$STUB"
