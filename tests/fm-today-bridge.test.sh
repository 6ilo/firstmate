#!/usr/bin/env bash
# Behavior tests for bin/fm-today-bridge.sh, the outward half of the Today
# bridge (docs/today-contract.md). The seams are the bridge's own commands over
# a fixture home, and a local stub portal (python3 http.server) standing in for
# POST /api/fleet/bridge/snapshot: a valid push carries the right header and gets the
# portal's heard_at, an invalid snapshot is refused before anything is sent, a
# call tripping each text-check rule family goes out withheld, every card and
# work row names its repo or null and its owning home, second mates' calls and
# work travel under their own owner, the portal's vendored schemas match ours and
# its ajv accepts the snapshot when a portal checkout is named, the day comes
# from the day file or is empty for today, and the token never reaches output.
# The answers half runs against a stub portal for POST /api/fleet/answers:
# held merge, go, and credential calls become cards of that kind; decision
# answers close through bin/fm-captain-hold.sh's intake; merge and go answers
# are refused for proof with every merging script a tripwire; stale cards are
# set aside; later, reconcile, and seen never close; an unbound home and a
# second mate's answer apply nothing; receipts survive a failed call; repeats
# are duplicates;
# and poll reports one round bin/fm-procevent-today-answers.sh reads.
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
- [ ] call-options - Choose the launch week (kind: captain) (hold: which week) (hold-kind: captain)
  Captain hold set: 2000-01-01T00:00:00Z
  Captain hold due: 2000-01-02
  Captain hold option: {"value":"week-1","label":"First week","hint":"Ships before the review","recommended":true}
  Captain hold option: {"value":"week-2","label":"Second week","recommended":false}
  Captain hold option: {"value":"later","label":"Reserved by the contract","recommended":false}
  Captain hold option: {"value":"week-2","label":"Repeated value","recommended":false}
- [ ] call-options-tripped - Choose a supplier (kind: captain) (hold: which supplier) (hold-kind: captain)
  Captain hold set: 2000-01-01T00:00:00Z
  Captain hold option: {"value":"north","label":"North depot","hint":"Write to jo.smith@example.org","recommended":false}
  Captain hold option: {"value":"south","label":"South depot","recommended":true}

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
  ERR_SNAP=$ERR
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

# A call held with options (bin/fm-captain-hold.sh hold --option) offers them,
# in order, then reconcile; a call without offers reconcile alone. An option
# the card cannot carry is left out and named; a tripped option withholds the
# whole card and shows each recorded option only by its position.
test_recorded_options_reach_the_card() {
  local snap=$TMP_ROOT/snap.json
  [ "$(jq -c '.sections.calls[] | select(.task_id == "call-options") | .options' "$snap")" \
    = '[{"value":"week-1","label":"First week","hint":"Ships before the review","recommended":true},{"value":"week-2","label":"Second week","recommended":false},{"value":"reconcile","label":"Already settled","hint":"Re-check the latest state, then close this with evidence or keep it open with a note","recommended":false}]' ] \
    || fail "the recorded options did not reach the card: $(jq -c '.sections.calls[] | select(.task_id == "call-options")' "$snap")"
  [ "$(jq -r '.sections.calls[] | select(.task_id == "call-options") | .text_check.verdict' "$snap")" = pass ] \
    || fail "a clean call with options was not passed"
  [ "$(jq -c '[.sections.calls[] | select(.task_id == "call-clean") | .options[].value]' "$snap")" = '["reconcile"]' ] \
    || fail "a call without options no longer offers reconcile alone"
  grep -q 'call call-options option "later"' "$ERR_SNAP" \
    || fail "a reserved option value was not named as left out: $(cat "$ERR_SNAP")"
  grep -q 'call call-options option "week-2"' "$ERR_SNAP" \
    || fail "a repeated option value was not named as left out: $(cat "$ERR_SNAP")"
  [ "$(jq -c '.sections.calls[] | select(.task_id == "call-options-tripped")
               | [.text_check.verdict, [.options[] | [.value, .label, .hint, .recommended]]]' "$snap")" \
    = '["withheld",[["north","Option 1","Text kept on the machine",false],["south","Option 2",null,true],["reconcile","Already settled","Re-check the latest state, then close this with evidence or keep it open with a note",false]]]' ] \
    || fail "a tripped option did not withhold its card: $(jq -c '.sections.calls[] | select(.task_id == "call-options-tripped")' "$snap")"
  ! grep -q 'depot' "$snap" || fail "withheld option text left in the snapshot"
  pass "recorded options reach the card before reconcile and pass the text check"
}

test_card_hash_recomputes() {
  local snap=$TMP_ROOT/snap.json card=$TMP_ROOT/card.json want
  jq '.sections.calls[0]' "$snap" > "$card"
  want=$(python3 "$ROOT/tests/fm-today-contract-check.py" hash "$card")
  [ "$(jq -r .card_hash "$card")" = "$want" ] || fail "card_hash does not recompute"
  pass "every card carries the contract's card_hash"
}

# The standing rule: every card and work row names its repository explicitly,
# owner/name when one is found and null otherwise, never by leaving it out.
test_every_row_carries_repo() {
  local snap=$TMP_ROOT/snap.json
  jq -e '[.sections.calls[], .sections.underway[], .sections.charted_next[], .sections.landed[]]
          | length > 0 and all(has("repo"))' "$snap" >/dev/null \
    || fail "a card or work row left out repo: $(jq -c '[.sections[] | arrays | .[] | select(has("repo") | not)]' "$snap")"
  jq -e '[.sections.calls[].repo] | all(. == null)' "$snap" >/dev/null \
    || fail "a card named a repository bearings never recorded: $(jq -c '[.sections.calls[].repo]' "$snap")"
  [ "$(jq -r '.sections.underway[] | select(.id == "ship-task") | .repo' "$snap")" = acme/widget ] \
    || fail "underway work lost the repository its PR names"
  jq -e '.sections.charted_next[] | select(.id == "live-gate") | has("repo") and .repo == null' "$snap" >/dev/null \
    || fail "work whose clone is absent did not carry repo null: $(jq -c .sections.charted_next "$snap")"
  pass "every card and work row carries repo, null when no repository is found"
}

test_every_row_carries_its_owner() {
  local snap=$TMP_ROOT/snap.json
  jq -e '[.sections.calls[], .sections.underway[], .sections.charted_next[], .sections.landed[]]
          | length > 0 and all(.owner == "(main)")' "$snap" >/dev/null \
    || fail "a main-home card or work row did not carry owner (main): $(jq -c '[.sections[] | arrays | .[] | {id, task_id, owner}]' "$snap")"
  pass "every main-home card and work row carries owner (main)"
}

# docs/today-contract.md: every decision card the bridge sends ends with the
# reconcile option, labelled "Already settled", and no other option uses reconcile.
test_every_decision_card_ends_with_reconcile() {
  local snap=$TMP_ROOT/snap.json
  jq -e '[.sections.calls[] | select(.kind == "decision")] | length > 0 and all(
          (.options[-1] | .value == "reconcile" and .label == "Already settled" and .recommended == false)
          and ([.options[] | select(.value == "reconcile")] | length == 1))' "$snap" >/dev/null \
    || fail "a decision card did not end with the one reconcile option: $(jq -c '[.sections.calls[] | .options]' "$snap")"
  pass "every decision card ends with the one reconcile option, labelled Already settled"
}

# Second mates' calls and work come from the bearings snapshot as `mate/task`
# ids with the mate as owner. A copy of the bridge whose bearings snapshot is a
# fixed document stands in for a fleet with a second mate: its calls go out
# under their owner with the bare task id, the same task id in two homes is
# two calls and two pieces of work, and owner is part of each card_hash.
test_second_mate_calls_and_work_travel() {
  local tree=$TMP_ROOT/mate-tree snap card
  mkdir -p "$tree/tests" "$tree/docs"
  cp -R "$ROOT/bin" "$tree/bin"
  cp "$ROOT/tests/fm-today-contract-check.py" "$tree/tests/"
  cp -R "$ROOT/docs/today-contract" "$tree/docs/today-contract"
  cat > "$tree/bin/fm-bearings-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"home": "firstmate",
 "decisions_open": [
  {"id": "rail-order", "key": "rail-order", "verb": "captain-hold", "summary": "Choose the rail order", "owner": "(main)"},
  {"id": "portal-mate/rail-order", "key": "rail-order", "verb": "captain-hold", "summary": "Choose the rail order", "owner": "portal-mate"},
  {"id": "portal-mate/kit-order", "key": "kit-order", "verb": "captain-hold", "summary": "Choose the kit order", "owner": "portal-mate"},
  {"id": "bad mate/odd-call", "key": "odd-call", "verb": "captain-hold", "summary": "Odd", "owner": "bad mate"}],
 "in_flight": [
  {"id": "ship-task", "kind": "ship", "state": "working", "repo": null, "name": "Ship the thing", "doing": "building"},
  {"id": "portal-mate/ship-task", "kind": "ship", "state": "working", "repo": null, "name": "Ship the kit", "doing": "building"}],
 "gates": [
  {"id": "live-gate", "title": "Main queued work", "blocked_by": "-", "reason": "-", "owner": "(main)", "filed": null},
  {"id": "live-gate", "title": "Mate queued work", "blocked_by": "-", "reason": "-", "owner": "portal-mate", "filed": null}],
 "landed": [
  {"id": "done-a", "what": "Main landed", "artifact": "-", "owner": "(main)"},
  {"id": "done-a", "what": "Mate landed", "artifact": "-", "owner": "portal-mate"}]}
JSON
EOF
  chmod +x "$tree/bin/fm-bearings-snapshot.sh"
  run_n=$((run_n + 1))
  OUT="$OUTPUTS/$run_n.out"
  ERR="$OUTPUTS/$run_n.err"
  CODE=0
  FM_HOME="$HOME_A" "$tree/bin/fm-today-bridge.sh" snapshot > "$OUT" 2> "$ERR" || CODE=$?
  [ "$CODE" -eq 0 ] || fail "snapshot with a second mate exited $CODE: $(cat "$ERR")"
  snap=$OUT
  "${CHECK[@]}" "$snap" >/dev/null || fail "snapshot with a second mate fails the contract: $("${CHECK[@]}" "$snap")"
  [ "$(jq -c '[.sections.calls[] | [.owner, .task_id]]' "$snap")" \
    = '[["(main)","rail-order"],["portal-mate","rail-order"],["portal-mate","kit-order"]]' ] \
    || fail "calls did not travel under their owners: $(jq -c '[.sections.calls[] | [.owner, .task_id]]' "$snap")"
  grep -q 'call "bad mate/odd-call": id the contract cannot carry' "$ERR" \
    || fail "a call whose owner the contract cannot carry was not named on stderr: $(cat "$ERR")"
  jq -e '[.sections.calls[] | select(.task_id == "rail-order") | .card_hash] | length == 2 and .[0] != .[1]' \
    "$snap" >/dev/null || fail "the same call text in two homes shares one card_hash"
  card=$TMP_ROOT/mate-card.json
  jq '.sections.calls[1]' "$snap" > "$card"
  [ "$(jq -r .card_hash "$card")" = "$(python3 "$ROOT/tests/fm-today-contract-check.py" hash "$card")" ] \
    || fail "a second mate's card_hash does not recompute"
  for section in underway charted_next landed; do
    [ "$(jq -c --arg s "$section" '[.sections[$s][] | [.owner, .id]] | sort' "$snap")" \
      = "$(jq -cn --arg s "$section" '{underway: "ship-task", charted_next: "live-gate", landed: "done-a"}[$s] as $id
            | [["(main)", $id], ["portal-mate", $id]]')" ] \
      || fail "$section work did not travel under both owners: $(jq -c --arg s "$section" '.sections[$s]' "$snap")"
  done
  ! grep -q 'already listed' "$ERR" || fail "work sharing an id with another home was left out: $(cat "$ERR")"
  pass "second mates' calls and work travel under their owner, keyed with the task id, owner hashed"
}

# The portal validates with ajv over its vendored copy of these schemas, which
# must stay byte-identical to docs/today-contract. When FM_TODAY_PORTAL_DIR
# names a relay-platform checkout, any vendored schema that differs fails by
# name, then the bridge's own snapshot is checked by the portal's ajv compiling
# the portal's vendored schema files. The portal's exported validator
# (src/lib/fleet/contract.ts) is not used: it is TypeScript importing JSON and
# an extensionless ajv path, so node cannot load it without the portal's build.
# Unset, the reference checker above is the check and this case skips.
test_snapshot_passes_the_portal_validator() {
  local snap=$TMP_ROOT/snap.json vendored out f
  if [ -z "${FM_TODAY_PORTAL_DIR:-}" ]; then
    echo "skip - portal cross-check: FM_TODAY_PORTAL_DIR is not set"
    return 0
  fi
  vendored=$FM_TODAY_PORTAL_DIR/src/lib/fleet/today-contract
  for f in "$vendored"/*.schema.json; do
    cmp -s "$f" "$ROOT/docs/today-contract/${f##*/}" \
      || fail "portal schema $f is not byte-identical to docs/today-contract/${f##*/}"
  done
  [ -d "$FM_TODAY_PORTAL_DIR/node_modules/ajv" ] \
    || fail "no ajv under $FM_TODAY_PORTAL_DIR/node_modules: install the portal's dependencies"
  command -v node >/dev/null 2>&1 || fail "node is required for the portal cross-check"
  out=$(node - "$FM_TODAY_PORTAL_DIR" "$vendored" "$snap" 2>&1 <<'JS'
const [portal, dir, file] = process.argv.slice(2);
const Ajv2020 = require(portal + "/node_modules/ajv/dist/2020").default;
const fs = require("fs");
const read = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
const ajv = new Ajv2020({ allErrors: false });
ajv.addSchema(read(dir + "/fm-today-card.v1.schema.json"));
const check = ajv.compile(read(dir + "/fm-today-snapshot.v1.schema.json"));
if (!check(read(file))) {
  console.log(JSON.stringify(check.errors.map((e) => [e.instancePath, e.keyword])));
  process.exit(1);
}
JS
) || fail "the portal's validator refused the bridge snapshot: $out"
  [ -z "$out" ] || fail "the portal's ajv warned on its vendored schemas: $out"
  pass "the portal's vendored schemas match and its ajv accepts the bridge snapshot"
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

test_retired_source_boards() {
  local home gone ended lost live open fresh split twice sid_gone sid_ended sid_lost sid_live sid_open
  local sid_fresh sid_split sid_twice
  local snap before after inbox
  home=$(make_home home-retired)
  mkdir -p "$home/state/procevent-inbox" "$home/.lavish" "$home/data/handoff" "$LAVISH_AXI_STATE_DIR"
  home=$(cd "$home" && pwd -P)
  inbox=$home/state/procevent-inbox
  gone="$home/.lavish/gone-board.html"; ended="$home/.lavish/ended-board.html"
  lost="$home/.lavish/lost-board.html"; live="$home/.lavish/live-board.html"
  open="$home/.lavish/open-board.html"; fresh="$home/data/handoff/fresh-board.html"
  split="$home/.lavish/split-board.html"; twice="$home/.lavish/twice-board.html"
  printf '<h1>Secret gone title</h1>\n' > "$gone"
  for f in "$ended" "$lost" "$live" "$open" "$fresh" "$split" "$twice"; do printf 'x\n' > "$f"; done
  sid_gone=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$gone")
  sid_ended=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ended")
  sid_lost=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$lost")
  sid_live=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$live")
  sid_open=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$open")
  sid_fresh=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$fresh")
  sid_split=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$split")
  sid_twice=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$twice")
  : > "$inbox/$sid_split.1.result"; printf 'torn-task\n' > "$inbox/$sid_split.1.owner-task"
  : > "$inbox/$sid_split.2.result"; printf 'ship-task\n' > "$inbox/$sid_split.2.owner-task"
  : > "$inbox/$sid_twice.1.result"; printf 'torn-task\n' > "$inbox/$sid_twice.1.owner-task"
  : > "$inbox/$sid_gone.1.result"; : > "$inbox/$sid_gone.1.handled"
  printf 'torn-task\n' > "$inbox/$sid_gone.1.owner-task"
  : > "$inbox/$sid_ended.1.result"
  printf 'torn-task\n' > "$inbox/$sid_ended.1.owner-task"
  : > "$inbox/$sid_lost.1.result"
  : > "$inbox/$sid_live.1.result"; : > "$inbox/$sid_live.1.handled"
  printf 'ship-task\n' > "$inbox/$sid_live.1.owner-task"
  : > "$inbox/$sid_open.1.result"; : > "$inbox/$sid_open.1.handled"
  printf 'ship-task\n' > "$inbox/$sid_open.1.owner-task"
  : > "$inbox/$sid_open.2.result"
  printf 'ship-task\n' > "$inbox/$sid_open.2.owner-task"
  jq -n --arg g "$gone" --arg e "$ended" --arg l "$lost" --arg v "$live" --arg o "$open" \
      --arg f "$fresh" --arg s "$split" --arg t "$twice" '{sessions:{
      a:{file:$g,status:"open",url:"http://host.example:4387/session/aaaa"},
      b:{file:$e,status:"ended",url:"http://host.example:4387/session/bbbb"},
      c:{file:$l,status:"open",url:"http://host.example:4387/session/cccc"},
      d:{file:"/elsewhere/other.html",status:"open",url:"http://host.example:4387/session/dddd"},
      e:{file:$v,status:"open",url:"http://host.example:4387/session/eeee"},
      f:{file:$o,status:"open",url:"http://host.example:4387/session/ffff"},
      g:{file:$f,status:"open",url:"http://host.example:4387/session/gggg"},
      h:{file:$s,status:"open",url:"http://host.example:4387/session/hhhh"},
      i:{file:$t,status:"ended",url:"http://host.example:4387/session/iiii"},
      j:{file:$t,status:"open",url:"http://host.example:4387/session/jjjj"}}}' \
    > "$LAVISH_AXI_STATE_DIR/state.json"
  before=$(cd "$home/state" && find . -type f -exec shasum {} + | sort; find . | sort)
  bridge "$home" snapshot
  after=$(cd "$home/state" && find . -type f -exec shasum {} + | sort; find . | sort)
  snap=$OUT
  [ "$before" = "$after" ] || fail "building the snapshot changed a file under state/"
  "${CHECK[@]}" "$snap" >/dev/null || fail "snapshot with a retired board fails the contract"
  jq -e '[.sections.boards[] | {owner_task, state, round, link}] | sort_by(.link) == [
          {owner_task:"torn-task",state:"owner-gone",round:1,link:"http://host.example:4387/session/aaaa"},
          {owner_task:"ship-task",state:"listening",round:1,link:"http://host.example:4387/session/eeee"},
          {owner_task:"ship-task",state:"round-open",round:2,link:"http://host.example:4387/session/ffff"}]' \
      "$snap" >/dev/null \
    || fail "retired board rows wrong: $(jq -c .sections.boards "$snap")"
  grep -q "board $sid_split: owner task cannot be recovered" "$ERR" \
    || fail "a board with disagreeing owners was not named on stderr: $(cat "$ERR")"
  grep -q "board $sid_twice: no single saved session link" "$ERR" \
    || fail "a board with two saved sessions was not named on stderr: $(cat "$ERR")"
  ! grep -q "$sid_ended\|$sid_fresh\|$sid_lost\|dddd\|handoff" "$ERR" \
    || fail "an ended, never-armed, unowned, or foreign board was named: $(cat "$ERR")"
  ! grep -qi 'secret' "$snap" || fail "board text reached the snapshot"
  pass "a still-open board whose source was retired keeps its owner's state; ended, unarmed, unowned, ambiguous, and doubly linked ones stay out"
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
  [ "$(jq -r .path "$req")" = /api/fleet/bridge/snapshot ] || fail "wrong path $(jq -r .path "$req")"
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

test_push_sends_a_given_snapshot() {
  local stub=$TMP_ROOT/stub-given given=$TMP_ROOT/given.json
  jq '.generated_at = "2026-09-28T17:59:00Z"' "$TMP_ROOT/snap.json" > "$given"
  start_stub "$stub" 200
  FM_TODAY_PORTAL_URL=$STUB_URL FM_TODAY_BRIDGE_TOKEN=$TOKEN bridge "$HOME_A" push --snapshot "$given"
  stop_stub
  [ "$CODE" -eq 0 ] || fail "push --snapshot exited $CODE: $(cat "$ERR")"
  jq -r .body "$stub/req-0.json" | jq -S . > "$TMP_ROOT/given-sent.json"
  jq -S . "$given" | cmp -s - "$TMP_ROOT/given-sent.json" \
    || fail "push --snapshot did not send the given document unchanged"
  printf '{}\n' > "$TMP_ROOT/given-bad.json"
  start_stub "$stub-bad" 200
  FM_TODAY_PORTAL_URL=$STUB_URL FM_TODAY_BRIDGE_TOKEN=$TOKEN bridge "$HOME_A" push --snapshot "$TMP_ROOT/given-bad.json"
  stop_stub
  [ "$CODE" -eq 1 ] || fail "an invalid given snapshot exited $CODE, want 1"
  [ -z "$(ls "$stub-bad")" ] || fail "an invalid given snapshot reached the portal"
  pass "push --snapshot sends the given document unchanged and still refuses one that fails the check"
}

test_token_never_in_output() {
  ! grep -rqF -- "$TOKEN" "$OUTPUTS" || fail "the token appeared in bridge output"
  pass "the token never appears in any output"
}

# --- answers -------------------------------------------------------------------
# The inward half runs against a copy of the bridge whose bearings snapshot is
# a fixed document naming every kind of call, over a fixture home whose backlog
# holds those calls, so the real bin/fm-captain-hold.sh does the recording. The
# stub portal behaves as docs/today-contract.md says the portal does: it stores
# the receipts in each request first, then returns every answer that has no
# receipt, so an answer is delivered again until its receipt arrives.

PASSKEY_ORIGIN=https://relay-api.mmeg.us

make_answers_tree() {  # <tree> <home>: a bridge copy with a fixed bearings snapshot
  local tree=$1
  mkdir -p "$tree/tests" "$tree/docs"
  cp -R "$ROOT/bin" "$tree/bin"
  cp "$ROOT/tests/fm-today-contract-check.py" "$tree/tests/"
  cp -R "$ROOT/docs/today-contract" "$tree/docs/today-contract"
  cat > "$tree/bin/fm-bearings-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"home": "firstmate",
 "decisions_open": [
  {"id": "q-pick", "key": "q-pick", "verb": "captain-hold", "summary": "Choose the rail order", "owner": "(main)",
   "task_kind": "captain", "options": [
     {"value": "east", "label": "East first", "recommended": true},
     {"value": "west", "label": "West first", "hint": "Slower but safer", "recommended": false}]},
  {"id": "w-held", "key": "w-held", "verb": "captain-hold", "summary": "Resume the widget work", "owner": "(main)",
   "task_kind": "ship", "options": [{"value": "resume", "label": "Resume", "recommended": true}]},
  {"id": "q-later", "key": "q-later", "verb": "captain-hold", "summary": "Pick a venue", "owner": "(main)", "task_kind": "captain"},
  {"id": "q-recon", "key": "q-recon", "verb": "captain-hold", "summary": "Maybe settled already", "owner": "(main)", "task_kind": "captain"},
  {"id": "c-key", "key": "c-key", "verb": "captain-hold", "summary": "Add the payments key", "owner": "(main)",
   "task_kind": "captain", "call": {"kind": "credential"}},
  {"id": "m-fix", "key": "m-fix", "verb": "captain-hold", "summary": "Merge the widget fix", "owner": "(main)",
   "task_kind": "ship", "call": {"kind": "merge", "pr_url": "https://github.com/acme/widget/pull/9"}},
  {"id": "g-build", "key": "g-build", "verb": "captain-hold", "summary": "Build the kit page", "owner": "(main)",
   "task_kind": "captain", "call": {"kind": "go"}},
  {"id": "mate/q-pick", "key": "q-pick", "verb": "captain-hold", "summary": "Choose the mate order", "owner": "mate"}],
 "in_flight": [], "gates": [], "landed": []}
JSON
EOF
  chmod +x "$tree/bin/fm-bearings-snapshot.sh"
}

make_answers_home() {  # <name>
  local home=$TMP_ROOT/$1 id
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] w-held - Widget work (repo: firstmate) (kind: ship) (since 2026-09-20) (hold: resume or not) (hold-kind: captain)
  Captain hold set: 2026-09-20T00:00:00Z
- [ ] m-fix - Widget fix (repo: firstmate) (kind: ship) (since 2026-09-20) (hold: merge it) (hold-kind: captain)
  Captain hold set: 2026-09-20T00:00:00Z
  Captain hold call: {"kind":"merge","pr_url":"https://github.com/acme/widget/pull/9"}

## Queued
- [ ] q-pick - Choose the rail order (kind: captain) (hold: pick one) (hold-kind: captain)
  Captain hold set: 2026-09-20T00:00:00Z
- [ ] q-later - Pick a venue (kind: captain) (hold: pick one) (hold-kind: captain)
  Captain hold set: 2026-09-20T00:00:00Z
- [ ] q-recon - Maybe settled already (kind: captain) (hold: check first) (hold-kind: captain)
  Captain hold set: 2026-09-20T00:00:00Z
- [ ] c-key - Add the payments key (kind: captain) (hold: key needed) (hold-kind: captain)
  Captain hold set: 2026-09-20T00:00:00Z
  Captain hold call: {"kind":"credential"}
- [ ] g-build - Build the kit page (kind: captain) (hold: go or not) (hold-kind: captain)
  Captain hold set: 2026-09-20T00:00:00Z
  Captain hold call: {"kind":"go"}

## Done
EOF
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" bind today-bridge >/dev/null \
    || fail "could not bind the bridge's reconcile source"
  printf '%s\n' "$home"
}

# The stub portal: POST /api/fleet/answers stores the request's receipts, then
# returns the answers in answers.json that have none (all of them while an
# ignore-receipts file exists). A status file makes it answer that status
# instead, storing nothing.
start_portal() {  # <dir>
  local dir=$1 i
  mkdir -p "$dir"
  PORTAL_DIR=$dir python3 - <<'PY' &
import http.server, json, os, time
d = os.environ["PORTAL_DIR"]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = len([f for f in os.listdir(d) if f.startswith("req-")])
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(os.path.join(d, "req-%d.json" % n), "w") as fh:
            json.dump({"path": self.path, "auth": self.headers.get("Authorization"),
                       "body": json.loads(body)}, fh)
        status = 200
        if os.path.exists(os.path.join(d, "status")):
            status = int(open(os.path.join(d, "status")).read())
        if status == 200:
            with open(os.path.join(d, "receipts.jsonl"), "a") as fh:
                for r in json.loads(body)["receipts"]:
                    fh.write(json.dumps(r) + "\n")
            closed = set()
            if not os.path.exists(os.path.join(d, "ignore-receipts")):
                with open(os.path.join(d, "receipts.jsonl")) as fh:
                    closed = {json.loads(l)["answer_id"] for l in fh if l.strip()}
            try:
                with open(os.path.join(d, "answers.json")) as fh:
                    answers = json.load(fh)
            except (OSError, ValueError):
                answers = []
            out = {"answers": [a for a in answers if a["answer_id"] not in closed]}
            if not out["answers"]:
                time.sleep(min(json.loads(body)["wait_seconds"], 1))
        else:
            out = {"code": "refused", "message": "refused", "request_id": "r1"}
        data = json.dumps(out).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port.tmp"), "w") as fh:
    fh.write(str(srv.server_address[1]))
os.rename(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
srv.serve_forever()
PY
  PORTAL_PID=$!
  printf '%s\n' "$PORTAL_PID" >> "$TMP_ROOT/portal-pids"
  i=0
  while [ ! -s "$dir/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  PORTAL_URL="http://127.0.0.1:$(cat "$dir/port")"
}

stop_portal() { kill "$PORTAL_PID" 2>/dev/null; wait "$PORTAL_PID" 2>/dev/null || true; }

# A failing case exits before its stop_portal, so every portal still running
# is stopped on the way out.
stop_portals() {
  local pid
  [ -f "$TMP_ROOT/portal-pids" ] || return 0
  while IFS= read -r pid; do kill "$pid" 2>/dev/null || true; done < "$TMP_ROOT/portal-pids"
}
trap 'stop_portals; fm_test_cleanup' EXIT

abridge() {  # <tree> <home> <args...>; sets OUT, ERR, CODE
  local tree=$1 home=$2
  shift 2
  run_n=$((run_n + 1))
  OUT="$OUTPUTS/$run_n.out"
  ERR="$OUTPUTS/$run_n.err"
  CODE=0
  FM_HOME="$home" FM_TODAY_PORTAL_URL=${PORTAL_URL:-} FM_TODAY_BRIDGE_TOKEN=$TOKEN \
    "$tree/bin/fm-today-bridge.sh" "$@" > "$OUT" 2> "$ERR" || CODE=$?
}

hash_of() {  # <tree> <home> <task> [<owner>]
  FM_HOME="$2" "$1/bin/fm-today-bridge.sh" snapshot 2>/dev/null \
    | jq -r --arg t "$3" --arg o "${4:-(main)}" '.sections.calls[] | select(.task_id == $t and .owner == $o) | .card_hash'
}

# answer <id> <task> <kind> <value> <card_hash> [<extra-json>]: one answer; a
# merge or go answer carries a passkey assertion whose client data holds the
# challenge the contract derives, so it is well-formed in every checked way.
answer() {
  local doc challenge extra=${6:-}
  [ -n "$extra" ] || extra='{}'
  doc=$(jq -nc --arg id "$1" --arg t "$2" --arg k "$3" --arg v "$4" --arg h "$5" --argjson x "$extra" \
    '{schema: "fm-today-answer.v1", answer_id: $id, task_id: $t, kind: $k, value: $v, card_hash: $h,
      answered_at: "2026-09-30T01:00:00Z", person: "captain", device: "phone-1"} + $x')
  case "$3" in
    merge|go)
      # Answers are built side by side in process substitutions, so each
      # gets its own file.
      printf '%s' "$doc" > "$TMP_ROOT/answer-doc.$1.json"
      challenge=$(python3 "$ROOT/tests/fm-today-contract-check.py" challenge "$TMP_ROOT/answer-doc.$1.json")
      doc=$(jq -c --arg c "$challenge" --arg o "$PASSKEY_ORIGIN" '. + {passkey: {
          credential_id: "Y3JlZC0x", authenticator_data: "YXV0aC1kYXRh", signature: "c2ln",
          client_data_json: ({type: "webauthn.get", challenge: $c, origin: $o} | tojson | @base64
                             | gsub("\\+"; "-") | gsub("/"; "_") | gsub("="; ""))}}' <<< "$doc")
      ;;
  esac
  printf '%s' "$doc"
}

summary_of() {  # <answer-id>: the answer-json line for it in $OUT
  sed -n 's/^answer-json: //p' "$OUT" | jq -c --arg id "$1" 'select(.answer_id == $id)'
}

row_of() { grep "^- \[.\] $2 " "$1/data/backlog.md"; }

test_held_calls_raise_merge_go_and_credential_cards() {
  local home snap pr=https://github.com/acme/widget/pull/12
  home=$(make_home home-calls)
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold ship-task --reason "merge the thing" \
    --call merge --pr "$pr" >/dev/null || fail "could not hold a merge call"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold call-clean --call go >/dev/null \
    || fail "could not hold a go call"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold call-dob --call credential >/dev/null \
    || fail "could not hold a credential call"
  bridge "$home" snapshot
  [ "$CODE" -eq 0 ] || fail "snapshot exited $CODE: $(cat "$ERR")"
  snap=$OUT
  "${CHECK[@]}" "$snap" >/dev/null || fail "the snapshot fails the contract: $("${CHECK[@]}" "$snap")"
  jq -e --arg pr "$pr" '.sections.calls[] | select(.task_id == "ship-task")
    | .kind == "merge" and .pr_url == $pr and .repo == "acme/widget"
      and ([.options[].value] == ["merge"])' "$snap" >/dev/null \
    || fail "a held merge call is not a merge card: $(jq -c '.sections.calls[] | select(.task_id == "ship-task")' "$snap")"
  jq -e '.sections.calls[] | select(.task_id == "call-clean")
    | .kind == "go" and ([.options[].value] == ["go"]) and (has("pr_url") | not)' "$snap" >/dev/null \
    || fail "a held go call is not a go card"
  jq -e '.sections.calls[] | select(.task_id == "call-dob")
    | .kind == "credential" and .options == [] and .text_check.verdict == "withheld"' "$snap" >/dev/null \
    || fail "a held credential call is not a credential card"
  jq -e '[.sections.calls[] | select(.task_id == "call-email") | .kind] == ["decision"]' "$snap" >/dev/null \
    || fail "an ordinary call stopped being a decision card"
  pass "a held merge, go, or credential call is raised as a card of that kind"
}

test_recorded_options_lead_a_decision_card() {
  local tree=$TMP_ROOT/answers-tree home snap
  home=$(make_answers_home answers-home-options)
  abridge "$tree" "$home" snapshot
  snap=$OUT
  "${CHECK[@]}" "$snap" >/dev/null || fail "the snapshot fails the contract: $("${CHECK[@]}" "$snap")"
  [ "$(jq -c '.sections.calls[] | select(.task_id == "q-pick" and .owner == "(main)") | [.options[].value]' "$snap")" \
    = '["east","west","reconcile"]' ] || fail "recorded options do not lead the decision card"
  [ "$(jq -c '.sections.calls[] | select(.task_id == "q-later") | [.options[].value]' "$snap")" = '["reconcile"]' ] \
    || fail "a call with no recorded options does not offer reconcile alone"
  pass "a decision card offers the hold's recorded options, then reconcile"
}

test_answers_decision_closes_and_held_work_needs_proof() {
  local tree=$TMP_ROOT/answers-tree home portal=$TMP_ROOT/portal-close s held_before
  home=$(make_answers_home answers-home-close)
  start_portal "$portal"
  jq -s . <(answer ans_pick_0001 q-pick decision east "$(hash_of "$tree" "$home" q-pick)" '{"note":"East, the tracks are in."}') \
    <(answer ans_held_0001 w-held decision resume "$(hash_of "$tree" "$home" w-held)") \
    <(jq -nc '{schema: "fm-today-receipt.v1", answer_id: "ans_wrong_0001", task_id: "q-pick",
               outcome: "applied", recorded_at: "2026-09-30T01:00:00Z"}') \
    <(jq -nc '{schema: "fm-today-answer.v1", answer_id: "ans_bare_0001", task_id: "q-pick"}') > "$portal/answers.json"
  abridge "$tree" "$home" answers once
  [ "$CODE" -eq 0 ] || fail "answers once exited $CODE: $(cat "$ERR")"
  s=$(summary_of ans_pick_0001)
  [ "$(jq -r '.outcome + " " + .action' <<< "$s")" = "applied closed" ] || fail "the decision was not closed: $s"
  [ "$(jq -r .note <<< "$s")" = "East, the tracks are in." ] || fail "the note did not reach firstmate: $s"
  row_of "$home" q-pick | grep -q '^- \[x\] q-pick ' || fail "the captain question is not closed: $(row_of "$home" q-pick)"
  grep -q 'Answer: east' "$home/data/backlog.md" || fail "the answer was not recorded"
  grep -q 'Answer as shown to the captain: East first' "$home/data/backlog.md" \
    || fail "the option label was not recorded"
  grep -q 'Captain answered this call through Today answer ans_pick_0001 on device phone-1; captain note: East, the tracks are in.' \
    "$home/data/backlog.md" || fail "the answer's provenance and note were not recorded"
  held_before=$(row_of "$home" w-held)
  s=$(summary_of ans_held_0001)
  [ "$(jq -r '.outcome + " " + .action' <<< "$s")" = "refused refused" ] || fail "held work was released: $s"
  jq -e '.reason | startswith("proof_required: ")' <<< "$s" >/dev/null || fail "held work was not refused for proof: $s"
  [ "$(row_of "$home" w-held)" = "$held_before" ] || fail "held work changed: $(row_of "$home" w-held)"
  row_of "$home" w-held | grep -q 'hold-kind' || fail "held work is no longer held: $(row_of "$home" w-held)"
  s=$(summary_of ans_wrong_0001)
  [ "$(jq -r '.outcome + " " + .action' <<< "$s")" = "refused refused" ] || fail "a receipt-shaped answer was carried: $s"
  grep -q 'ans_bare_0001' "$OUT" || fail "an answer with no kind or value was not receipted: $(cat "$OUT")"
  [ "$(jq -c '.body.receipts' "$portal/req-0.json")" = '[]' ] || fail "the first call sent a receipt"
  [ "$(jq -r '.body.wait_seconds' "$portal/req-0.json")" = 0 ] || fail "once did not send wait_seconds 0"
  [ "$(jq -r .auth "$portal/req-0.json")" = "Bearer $TOKEN" ] || fail "the answers call did not carry the token"
  [ "$(jq -r .path "$portal/req-0.json")" = /api/fleet/answers ] || fail "the answers call went elsewhere"
  abridge "$tree" "$home" answers once --wait 3
  [ "$CODE" -eq 0 ] || fail "the second call exited $CODE: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "an answer was carried twice: $(cat "$OUT")"
  [ "$(jq -r '.body.wait_seconds' "$portal/req-1.json")" = 3 ] || fail "--wait did not reach the body"
  [ "$(jq -c '[.body.receipts[] | [.answer_id, .outcome]] | sort' "$portal/req-1.json")" \
    = '[["ans_bare_0001","refused"],["ans_held_0001","refused"],["ans_pick_0001","applied"],["ans_wrong_0001","refused"]]' ] \
    || fail "the receipts did not go out on the next call: $(jq -c .body "$portal/req-1.json")"
  jq -c '.body.receipts[]' "$portal/req-1.json" | while IFS= read -r s; do
    printf '%s' "$s" > "$TMP_ROOT/receipt.json"
    "${CHECK[@]}" "$TMP_ROOT/receipt.json" >/dev/null || fail "a receipt fails the contract: $s"
  done
  abridge "$tree" "$home" answers once
  [ "$(jq -c '.body.receipts' "$portal/req-2.json")" = '[]' ] || fail "a sent receipt went out again"
  stop_portal
  pass "a decision answer closes its question, held work is refused for proof, a malformed answer is refused, and one receipt each follows"
}

# An unbound home applies nothing: the Today source feeds the hold lifecycle
# only once its source id is bound, as every captured-answer source does.
test_answers_unbound_home_applies_nothing() {
  local tree=$TMP_ROOT/answers-tree home portal=$TMP_ROOT/portal-unbound before s id
  home=$(make_answers_home answers-home-unbound)
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" unbind today-bridge >/dev/null \
    || fail "could not unbind the bridge's source"
  before=$(cat "$home/data/backlog.md")
  start_portal "$portal"
  jq -s . <(answer ans_ub_pick_01 q-pick decision east "$(hash_of "$tree" "$home" q-pick)") \
    <(answer ans_ub_later_01 q-later decision later "$(hash_of "$tree" "$home" q-later)" '{"later_until":"2026-10-04T15:00:00Z"}') \
    <(answer ans_ub_recon_01 q-recon decision reconcile "$(hash_of "$tree" "$home" q-recon)") > "$portal/answers.json"
  abridge "$tree" "$home" answers once
  [ "$CODE" -eq 0 ] || fail "answers once exited $CODE: $(cat "$ERR")"
  for id in ans_ub_pick_01 ans_ub_later_01 ans_ub_recon_01; do
    s=$(summary_of "$id")
    [ "$(jq -r '.outcome + " " + .action' <<< "$s")" = "refused refused" ] || fail "an unbound home applied $id: $s"
    jq -r .reason <<< "$s" | grep -q 'not bound' || fail "the refusal does not say the source is unbound: $s"
  done
  [ "$(cat "$home/data/backlog.md")" = "$before" ] || fail "an unbound home changed the backlog"
  [ ! -d "$home/state/reconcile-requests" ] || [ -z "$(ls -A "$home/state/reconcile-requests")" ] \
    || fail "an unbound home filed a reconcile request"
  stop_portal
  pass "a home whose Today source is not bound refuses every answer and applies nothing"
}

# Until firstmate checks the captain's passkey itself, a merge or go answer is
# refused however well-formed, and nothing that could merge, release, start,
# or close is ever run: this copy's hold, merge, spawn, send, and control
# scripts are tripwires.
test_answers_merge_and_go_are_refused_without_proof() {
  local tree=$TMP_ROOT/proof-tree home portal=$TMP_ROOT/portal-proof before f m g
  make_answers_tree "$tree"
  home=$(make_answers_home answers-home-proof)
  m=$(hash_of "$tree" "$home" m-fix)
  g=$(hash_of "$tree" "$home" g-build)
  for f in fm-captain-hold.sh fm-pr-merge.sh fm-merge-local.sh fm-spawn.sh fm-send.sh fm-control.sh fm-teardown.sh; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/tripwire"\nexit 0\n' "$f" "$TMP_ROOT/proof" > "$tree/bin/$f"
    chmod +x "$tree/bin/$f"
  done
  mkdir -p "$TMP_ROOT/proof"
  start_portal "$portal"
  jq -s . <(answer ans_merge_001 m-fix merge merge "$m") <(answer ans_go_00001 g-build go go "$g") \
    <(answer ans_mlater_01 m-fix merge later "$m" '{"later_until":"2026-10-02T09:00:00Z"}') \
    <(answer ans_mdec_0001 m-fix decision merge "$m") > "$portal/answers.json"
  for f in 0 1 2; do
    jq ".[$f]" "$portal/answers.json" > "$TMP_ROOT/proof-answer.json"
    "${CHECK[@]}" "$TMP_ROOT/proof-answer.json" >/dev/null \
      || fail "the merge or go answer is not well-formed: $("${CHECK[@]}" "$TMP_ROOT/proof-answer.json")"
  done
  before=$(cat "$home/data/backlog.md")
  abridge "$tree" "$home" answers once
  [ "$CODE" -eq 0 ] || fail "answers once exited $CODE: $(cat "$ERR")"
  for f in ans_merge_001 ans_go_00001 ans_mlater_01 ans_mdec_0001; do
    s=$(summary_of "$f")
    [ "$(jq -r .outcome <<< "$s")" = refused ] || fail "$f was not refused: $s"
    jq -e '.reason | startswith("proof_required: ")' <<< "$s" >/dev/null || fail "$f was not refused for proof: $s"
  done
  [ ! -e "$TMP_ROOT/proof/tripwire" ] || fail "a merge or go answer ran: $(cat "$TMP_ROOT/proof/tripwire")"
  [ "$(cat "$home/data/backlog.md")" = "$before" ] || fail "a merge or go answer changed the backlog"
  [ ! -d "$home/state/reconcile-requests" ] || fail "a merge or go answer filed a reconcile request"
  abridge "$tree" "$home" answers once
  [ "$(jq -c '[.body.receipts[] | select(.outcome == "refused" and (.reason | startswith("proof_required: "))) | .answer_id] | sort' "$portal/req-1.json")" \
    = '["ans_go_00001","ans_mdec_0001","ans_merge_001","ans_mlater_01"]' ] \
    || fail "the refusals were not receipted: $(jq -c .body.receipts "$portal/req-1.json")"
  stop_portal
  pass "a merge or go answer is recorded and refused for proof, and nothing is merged, released, or closed"
}

test_answers_that_do_not_fit_the_call_are_set_aside_or_refused() {
  local tree=$TMP_ROOT/answers-tree home portal=$TMP_ROOT/portal-stale before h s
  home=$(make_answers_home answers-home-stale)
  h=$(hash_of "$tree" "$home" q-pick)
  start_portal "$portal"
  jq -s . <(answer ans_stale_001 q-pick decision east "$(printf '0%.0s' {1..64})") \
    <(answer ans_gone_0001 q-gone decision east "$h") \
    <(answer ans_offer_001 q-pick decision north "$h") \
    <(answer ans_bad_00001 q-pick decision east "$h" '{"later_until":"2026-10-02T09:00:00Z"}') \
    <(answer ans_note_0001 q-pick decision east "$h" "$(jq -nc '{note: ("é" * 300)}')") > "$portal/answers.json"
  before=$(cat "$home/data/backlog.md")
  abridge "$tree" "$home" answers once
  [ "$CODE" -eq 0 ] || fail "answers once exited $CODE: $(cat "$ERR")"
  s=$(summary_of ans_stale_001)
  [ "$(jq -r .outcome <<< "$s")" = set-aside ] || fail "a stale card_hash was not set aside: $s"
  [ "$(jq -r '.reason' <<< "$(summary_of ans_gone_0001)")" = "the call is no longer open" ] \
    || fail "an answer to a closed call was not refused: $(summary_of ans_gone_0001)"
  [ "$(jq -r '.reason' <<< "$(summary_of ans_offer_001)")" = "the card did not offer north" ] \
    || fail "an unoffered value was not refused: $(summary_of ans_offer_001)"
  jq -e '.outcome == "refused" and (.reason | startswith("invalid answer: "))' <<< "$(summary_of ans_bad_00001)" >/dev/null \
    || fail "an answer failing its schema was not refused: $(summary_of ans_bad_00001)"
  [ "$(jq -r '.reason' <<< "$(summary_of ans_note_0001)")" = "the note is over 512 bytes" ] \
    || fail "a note over 512 bytes was not refused: $(summary_of ans_note_0001)"
  [ "$(cat "$home/data/backlog.md")" = "$before" ] || fail "an answer that did not fit changed the backlog"
  abridge "$tree" "$home" answers once
  jq -e --arg h "$h" '.body.receipts[] | select(.answer_id == "ans_stale_001")
    | .outcome == "set-aside" and .current_card_hash == $h' "$portal/req-1.json" >/dev/null \
    || fail "the set-aside receipt does not carry the current card_hash: $(jq -c .body.receipts "$portal/req-1.json")"
  stop_portal
  pass "a stale card is set aside with its current hash; a closed call, unoffered value, bad shape, or long note is refused"
}

test_answers_later_reconcile_and_seen_never_close() {
  local tree=$TMP_ROOT/answers-tree home portal=$TMP_ROOT/portal-later want
  home=$(make_answers_home answers-home-later)
  start_portal "$portal"
  jq -s . <(answer ans_later_001 q-later decision later "$(hash_of "$tree" "$home" q-later)" \
      '{"later_until":"2031-03-04T12:00:00Z"}') \
    <(answer ans_recon_001 q-recon decision reconcile "$(hash_of "$tree" "$home" q-recon)" \
      '{"note":"I think it landed\nq-pick"}') \
    <(answer ans_badday_001 q-later decision later "$(hash_of "$tree" "$home" q-later)" \
      '{"later_until":"2026-02-30T00:00:00Z"}') \
    <(answer ans_seen_0001 c-key credential seen "$(hash_of "$tree" "$home" c-key)") > "$portal/answers.json"
  abridge "$tree" "$home" answers once
  [ "$CODE" -eq 0 ] || fail "answers once exited $CODE: $(cat "$ERR")"
  [ "$(jq -r '.outcome + " " + .action' <<< "$(summary_of ans_badday_001)")" = "refused refused" ] \
    || fail "an impossible later_until was not refused: $(summary_of ans_badday_001)"
  want=2031-03-04  # the suite runs with TZ=UTC, so the captain's local date is the UTC one
  [ "$(jq -r '.action + " " + .reason' <<< "$(summary_of ans_later_001)")" = "deferred deferred until $want" ] \
    || fail "later was not a deferral: $(summary_of ans_later_001)"
  row_of "$home" q-later | grep -q "(hold-kind: captain) (hold-until: $want)" \
    || fail "later did not re-hold the call until its date: $(row_of "$home" q-later)"
  [ "$(jq -r .action <<< "$(summary_of ans_recon_001)")" = reconcile-requested ] \
    || fail "reconcile did not file a request: $(summary_of ans_recon_001)"
  grep -q '^source=Today answer ans_recon_001 on device phone-1; captain note: I think it landed q-pick$' \
    "$home/state/reconcile-requests/q-recon.request" || fail "the reconcile request lacks its provenance"
  [ "$(ls "$home/state/reconcile-requests")" = q-recon.request ] \
    || fail "a line in the captain's note filed a request for another call: $(ls "$home/state/reconcile-requests")"
  row_of "$home" q-recon | grep -q '^- \[ \] q-recon .*(hold-kind: captain)' || fail "reconcile closed the call"
  [ "$(jq -r .action <<< "$(summary_of ans_seen_0001)")" = seen-recorded ] || fail "seen was not recorded"
  row_of "$home" c-key | grep -q '^- \[ \] c-key .*(hold-kind: captain)' || fail "seen closed the credential call"
  ! grep -q 'Resolution recorded' "$home/data/backlog.md" || fail "later, reconcile, or seen wrote a resolution"
  abridge "$tree" "$home" answers once
  [ "$(jq -c '[.body.receipts[] | [.answer_id, .outcome]] | sort' "$portal/req-1.json")" \
    = '[["ans_badday_001","refused"],["ans_later_001","applied"],["ans_recon_001","applied"],["ans_seen_0001","applied"]]' ] \
    || fail "every answer beside an impossible later_until did not get its receipt: $(jq -c .body "$portal/req-1.json")"
  stop_portal
  pass "later defers the call, reconcile files a request, and seen is recorded; none closes it, and an impossible later_until is refused alone"
}

test_answers_second_mate_answer_is_refused_in_every_home() {
  local tree=$TMP_ROOT/answers-tree home mate portal=$TMP_ROOT/portal-mate before mate_before s id
  home=$(make_answers_home answers-home-mate)
  mate=$(make_answers_home answers-mate-home)
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-09-20)\n' \
    "$mate" > "$home/data/secondmates.md"
  start_portal "$portal"
  jq -s . <(answer ans_mate_0001 q-pick decision reconcile "$(hash_of "$tree" "$home" q-pick mate)" \
    '{"owner":"mate","note":"re-check it"}') \
    <(answer ans_mate_0002 q-pick decision east "$(hash_of "$tree" "$home" q-pick mate)" '{"owner":"mate"}') \
    > "$portal/answers.json"
  before=$(cd "$home" && find data state -type f ! -path 'state/today-answers/*' -exec cksum {} + | sort)
  mate_before=$(cd "$mate" && find . -type f -exec cksum {} + | sort)
  abridge "$tree" "$home" answers once
  [ "$CODE" -eq 0 ] || fail "answers once exited $CODE: $(cat "$ERR")"
  for id in ans_mate_0001 ans_mate_0002; do
    s=$(summary_of "$id")
    [ "$(jq -r '.owner + " " + .outcome + " " + .action' <<< "$s")" = "mate refused refused" ] \
      || fail "a second mate's answer was not refused: $s"
    [ "$(jq -r .reason <<< "$s")" = "answer a second mate's call at the machine for now; nothing was applied" ] \
      || fail "the refusal does not carry the fixed reason: $s"
    [ "$(jq -r '.task_id + " " + .owner' "$home/state/today-answers/answers/$id.json")" = "q-pick mate" ] \
      || fail "the second mate's answer was not recorded"
  done
  [ "$(cd "$home" && find data state -type f ! -path 'state/today-answers/*' -exec cksum {} + | sort)" = "$before" ] \
    || fail "a second mate's answer changed this home"
  [ "$(cd "$mate" && find . -type f -exec cksum {} + | sort)" = "$mate_before" ] \
    || fail "a second mate's answer changed the mate's home"
  abridge "$tree" "$home" answers once
  [ "$(jq -c '[.body.receipts[] | select(.owner == "mate") | [.answer_id, .outcome]] | sort' "$portal/req-1.json")" \
    = '[["ans_mate_0001","refused"],["ans_mate_0002","refused"]]' ] \
    || fail "the refusals did not go out with the answer's owner: $(jq -c .body.receipts "$portal/req-1.json")"
  stop_portal
  pass "a second mate's answer, reconcile included, is recorded and refused, and changes nothing in either home"
}

# The receipt is written before the next call, so a failed call re-sends it and
# the answer is never carried twice; an answer the portal hands back after its
# receipt went out is answered duplicate.
test_answers_receipts_survive_a_failed_call_and_repeats_are_duplicates() {
  local tree=$TMP_ROOT/answers-tree home portal=$TMP_ROOT/portal-dup
  home=$(make_answers_home answers-home-dup)
  start_portal "$portal"
  jq -s . <(answer ans_dup_00001 q-pick decision east "$(hash_of "$tree" "$home" q-pick)") > "$portal/answers.json"
  abridge "$tree" "$home" answers once
  [ "$(jq -r .action <<< "$(summary_of ans_dup_00001)")" = closed ] || fail "the answer was not carried"
  printf '503' > "$portal/status"
  abridge "$tree" "$home" answers once
  [ "$CODE" -eq 3 ] || fail "a failed call exited $CODE, want 3: $(cat "$ERR")"
  grep -q 'answered 503' "$ERR" || fail "the failed call was not named: $(cat "$ERR")"
  [ ! -e "$home/state/today-answers/receipts/ans_dup_00001.sent" ] || fail "a receipt was marked sent on a failed call"
  rm -f "$portal/status"
  abridge "$tree" "$home" answers once
  [ "$(jq -c '[.body.receipts[].answer_id]' "$portal/req-2.json")" = '["ans_dup_00001"]' ] \
    || fail "the receipt was not re-sent after the failed call: $(jq -c .body "$portal/req-2.json")"
  [ "$(grep -c 'Resolution recorded' "$home/data/backlog.md")" = 1 ] || fail "the answer was carried twice"
  touch "$portal/ignore-receipts"
  abridge "$tree" "$home" answers once
  grep -qx 'duplicate: ans_dup_00001' "$OUT" || fail "a repeated answer was not recognized: $(cat "$OUT")"
  ! grep -q '^answer-json: ' "$OUT" || fail "a repeated answer was carried again"
  rm -f "$portal/ignore-receipts"
  abridge "$tree" "$home" answers once
  [ "$(jq -c '[.body.receipts[] | [.answer_id, .outcome]]' "$portal/req-4.json")" = '[["ans_dup_00001","duplicate"]]' ] \
    || fail "the repeat was not answered duplicate: $(jq -c .body "$portal/req-4.json")"
  [ "$(grep -c 'Resolution recorded' "$home/data/backlog.md")" = 1 ] || fail "a duplicate was carried"
  stop_portal
  pass "a receipt survives a failed call and is re-sent, and a repeated answer is answered duplicate"
}

# A bridge that stopped after storing an answer but before its receipt may
# already have carried it, so the redelivered answer is refused, not carried.
test_answers_interrupted_carry_is_refused_not_carried_again() {
  local tree=$TMP_ROOT/answers-tree home portal=$TMP_ROOT/portal-interrupted s
  home=$(make_answers_home answers-home-interrupted)
  start_portal "$portal"
  jq -s . <(answer ans_intr_0001 q-later decision later "$(hash_of "$tree" "$home" q-later)" \
    '{"later_until":"2031-03-04T12:00:00Z"}') > "$portal/answers.json"
  mkdir -p "$home/state/today-answers/answers"
  jq '.[0]' "$portal/answers.json" > "$home/state/today-answers/answers/ans_intr_0001.json"
  abridge "$tree" "$home" answers once
  [ "$CODE" -eq 0 ] || fail "answers once exited $CODE: $(cat "$ERR")"
  s=$(summary_of ans_intr_0001)
  [ "$(jq -r '.outcome + " " + .action' <<< "$s")" = "refused refused" ] \
    || fail "an interrupted answer was not refused: $s"
  jq -r .reason <<< "$s" | grep -q 'check the call at the machine' \
    || fail "the refusal does not send the captain to the machine: $s"
  ! row_of "$home" q-later | grep -q 'hold-until' || fail "an interrupted answer was carried again"
  abridge "$tree" "$home" answers once
  [ "$(jq -c '[.body.receipts[] | [.answer_id, .outcome]]' "$portal/req-1.json")" = '[["ans_intr_0001","refused"]]' ] \
    || fail "the interrupted answer was not receipted: $(jq -c .body "$portal/req-1.json")"
  stop_portal
  pass "an answer stored without a receipt is refused and never carried again"
}

test_answers_poll_reports_through_the_process_event_adapter() {
  local tree=$TMP_ROOT/answers-tree home portal=$TMP_ROOT/portal-poll result
  home=$(make_answers_home answers-home-poll)
  start_portal "$portal"
  jq -s . <(answer ans_poll_0001 q-pick decision west "$(hash_of "$tree" "$home" q-pick)") > "$portal/answers.json"
  abridge "$tree" "$home" answers poll --wait 1
  [ "$CODE" -eq 0 ] || fail "poll exited $CODE: $(cat "$ERR")"
  result=$OUT
  [ "$(sed -n 2p "$result")" = "status: answers" ] || fail "poll did not report answers: $(cat "$result")"
  [ "$(jq -c '[.body.receipts[].answer_id]' "$portal/req-1.json")" = '["ans_poll_0001"]' ] \
    || fail "poll did not send the receipt before reporting"
  [ "$(FM_HOME="$home" "$tree/bin/fm-procevent-today-answers.sh" classify "$result")" = answers ] \
    || fail "the adapter does not classify the round as answers"
  FM_HOME="$home" "$tree/bin/fm-procevent-today-answers.sh" terminal "$result" \
    && fail "a round of answers retired the source"
  [ "$(FM_HOME="$home" "$tree/bin/fm-procevent-today-answers.sh" read "$result" | jq -r '.answers[0].action')" = closed ] \
    || fail "the adapter does not read the carried answer"
  printf '401' > "$portal/status"
  abridge "$tree" "$home" answers poll --wait 1
  [ "$CODE" -eq 0 ] || fail "poll on a refused token exited $CODE"
  [ "$(FM_HOME="$home" "$tree/bin/fm-procevent-today-answers.sh" classify "$OUT")" = error ] \
    || fail "a refused token is not an error round: $(cat "$OUT")"
  FM_HOME="$home" "$tree/bin/fm-procevent-today-answers.sh" terminal "$OUT" \
    || fail "an error round keeps the source armed"
  grep -q '^detail: the portal refused the bridge token (401)' "$OUT" || fail "the error round names no reason: $(cat "$OUT")"
  rm -f "$portal/status"
  stop_portal
  pass "poll carries answers, sends their receipts, and reports one round the adapter reads"
}

test_answers_refuse_bad_settings() {
  local home
  home=$(make_answers_home answers-home-config)
  PORTAL_URL='' abridge "$TMP_ROOT/answers-tree" "$home" answers once
  [ "$CODE" -eq 2 ] || fail "a missing URL exited $CODE, want 2"
  grep -q 'missing FM_TODAY_PORTAL_URL' "$ERR" || fail "the missing URL was not named: $(cat "$ERR")"
  PORTAL_URL=http://portal.example abridge "$TMP_ROOT/answers-tree" "$home" answers once
  if [ "$CODE" -ne 2 ] || ! grep -q 'nothing was sent' "$ERR"; then
    fail "plain http off loopback was not refused: $(cat "$ERR")"
  fi
  PORTAL_URL=http://portal.example abridge "$TMP_ROOT/answers-tree" "$home" answers check
  [ "$CODE" -eq 2 ] || fail "answers check accepted plain http off loopback"
  pass "the answers calls refuse a missing URL and plain http off loopback, sending nothing"
}

# Armed as a process-event source, the long-poll runs outside any turn: the
# runner starts it, the captain's answer is carried once, its receipt goes out,
# and firstmate is woken with the round. The source's own id is never bound, so
# the runner's generic keyed-answer feed never sees the answer.
test_armed_source_carries_answers_and_wakes_firstmate() {
  local home portal=$TMP_ROOT/portal-armed result i
  home=$(make_home home-armed)
  start_portal "$portal"
  printf 'FM_TODAY_PORTAL_URL=%s\nFM_TODAY_BRIDGE_TOKEN=%s\n' "$PORTAL_URL" "$TOKEN" > "$home/.env"
  answer ans_armed_001 call-clean decision reconcile "$(FM_HOME="$home" "$BRIDGE" snapshot 2>/dev/null \
    | jq -r '.sections.calls[] | select(.task_id == "call-clean") | .card_hash')" | jq -s . > "$portal/answers.json"
  export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$ROOT/bin/fm-procevent-today-answers.sh" arm --wait 1 > "$OUTPUTS/arm.out" 2>&1 \
    || fail "arm failed: $(cat "$OUTPUTS/arm.out")"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" binding today-answers >/dev/null 2>&1 \
    && fail "the process-event source itself was bound to the keyed-answer intake"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" binding today-bridge)" = '(any)' ] \
    || fail "arm did not bind the bridge's reconcile source"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  result=''
  for i in $(seq 1 300); do
    result=$(find "$home/state/procevent-inbox" -name 'today-answers.*.result' 2>/dev/null | head -1)
    [ -z "$result" ] || break
    sleep 0.1
  done
  [ -n "$result" ] || fail "no round was captured from the armed source"
  for i in $(seq 1 100); do
    ! grep -q 'procevent today-answers today-answers' "$home/state/.wake-queue" 2>/dev/null || break
    sleep 0.1
  done
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$ROOT/bin/fm-procevent-today-answers.sh" retire >/dev/null 2>&1 || true
  cp "$result" "$OUTPUTS/armed.result"
  [ "$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$ROOT/bin/fm-procevent-today-answers.sh" read "$result" | jq -r '.answers[0].action')" \
    = reconcile-requested ] || fail "the armed round did not carry the answer: $(cat "$result")"
  [ -f "$home/state/reconcile-requests/call-clean.request" ] || fail "the reconcile request was not filed"
  grep -q 'procevent today-answers today-answers' "$home/state/.wake-queue" \
    || fail "firstmate was not woken with the round: $(cat "$home/state/.wake-queue" 2>/dev/null)"
  [ "$(cat "$portal"/req-*.json | jq -s '[.[].body.receipts[] | select(.answer_id == "ans_armed_001")] | length')" = 1 ] \
    || fail "the receipt did not go out exactly once"
  stop_portal
  pass "armed as a process-event source, the long-poll carries answers and wakes firstmate"
}

test_snapshot_is_valid_and_withholds_each_rule_family
test_snapshot_carries_the_fleet
test_recorded_options_reach_the_card
test_card_hash_recomputes
test_every_row_carries_repo
test_every_row_carries_its_owner
test_every_decision_card_ends_with_reconcile
test_second_mate_calls_and_work_travel
test_snapshot_passes_the_portal_validator
test_cut_text_loses_its_partial_word
test_cut_after_a_number_is_withheld
test_mid_text_cut_loses_its_partial_word
test_day_from_file_and_empty_when_missing
test_board_row_carries_no_board_text
test_retired_source_boards
test_push_sends_with_the_bearer_header
test_push_reads_the_home_env
test_push_refuses_invalid_snapshot
test_push_reports_portal_refusal
test_push_refuses_plain_http_off_loopback
test_push_missing_config_sends_nothing
test_dry_run_writes_and_sends_nothing
test_push_sends_a_given_snapshot
test_held_calls_raise_merge_go_and_credential_cards
make_answers_tree "$TMP_ROOT/answers-tree"
test_recorded_options_lead_a_decision_card
test_answers_decision_closes_and_held_work_needs_proof
test_answers_unbound_home_applies_nothing
test_answers_merge_and_go_are_refused_without_proof
test_answers_that_do_not_fit_the_call_are_set_aside_or_refused
test_answers_later_reconcile_and_seen_never_close
test_answers_second_mate_answer_is_refused_in_every_home
test_answers_receipts_survive_a_failed_call_and_repeats_are_duplicates
test_answers_interrupted_carry_is_refused_not_carried_again
test_answers_poll_reports_through_the_process_event_adapter
test_answers_refuse_bad_settings
test_armed_source_carries_answers_and_wakes_firstmate
test_token_never_in_output

echo "all fm-today-bridge tests passed"
