#!/usr/bin/env bash
# Manual live drive of bin/fm-today-bridge.sh in a disposable lab home with a loopback stub portal.
set -u
W=$1; E=$2
cd "$W"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TODAY_PORTAL_URL FM_TODAY_BRIDGE_TOKEN
export FM_HOME=$LAB LAVISH_AXI_STATE_DIR=$LAB/lavish
TODAY=$(date +%Y-%m-%d); OFF=$(date +%z | sed 's/\(..\)$/:\1/')
cat > $LAB/data/backlog.md <<EOF
## In flight
- [ ] ship-task - Ship the Today bridge (repo: firstmate) (kind: ship) (since 2026-09-20)

## Queued
- [ ] next-up - Wire the portal answers back (repo: firstmate) (kind: ship)
- [ ] call-clean - Choose the rail order (kind: captain) (hold: pick one of two orders) (hold-kind: captain)
- [ ] call-fee - Approve the refund of \$450 for the term (kind: captain) (hold: approve or not) (hold-kind: captain)
- [ ] call-family - Tell the guardian about the schedule change (kind: captain) (hold: tell or not) (hold-kind: captain)
- [ ] call-email - Reply to jo.smith@example.org today (kind: captain) (hold: send it or not) (hold-kind: captain)
- [ ] call-cut-phone - Ring the suppliers (kind: captain) (hold: call the front desk at the hq office after lunch and ask for +1 555 123 4567) (hold-kind: captain)
- [ ] call-noted - Confirm the order and write to jo.smith@example.org (kind: captain) (hold: send it or not) (hold-kind: captain) (hold-due: 2026-10-01)

## Done
- [x] done-a - Landed contract docs https://github.com/acme/widget/pull/9 (repo: firstmate) (kind: ship) (merged 2026-09-27)
EOF
cat > $LAB/state/ship-task.meta <<EOF
window=firstmate:fm-ship-task
worktree=$LAB/projects
project=firstmate
harness=claude
kind=ship
mode=no-mistakes
EOF
printf 'working: building the bridge\n' > $LAB/state/ship-task.status
cat > $LAB/day.json <<EOF
{"date":"$TODAY","ends_at":"${TODAY}T23:59:59$OFF","fetched_at":"x","blocks":[
 {"id":"b1","title":"Portal review\nwith team","starts_at":"${TODAY}T09:00:00$OFF","ends_at":"${TODAY}T10:00:00$OFF"},
 {"id":"b2","title":"Focus block","starts_at":"${TODAY}T13:00:00$OFF","ends_at":"${TODAY}T15:00:00$OFF"},
 {"id":"","title":"bad id","starts_at":"x","ends_at":"y"}]}
EOF
export FM_TODAY_DAY_FILE=$LAB/day.json
say() { printf '\n$ %s\n' "$*"; }

say "fm-today-bridge.sh snapshot  (lab home)"
bin/fm-today-bridge.sh snapshot > $E/snapshot.json 2> $E/snapshot.err; echo "exit=$?"
echo "--- stderr:"; cat $E/snapshot.err
echo "--- reference checker:"; python3 tests/fm-today-contract-check.py check docs/today-contract $E/snapshot.json 2>&1 || python3 tests/fm-today-contract-check.py --help 2>&1 | head -5
echo "--- calls (task_id, verdict, title, summary):"
jq -r '.calls[] | [.task_id, .text_check.verdict, .title, (.summary//"")] | @tsv' $E/snapshot.json
echo "--- underway / charted_next / landed:"
jq -c '{underway:[.underway[]|{task_id,title,doing}],charted_next:[.charted_next[]|.task_id],landed:[.landed[]|.task_id],health}' $E/snapshot.json
echo "--- day:"; jq -c '.day' $E/snapshot.json
echo "--- leak scan of snapshot for private text:"
for p in 'jo.smith' 'example.org' '450' 'guardian' '555' '4567'; do grep -q -- "$p" $E/snapshot.json && echo "LEAK $p" || echo "absent: $p"; done

# stub portal on loopback
SD=$LAB/stub; mkdir -p $SD
STUB_DIR=$SD python3 - <<'PY' &
import http.server, json, os
d=os.environ["STUB_DIR"]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b=self.rfile.read(int(self.headers.get("Content-Length",0)))
        n=len([f for f in os.listdir(d) if f.startswith("req")])
        json.dump({"path":self.path,"auth":self.headers.get("Authorization"),"type":self.headers.get("Content-Type"),"body":b.decode()},open(os.path.join(d,"req-%d.json"%n),"w"))
        st=int(open(os.path.join(d,"status")).read()) if os.path.exists(os.path.join(d,"status")) else 200
        out=json.dumps({"heard_at":"2026-09-28T19:00:00Z"} if st==200 else {"code":"bad_snapshot","message":"refused","request_id":"r1"}).encode()
        self.send_response(st); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self,*a): pass
s=http.server.HTTPServer(("127.0.0.1",0),H); open(os.path.join(d,"port"),"w").write(str(s.server_address[1])); s.serve_forever()
PY
SP=$!; for i in $(seq 50); do [ -s $SD/port ] && break; sleep 0.1; done
URL=http://127.0.0.1:$(cat $SD/port)
TOK="tok-live-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
nreq() { ls $SD | grep -c '^req' ; }

say "push via home .env (URL + token in \$FM_HOME/.env)"
printf 'FM_TODAY_PORTAL_URL=%s\nFM_TODAY_BRIDGE_TOKEN=%s\n' "$URL" "$TOK" > $LAB/.env
bin/fm-today-bridge.sh push 2>&1 | tee $E/push.out; echo "exit=${PIPESTATUS[0]} requests=$(nreq)"
jq -r '"path=\(.path) type=\(.type) auth_is_bearer_token=\(.auth=="Bearer '"$TOK"'")"' $SD/req-0.json
jq -r '.body' $SD/req-0.json > $E/pushed-body.json
python3 tests/fm-today-contract-check.py check docs/today-contract $E/pushed-body.json && echo "pushed body passes reference checker"
rm $LAB/.env

say "push with portal answering 400"
echo 400 > $SD/status
FM_TODAY_PORTAL_URL=$URL FM_TODAY_BRIDGE_TOKEN=$TOK bin/fm-today-bridge.sh push; echo "exit=$?"
rm $SD/status

say "push with missing token"
before=$(nreq); FM_TODAY_PORTAL_URL=$URL bin/fm-today-bridge.sh push; echo "exit=$? new_requests=$(( $(nreq)-before ))"

say "push to plain http off loopback (http://example.com)"
FM_TODAY_PORTAL_URL=http://example.com FM_TODAY_BRIDGE_TOKEN=$TOK bin/fm-today-bridge.sh push; echo "exit=$?"
say "push to http://127.0.0.1.evil.example (loopback lookalike)"
FM_TODAY_PORTAL_URL=http://127.0.0.1.evil.example FM_TODAY_BRIDGE_TOKEN=$TOK bin/fm-today-bridge.sh push; echo "exit=$?"
say "push to http://localhost@evil.example (userinfo trick)"
FM_TODAY_PORTAL_URL=http://localhost@evil.example FM_TODAY_BRIDGE_TOKEN=$TOK bin/fm-today-bridge.sh push; echo "exit=$?"

say "push --from (removed option)"
before=$(nreq); FM_TODAY_PORTAL_URL=$URL FM_TODAY_BRIDGE_TOKEN=$TOK bin/fm-today-bridge.sh push --from $E/snapshot.json; echo "exit=$? new_requests=$(( $(nreq)-before ))"

say "push --dry-run out.json (no URL/token)"
before=$(nreq); bin/fm-today-bridge.sh push --dry-run $LAB/dry.json; echo "exit=$? new_requests=$(( $(nreq)-before )) wrote=$(test -s $LAB/dry.json && echo yes)"

say "stale day file (yesterday) -> empty day for today"
jq --arg d 2000-01-01 '.date=$d' $LAB/day.json > $LAB/day-old.json
FM_TODAY_DAY_FILE=$LAB/day-old.json bin/fm-today-bridge.sh snapshot 2>/dev/null | jq -c '.day'

say "token leak scan across all outputs and pushed body"
grep -rl -- "$TOK" $E 2>/dev/null && echo "TOKEN LEAKED" || echo "token absent from every evidence file"

kill $SP; wait $SP 2>/dev/null
rm -rf "$LAB"; echo "lab removed: $(test -e $LAB && echo no || echo yes)"
