#!/usr/bin/env bash
# Behavior tests for bin/fm-today-notes.sh, the Today notes and dispatch order
# intake (docs/today-contract.md). The seams are the script's own commands over
# a fixture home, and a local stub portal (python3 http.server) standing in for
# POST /api/fleet/notes: it stores every receipt a call carries and answers with
# every note and order that has no receipt yet. Covered: a note is recorded as
# evidence with its text check verdict and its task, and receipted on the very
# next exchange; a note changes no backlog row and reaches no captain inbox; a
# repeat is `duplicate`; a note over 2000 UTF-8 bytes is refused without its
# words leaving; a dispatch order ranks the charted items through the planning
# record, moves earlier ranks after them, leaves out work no longer charted,
# keeps a second mate's items for routing, and starts nothing; an older order
# and one with nothing charted are refused; a receipt survives a failed call;
# a note whose record cannot be written is not receipted, and the rest of its
# answer is still recorded and reported; a note whose receipt cannot be written
# is still reported once and only receipted on redelivery; a retry settled by
# a later exchange of the same collect is not pending; an unreadable
# document wakes the standing check once, not on every poll;
# the standing check reports once and arms, refuses a secondmate home, and
# disarms; the portal's ajv accepts the shapes when a portal checkout is named;
# and the token never reaches output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

NOTES="$ROOT/bin/fm-today-notes.sh"
CONTRACT="$ROOT/docs/today-contract"
CHECK=(python3 "$ROOT/tests/fm-today-contract-check.py" check "$CONTRACT")
TMP_ROOT=$(fm_test_tmproot fm-today-notes)
TOKEN="tok-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish"
unset FM_TODAY_PORTAL_URL FM_TODAY_BRIDGE_TOKEN FM_CHECK_TIMEOUT FM_TODAY_NOTES_WAIT

OUTPUTS="$TMP_ROOT/outputs"
mkdir -p "$OUTPUTS"
run_n=0
notes() {  # <home> <args...>; sets OUT, ERR, CODE
  local home=$1
  shift
  run_n=$((run_n + 1))
  OUT="$OUTPUTS/$run_n.out"
  ERR="$OUTPUTS/$run_n.err"
  CODE=0
  FM_HOME="$home" FM_TODAY_PORTAL_URL=${PORTAL_URL-$STUB_URL} FM_TODAY_BRIDGE_TOKEN=$TOKEN \
    "$NOTES" "$@" > "$OUT" 2> "$ERR" || CODE=$?
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship the thing (repo: firstmate) (kind: ship) (since 2026-09-20)

## Queued
- [ ] alpha - First charted work (repo: firstmate) (kind: ship)
- [ ] bravo - Second charted work (repo: firstmate) (kind: ship)
- [ ] charlie - Third charted work (repo: firstmate) (kind: ship)

## Done
EOF
  printf '%s\n' "$home"
}

# The stub keeps its queue in <dir>/queue.json and answers 200 until
# <dir>/fail-from names a request number, from which it answers 503.
start_stub() {  # <dir>
  local dir=$1 i
  mkdir -p "$dir/requests"
  [ -f "$dir/queue.json" ] || printf '[]\n' > "$dir/queue.json"
  STUB_DIR=$dir python3 - <<'PY' &
import http.server, json, os
d = os.environ["STUB_DIR"]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = len(os.listdir(os.path.join(d, "requests")))
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8")
        with open(os.path.join(d, "requests", "req-%03d.json" % n), "w") as fh:
            json.dump({"path": self.path, "auth": self.headers.get("Authorization"), "body": body}, fh)
        fail_from = os.path.join(d, "fail-from")
        if os.path.exists(fail_from) and n >= int(open(fail_from).read()):
            status, out = 503, {"code": "unavailable", "message": "down", "request_id": "r"}
        else:
            receipted = os.path.join(d, "receipted.json")
            done = json.load(open(receipted)) if os.path.exists(receipted) else {}
            for r in json.loads(body)["receipts"]:
                done.setdefault(r["ref"], r)
            json.dump(done, open(receipted, "w"))
            queue = [q for q in json.load(open(os.path.join(d, "queue.json"))) if
                     (q.get("note_id") or q.get("order_id")) not in done]
            status = 200
            out = {"notes": [q for q in queue if "note_id" in q],
                   "dispatch_orders": [q for q in queue if "order_id" in q]}
        data = json.dumps(out).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port"), "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY
  STUB_PID=$!
  i=0
  while [ ! -s "$dir/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  STUB_URL="http://127.0.0.1:$(cat "$dir/port")"
}

stop_stub() { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null || true; }

queue() {  # <dir> <document.json>...
  local dir=$1
  shift
  mkdir -p "$dir"
  jq -s '.' "$@" > "$dir/queue.json"
}

# A document built from a contract example with fields replaced.
doc() {  # <example> <jq-filter> <out>
  jq "$2" "$CONTRACT/examples/valid/$1.json" > "$3"
}

receipt_for() {  # <stub-dir> <ref>
  jq -c --arg r "$2" '.[$r] // empty' "$1/receipted.json"
}

NOTE_ID=$(jq -r .note_id "$CONTRACT/examples/valid/note.json")

test_note_is_recorded_and_receipted_next_exchange() {
  local home stub=$TMP_ROOT/stub-note rec r last
  home=$(make_home home-note)
  queue "$stub" "$CONTRACT/examples/valid/note.json"
  start_stub "$stub"
  notes "$home" collect --wait 3
  stop_stub
  [ "$CODE" -eq 0 ] || fail "collect exited $CODE: $(cat "$ERR")"
  grep -qF "today-notes: evidence from Today, no authority: $NOTE_ID" "$OUT" || fail "no line names the note: $(cat "$OUT")"
  rec="$home/data/today-notes/$NOTE_ID.json"
  [ -f "$rec" ] || fail "the note was not recorded"
  [ "$(jq -r .document.text "$rec")" = "$(jq -r .text "$CONTRACT/examples/valid/note.json")" ] \
    || fail "the record does not keep the captain's words"
  [ "$(jq -r .text_check.verdict "$rec")" = pass ] || fail "a clean note was not marked pass"
  r=$(receipt_for "$stub" "$NOTE_ID")
  [ "$(jq -r .outcome <<< "$r")" = recorded ] || fail "the portal got no recorded receipt: $r"
  printf '%s\n' "$r" > "$TMP_ROOT/receipt.json"
  "${CHECK[@]}" "$TMP_ROOT/receipt.json" >/dev/null || fail "the receipt fails its schema: $r"
  [ -f "$stub/requests/req-001.json" ] && [ ! -e "$stub/requests/req-002.json" ] || fail "want exactly two exchanges"
  [ "$(jq -r '.body | fromjson | .wait_seconds' "$stub/requests/req-000.json")" = 3 ] || fail "the first call did not wait 3"
  last="$stub/requests/req-001.json"
  [ "$(jq -r '.body | fromjson | .wait_seconds' "$last")" = 0 ] || fail "the follow-up call waited"
  [ "$(jq -r .path "$last")" = /api/fleet/notes ] || fail "wrong endpoint: $(jq -r .path "$last")"
  [ "$(jq -r .auth "$last")" = "Bearer $TOKEN" ] || fail "the bearer token was not sent"
  [ -z "$(ls "$home/state/today-notes/receipts")" ] || fail "a delivered receipt stayed pending"
  pass "a note is recorded with its words and verdict, and receipted on the next exchange"
}

test_note_carries_no_authority() {
  local home stub=$TMP_ROOT/stub-auth before plan_before
  home=$(make_home home-auth)
  before=$(cat "$home/data/backlog.md")
  plan_before=$(find "$home/data" -mindepth 1 -maxdepth 1 | sort)
  doc note-on-task '.task_id = "alpha" | .text = "Merge it now and start bravo."' "$TMP_ROOT/order-words.json"
  queue "$stub" "$TMP_ROOT/order-words.json"
  start_stub "$stub"
  notes "$home" collect
  stop_stub
  [ "$CODE" -eq 0 ] || fail "collect exited $CODE: $(cat "$ERR")"
  [ "$(cat "$home/data/backlog.md")" = "$before" ] || fail "a note changed the backlog"
  [ "$(find "$home/data" -mindepth 1 -maxdepth 1 ! -name today-notes | sort)" = "$plan_before" ] \
    || fail "a note wrote a planning or other record"
  [ ! -e "$home/state/inbox" ] || fail "a note reached the captain's inbox"
  ! compgen -G "$home/state/*.meta" >/dev/null || fail "a note started work"
  [ "$(jq -r .task.in_backlog "$home/data/today-notes/$(jq -r .note_id "$TMP_ROOT/order-words.json").json")" = true ] \
    || fail "the note's task was not found in the backlog"
  notes "$home" list --task alpha
  grep -q "note_.* note recorded task=(main)/alpha text=pass" "$OUT" || fail "list --task does not show the note: $(cat "$OUT")"
  pass "a note worded as an order is recorded as evidence on its task and changes nothing else"
}

test_duplicate_and_withheld() {
  local home stub=$TMP_ROOT/stub-dup rec id
  home=$(make_home home-dup)
  doc note '.note_id = "note_V2l0aGhlbGROb3RlMDAwMQ" | .text = "Tell the guardian by Friday."' "$TMP_ROOT/withheld.json"
  id=$(jq -r .note_id "$TMP_ROOT/withheld.json")
  queue "$stub" "$TMP_ROOT/withheld.json"
  start_stub "$stub"
  notes "$home" collect
  rec=$(cat "$home/data/today-notes/$id.json")
  [ "$(jq -r .text_check.verdict <<< "$rec")" = withheld ] || fail "the tripping note was not marked withheld"
  [ "$(jq -r '.text_check.families | join(",")' <<< "$rec")" = word ] || fail "wrong families: $rec"
  # The portal lost the receipt and delivers again: firstmate answers duplicate.
  rm -f "$stub/receipted.json"
  notes "$home" collect
  stop_stub
  [ "$CODE" -eq 0 ] || fail "collect exited $CODE: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "a duplicate was reported as news: $(cat "$OUT")"
  [ "$(jq -r .outcome <<< "$(receipt_for "$stub" "$id")")" = duplicate ] || fail "the repeat was not answered duplicate"
  [ "$(cat "$home/data/today-notes/$id.json")" = "$rec" ] || fail "the duplicate changed the record"
  ! grep -rqF guardian "$stub/requests" || fail "the note's words were sent back to the portal"
  pass "a tripping note is recorded withheld, a repeat is duplicate, and no words go back"
}

test_oversized_note_is_refused() {
  local home stub=$TMP_ROOT/stub-big id r
  home=$(make_home home-big)
  doc note '.note_id = "note_QmlnTm90ZUZvclJlZnVzZQ" | .text = ("é" * 1001)' "$TMP_ROOT/big.json"
  id=$(jq -r .note_id "$TMP_ROOT/big.json")
  queue "$stub" "$TMP_ROOT/big.json"
  start_stub "$stub"
  notes "$home" collect
  stop_stub
  r=$(receipt_for "$stub" "$id")
  [ "$(jq -r .outcome <<< "$r")" = refused ] || fail "an oversized note was not refused: $r"
  [ "$(jq -r .reason <<< "$r")" = "the note does not match fm-today-note.v1 at \$.text (bytes)" ] \
    || fail "wrong reason: $r"
  grep -qF "$id refused" "$OUT" || fail "the refusal was not reported: $(cat "$OUT")"
  ! grep -rqF 'éé' "$stub/requests" || fail "the note's words were sent back"
  pass "a note over 2000 UTF-8 bytes is refused with its path and rule only"
}

test_dispatch_order_records_ranks_and_starts_nothing() {
  local home stub=$TMP_ROOT/stub-order id rec r plan before
  home=$(make_home home-order)
  FM_HOME="$home" "$ROOT/bin/fm-backlog-plan.sh" set charlie --order 1 >/dev/null || fail "fixture plan"
  before=$(cat "$home/data/backlog.md")
  doc dispatch-order '.items = [{"task_id": "bravo"}, {"task_id": "t11", "owner": "admin-portal"},
    {"task_id": "gone"}, {"task_id": "alpha", "owner": "(main)"}]' "$TMP_ROOT/order.json"
  id=$(jq -r .order_id "$TMP_ROOT/order.json")
  queue "$stub" "$TMP_ROOT/order.json"
  start_stub "$stub"
  notes "$home" collect
  stop_stub
  [ "$CODE" -eq 0 ] || fail "collect exited $CODE: $(cat "$ERR")"
  grep -qF "$id (2 ranked, 1 for a second mate)" "$OUT" || fail "the order was not reported: $(cat "$OUT")"
  plan=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-plan.sh" list)
  [ "$(jq -c '[.bravo.order, .alpha.order, .charlie.order]' <<< "$plan")" = "[1,2,3]" ] \
    || fail "ranks are not bravo 1, alpha 2, charlie moved to 3: $plan"
  rec="$home/data/today-notes/$id.json"
  [ "$(jq -c .left_out "$rec")" = '["gone"]' ] || fail "work no longer charted was not left out"
  [ "$(jq -c .second_mate "$rec")" = '[{"owner":"admin-portal","task_id":"t11","position":2}]' ] \
    || fail "the second mate's item was not kept for routing"
  r=$(receipt_for "$stub" "$id")
  [ "$(jq -r .outcome <<< "$r")" = recorded ] || fail "the order was not receipted recorded: $r"
  jq -r .reason <<< "$r" | grep -q '^1 of 4 items is no longer charted in this home and was left out; 1 belongs to a second mate' \
    || fail "wrong reason: $r"
  [ "$(cat "$home/data/backlog.md")" = "$before" ] || fail "the order changed a backlog row"
  ! compgen -G "$home/state/*.meta" >/dev/null || fail "recording the order started work"
  pass "a dispatch order ranks charted work, moves earlier ranks after it, keeps a second mate's items, and starts nothing"
}

test_older_and_empty_orders_are_refused() {
  local home stub=$TMP_ROOT/stub-older r
  home=$(make_home home-older)
  doc dispatch-order '.items = [{"task_id": "alpha"}]' "$TMP_ROOT/newer.json"
  doc dispatch-order '.order_id = "dord_T2xkZXJPcmRlckZyb21Ubw" | .queued_at = "2026-09-29T14:00:00Z"
    | .items = [{"task_id": "bravo"}]' "$TMP_ROOT/older.json"
  doc dispatch-order '.order_id = "dord_R29uZU9yZGVyRnJvbVRvZA" | .queued_at = "2026-09-29T16:00:00Z"
    | .items = [{"task_id": "gone"}]' "$TMP_ROOT/gone.json"
  queue "$stub" "$TMP_ROOT/newer.json"
  start_stub "$stub"
  notes "$home" collect
  queue "$stub" "$TMP_ROOT/older.json" "$TMP_ROOT/gone.json"
  notes "$home" collect
  stop_stub
  r=$(receipt_for "$stub" "$(jq -r .order_id "$TMP_ROOT/older.json")")
  [ "$(jq -r .reason <<< "$r")" = "an older order than the one already recorded" ] || fail "the older order: $r"
  r=$(receipt_for "$stub" "$(jq -r .order_id "$TMP_ROOT/gone.json")")
  [ "$(jq -r .reason <<< "$r")" = "none of the 1 ordered items is still charted in this home" ] || fail "the empty order: $r"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-backlog-plan.sh" list | jq -c '[.alpha.order, .bravo.order]')" = "[1,null]" ] \
    || fail "a refused order changed a rank"
  pass "an order older than the recorded one, and one with nothing charted, are refused and change nothing"
}

test_receipt_survives_a_failed_call() {
  local home stub=$TMP_ROOT/stub-fail
  home=$(make_home home-fail)
  queue "$stub" "$CONTRACT/examples/valid/note.json"
  printf '1\n' > "$stub/fail-from"
  start_stub "$stub"
  notes "$home" collect
  [ "$CODE" -eq 3 ] || fail "a 503 exited $CODE, want 3"
  grep -q 'the portal answered 503 (unavailable)' "$ERR" || fail "the status was not named: $(cat "$ERR")"
  [ -f "$home/state/today-notes/receipts/$NOTE_ID.json" ] || fail "the undelivered receipt was lost"
  rm -f "$stub/fail-from"
  notes "$home" collect
  stop_stub
  [ "$CODE" -eq 0 ] || fail "the retry exited $CODE: $(cat "$ERR")"
  [ "$(jq -r .outcome <<< "$(receipt_for "$stub" "$NOTE_ID")")" = recorded ] || fail "the pending receipt was not delivered"
  [ -z "$(ls "$home/state/today-notes/receipts")" ] || fail "the delivered receipt stayed pending"
  pass "a receipt stays pending through a failed call and is delivered on the next"
}

test_failed_record_leaves_the_note_unreceipted() {
  local home stub=$TMP_ROOT/stub-norec
  if [ "$(id -u)" = 0 ]; then
    echo "skip - an unwritable record directory: running as root"
    return 0
  fi
  home=$(make_home home-norec)
  mkdir -p "$home/data/today-notes"
  chmod 500 "$home/data/today-notes"
  queue "$stub" "$CONTRACT/examples/valid/note.json"
  start_stub "$stub"
  notes "$home" collect
  chmod 700 "$home/data/today-notes"
  [ "$CODE" -eq 1 ] || fail "a failed record exited $CODE, want 1: $(cat "$ERR")"
  [ -z "$(ls "$home/state/today-notes/receipts")" ] || fail "a receipt was written for a note that was not recorded"
  [ -z "$(receipt_for "$stub" "$NOTE_ID" 2>/dev/null)" ] || fail "the portal was told an unrecorded note was recorded"
  notes "$home" collect
  stop_stub
  [ "$CODE" -eq 0 ] || fail "the retry exited $CODE: $(cat "$ERR")"
  [ -f "$home/data/today-notes/$NOTE_ID.json" ] || fail "the redelivered note was not recorded"
  [ "$(jq -r .outcome <<< "$(receipt_for "$stub" "$NOTE_ID")")" = recorded ] || fail "the redelivered note was not receipted recorded"
  pass "a note whose record cannot be written is not receipted, and is recorded on redelivery"
}

test_failed_record_spares_the_rest_of_the_answer() {
  local home stub=$TMP_ROOT/stub-half bin=$TMP_ROOT/half-bin b r
  if [ "$(id -u)" = 0 ]; then
    echo "skip - an unwritable record directory: running as root"
    return 0
  fi
  home=$(make_home home-half)
  mkdir -p "$home/data/today-notes" "$bin"
  printf '#!/bin/sh\nchmod 500 %q\n' "$home/data/today-notes" > "$bin/tasks-axi"
  chmod +x "$bin/tasks-axi"
  doc note-on-task '.note_id = "note_U2Vjb25kTm90ZUZhaWxzMD" | .task_id = "alpha"' "$TMP_ROOT/second.json"
  b=$(jq -r .note_id "$TMP_ROOT/second.json")
  queue "$stub" "$CONTRACT/examples/valid/note.json" "$TMP_ROOT/second.json"
  start_stub "$stub"
  PATH="$bin:$PATH" notes "$home" collect
  chmod 700 "$home/data/today-notes"
  [ "$CODE" -eq 1 ] || fail "a failed second record exited $CODE, want 1: $(cat "$ERR")"
  grep -qF "today-notes: evidence from Today, no authority: $NOTE_ID" "$OUT" || fail "the first note was not reported: $(cat "$OUT")"
  grep -qF "$b" "$ERR" || fail "the failed note was not named: $(cat "$ERR")"
  ! grep -qF "$b" "$OUT" || fail "the failed note was reported as recorded: $(cat "$OUT")"
  [ -f "$home/data/today-notes/$NOTE_ID.json" ] || fail "the first note was not recorded"
  [ "$(jq -r .outcome <<< "$(receipt_for "$stub" "$NOTE_ID")")" = recorded ] || fail "the first note was not receipted"
  [ ! -e "$home/data/today-notes/$b.json" ] || fail "the failed note has a record"
  [ -z "$(receipt_for "$stub" "$b")" ] || fail "the portal was told the failed note was recorded"
  [ -z "$(ls "$home/state/today-notes/receipts")" ] || fail "a receipt is pending for the failed note"
  notes "$home" collect
  stop_stub
  [ "$CODE" -eq 0 ] || fail "the retry exited $CODE: $(cat "$ERR")"
  r=$(receipt_for "$stub" "$b")
  [ "$(jq -r .outcome <<< "$r")" = recorded ] && [ -f "$home/data/today-notes/$b.json" ] \
    || fail "the redelivered note was not recorded: $r"
  pass "a record that fails leaves that note unreceipted while the rest of the answer is recorded and reported"
}

test_failed_receipt_still_reports_the_record() {
  local home stub=$TMP_ROOT/stub-norcpt bin=$TMP_ROOT/norcpt-bin id
  if [ "$(id -u)" = 0 ]; then
    echo "skip - an unwritable receipt directory: running as root"
    return 0
  fi
  home=$(make_home home-norcpt)
  mkdir -p "$bin"
  printf '#!/bin/sh\nchmod 500 %q\n' "$home/state/today-notes/receipts" > "$bin/tasks-axi"
  chmod +x "$bin/tasks-axi"
  doc note-on-task '.note_id = "note_UmVjZWlwdEZhaWxzTm90ZQ" | .task_id = "alpha"' "$TMP_ROOT/norcpt.json"
  id=$(jq -r .note_id "$TMP_ROOT/norcpt.json")
  queue "$stub" "$TMP_ROOT/norcpt.json"
  start_stub "$stub"
  PATH="$bin:$PATH" notes "$home" collect
  chmod 700 "$home/state/today-notes/receipts"
  [ "$CODE" -eq 1 ] || fail "a failed receipt exited $CODE, want 1: $(cat "$ERR")"
  grep -qF "today-notes: evidence from Today, no authority: $id on alpha" "$OUT" \
    || fail "the recorded note was not reported: $(cat "$OUT")"
  grep -qF "$id (recorded, but its receipt could not be written)" "$ERR" || fail "the receipt failure was not named: $(cat "$ERR")"
  [ -f "$home/data/today-notes/$id.json" ] || fail "the note was not recorded"
  [ -z "$(receipt_for "$stub" "$id" 2>/dev/null)" ] || fail "a receipt reached the portal"
  notes "$home" collect
  stop_stub
  [ "$CODE" -eq 0 ] || fail "the redelivery exited $CODE: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "the redelivered note woke firstmate again: $(cat "$OUT")"
  [ "$(jq -r .outcome <<< "$(receipt_for "$stub" "$id")")" = duplicate ] || fail "the redelivery was not receipted"
  [ -z "$(ls "$home/state/today-notes/receipts")" ] || fail "the redelivery receipt stayed pending"
  pass "a receipt that cannot be written still reports the recorded note once, and redelivery only receipts it"
}

test_retry_settled_later_in_the_collect_is_not_pending() {
  local home stub=$TMP_ROOT/stub-settle bin=$TMP_ROOT/settle-bin b c
  if [ "$(id -u)" = 0 ]; then
    echo "skip - an unwritable record directory: running as root"
    return 0
  fi
  home=$(make_home home-settle)
  mkdir -p "$home/data/today-notes" "$bin"
  printf '#!/bin/sh\nif [ -e %q ]; then chmod 700 %q; else : > %q; chmod 500 %q; fi\n' \
    "$bin/called" "$home/data/today-notes" "$bin/called" "$home/data/today-notes" > "$bin/tasks-axi"
  chmod +x "$bin/tasks-axi"
  doc note-on-task '.note_id = "note_UmV0cmllZFRoZW5SZWNvcm" | .task_id = "alpha"' "$TMP_ROOT/settle-b.json"
  doc note-on-task '.note_id = "note_UmVjb3JkZWRGaXJzdFRpbW" | .task_id = "bravo"' "$TMP_ROOT/settle-c.json"
  b=$(jq -r .note_id "$TMP_ROOT/settle-b.json")
  c=$(jq -r .note_id "$TMP_ROOT/settle-c.json")
  queue "$stub" "$TMP_ROOT/settle-b.json" "$TMP_ROOT/settle-c.json"
  start_stub "$stub"
  PATH="$bin:$PATH" notes "$home" collect
  stop_stub
  chmod 700 "$home/data/today-notes"
  [ "$CODE" -eq 0 ] || fail "a retry settled in the same collect exited $CODE: $(cat "$ERR")"
  [ ! -s "$ERR" ] || fail "a settled retry was reported as pending: $(cat "$ERR")"
  grep -qF "$c on bravo" "$OUT" || fail "the note recorded first was not reported: $(cat "$OUT")"
  grep -qF "$b on alpha" "$OUT" || fail "the retried note was not reported: $(cat "$OUT")"
  [ "$(jq -r .outcome <<< "$(receipt_for "$stub" "$b")")" = recorded ] || fail "the retried note was not receipted"
  pass "a note retried in one exchange and recorded in the next is not reported as pending"
}

test_unreadable_document_wakes_once() {
  local home stub=$TMP_ROOT/stub-unread
  home=$(make_home home-unread)
  doc note '.note_id = "note_short"' "$TMP_ROOT/unreadable.json"
  queue "$stub" "$TMP_ROOT/unreadable.json"
  start_stub "$stub"
  FM_TODAY_NOTES_WAIT=0 notes "$home" check
  if [ "$(wc -l < "$OUT" | tr -d ' ')" != 1 ] || ! grep -q '^today-notes: .*1 unreadable' "$OUT"; then
    fail "check did not report the unreadable document once: $(cat "$OUT")"
  fi
  FM_TODAY_NOTES_WAIT=0 notes "$home" check
  [ ! -s "$OUT" ] || fail "the same unreadable document woke firstmate again: $(cat "$OUT")"
  queue "$stub" "$TMP_ROOT/unreadable.json" "$CONTRACT/examples/valid/note.json"
  FM_TODAY_NOTES_WAIT=0 notes "$home" check
  stop_stub
  if [ "$(wc -l < "$OUT" | tr -d ' ')" != 1 ] || ! grep -qF "$NOTE_ID" "$OUT"; then
    fail "a new note alongside the unreadable one was not reported alone: $(cat "$OUT")"
  fi
  pass "an unreadable document is reported once, not on every poll, while new notes still wake"
}

test_settings_are_required() {
  local home
  home=$(make_home home-bare)
  PORTAL_URL='' notes "$home" collect
  if [ "$CODE" -ne 2 ] || ! grep -q 'missing FM_TODAY_PORTAL_URL; nothing was sent' "$ERR"; then
    fail "a missing URL: $CODE $(cat "$ERR")"
  fi
  PORTAL_URL=http://portal.example notes "$home" collect
  if [ "$CODE" -ne 2 ] || ! grep -q 'must be https://' "$ERR"; then
    fail "plain http off loopback: $CODE $(cat "$ERR")"
  fi
  pass "collect needs the bridge settings and the https rule"
}

test_standing_check() {
  local home stub=$TMP_ROOT/stub-check mate
  home=$(make_home home-check)
  notes "$home" arm
  [ "$CODE" -eq 0 ] || fail "arm exited $CODE: $(cat "$ERR")"
  [ -x "$home/state/today-notes.check.sh" ] && [ -f "$home/state/today-notes.check-trust" ] \
    || fail "arm did not write and bind the shim"
  queue "$stub" "$CONTRACT/examples/valid/note.json"
  start_stub "$stub"
  FM_TODAY_NOTES_WAIT=0 notes "$home" check
  if [ "$(wc -l < "$OUT" | tr -d ' ')" != 1 ] || ! grep -qF "$NOTE_ID" "$OUT"; then
    fail "check did not report the note once: $(cat "$OUT")"
  fi
  stop_stub
  PORTAL_URL=http://127.0.0.1:9 FM_TODAY_NOTES_WAIT=0 notes "$home" check
  grep -q '^today-notes: could not reach the portal' "$OUT" || fail "an unreachable portal was not reported: $(cat "$OUT")"
  PORTAL_URL=http://127.0.0.1:9 FM_TODAY_NOTES_WAIT=0 notes "$home" check
  [ ! -s "$OUT" ] || fail "the same failure was reported twice: $(cat "$OUT")"
  notes "$home" disarm
  [ ! -e "$home/state/today-notes.check.sh" ] && [ ! -e "$home/state/today-notes.check-trust" ] \
    || fail "disarm left the shim"
  [ -f "$home/data/today-notes/$NOTE_ID.json" ] || fail "disarm dropped a record"
  mate=$(make_home home-mate)
  : > "$mate/.fm-secondmate-home"
  notes "$mate" arm
  [ "$CODE" -eq 2 ] && [ ! -e "$mate/state/today-notes.check.sh" ] || fail "a secondmate home was armed"
  pass "the standing check arms, reports a note and a failure once, disarms, and refuses a secondmate home"
}

# When FM_TODAY_PORTAL_DIR names a relay-platform checkout, the portal's ajv
# compiles the three schemas (its vendored copies, which must be byte-identical,
# once vendored; ours until then) and accepts every valid example and every
# receipt this file's collects sent. Unset, the reference checker is the check.
test_portal_validator_accepts_the_shapes() {
  local vendored dir f out
  if [ -z "${FM_TODAY_PORTAL_DIR:-}" ]; then
    echo "skip - portal cross-check: FM_TODAY_PORTAL_DIR is not set"
    return 0
  fi
  vendored=$FM_TODAY_PORTAL_DIR/src/lib/fleet/today-contract
  dir=$CONTRACT
  if [ -f "$vendored/fm-today-note.v1.schema.json" ]; then
    for f in fm-today-note.v1 fm-today-dispatch-order.v1 fm-today-note-receipt.v1; do
      cmp -s "$vendored/$f.schema.json" "$CONTRACT/$f.schema.json" \
        || fail "portal schema $f is not byte-identical to docs/today-contract/$f.schema.json"
    done
    dir=$vendored
  fi
  [ -d "$FM_TODAY_PORTAL_DIR/node_modules/ajv" ] || fail "no ajv under $FM_TODAY_PORTAL_DIR/node_modules"
  jq -s '[.[] | .body | fromjson | .receipts[]]' "$TMP_ROOT"/stub-*/requests/*.json > "$TMP_ROOT/sent-receipts.json"
  out=$(node - "$FM_TODAY_PORTAL_DIR" "$dir" "$CONTRACT" "$TMP_ROOT/sent-receipts.json" 2>&1 <<'JS'
const [portal, dir, ours, sent] = process.argv.slice(2);
const Ajv2020 = require(portal + "/node_modules/ajv/dist/2020").default;
const fs = require("fs");
const read = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
const ajv = new Ajv2020({ allErrors: false });
for (const f of ["fm-today-card.v1", "fm-today-answer.v1"]) ajv.addSchema(read(ours + "/" + f + ".schema.json"));
const check = {};
for (const s of ["fm-today-note.v1", "fm-today-dispatch-order.v1", "fm-today-note-receipt.v1"]) {
  check[s] = ajv.compile(read(dir + "/" + s + ".schema.json"));
}
const docs = fs.readdirSync(ours + "/examples/valid").filter((f) => /^(note|dispatch-order)/.test(f))
  .map((f) => [f, read(ours + "/examples/valid/" + f)]);
read(sent).forEach((r, i) => docs.push(["sent receipt " + i, r]));
let bad = 0;
for (const [name, doc] of docs) {
  if (!check[doc.schema](doc)) { console.log(name, JSON.stringify(check[doc.schema].errors)); bad++; }
}
for (const f of ["note--authority-granted", "note--control-character", "note--owner-without-task",
                 "dispatch-order--owner-qualified", "dispatch-order--start-flag", "note-receipt--applied"]) {
  const doc = read(ours + "/examples/invalid/" + f + ".json");
  if (check[doc.schema](doc)) { console.log(f, "accepted"); bad++; }
}
process.exit(bad ? 1 : 0);
JS
) || fail "the portal's validator disagrees: $out"
  pass "the portal's ajv accepts the valid shapes and sent receipts and refuses the invalid ones"
}

test_token_never_in_output() {
  ! grep -rqF -- "$TOKEN" "$OUTPUTS" || fail "the token appeared in output"
  pass "the token never appears in any output"
}

test_note_is_recorded_and_receipted_next_exchange
test_note_carries_no_authority
test_duplicate_and_withheld
test_oversized_note_is_refused
test_dispatch_order_records_ranks_and_starts_nothing
test_older_and_empty_orders_are_refused
test_receipt_survives_a_failed_call
test_failed_record_leaves_the_note_unreceipted
test_failed_record_spares_the_rest_of_the_answer
test_failed_receipt_still_reports_the_record
test_retry_settled_later_in_the_collect_is_not_pending
test_unreadable_document_wakes_once
test_settings_are_required
test_standing_check
test_portal_validator_accepts_the_shapes
test_token_never_in_output

echo "all fm-today-notes tests passed"
