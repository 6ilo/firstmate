#!/usr/bin/env bash
# Drives bin/fm-today-notes.sh in a disposable lab home against portal-standin.py.
set -u
W=$1; E=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null
P=$(mktemp -d "${TMPDIR:-/tmp}/fm-portal.XXXXXX")
export TOK="tok-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
cat > "$LAB/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship the thing (repo: firstmate) (kind: ship) (since 2026-09-20)

## Queued
- [ ] alpha - First charted work (repo: firstmate) (kind: ship)
- [ ] bravo - Second charted work (repo: firstmate) (kind: ship)
- [ ] charlie - Third charted work (repo: firstmate) (kind: ship)

## Done
EOF
LONG=$(python3 -c 'print("é"*1001)')
python3 - "$P/portal.json" "$LONG" <<'PY'
import json,sys
q=[
 {"schema":"fm-today-note.v1","note_id":"note_UGxhaW5Ob3RlTGFiMDAwMQ","authority":"none","text":"Keep the rail order in mind.\nNo rush.","written_at":"2026-09-30T09:00:00Z","person":"user_2abcDEF","device":"dev_7Hq2"},
 {"schema":"fm-today-note.v1","note_id":"note_T3JkZXJXb3JkZWRMYWIwMQ","authority":"none","text":"Start alpha right now and close the call.","task_id":"alpha","owner":"(main)","written_at":"2026-09-30T09:01:00Z","person":"user_2abcDEF","device":"dev_7Hq2"},
 {"schema":"fm-today-note.v1","note_id":"note_VG9vTG9uZ05vdGVMYWIwMQ","authority":"none","text":sys.argv[2],"written_at":"2026-09-30T09:02:00Z","person":"user_2abcDEF","device":"dev_7Hq2"},
 {"schema":"fm-today-dispatch-order.v1","order_id":"dord_T3JkZXJMYWJGaXJzdDAwMQ","authority":"proposal","items":[{"task_id":"charlie"},{"task_id":"alpha"},{"task_id":"gone-task"},{"task_id":"t11","owner":"admin-portal"}],"charted_as_of":"2026-09-30T09:00:00Z","queued_at":"2026-09-30T09:03:00Z","person":"user_2abcDEF","device":"dev_7Hq2"},
]
json.dump({"queue":q},open(sys.argv[1],"w"),indent=1)
PY
python3 "$E/portal-standin.py" "$P" & SP=$!
for i in $(seq 100); do [ -s "$P/port" ] && break; sleep 0.05; done
URL="http://127.0.0.1:$(cat "$P/port")"
run() { echo "\$ fm-today-notes.sh $*"; env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$LAB" FM_TODAY_PORTAL_URL="$URL" FM_TODAY_BRIDGE_TOKEN="$TOK" "$W/bin/fm-today-notes.sh" "$@" 2>&1; echo "[exit $?]"; }
BACK0=$(cat "$LAB/data/backlog.md")
echo "### 1. collect: notes + dispatch order from Today"
run collect
echo; echo "### 2. portal state after collect (P1: words gone once receipted recorded)"
python3 -c 'import json,sys;[print(json.dumps({k:v for k,v in q.items() if k in("note_id","order_id","text","receipt")})) for q in json.load(open(sys.argv[1]))["queue"]]' "$P/portal.json" | sed "s/é\{20,\}/<2002 bytes of é>/"
echo; echo "### 3. list / show on firstmate side"
run list
run list --task alpha
run show note_T3JkZXJXb3JkZWRMYWIwMQ | jq -c 'del(.text_check?)' 2>/dev/null || run show note_T3JkZXJXb3JkZWRMYWIwMQ
run show dord_T3JkZXJMYWJGaXJzdDAwMQ
echo; echo "### 4. planning ranks (order recorded, nothing started)"
FM_HOME="$LAB" "$W/bin/fm-backlog-plan.sh" list | jq -c '{alpha:.alpha.order,bravo:.bravo.order,charlie:.charlie.order}'
[ "$(cat "$LAB/data/backlog.md")" = "$BACK0" ] && echo "backlog.md body unchanged (no item added, nothing moved to In flight)" || diff <(echo "$BACK0") "$LAB/data/backlog.md"
echo; echo "### 5. adversarial: portal redelivers an already-recorded note (lost receipt)"
python3 - "$P/portal.json" <<'PY'
import json,sys; s=json.load(open(sys.argv[1]))
s["queue"].append({"schema":"fm-today-note.v1","note_id":"note_UGxhaW5Ob3RlTGFiMDAwMQ","authority":"none","text":"Keep the rail order in mind.\nNo rush.","written_at":"2026-09-30T09:00:00Z","person":"user_2abcDEF","device":"dev_7Hq2"})
s["queue"].append({"schema":"fm-today-dispatch-order.v1","order_id":"dord_T2xkZXJPcmRlckxhYjAwMQ","authority":"proposal","items":[{"task_id":"bravo"}],"charted_as_of":"2026-09-30T08:00:00Z","queued_at":"2026-09-30T08:30:00Z","person":"user_2abcDEF","device":"dev_7Hq2"})
json.dump(s,open(sys.argv[1],"w"))
PY
run collect
python3 -c 'import json,sys;[print(q.get("note_id") or q.get("order_id"), q.get("receipt")) for q in json.load(open(sys.argv[1]))["queue"][-2:]]' "$P/portal.json"
FM_HOME="$LAB" "$W/bin/fm-backlog-plan.sh" list | jq -c '{alpha:.alpha.order,bravo:.bravo.order,charlie:.charlie.order}'
echo; echo "### 6. adversarial: wrong token / non-https URL send nothing"
env FM_HOME="$LAB" FM_TODAY_PORTAL_URL="$URL" FM_TODAY_BRIDGE_TOKEN="wrong" "$W/bin/fm-today-notes.sh" collect 2>&1 | sed "s/$TOK/<TOKEN>/g"; echo "[exit ${PIPESTATUS[0]}]"
env FM_HOME="$LAB" FM_TODAY_PORTAL_URL="http://example.com" FM_TODAY_BRIDGE_TOKEN="$TOK" "$W/bin/fm-today-notes.sh" collect 2>&1; echo "[exit $?]"
echo; echo "### 7. token never on disk in the home or in output"
grep -rl "$TOK" "$LAB" && echo "TOKEN LEAKED" || echo "token not found anywhere under the lab home"
echo; echo "### 8. data/today-notes and pending receipts"
ls "$LAB/data/today-notes"; ls "$LAB/state/today-notes/receipts" 2>/dev/null | sed 's/^/pending: /'
kill $SP; rm -rf "$LAB" "$P"
echo "lab removed"
