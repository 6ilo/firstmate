#!/usr/bin/env bash
# Manual live-drive of bin/fm-today-notes.sh against a real local HTTP stub of
# the admin-portal POST /api/fleet/notes. Produces reviewer-visible evidence of
# the D34/D35 note + dispatch-order relay behaviour the change ships.
set -u
ROOT=/Users/anwulikaanigbodesktop/.no-mistakes/worktrees/ba7143190a89/01M3VJ82EXHV9VB4G7D01HTFV1
EVID=/Users/anwulikaanigbodesktop/.no-mistakes/evidence/01M3VJ82EXHV9VB4G7D01HTFV1
NOTES="$ROOT/bin/fm-today-notes.sh"
CONTRACT="$ROOT/docs/today-contract"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME="$TMP/home"
mkdir -p "$HOME/state" "$HOME/data" "$HOME/projects" "$HOME/config"
cat > "$HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship the thing (repo: firstmate) (kind: ship) (since 2026-09-20)

## Queued
- [ ] alpha - First charted work (repo: firstmate) (kind: ship)
- [ ] bravo - Second charted work (repo: firstmate) (kind: ship)
- [ ] charlie - Third charted work (repo: firstmate) (kind: ship)

## Done
EOF
TOKEN="tok-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"

mkdir -p "$TMP/stub/requests"
printf '[]\n' > "$TMP/stub/queue.json"
STUB_DIR="$TMP/stub" python3 - <<'PY' &
import http.server, json, os
d = os.environ["STUB_DIR"]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = len(os.listdir(os.path.join(d, "requests")))
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8")
        recv = json.loads(body).get("receipts", [])
        with open(os.path.join(d, "requests", "req-%03d.json" % n), "w") as fh:
            json.dump({"path": self.path, "auth": self.headers.get("Authorization"), "body": body, "receipts": recv}, fh)
        done = os.path.join(d, "receipted.json")
        seen = json.load(open(done)) if os.path.exists(done) else {}
        # mirror the portal: refs with a recorded receipt are dropped (words gone)
        for r in recv:
            seen.setdefault(r["ref"], r)
        json.dump(seen, open(done, "w"))
        queue = [q for q in json.load(open(os.path.join(d, "queue.json"))) if
                 (q.get("note_id") or q.get("order_id")) not in seen]
        out = {"notes": [q for q in queue if "note_id" in q],
               "dispatch_orders": [q for q in queue if "order_id" in q]}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(d, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
STUB_PID=$!
i=0
while [ ! -s "$TMP/stub/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
STUB_URL="http://127.0.0.1:$(cat "$TMP/stub/port")"

export FM_HOME="$HOME"
export FM_TODAY_PORTAL_URL="$STUB_URL"
export FM_TODAY_BRIDGE_TOKEN="$TOKEN"

jq -n '{schema:"fm-today-note.v1",
  note_id:"note_0ld40LmV2aWRlbmNlTn902",
  authority:"none",
  text:"This round of numbers and words stay on my machine.",
  written_at:"2026-09-30T10:00:00Z", person:"a", device:"d"}' > "$TMP/note.json"
jq -n '{schema:"fm-today-dispatch-order.v1",
  order_id:"dord_0ld40l2lzUGF0Y2hPcmRlc",
  authority:"proposal",
  items:[{task_id:"bravo"},{task_id:"alpha"},{task_id:"doomed"}],
  charted_as_of:"2026-09-30T10:00:00Z", queued_at:"2026-09-30T10:01:00Z",
  person:"a", device:"d"}' > "$TMP/order.json"
jq -s '.' "$TMP/note.json" "$TMP/order.json" > "$TMP/stub/queue.json"
cp "$TMP/note.json" "$TMP/stub/queue-note-unsent.json"

before=$(cat "$HOME/data/backlog.md")
FM_HOME="$HOME" "$NOTES" collect --wait 3 > "$EVID/collect.transcript.txt" 2>&1
echo "collect_exit=$?" >> "$EVID/collect.transcript.txt"

NOTE_ID=$(jq -r .note_id "$TMP/note.json")
ORD_ID=$(jq -r .order_id "$TMP/order.json")
cp "$HOME/data/today-notes/$NOTE_ID.json" "$EVID/note-record.json"
cp "$HOME/data/today-notes/$ORD_ID.json" "$EVID/order-record.json"
if [ "$(cat "$HOME/data/backlog.md")" = "$before" ]; then BU=yes; else BU=no; fi
printf '%s\n' "backlog_unchanged=$BU" > "$EVID/backlog.invariant.txt"
if [ -z "$(ls "$HOME/state" 2>/dev/null | grep '\.meta' || true)" ]; then NM=yes; else NM=no; fi
printf '%s\n' "no_meta_files=$NM" >> "$EVID/backlog.invariant.txt"
echo "portal_receipts:" >> "$EVID/portal-receipts.jsonl"
jq -c '.[]' "$TMP/stub/receipted.json" >> "$EVID/portal-receipts.jsonl"
echo "recorded_note_receipt:" >> "$EVID/portal-receipts.jsonl"
jq -c --arg r "$NOTE_ID" '.[$r]' "$TMP/stub/receipted.json" >> "$EVID/portal-receipts.jsonl"

echo "=== plan after dispatch order ===" > "$EVID/plan.after.txt"
FM_HOME="$HOME" "$ROOT/bin/fm-backlog-plan.sh" list >> "$EVID/plan.after.txt" 2>&1

echo "=== show note record + words ===" > "$EVID/show.note.txt"
FM_HOME="$HOME" "$NOTES" show "$NOTE_ID" >> "$EVID/show.note.txt" 2>&1

# Redelivery: portal lost the receipt -> firstmate replays recorded, never re-wakes.
rm -f "$TMP/stub/receipted.json"
FM_HOME="$HOME" "$NOTES" collect > "$EVID/redelivery.transcript.txt" 2>&1
rc=$?
n=$(wc -l < "$EVID/redelivery.transcript.txt")
echo "redelivery_exit=$rc lines=$n" >> "$EVID/redelivery.transcript.txt"

kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null || true
echo done

