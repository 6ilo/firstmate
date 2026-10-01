#!/usr/bin/env bash
# Live validation of the fm/today-push-timeout change.
# Intent: raise the default FM_TODAY_PUSH_TIMEOUT from 60 to 180 so the Today
# auto-push succeeds even when building the snapshot takes ~72s on a loaded
# machine (it had been failing because the 60s default was too tight).
#
# Proves the DEFAULT (FM_TODAY_PUSH_TIMEOUT unset) now lets a build slower than
# the old 60s default push: with a 72s snapshot assembly it must push exactly
# once with no failure notice. Uses the real bin/fm-today-autopush.sh and
# bin/fm-today-bridge.sh against a local stub portal, mirroring the suite's own
# fixture mechanics.
set -u
ROOT=/Users/anwulikaanigbodesktop/.no-mistakes/worktrees/ba7143190a89/01M3TQ753CHBAFE9N0AWXMVGHP
AUTOPUSH="$ROOT/bin/fm-today-autopush.sh"
umask 022
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/timeout180.XXXXXX")
trap 'rm -rf "$TMP_ROOT"; kill -KILL "$STUB_PID" 2>/dev/null' EXIT

unset FM_TODAY_PORTAL_URL FM_TODAY_BRIDGE_TOKEN FM_TODAY_PUSH_MIN_SECS \
  FM_TODAY_PUSH_TOPUP_SECS FM_TODAY_PUSH_TIMEOUT FM_TODAY_PUSH_CHECK_SECS
TOKEN="tok-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"

# ---- stub portal (mirrors the suite's stub) ----
STUB="$TMP_ROOT/stub"; mkdir -p "$STUB/requests"; printf '200\n' > "$STUB/status"; printf '0\n' > "$STUB/delay"
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
        out = {"heard_at": "2026-09-28T18:00:00Z"} if status == 200 else {"code": "bad_snapshot", "message": "refused", "request_id": "r1"}
        data = json.dumps(out).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port.tmp"), "w") as fh: fh.write(str(srv.server_address[1]))
os.rename(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
srv.serve_forever()
PY
STUB_DIR=$STUB python3 "$STUB/server.py" & STUB_PID=$!
i=0; while [ ! -s "$STUB/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
[ -s "$STUB/port" ] || { echo "FATAL: stub did not start"; exit 2; }
STUB_URL="http://127.0.0.1:$(cat "$STUB/port")"

# ---- slow python3 shim: sleeps only when assembling the snapshot (FM_TODAY_BEARINGS set) ----
SLOWBIN="$TMP_ROOT/slowbin"; mkdir -p "$SLOWBIN"
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

home="$TMP_ROOT/home"; mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
printf '## In flight\n\n## Queued\n- [ ] first - First queued thing (kind: ship)\n\n## Done\n' > "$home/data/backlog.md"
printf 'FM_TODAY_PORTAL_URL=%s\nFM_TODAY_BRIDGE_TOKEN=%s\n' "$STUB_URL" "$TOKEN" > "$home/.env"

requests() { find "$STUB/requests" -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "== driving a tick with DEFAULT settings (no FM_TODAY_PUSH_TIMEOUT) =="
echo "current FM_TODAY_PUSH_TIMEOUT env: '${FM_TODAY_PUSH_TIMEOUT:-<unset -> script default 180>}'"
printf '72\n' > "$SLOWBIN/delay"   # a build slower than the OLD 60s default
SECONDS=0
FM_HOME="$home" FM_TODAY_PUSH_MIN_SECS=1 FM_TODAY_PUSH_TOPUP_SECS=3600 \
  PATH="$SLOWBIN:$PATH" "$AUTOPUSH" tick
rc=$?
echo "tick exit=$rc after ${SECONDS}s wall clock; requests=$(requests)"
NOTICE=$(FM_HOME="$home" "$AUTOPUSH" take-notice || true)
echo "notice='$NOTICE'"
echo "requests after: $(requests)"

ok=1
[ "$rc" -eq 0 ] || { echo "FAIL: tick exited $rc"; ok=0; }
[ "$(requests)" -eq 1 ] || { echo "FAIL: expected exactly 1 push, got $(requests)"; ok=0; }
[ -z "$NOTICE" ] || { echo "FAIL: unexpected failure notice '$NOTICE'"; ok=0; }
grep -q "generated_at" "$STUB/requests/req-0.json" && echo "OK: pushed snapshot carries generated_at"
[ "$(jq -r .auth "$STUB/requests/req-0.json" 2>/dev/null)" = "Bearer $TOKEN" ] && echo "OK: push carried bridge token"

printf '0\n' > "$SLOWBIN/delay"
if [ "$ok" -eq 1 ]; then
  echo "RESULT: PASS - default timeout 180 accepted a 72s build and pushed once"
  exit 0
fi
echo "RESULT: FAIL"
exit 1
