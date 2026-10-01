#!/usr/bin/env bash
# Manual F3 evidence drive: runs the REAL bin/fm-today-bridge.sh (the product)
# end-to-end against a fixture home, a local python http.server stub portal, a
# stub gh forge, and the REAL verifier (bin/fm-today-passkey-verify.py) fed by
# the software authenticator's ES256 signatures. Captures reviewer-visible
# artifacts into the companion evidence dir.
set -u
EVID=./f3-artifacts
mkdir -p "$EVID"
. tests/lib.sh

TMP_ROOT=$(fm_test_tmproot f3-drive)
TOKEN="tok-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
export TZ=UTC
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish"
unset FM_TODAY_PORTAL_URL FM_TODAY_BRIDGE_TOKEN FM_TODAY_DAY_FILE
PASSKEY_ORIGIN=https://relay-api.mmeg.us
PR9=https://github.com/acme/widget/pull/9
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

export FM_TEST_GH_DIR="$TMP_ROOT/gh"
mkdir -p "$TMP_ROOT/fakebin" "$FM_TEST_GH_DIR"
printf '%s\n' "$HEAD_A" > "$FM_TEST_GH_DIR/head-9"
printf '%s\n' "$HEAD_A" > "$FM_TEST_GH_DIR/merge-head-9"
cat > "$TMP_ROOT/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_DIR/gh.log"
case "$1 $2" in
  "pr view")
    case "$*" in
      *isInMergeQueue*) cat "$FM_TEST_GH_DIR/state-${3##*/}" 2>/dev/null || echo "OPEN false" ;;
      *) cat "$FM_TEST_GH_DIR/head-${3##*/}" 2>/dev/null ;;
    esac ;;
  "pr comment") exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP_ROOT/fakebin/gh"
export PATH="$TMP_ROOT/fakebin:$PATH"

# real fm-pr-merge.sh does the head binding; but to observe the exact head_sha
# the bridge hands it, use a recorder that also logs args (head moved => exit 3
# is still the REAL script's behaviour; here we observe the passed head).
mkdir -p "$TMP_ROOT/tree"
cp -R "$ROOT/bin" "$TMP_ROOT/tree/bin"
mkdir -p "$TMP_ROOT/tree/tests" "$TMP_ROOT/tree/docs"
cp "$ROOT/tests/fm-today-contract-check.py" "$TMP_ROOT/tree/tests/" 2>/dev/null || true
cp -R "$ROOT/docs/today-contract" "$TMP_ROOT/tree/docs/today-contract"
cat > "$TMP_ROOT/tree/bin/fm-pr-merge.sh" <<'EOF'
#!/usr/bin/env bash
printf 'MERGE %s\n' "$*" >> "$FM_TEST_GH_DIR/merge.log"
live=$(cat "$FM_TEST_GH_DIR/merge-head-${2##*/}" 2>/dev/null || cat "$FM_TEST_GH_DIR/head-${2##*/}")
if [ "$3" != --head-sha ] || [ "$4" != "$live" ]; then
  echo "error: refusing to merge $2: head moved: the live head is $live, not the signed head $4" >&2
  exit 3
fi
echo "verified: $2 is merged"
EOF
chmod +x "$TMP_ROOT/tree/bin/fm-pr-merge.sh"

# fixed bearings snapshot proclaiming merge + go + cred calls
cat > "$TMP_ROOT/tree/bin/fm-bearings-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"home": "firstmate",
 "decisions_open": [
  {"id": "m-fix", "key": "m-fix", "verb": "captain-hold", "summary": "Merge the widget fix", "owner": "(main)",
   "task_kind": "ship", "call": {"kind": "merge", "pr_url": "https://github.com/acme/widget/pull/9"}},
  {"id": "g-build", "key": "g-build", "verb": "captain-hold", "summary": "Build the kit page", "owner": "(main)",
   "task_kind": "captain", "call": {"kind": "go"}}],
 "in_flight": [], "gates": [], "landed": []}
JSON
EOF
chmod +x "$TMP_ROOT/tree/bin/fm-bearings-snapshot.sh"

home="$TMP_ROOT/home"
mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] m-fix - Widget fix (repo: firstmate) (kind: ship) (since 2026-09-20) (hold: merge it) (hold-kind: captain)
  Captain hold set: 2026-09-20T00:00:00Z
  Captain hold call: {"kind":"merge","pr_url":"https://github.com/acme/widget/pull/9"}

## Queued
- [ ] g-build - Build the kit page (kind: captain) (hold: go or not) (hold-kind: captain)
  Captain hold set: 2026-09-20T00:00:00Z
  Captain hold call: {"kind":"go"}

## Done
EOF
FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" bind today-bridge >/dev/null

# enrol one passkey (iPhone) in the store; head content hash bank
AUTH=(python3 "$ROOT/tests/fm-today-soft-authenticator.py")
SIGN_KEYS="$TMP_ROOT/sign-keys"
mkdir -p "$SIGN_KEYS"
"${AUTH[@]}" keygen "$SIGN_KEYS/phone.pem" es256 > "$SIGN_KEYS/phone.json"
python3 - "$SIGN_KEYS/phone.json" <<'PY'
import base64, json, sys, textwrap
cred = json.load(open(sys.argv[1]))
der = base64.urlsafe_b64decode(cred["public_key_spki"] + "=" * (-len(cred["public_key_spki"]) % 4))
pem = "-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n" % "\n".join(
    textwrap.wrap(base64.b64encode(der).decode("ascii"), 64))
entry = {"credential_id": cred["credential_id"], "public_key_pem": pem, "alg": cred["alg"],
         "rp_id": "relay-api.mmeg.us", "origin": "https://relay-api.mmeg.us",
         "label": "iPhone passkey", "enrolled_at": "2026-09-28T12:00:00Z",
         "enrolled_via": "portal", "backup_eligible": True, "sign_count": 0,
         "status": "active", "revoked_at": None}
json.dump({"credentials": [entry]}, open(sys.argv[2] if len(sys.argv) > 2 else "/dev/stdout", "w"))
PY
# write store
python3 - "$SIGN_KEYS/phone.json" "$home/config/today-passkeys.json" <<'PY'
import base64, json, sys, textwrap
cred = json.load(open(sys.argv[1]))
der = base64.urlsafe_b64decode(cred["public_key_spki"] + "=" * (-len(cred["public_key_spki"]) % 4))
pem = "-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n" % "\n".join(
    textwrap.wrap(base64.b64encode(der).decode("ascii"), 64))
entry = {"credential_id": cred["credential_id"], "public_key_pem": pem, "alg": cred["alg"],
         "rp_id": "relay-api.mmeg.us", "origin": "https://relay-api.mmeg.us",
         "label": "iPhone passkey", "enrolled_at": "2026-09-28T12:00:00Z",
         "enrolled_via": "portal", "backup_eligible": True, "sign_count": 0,
         "status": "active", "revoked_at": None}
json.dump({"credentials": [entry]}, open(sys.argv[2], "w"))
PY

# ---- SCENARIO 1: cards carry head_sha / subject_sha256 + proof nonce + passkeys block
FM_HOME="$home" FM_TODAY_PORTAL_URL= FM_TODAY_BRIDGE_TOKEN="$TOKEN" \
  "$TMP_ROOT/tree/bin/fm-today-bridge.sh" snapshot 2>"$EVID/snap.err" > "$EVID/snapshot-1.json"
echo "== SCENARIO 1: signed cards carry head_sha / subject_sha256 + proof nonce + proof.expires_at ==" > "$EVID/scenario-1.txt"
jq -c '.sections.calls[] | {task_id, kind, head_sha, subject_sha256, proof, pr_url}' "$EVID/snapshot-1.json" >> "$EVID/scenario-1.txt"
echo "--- passkeys block ---" >> "$EVID/scenario-1.txt"
jq -c '.passkeys' "$EVID/snapshot-1.json" >> "$EVID/scenario-1.txt"
NONCE_M=$(jq -r '.sections.calls[] | select(.task_id=="m-fix") | .proof.nonce' "$EVID/snapshot-1.json")
HASH_M=$(jq -r --arg t m-fix '.sections.calls[] | select(.task_id==$t) | .card_hash' "$EVID/snapshot-1.json")
HASH_G=$(jq -r --arg t g-build '.sections.calls[] | select(.task_id==$t) | .card_hash' "$EVID/snapshot-1.json")

# ---- SCENARIO 1b: unexpired nonce is reused (not re-minted) on a re-snapshot
FM_HOME="$home" "$TMP_ROOT/tree/bin/fm-today-bridge.sh" snapshot 2>/dev/null > "$EVID/snapshot-2.json"
NONCE_M2=$(jq -r '.sections.calls[] | select(.task_id=="m-fix") | .proof.nonce' "$EVID/snapshot-2.json")
echo "re-snapshot nonce identical (no re-mint while unexpired, same raising): [$NONCE_M] vs [$NONCE_M2]" >> "$EVID/scenario-1.txt"

# ---- SCENARIO 2: verify-then-release; signed merge binds head, PR comment + announce
# start portal + sign two answers
PORTAL="$TMP_ROOT/portal"
mkdir -p "$PORTAL"
PORTAL_DIR=$PORTAL python3 - <<'PY' &
import http.server, json, os, time
d = os.environ["PORTAL_DIR"]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = len([f for f in os.listdir(d) if f.startswith("req-")])
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(os.path.join(d, "req-%d.json" % n), "w") as fh:
            json.dump({"path": self.path, "auth": self.headers.get("Authorization"), "body": json.loads(body)}, fh)
        with open(os.path.join(d, "receipts.jsonl"), "a") as fh:
            for r in json.loads(body)["receipts"]: fh.write(json.dumps(r) + "\n")
        closed = set()
        try:
            with open(os.path.join(d, "receipts.jsonl")) as fh:
                closed = {json.loads(l)["answer_id"] for l in fh if l.strip()}
        except OSError: closed = set()
        try:
            with open(os.path.join(d, "answers.json")) as fh: answers = json.load(fh)
        except (OSError, ValueError): answers = []
        out = {"answers": [a for a in answers if a["answer_id"] not in closed]}
        data = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(d,"port.tmp"),"w").write(str(srv.server_address[1]))
os.rename(os.path.join(d,"port.tmp"), os.path.join(d,"port"))
srv.serve_forever()
PY
PORTAL_PID=$!
i=0; while [ ! -s "$PORTAL/port" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done
PORT_URL="http://127.0.0.1:$(cat "$PORTAL/port")"

signed_one() { # <pem> <id> <task> <kind> <value> <hash>
  local f="$TMP_ROOT/s.$2"
  jq -nc --arg id "$2" --arg t "$3" --arg k "$4" --arg v "$5" --arg h "$6" \
    '{schema:"fm-today-answer.v1", answer_id:$id, task_id:$t, kind:$k, value:$v, card_hash:$h,
      owner:"(main)", answered_at:"2026-09-30T01:00:00Z", person:"captain", device:"phone-1"}' > "$f.unsigned"
  "${AUTH[@]}" assert "$SIGN_KEYS/$1.pem" "$(jq -r .credential_id "$SIGN_KEYS/$1.json")" \
    relay-api.mmeg.us "$PASSKEY_ORIGIN" "$f.unsigned" > "$f"
  jq -c . "$f"
}
signed_one phone ans_sm_000001 m-fix merge merge "$HASH_M" > "$PORTAL/a1.json"
signed_one phone ans_sg_000001 g-build go go "$HASH_G" > "$PORTAL/a2.json"
jq -s . "$PORTAL/a1.json" "$PORTAL/a2.json" > "$PORTAL/answers.json"

FM_HOME="$home" FM_TODAY_PORTAL_URL="$PORT_URL" FM_TODAY_BRIDGE_TOKEN="$TOKEN" \
  "$TMP_ROOT/tree/bin/fm-today-bridge.sh" answers once 2>"$EVID/answers.err" > "$EVID/answers.out"
echo "== SCENARIO 2: verify-then-release, signed merge binds head, PR comment + chat line ==" > "$EVID/scenario-2.txt"
echo "--- answer receipts (announce/chat lines + actions) ---" >> "$EVID/scenario-2.txt"
sed -n 's/^answer-json: //p' "$EVID/answers.out" | jq -c '{answer_id, outcome, action, announce}' >> "$EVID/scenario-2.txt"
echo "--- release words recorded on the hold (data/backlog.md) ---" >> "$EVID/scenario-2.txt"
grep 'signed with passkey' "$home/data/backlog.md" >> "$EVID/scenario-2.txt"
echo "--- head_sha handed to fm-pr-merge.sh ---" >> "$EVID/scenario-2.txt"
cat "$FM_TEST_GH_DIR/merge.log" >> "$EVID/scenario-2.txt"
echo "--- PR comment posted (gh.log) ---" >> "$EVID/scenario-2.txt"
grep '^pr comment ' "$FM_TEST_GH_DIR/gh.log" >> "$EVID/scenario-2.txt"
echo "--- nonce on the re-snapshot after the verified merge (proves re-mint) ---" >> "$EVID/scenario-2.txt"
FM_HOME="$home" "$TMP_ROOT/tree/bin/fm-today-bridge.sh" snapshot 2>/dev/null > "$EVID/snapshot-3.json"
NONCE_AFTER=$(jq -r '.sections.calls[] | select(.task_id=="m-fix") | .proof.nonce // "(no card)"' "$EVID/snapshot-3.json" 2>/dev/null)
echo "pre-merge nonce [$NONCE_M]; after verified merge [$NONCE_AFTER]" >> "$EVID/scenario-2.txt"

# ---- SCENARIO 3: moved head refuses and re-raises with new head + new nonce
: > "$FM_TEST_GH_DIR/merge.log"; : > "$FM_TEST_GH_DIR/gh.log"
FM_HOME="$home" FM_TODAY_PORTAL_URL= FM_TODAY_BRIDGE_TOKEN="$TOKEN" \
  "$TMP_ROOT/tree/bin/fm-today-bridge.sh" snapshot 2>/dev/null > "$EVID/snapshot-4.json"
HASH_M=$(jq -r --arg t m-fix '.sections.calls[] | select(.task_id==$t) | .card_hash' "$EVID/snapshot-4.json")
NONCE_PRE=$(jq -r --arg t m-fix '.sections.calls[] | select(.task_id==$t) | .proof.nonce' "$EVID/snapshot-4.json")
# move the live head so the signed head no longer matches
printf '%s\n' "$HEAD_B" > "$FM_TEST_GH_DIR/head-9"
printf '%s\n' "$HEAD_B" > "$FM_TEST_GH_DIR/merge-head-9"
signed_one phone ans_smv_0001 m-fix merge merge "$HASH_M" > "$PORTAL/answers.json"
: > "$PORTAL/receipts.jsonl"
FM_HOME="$home" FM_TODAY_PORTAL_URL="$PORT_URL" FM_TODAY_BRIDGE_TOKEN="$TOKEN" \
  "$TMP_ROOT/tree/bin/fm-today-bridge.sh" answers once 2>"$EVID/moved.err" > "$EVID/moved.out"
echo "== SCENARIO 3: a signed merge whose head moved refuses, never merges, and re-raises with the new head + new nonce ==" > "$EVID/scenario-3.txt"
sed -n 's/^answer-json: //p' "$EVID/moved.out" | jq -c '{answer_id, outcome, action, reason}' >> "$EVID/scenario-3.txt"
echo "merge.log: $(wc -l < "$FM_TEST_GH_DIR/merge.log" | tr -d ' ') merge calls; gh.log comments: $(grep -c '^pr comment ' "$FM_TEST_GH_DIR/gh.log" | tr -d ' ')" >> "$EVID/scenario-3.txt"
FM_HOME="$home" "$TMP_ROOT/tree/bin/fm-today-bridge.sh" snapshot 2>/dev/null > "$EVID/snapshot-5.json"
echo "--- re-raised card ---" >> "$EVID/scenario-3.txt"
jq -c '.sections.calls[] | select(.task_id=="m-fix") | {kind, head_sha, proof}' "$EVID/snapshot-5.json" >> "$EVID/scenario-3.txt"
NONCE_NEW=$(jq -r --arg t m-fix '.sections.calls[] | select(.task_id==$t) | .proof.nonce' "$EVID/snapshot-5.json")
echo "pre nonce [$NONCE_PRE]; re-raised nonce [$NONCE_NEW]; re-raised head_sha should be $HEAD_B" >> "$EVID/scenario-3.txt"

kill "$PORTAL_PID" 2>/dev/null; wait "$PORTAL_PID" 2>/dev/null || true
echo DONE
