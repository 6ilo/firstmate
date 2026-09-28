#!/usr/bin/env bash
# Live drive of bin/fm-today-bridge.sh against a disposable lab home and a loopback stub portal.
set -u
WT=$1; EV=$2
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TODAY_PORTAL_URL FM_TODAY_BRIDGE_TOKEN
export FM_HOME=$LAB
TODAY=$(date +%Y-%m-%d)
cat > "$LAB/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-today - Build the Today bridge (repo: firstmate) (kind: ship) (since 2026-09-27)

## Queued
- [ ] next-up - Portal answers inbound (repo: firstmate) (kind: ship)
- [ ] call-rail - Choose the rail order for the dock (kind: captain) (hold: pick one of two orders) (hold-kind: captain)
- [ ] call-fee - Approve the tuition waiver for the Smith family (kind: captain) (hold: approve or not) (hold-kind: captain)
- [ ] call-mail - Reply to jo.smith@example.org about pickup (kind: captain) (hold: send or not) (hold-kind: captain)
- [ ] call-cutaddr - Choose a kit (kind: captain) (hold: ship it to the depot at the far side of the town square at 42 Juniper Hill Rd) (hold-kind: captain)

## Done
- [x] landed-one - Publish the contract https://github.com/acme/widget/pull/9 (repo: firstmate) (kind: ship) (merged 2026-09-27)
EOF
printf 'working: wiring push\n' > "$LAB/state/ship-today.status"
printf 'window=firstmate:fm-ship-today\nworktree=%s/projects\nproject=firstmate\nharness=claude\nkind=ship\nmode=no-mistakes\n' "$LAB" > "$LAB/state/ship-today.meta"
cat > "$LAB/day.json" <<EOF
{"date":"$TODAY","ends_at":"${TODAY}T23:59:59-05:00","fetched_at":"now",
 "blocks":[{"id":"b1","title":"Standup with crew","starts_at":"${TODAY}T09:00:00-05:00","ends_at":"${TODAY}T09:30:00-05:00"},
           {"id":"b2","title":"Deep work","starts_at":"${TODAY}T10:00:00-05:00","ends_at":"${TODAY}T12:00:00-05:00"}]}
EOF
export FM_TODAY_DAY_FILE=$LAB/day.json
export TOKEN="tok-live-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"

# stub portal
STUB=$LAB/stub; mkdir -p "$STUB"
start_stub() { rm -f "$STUB/port"; STUB_STATUS=$1 STUB_DIR=$STUB python3 - <<'PY' &
import http.server, json, os
d=os.environ["STUB_DIR"]; st=int(os.environ["STUB_STATUS"])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b=self.rfile.read(int(self.headers.get("Content-Length",0)))
        n=len([f for f in os.listdir(d) if f.startswith("req")])
        json.dump({"path":self.path,"auth":self.headers.get("Authorization"),"type":self.headers.get("Content-Type"),"body":b.decode()},open(os.path.join(d,"req-%d.json"%n),"w"))
        out={"heard_at":"2026-09-28T19:00:00Z"} if st==200 else {"code":"bad_snapshot","message":"refused","request_id":"r9"}
        data=json.dumps(out).encode(); self.send_response(st); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
s=http.server.HTTPServer(("127.0.0.1",0),H)
open(os.path.join(d,"port"),"w").write(str(s.server_address[1])); s.serve_forever()
PY
PID=$!; for i in $(seq 100); do [ -s "$STUB/port" ] && break; sleep 0.05; done; URL="http://127.0.0.1:$(cat "$STUB/port")"; }
stop_stub() { kill $PID; wait $PID 2>/dev/null; }
reqs() { ls "$STUB" | grep -c '^req' ; }
run() { echo; echo "\$ $*"; "$@"; echo "[exit $?]"; }

echo "=== S1 snapshot ==="
bin/fm-today-bridge.sh snapshot > "$EV/snapshot.json" 2> "$EV/snapshot.stderr"; echo "[exit $?]"
echo "stderr:"; cat "$EV/snapshot.stderr"
python3 tests/fm-today-contract-check.py check docs/today-contract "$EV/snapshot.json"; echo "[checker exit $?]"
jq '{calls: [.sections.calls[] | {task_id, title, verdict: .text_check.verdict}], underway: [.sections.underway[]? | {task_id: (.task_id // .id), title}], charted_next: [.sections.charted_next[]? | (.task_id // .id)], landed: [.sections.landed[]? | (.task_id // .id)], supervision: .sections.health.supervision, day: .sections.day}' "$EV/snapshot.json"
echo "leak grep (Smith|tuition|jo.smith|Juniper|42 ):"; grep -Eio 'smith|tuition|jo\.smith|juniper|"42 ' "$EV/snapshot.json" || echo "none"

echo; echo "=== S2 push --dry-run ==="
run bin/fm-today-bridge.sh push --dry-run "$EV/dryrun.json"
echo "dry-run file bytes: $(wc -c < "$EV/dryrun.json")"

echo; echo "=== S3 push to loopback stub (200) ==="
start_stub 200
FM_TODAY_PORTAL_URL=$URL FM_TODAY_BRIDGE_TOKEN=$TOKEN bin/fm-today-bridge.sh push > "$LAB/o" 2> "$LAB/e"; echo "[exit $?]"; echo "stdout: $(cat "$LAB/o")"; echo "stderr: $(cat "$LAB/e")"
jq -r '"path=\(.path) type=\(.type) auth_is_bearer_token=\(.auth == ("Bearer " + env.TOKEN))"' "$STUB/req-0.json" 2>/dev/null || TOKEN=$TOKEN jq -r '"path=\(.path) type=\(.type) auth_is_bearer_token=\(.auth == ("Bearer " + env.TOKEN))"' "$STUB/req-0.json"
jq -r .body "$STUB/req-0.json" > "$EV/received-body.json"; python3 tests/fm-today-contract-check.py check docs/today-contract "$EV/received-body.json"; echo "[checker on received body exit $?]"
echo "token in any output? $(grep -c "$TOKEN" "$LAB/o" "$LAB/e" | paste -sd' ' -)"
stop_stub

echo; echo "=== S4 push from home .env ==="
start_stub 200
printf 'FM_TODAY_PORTAL_URL=%s\nFM_TODAY_BRIDGE_TOKEN=%s\n' "$URL" "$TOKEN" > "$LAB/.env"
run bin/fm-today-bridge.sh push
echo "requests received: $(reqs)"; rm -f "$LAB/.env"; stop_stub

echo; echo "=== S5 portal answers 400 ==="
rm -f "$STUB"/req*; start_stub 400
FM_TODAY_PORTAL_URL=$URL FM_TODAY_BRIDGE_TOKEN=$TOKEN bin/fm-today-bridge.sh push; echo "[exit $?]"
stop_stub

echo; echo "=== S6 adversarial: non-loopback http and other schemes send nothing ==="
rm -f "$STUB"/req*; start_stub 200
for u in "http://127.0.0.1@evil.example" "http://localhost:80@evil.example/x" "http://127.0.0.1#@evil.example" "http://portal.example" "http://127.0.0.1.evil.example:1" "ftp://127.0.0.1" "http://localhost.evil.example" "http://user@evil.example"; do
  FM_TODAY_PORTAL_URL=$u FM_TODAY_BRIDGE_TOKEN=$TOKEN bin/fm-today-bridge.sh push; echo "[exit $? for $u]"
done
echo "requests received by stub: $(reqs)"
stop_stub

echo; echo "=== S7 missing token / URL ==="
FM_TODAY_PORTAL_URL=https://portal.example bin/fm-today-bridge.sh push; echo "[exit $?]"
FM_TODAY_BRIDGE_TOKEN=$TOKEN bin/fm-today-bridge.sh push; echo "[exit $?]"

echo; echo "=== S8 stale day file -> empty day for today ==="
sed "s/\"date\":\"$TODAY\"/\"date\":\"2001-01-01\"/" "$LAB/day.json" > "$LAB/stale.json"
FM_TODAY_DAY_FILE=$LAB/stale.json bin/fm-today-bridge.sh snapshot 2>/dev/null | jq -c .sections.day
FM_TODAY_DAY_FILE=$LAB/nope.json bin/fm-today-bridge.sh snapshot 2>/dev/null | jq -c .sections.day

echo; echo "=== S9 nothing listens ==="
echo "listening sockets owned by bridge during snapshot: none expected"; (bin/fm-today-bridge.sh snapshot >/dev/null 2>&1 & p=$!; sleep 0.3; lsof -a -p $p -iTCP -sTCP:LISTEN 2>/dev/null | wc -l; wait $p)

rm -rf "$LAB"; echo; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
