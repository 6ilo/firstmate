#!/usr/bin/env bash
# Behavior tests for bin/fm-today-autopush.sh, the watcher-driven Today push.
# The seams are the script's own tick and take-notice commands over a fixture
# home, the real watcher for delivery and beacon isolation, and a local stub
# portal (python3 http.server) standing in for POST /api/fleet/bridge/snapshot.
# The stub reads the status to answer and a delay from files on every request,
# so one stub serves success, failure, and a slow portal. The real portal is
# never contacted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

AUTOPUSH="$ROOT/bin/fm-today-autopush.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-today-autopush)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
TOKEN="tok-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
export TZ=UTC
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish"
unset FM_TODAY_PORTAL_URL FM_TODAY_BRIDGE_TOKEN FM_TODAY_DAY_FILE \
  FM_TODAY_PUSH_MIN_SECS FM_TODAY_PUSH_TOPUP_SECS FM_TODAY_PUSH_TIMEOUT FM_TODAY_PUSH_CHECK_SECS
STUB_PID=
WATCH_PID=

cleanup() {
  local pid
  for pid in "$WATCH_PID" "$STUB_PID"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/no-mistakes"
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

STUB="$TMP_ROOT/stub"
mkdir -p "$STUB/requests"
printf '200\n' > "$STUB/status"
printf '0\n' > "$STUB/delay"
cat > "$STUB/server.py" <<'PY'
import http.server, json, os, time
d = os.environ["STUB_DIR"]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        req = os.path.join(d, "requests")
        n = len(os.listdir(req))
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(os.path.join(req, "req-%d.json" % n), "w") as fh:
            json.dump({"auth": self.headers.get("Authorization"), "body": body.decode("utf-8")}, fh)
        time.sleep(float(open(os.path.join(d, "delay")).read()))
        status = int(open(os.path.join(d, "status")).read())
        out = {"heard_at": "2026-09-28T18:00:00Z"} if status == 200 else \
              {"code": "bad_snapshot", "message": "refused", "request_id": "r1"}
        data = json.dumps(out).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port.tmp"), "w") as fh:
    fh.write(str(srv.server_address[1]))
os.rename(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
srv.serve_forever()
PY
STUB_DIR=$STUB python3 "$STUB/server.py" &
STUB_PID=$!
disown "$STUB_PID" 2>/dev/null || true
i=0
while [ ! -s "$STUB/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$STUB/port" ] || fail "the stub portal did not start"
STUB_URL="http://127.0.0.1:$(cat "$STUB/port")"

requests() { find "$STUB/requests" -type f | wc -l | tr -d ' '; }
reset_requests() { rm -f "$STUB/requests"/*; }

make_home() {  # <name> [configured]
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '## In flight\n\n## Queued\n- [ ] first - First queued thing (kind: ship)\n\n## Done\n' \
    > "$home/data/backlog.md"
  if [ "${2:-}" = configured ]; then
    printf 'FM_TODAY_PORTAL_URL=%s\nFM_TODAY_BRIDGE_TOKEN=%s\n' "$STUB_URL" "$TOKEN" > "$home/.env"
  fi
  printf '%s\n' "$home"
}

add_queued() {  # <home> <id>
  awk -v id="$2" '/^## Done/ { printf "- [ ] %s - Another queued thing %s (kind: ship)\n\n", id, id } { print }' \
    "$1/data/backlog.md" > "$1/data/backlog.md.tmp" && mv "$1/data/backlog.md.tmp" "$1/data/backlog.md"
}

OUTPUTS="$TMP_ROOT/outputs"
mkdir -p "$OUTPUTS"
tick() {  # <home>; any output is kept for the leak check
  FM_HOME="$1" "$AUTOPUSH" tick >> "$OUTPUTS/tick.out" 2>> "$OUTPUTS/tick.err" \
    || fail "tick exited non-zero"
}
take_notice() {  # <home>; sets NOTICE
  NOTICE=$(FM_HOME="$1" "$AUTOPUSH" take-notice 2>> "$OUTPUTS/notice.err")
  printf '%s\n' "$NOTICE" >> "$OUTPUTS/notice.out"
}

test_unconfigured_is_a_silent_noop() {
  local home secondmate
  reset_requests
  home=$(make_home plain)
  tick "$home"
  [ "$(requests)" -eq 0 ] || fail "an unconfigured home pushed"
  [ -z "$(ls -A "$home/state")" ] || fail "an unconfigured home wrote state: $(ls -A "$home/state")"
  secondmate=$(make_home mate configured)
  printf 'mate\n' > "$secondmate/.fm-secondmate-home"
  tick "$secondmate"
  [ "$(requests)" -eq 0 ] || fail "a secondmate home pushed"
  pass "an unconfigured or secondmate home neither pushes nor writes state"
}

test_env_configuration_pushes() {
  local home
  reset_requests
  home=$(make_home env-home)
  FM_HOME="$home" FM_TODAY_PORTAL_URL="$STUB_URL" FM_TODAY_BRIDGE_TOKEN="$TOKEN" \
    "$AUTOPUSH" tick >> "$OUTPUTS/tick.out" 2>> "$OUTPUTS/tick.err"
  [ "$(requests)" -eq 1 ] || fail "a home configured by environment did not push"
  [ "$(jq -r .auth "$STUB/requests/req-0.json")" = "Bearer $TOKEN" ] \
    || fail "the push did not carry the bridge token"
  pass "a home configured by environment pushes with its token"
}

# The bridge assembles each snapshot in one python3 run that reads the bearings
# document named by FM_TODAY_BEARINGS; a python3 shim counts those runs.
test_tick_builds_the_snapshot_once() {
  local home shim=$TMP_ROOT/build-count-bin builds=$TMP_ROOT/builds real_python
  reset_requests
  real_python=$(command -v python3)
  mkdir -p "$shim"
  cat > "$shim/python3" <<SH
#!/usr/bin/env bash
[ -z "\${FM_TODAY_BEARINGS:-}" ] || printf 'build\n' >> '$builds'
exec '$real_python' "\$@"
SH
  chmod +x "$shim/python3"
  : > "$builds"
  home=$(make_home build-once configured)
  PATH="$shim:$PATH" tick "$home"
  [ "$(requests)" -eq 1 ] || fail "the tick did not push (got $(requests))"
  [ "$(wc -l < "$builds" | tr -d ' ')" -eq 1 ] \
    || fail "one tick built the snapshot $(wc -l < "$builds" | tr -d ' ') times"
  jq -r .body "$STUB/requests/req-0.json" | jq -e '[.sections.charted_next[].id] | index("first")' >/dev/null \
    || fail "the pushed snapshot did not carry the home's queued work"
  pass "a tick builds the snapshot once and pushes that same document"
}

test_debounce_coalesces_changes() {
  local home
  reset_requests
  home=$(make_home debounce configured)
  export FM_TODAY_PUSH_MIN_SECS=5 FM_TODAY_PUSH_TOPUP_SECS=3600
  tick "$home"
  [ "$(requests)" -eq 1 ] || fail "the first tick did not push (got $(requests))"
  add_queued "$home" second
  tick "$home"
  add_queued "$home" third
  tick "$home"
  [ "$(requests)" -eq 1 ] || fail "changes inside the window pushed again (got $(requests))"
  sleep 5
  tick "$home"
  [ "$(requests)" -eq 2 ] || fail "the changes were not pushed once the window passed (got $(requests))"
  jq -r .body "$STUB/requests/req-1.json" | jq -e '[.sections.charted_next[].id] | index("third")' >/dev/null \
    || fail "the coalesced push did not carry the latest change"
  sleep 5
  tick "$home"
  [ "$(requests)" -eq 2 ] || fail "an unchanged fleet pushed before the top-up (got $(requests))"
  unset FM_TODAY_PUSH_MIN_SECS FM_TODAY_PUSH_TOPUP_SECS
  pass "two changes inside the debounce window give one push, and no change gives none"
}

test_topup_after_idle_interval() {
  local home
  reset_requests
  home=$(make_home topup configured)
  export FM_TODAY_PUSH_MIN_SECS=1 FM_TODAY_PUSH_TOPUP_SECS=3
  tick "$home"
  [ "$(requests)" -eq 1 ] || fail "the first tick did not push"
  sleep 1
  tick "$home"
  [ "$(requests)" -eq 1 ] || fail "an unchanged fleet pushed before the top-up interval"
  sleep 2
  tick "$home"
  [ "$(requests)" -eq 2 ] || fail "no top-up push after the idle interval (got $(requests))"
  unset FM_TODAY_PUSH_MIN_SECS FM_TODAY_PUSH_TOPUP_SECS
  pass "an unchanged fleet is pushed again after the top-up interval"
}

test_one_notice_per_failure_episode() {
  local home
  reset_requests
  home=$(make_home failing configured)
  export FM_TODAY_PUSH_MIN_SECS=3 FM_TODAY_PUSH_TOPUP_SECS=3
  printf '500\n' > "$STUB/status"
  tick "$home"
  take_notice "$home"
  [ "$NOTICE" = "check: today-push failed (exit 3: the portal answered 500 (bad_snapshot))" ] \
    || fail "the first failure did not leave its notice: '$NOTICE'"
  take_notice "$home"
  [ -z "$NOTICE" ] || fail "the notice was surfaced twice: '$NOTICE'"
  tick "$home"
  [ "$(requests)" -eq 1 ] || fail "a failure retried inside the debounce window"
  sleep 3
  tick "$home"
  [ "$(requests)" -eq 2 ] || fail "the next attempt did not run after the window"
  take_notice "$home"
  [ -z "$NOTICE" ] || fail "a second failure in one episode raised another notice: '$NOTICE'"
  printf '200\n' > "$STUB/status"
  sleep 3
  tick "$home"
  [ "$(requests)" -eq 3 ] || fail "the recovery attempt did not run"
  printf '500\n' > "$STUB/status"
  sleep 3
  tick "$home"
  take_notice "$home"
  [ -n "$NOTICE" ] || fail "a failure after a success did not start a new episode"
  # A notice still pending when a push succeeds is dropped with the episode.
  printf '200\n' > "$STUB/status"
  add_queued "$home" late
  sleep 3
  tick "$home"
  take_notice "$home"
  [ -z "$NOTICE" ] || fail "a success left a stale notice: '$NOTICE'"
  printf '500\n' > "$STUB/status"
  sleep 3
  tick "$home"
  printf '200\n' > "$STUB/status"
  sleep 3
  tick "$home"
  take_notice "$home"
  [ -z "$NOTICE" ] || fail "a pending notice survived the success that ended its episode: '$NOTICE'"
  unset FM_TODAY_PUSH_MIN_SECS FM_TODAY_PUSH_TOPUP_SECS
  pass "a failure episode raises one notice, and a success ends it"
}

# A python3 that first sleeps $SLOWBIN/delay seconds when it is the snapshot
# assembly (the python3 run with FM_TODAY_BEARINGS set, not its own python3
# children), so a build runs slow by a chosen amount.
SLOWBIN="$TMP_ROOT/slowbin"
mkdir -p "$SLOWBIN"
REAL_PYTHON3=$(command -v python3)
cat > "$SLOWBIN/python3" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_TODAY_BEARINGS:-}" ] && [ -z "\${FM_TEST_SLOWED:-}" ]; then
  export FM_TEST_SLOWED=1
  sleep "\$(cat '$SLOWBIN/delay')"
fi
exec '$REAL_PYTHON3' "\$@"
SH
chmod +x "$SLOWBIN/python3"

test_slow_build_pushes_within_the_bound() {
  local home
  reset_requests
  home=$(make_home slow-build configured)
  export FM_TODAY_PUSH_MIN_SECS=1 FM_TODAY_PUSH_TOPUP_SECS=3600 FM_TODAY_PUSH_TIMEOUT=12
  # A build slower than the old 60-second default, scaled: 3s under a 12s
  # bound that the push's own contract check and send must also fit.
  printf '3\n' > "$SLOWBIN/delay"
  PATH="$SLOWBIN:$PATH" tick "$home"
  take_notice "$home"
  [ "$(requests)" -eq 1 ] || fail "a slow build inside the bound did not push (got $(requests)): '$NOTICE'"
  [ -z "$NOTICE" ] || fail "a slow build inside the bound left a notice: '$NOTICE'"
  # Beyond the bound it still times out, once, with the bound in its reason.
  add_queued "$home" slower
  printf '14\n' > "$SLOWBIN/delay"
  sleep 1
  PATH="$SLOWBIN:$PATH" tick "$home"
  take_notice "$home"
  [ "$(requests)" -eq 1 ] || fail "a build beyond the bound pushed (got $(requests))"
  [ "$NOTICE" = "check: today-push failed (timed out after 12s)" ] \
    || fail "a build beyond the bound did not time out: '$NOTICE'"
  unset FM_TODAY_PUSH_MIN_SECS FM_TODAY_PUSH_TOPUP_SECS FM_TODAY_PUSH_TIMEOUT
  pass "a slow build pushes within the bound and times out beyond it"
}

beat_mtime() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime)' "$1"; }

start_watch() {  # <home> <out>
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" \
    FM_POLL=1 FM_TODAY_PUSH_CHECK_SECS=1 FM_TODAY_PUSH_MIN_SECS=1 FM_TODAY_PUSH_TIMEOUT=60 \
    FM_HOME_SUMMARY_INTERVAL=9999999 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
    "$WATCH" > "$2" 2> "$2.err" &
  WATCH_PID=$!
}

stop_watch() {
  kill "$WATCH_PID" >/dev/null 2>&1 || true
  wait "$WATCH_PID" >/dev/null 2>&1 || true
  WATCH_PID=
}

test_slow_push_does_not_delay_the_beacon() {
  local home seen last now i
  reset_requests
  home=$(make_home slow configured)
  printf '200\n' > "$STUB/status"
  printf '30\n' > "$STUB/delay"
  start_watch "$home" "$TMP_ROOT/slow-watch.out"
  i=0
  while [ "$(requests)" -eq 0 ] && [ "$i" -lt 300 ]; do
    kill -0 "$WATCH_PID" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(requests)" -ge 1 ] || fail "the watcher never started a push: $(cat "$TMP_ROOT/slow-watch.out.err")"
  seen=0
  last=$(beat_mtime "$home/state/.last-watcher-beat")
  i=0
  while [ "$seen" -lt 3 ] && [ "$i" -lt 100 ]; do
    kill -0 "$WATCH_PID" 2>/dev/null || fail "the watcher exited: $(cat "$TMP_ROOT/slow-watch.out.err")"
    sleep 0.1
    now=$(beat_mtime "$home/state/.last-watcher-beat")
    if [ "$now" != "$last" ]; then
      seen=$((seen + 1))
      last=$now
    fi
    i=$((i + 1))
  done
  [ "$seen" -ge 3 ] || fail "the beacon advanced only $seen time(s) in 10 seconds while a push was stalled"
  [ "$(requests)" -eq 1 ] || fail "a second push started while one was in flight (got $(requests))"
  stop_watch
  printf '0\n' > "$STUB/delay"
  pass "a stalled push does not delay the watcher beacon, and pushes run one at a time"
}

test_watcher_surfaces_the_notice_once() {
  local home i out="$TMP_ROOT/notice-watch.out"
  reset_requests
  home=$(make_home watched configured)
  printf '500\n' > "$STUB/status"
  start_watch "$home" "$out"
  i=0
  while ! grep -q 'today-push' "$out" 2>/dev/null && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -qx 'check: today-push failed (exit 3: the portal answered 500 (bad_snapshot))' "$out" \
    || fail "the watcher did not wake with the failure notice: $(cat "$out" "$out.err")"
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=
  # Later watcher cycles keep failing inside the same episode and stay quiet.
  # A watcher exits after each wake (a restart first resurfaces its recovery),
  # so re-arm it the way supervision does until two more attempts have run.
  : > "$out.later"
  i=0
  while [ "$(requests)" -lt 3 ] && [ "$i" -lt 200 ]; do
    if [ -z "$WATCH_PID" ] || ! kill -0 "$WATCH_PID" 2>/dev/null; then
      [ -z "$WATCH_PID" ] || { wait "$WATCH_PID" 2>/dev/null || true; cat "$out.2" >> "$out.later"; }
      start_watch "$home" "$out.2"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  stop_watch
  cat "$out.2" >> "$out.later"
  [ "$(requests)" -ge 3 ] || fail "the watcher stopped attempting pushes (got $(requests)): $(cat "$out.later")"
  ! grep -q 'today-push' "$out.later" || fail "the watcher surfaced the same episode twice: $(cat "$out.later")"
  printf '200\n' > "$STUB/status"
  pass "the watcher wakes once per failure episode with the notice"
}

test_token_never_reaches_output() {
  local f
  for f in "$OUTPUTS"/* "$TMP_ROOT"/*.out "$TMP_ROOT"/*.out.* "$TMP_ROOT"/*/state/.today-push*; do
    [ -f "$f" ] || continue
    ! grep -qF "$TOKEN" "$f" || fail "the token appeared in $f"
  done
  pass "the token never appears in output, notices, or state"
}

test_unconfigured_is_a_silent_noop
test_env_configuration_pushes
test_tick_builds_the_snapshot_once
test_debounce_coalesces_changes
test_topup_after_idle_interval
test_one_notice_per_failure_episode
test_slow_build_pushes_within_the_bound
test_slow_push_does_not_delay_the_beacon
test_watcher_surfaces_the_notice_once
test_token_never_reaches_output
