#!/usr/bin/env bash
# Behavior tests for bin/fm-today-bridge.sh, the outward half of the Today
# bridge (docs/today-contract.md). The seams are the bridge's own commands over
# a fixture home, and a local stub portal (python3 http.server) standing in for
# POST /api/fleet/snapshot: a valid push carries the right header and gets the
# portal's heard_at, an invalid snapshot is refused before anything is sent, a
# call tripping each text-check rule family goes out withheld, the day comes
# from the day file or is empty for today, and the token never reaches output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

BRIDGE="$ROOT/bin/fm-today-bridge.sh"
CHECK=(python3 "$ROOT/tests/fm-today-contract-check.py" check "$ROOT/docs/today-contract")
TMP_ROOT=$(fm_test_tmproot fm-today-bridge)
TOKEN="tok-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
export TZ=UTC
TODAY=$(date +%Y-%m-%d)
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish"
unset FM_TODAY_PORTAL_URL FM_TODAY_BRIDGE_TOKEN FM_TODAY_DAY_FILE

# Every output the bridge produces is kept, so the leak check covers them all.
OUTPUTS="$TMP_ROOT/outputs"
mkdir -p "$OUTPUTS"
run_n=0
bridge() {  # <home> <args...>; sets OUT, ERR, CODE
  local home=$1
  shift
  run_n=$((run_n + 1))
  OUT="$OUTPUTS/$run_n.out"
  ERR="$OUTPUTS/$run_n.err"
  CODE=0
  FM_HOME="$home" "$BRIDGE" "$@" > "$OUT" 2> "$ERR" || CODE=$?
}

# One captain call per text-check rule family, one clean call, and ordinary work.
make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship the thing (repo: firstmate) (kind: ship) (since 2026-09-20)

## Queued
- [ ] live-gate - Real queued work blocked-by: ship-task (repo: firstmate) (kind: ship)
- [ ] call-clean - Choose the rail order (kind: captain) (hold: pick one of two orders) (hold-kind: captain)
- [ ] call-email - Reply to jo.smith@example.org (kind: captain) (hold: send it or not) (hold-kind: captain)
- [ ] call-phone - Ring back (555) 201-9934 (kind: captain) (hold: call or wait) (hold-kind: captain)
- [ ] call-money - Approve the refund of $450 (kind: captain) (hold: approve or not) (hold-kind: captain)
- [ ] call-address - Ship the kit to 42 Juniper Hill Rd (kind: captain) (hold: send it or not) (hold-kind: captain)
- [ ] call-dob - Confirm the date of birth on file (kind: captain) (hold: confirm or not) (hold-kind: captain)
- [ ] call-word - Tell the guardian about the change (kind: captain) (hold: tell or not) (hold-kind: captain)
- [ ] call-cut - Choose the order (kind: captain) (hold: check the vendor timeline first and after that write back to jo.smith@example.org) (hold-kind: captain)
- [ ] call-cut-address - Choose a kit (kind: captain) (hold: ship it to the depot at the far side of the town square at 42 Juniper Hill Rd) (hold-kind: captain)
- [ ] call-cut-phone - Ring the suppliers (kind: captain) (hold: call the front desk at the hq office after lunch and ask for +1 555 123 4567) (hold-kind: captain)
- [ ] call-cut-noted - Confirm the order and write to jo.smith@example.org (kind: captain) (hold: send it or not) (hold-kind: captain)
  Captain hold set: 2000-01-01T00:00:00Z

## Done
- [x] done-a - Landed thing https://github.com/acme/widget/pull/7 (repo: firstmate) (kind: ship) (merged 2026-09-27)
EOF
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" "worktree=$home/projects" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "pr=https://github.com/acme/widget/pull/9"
  printf 'working: building the thing\n' > "$home/state/ship-task.status"
  printf '%s\n' "$home"
}

# A local stub portal: records each request's Authorization header and body,
# and answers with STUB_STATUS (200 carries a heard_at stamp).
start_stub() {  # <dir> <status>
  local dir=$1 status=$2 i
  mkdir -p "$dir"
  STUB_STATUS=$status STUB_DIR=$dir python3 - <<'PY' &
import http.server, json, os
d = os.environ["STUB_DIR"]
status = int(os.environ["STUB_STATUS"])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = len(os.listdir(d))
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(os.path.join(d, "req-%d.json" % n), "w") as fh:
            json.dump({"path": self.path, "auth": self.headers.get("Authorization"),
                       "type": self.headers.get("Content-Type"),
                       "body": body.decode("utf-8")}, fh)
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
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "..", os.path.basename(d) + ".port"), "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY
  STUB_PID=$!
  i=0
  while [ ! -s "$dir/../$(basename "$dir").port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  STUB_URL="http://127.0.0.1:$(cat "$dir/../$(basename "$dir").port")"
}

stop_stub() { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null || true; }

HOME_A=$(make_home home-a)

test_snapshot_is_valid_and_withholds_each_rule_family() {
  local snap=$TMP_ROOT/snap.json family verdict
  bridge "$HOME_A" snapshot
  [ "$CODE" -eq 0 ] || fail "snapshot exited $CODE: $(cat "$ERR")"
  cp "$OUT" "$snap"
  "${CHECK[@]}" "$snap" >/dev/null || fail "snapshot fails the contract: $("${CHECK[@]}" "$snap")"
  [ "$(jq -r '.sections.calls[] | select(.task_id == "call-clean") | .text_check.verdict' "$snap")" = pass ] \
    || fail "a clean call was not passed"
  jq -e '.sections.calls[] | select(.task_id == "call-clean") | .title | test("rail order")' "$snap" >/dev/null \
    || fail "a clean call lost its own words"
  for family in email phone money address dob word; do
    verdict=$(jq -r --arg id "call-$family" '.sections.calls[] | select(.task_id == $id) | .text_check.verdict' "$snap")
    [ "$verdict" = withheld ] || fail "the $family call went out with verdict '$verdict'"
  done
  for family in jo.smith 201-9934 refund Juniper 'date of birth' guardian; do
    ! grep -qi -- "$family" "$snap" || fail "withheld call text '$family' left in the snapshot"
  done
  jq -e '[.sections.calls[] | select(.text_check.verdict == "withheld")
          | .title == "A call is waiting on the machine"] | all' "$snap" >/dev/null \
    || fail "a withheld card kept some of its own text"
  pass "the snapshot passes the contract and each rule family's call is withheld whole"
}

test_snapshot_carries_the_fleet() {
  local snap=$TMP_ROOT/snap.json
  jq -e '.sections.underway[] | select(.id == "ship-task" and .repo == "acme/widget"
          and .pr_url == "https://github.com/acme/widget/pull/9")' "$snap" >/dev/null \
    || fail "underway work missing or without its PR: $(jq -c .sections.underway "$snap")"
  jq -e '.sections.charted_next[] | select(.id == "live-gate" and .dispatchable == false
          and .blocked_by == ["ship-task"])' "$snap" >/dev/null \
    || fail "charted work missing its blocker: $(jq -c .sections.charted_next "$snap")"
  jq -e '.sections.landed[] | select(.id == "done-a" and .pr_url == "https://github.com/acme/widget/pull/7")' \
    "$snap" >/dev/null || fail "landed work missing: $(jq -c .sections.landed "$snap")"
  pass "the snapshot carries underway, charted, and landed work from bearings"
}

test_card_hash_recomputes() {
  local snap=$TMP_ROOT/snap.json card=$TMP_ROOT/card.json want
  jq '.sections.calls[0]' "$snap" > "$card"
  want=$(python3 "$ROOT/tests/fm-today-contract-check.py" hash "$card")
  [ "$(jq -r .card_hash "$card")" = "$want" ] || fail "card_hash does not recompute"
  pass "every card carries the contract's card_hash"
}

test_day_from_file_and_empty_when_missing() {
  local day=$TMP_ROOT/day.json snap
  cat > "$day" <<EOF
{"date":"$TODAY","ends_at":"${TODAY}T23:59:59Z","fetched_at":"${TODAY}T06:00:00Z",
 "blocks":[
  {"id":"evt-1","title":"Standup with jo.smith@example.org","starts_at":"${TODAY}T14:00:00Z","ends_at":"${TODAY}T14:30:00Z"},
  {"id":"evt-2","title":"$(printf 'x%.0s' $(seq 1 250))","starts_at":"${TODAY}T15:00:00-05:00","ends_at":"${TODAY}T16:00:00-05:00"},
  {"id":"evt-3","title":"Backwards","starts_at":"${TODAY}T18:00:00Z","ends_at":"${TODAY}T17:00:00Z"}
 ]}
EOF
  FM_TODAY_DAY_FILE=$day bridge "$HOME_A" snapshot
  [ "$CODE" -eq 0 ] || fail "snapshot with a day file exited $CODE"
  snap=$OUT
  "${CHECK[@]}" "$snap" >/dev/null || fail "snapshot with a day fails the contract"
  [ "$(jq -r '.sections.day.date' "$snap")" = "$TODAY" ] || fail "day date is not today"
  [ "$(jq -r '[.sections.day.blocks[].id] | join(",")' "$snap")" = "evt-1,evt-2" ] \
    || fail "day blocks wrong: $(jq -c .sections.day.blocks "$snap")"
  [ "$(jq -r '.sections.day.blocks[0].title' "$snap")" = "Standup with jo.smith@example.org" ] \
    || fail "a day block title was checked or changed"
  [ "$(jq -r '.sections.day.blocks[1].title | length' "$snap")" -le 200 ] || fail "a day block title was not capped"
  grep -q 'evt-3' "$ERR" || fail "the unusable block was not named on stderr"

  FM_TODAY_DAY_FILE=$TMP_ROOT/no-such-day.json bridge "$HOME_A" snapshot
  [ "$CODE" -eq 0 ] || fail "snapshot with no day file exited $CODE"
  jq -e --arg d "$TODAY" '.sections.day | .date == $d and .blocks == []' "$OUT" >/dev/null \
    || fail "a missing day file did not give an empty day for today"
  sed "s/\"date\":\"$TODAY\"/\"date\":\"2000-01-01\"/" "$day" > "$TMP_ROOT/stale-day.json"
  FM_TODAY_DAY_FILE=$TMP_ROOT/stale-day.json bridge "$HOME_A" snapshot
  jq -e --arg d "$TODAY" '.sections.day | .date == $d and .blocks == []' "$OUT" >/dev/null \
    || fail "a stale day file did not give an empty day for today"
  pass "the day comes from the day file, titles unchecked but capped, and is empty when missing or stale"
}

test_board_row_carries_no_board_text() {
  local home artifact snap
  home=$(make_home home-board)
  artifact="$TMP_ROOT/board-secret-title.html"
  printf '<h1>Secret board title</h1>\n' > "$artifact"
  artifact=$(cd "$(dirname "$artifact")" && pwd -P)/$(basename "$artifact")
  mkdir -p "$home/state/procevent" "$home/state/procevent-inbox" "$LAVISH_AXI_STATE_DIR"
  printf 'adapter=lavish\nkind=task-owned\nowner_task=ship-task\nargc=3\nargv:\n%s\npoll\n%s\n' \
    "$ROOT/bin/fm-procevent-lavish.sh" "$artifact" > "$home/state/procevent/lavish-0123456789abcdef.source"
  : > "$home/state/procevent-inbox/lavish-0123456789abcdef.1.result"
  : > "$home/state/procevent-inbox/lavish-0123456789abcdef.1.handled"
  : > "$home/state/procevent-inbox/lavish-0123456789abcdef.2.result"
  jq -n --arg f "$artifact" '{sessions:{abc:{file:$f,url:"http://host.example:4387/session/0123456789abcdef"}}}' \
    > "$LAVISH_AXI_STATE_DIR/state.json"
  bridge "$home" snapshot
  snap=$OUT
  "${CHECK[@]}" "$snap" >/dev/null || fail "snapshot with a board fails the contract"
  jq -e '.sections.boards == [{owner_task:"ship-task",state:"round-open",round:2,
          last_changed:.sections.boards[0].last_changed,
          link:"http://host.example:4387/session/0123456789abcdef"}]' "$snap" >/dev/null \
    || fail "board row wrong: $(jq -c .sections.boards "$snap")"
  ! grep -qi 'secret' "$snap" || fail "board text or path reached the snapshot"
  pass "an open review board goes out as owner, state, round, change time, and link only"
}

test_push_sends_with_the_bearer_header() {
  local stub=$TMP_ROOT/stub-ok req
  start_stub "$stub" 200
  FM_TODAY_PORTAL_URL=$STUB_URL/ FM_TODAY_BRIDGE_TOKEN=$TOKEN bridge "$HOME_A" push
  stop_stub
  [ "$CODE" -eq 0 ] || fail "push exited $CODE: $(cat "$ERR")"
  [ "$(cat "$OUT")" = "heard_at: 2026-09-28T18:00:00Z" ] || fail "push printed: $(cat "$OUT")"
  req="$stub/req-0.json"
  [ -f "$req" ] || fail "the stub portal received nothing"
  [ "$(jq -r .path "$req")" = /api/fleet/snapshot ] || fail "wrong path $(jq -r .path "$req")"
  [ "$(jq -r .auth "$req")" = "Bearer $TOKEN" ] || fail "wrong Authorization header"
  [ "$(jq -r .type "$req")" = application/json ] || fail "wrong content type"
  jq -r .body "$req" > "$TMP_ROOT/sent.json"
  "${CHECK[@]}" "$TMP_ROOT/sent.json" >/dev/null || fail "the sent body fails the contract"
  pass "push sends a valid snapshot with the bearer token and prints heard_at"
}

test_push_reads_the_home_env() {
  local stub=$TMP_ROOT/stub-env home
  home=$(make_home home-env)
  start_stub "$stub" 200
  printf 'FM_TODAY_PORTAL_URL=%s\nexport FM_TODAY_BRIDGE_TOKEN="%s"\n' "$STUB_URL" "$TOKEN" > "$home/.env"
  bridge "$home" push
  stop_stub
  [ "$CODE" -eq 0 ] || fail "push from .env exited $CODE: $(cat "$ERR")"
  [ "$(jq -r .auth "$stub/req-0.json")" = "Bearer $TOKEN" ] || fail "the .env token was not sent"
  pass "push reads the URL and token from the home .env"
}

# A copy of the bridge whose contract demands a generator version it never
# writes, so every snapshot it builds fails the check.
test_push_refuses_invalid_snapshot() {
  local stub=$TMP_ROOT/stub-invalid tree=$TMP_ROOT/strict-tree schema
  mkdir -p "$tree/tests" "$tree/docs"
  cp -R "$ROOT/bin" "$tree/bin"
  cp "$ROOT/tests/fm-today-contract-check.py" "$tree/tests/"
  cp -R "$ROOT/docs/today-contract" "$tree/docs/today-contract"
  schema="$tree/docs/today-contract/fm-today-snapshot.v1.schema.json"
  jq '.properties.generator_version = {"const": "0.0.0"}' "$schema" > "$schema.new" && mv "$schema.new" "$schema"
  start_stub "$stub" 200
  run_n=$((run_n + 1))
  OUT="$OUTPUTS/$run_n.out"
  ERR="$OUTPUTS/$run_n.err"
  CODE=0
  FM_HOME="$HOME_A" FM_TODAY_PORTAL_URL=$STUB_URL FM_TODAY_BRIDGE_TOKEN=$TOKEN \
    "$tree/bin/fm-today-bridge.sh" push > "$OUT" 2> "$ERR" || CODE=$?
  stop_stub
  [ "$CODE" -eq 1 ] || fail "invalid snapshot push exited $CODE, want 1"
  grep -q 'refusing to send' "$ERR" || fail "no refusal message: $(cat "$ERR")"
  [ -z "$(ls "$stub")" ] || fail "an invalid snapshot reached the portal"
  pass "push refuses an invalid snapshot and sends nothing"
}

test_push_reports_portal_refusal() {
  local stub=$TMP_ROOT/stub-400
  start_stub "$stub" 400
  FM_TODAY_PORTAL_URL=$STUB_URL FM_TODAY_BRIDGE_TOKEN=$TOKEN bridge "$HOME_A" push
  stop_stub
  [ "$CODE" -eq 3 ] || fail "a 400 answer exited $CODE, want 3"
  [ "$(tail -n1 "$ERR")" = "fm-today-bridge: the portal answered 400 (bad_snapshot)" ] \
    || fail "status not reported alone: $(cat "$ERR")"
  pass "push exits non-zero naming the portal's status"
}

test_push_missing_config_sends_nothing() {
  local home
  home=$(make_home home-bare)
  bridge "$home" push
  [ "$CODE" -eq 2 ] || fail "missing config exited $CODE, want 2"
  [ "$(wc -l < "$ERR" | tr -d ' ')" = 1 ] || fail "want one line: $(cat "$ERR")"
  grep -q 'missing FM_TODAY_PORTAL_URL and FM_TODAY_BRIDGE_TOKEN' "$ERR" || fail "wrong message: $(cat "$ERR")"
  FM_TODAY_PORTAL_URL=http://127.0.0.1:9 bridge "$home" push
  if [ "$CODE" -ne 2 ] || ! grep -q 'missing FM_TODAY_BRIDGE_TOKEN;' "$ERR"; then
    fail "missing token not named: $(cat "$ERR")"
  fi
  FM_TODAY_BRIDGE_TOKEN=$TOKEN bridge "$home" push
  if [ "$CODE" -ne 2 ] || ! grep -q 'missing FM_TODAY_PORTAL_URL;' "$ERR"; then
    fail "missing URL not named: $(cat "$ERR")"
  fi
  pass "a missing URL or token exits 2 naming it"
}

test_push_refuses_plain_http_off_loopback() {
  local url
  for url in http://portal.example http://127.0.0.1.example.org http://localhost@portal.example \
    http://localhost:80@portal.example ftp://portal.example; do
    FM_TODAY_PORTAL_URL=$url FM_TODAY_BRIDGE_TOKEN=$TOKEN bridge "$HOME_A" push
    [ "$CODE" -eq 2 ] || fail "portal URL $url exited $CODE, want 2"
    grep -q 'nothing was sent' "$ERR" || fail "portal URL $url not refused: $(cat "$ERR")"
  done
  pass "push refuses a portal URL that is neither https nor loopback http"
}

test_cut_text_loses_its_partial_word() {
  local snap=$TMP_ROOT/snap.json card
  card=$(jq -c '.sections.calls[] | select(.task_id == "call-cut")' "$snap")
  [ -n "$card" ] || fail "the cut call is missing"
  [ "$(jq -r .text_check.verdict <<< "$card")" = pass ] || fail "the cut call was withheld: $card"
  jq -e '.title | endswith("write back to…")' <<< "$card" >/dev/null \
    || fail "the cut call kept its partial word: $card"
  ! grep -q -- 'jo\.smith' "$snap" || fail "part of a cut email address left in the snapshot"
  pass "text bearings cut short loses its trailing partial word before the check"
}

test_cut_after_a_number_is_withheld() {
  local snap=$TMP_ROOT/snap.json id
  for id in call-cut-address call-cut-phone; do
    [ "$(jq -r --arg id "$id" '.sections.calls[] | select(.task_id == $id) | .text_check.verdict' "$snap")" = withheld ] \
      || fail "$id went out with a number just before its cut: $(jq -c --arg id "$id" '.sections.calls[] | select(.task_id == $id)' "$snap")"
  done
  ! grep -qE -- 'town square|555 1' "$snap" || fail "text before a cut number left in the snapshot"
  pass "a cut field with a number in the five words before the cut is withheld"
}

test_mid_text_cut_loses_its_partial_word() {
  local snap=$TMP_ROOT/snap.json card
  card=$(jq -c '.sections.calls[] | select(.task_id == "call-cut-noted")' "$snap")
  [ -n "$card" ] || fail "the hold-noted call is missing"
  [ "$(jq -r .text_check.verdict <<< "$card")" = pass ] || fail "the hold-noted call was withheld: $card"
  jq -e '.title | test("write to…: held [0-9]+d: send it or not$")' <<< "$card" >/dev/null \
    || fail "the mid-text cut kept its partial word: $card"
  ! grep -q -- 'jo\.s' "$snap" || fail "part of a mid-text cut email address left in the snapshot"
  pass "a cut in the middle of a hold-noted summary loses its partial word before the check"
}

test_dry_run_writes_and_sends_nothing() {
  local stub=$TMP_ROOT/stub-dry out=$TMP_ROOT/dry.json
  start_stub "$stub" 200
  FM_TODAY_PORTAL_URL=$STUB_URL FM_TODAY_BRIDGE_TOKEN=$TOKEN bridge "$HOME_A" push --dry-run "$out"
  stop_stub
  [ "$CODE" -eq 0 ] || fail "dry-run exited $CODE: $(cat "$ERR")"
  "${CHECK[@]}" "$out" >/dev/null || fail "the dry-run file fails the contract"
  cp "$out" "$OUTPUTS/dry.json"
  [ -z "$(ls "$stub")" ] || fail "dry-run reached the portal"
  pass "--dry-run writes the checked snapshot and sends nothing"
}

test_token_never_in_output() {
  ! grep -rqF -- "$TOKEN" "$OUTPUTS" || fail "the token appeared in bridge output"
  pass "the token never appears in any output"
}

test_snapshot_is_valid_and_withholds_each_rule_family
test_snapshot_carries_the_fleet
test_card_hash_recomputes
test_cut_text_loses_its_partial_word
test_cut_after_a_number_is_withheld
test_mid_text_cut_loses_its_partial_word
test_day_from_file_and_empty_when_missing
test_board_row_carries_no_board_text
test_push_sends_with_the_bearer_header
test_push_reads_the_home_env
test_push_refuses_invalid_snapshot
test_push_reports_portal_refusal
test_push_refuses_plain_http_off_loopback
test_push_missing_config_sends_nothing
test_dry_run_writes_and_sends_nothing
test_token_never_in_output

echo "all fm-today-bridge tests passed"
