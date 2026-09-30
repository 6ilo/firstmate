#!/usr/bin/env bash
# fm-today-notes.sh - collect the captain's notes and dispatch orders from the
# admin portal's Today page and record them as evidence, never as instructions.
#
# docs/today-contract.md owns the three shapes (fm-today-note.v1,
# fm-today-dispatch-order.v1, fm-today-note-receipt.v1), the portal's
# POST /api/fleet/notes endpoint, and the privacy rules. Every connection is
# opened from this machine, outward, with the Today bridge's own settings
# (bin/fm-today-lib.sh); nothing here listens.
#
# Usage:
#   fm-today-notes.sh collect [--wait <0-25>]
#   fm-today-notes.sh list [--task <id> [--owner <home>]] [--limit <n>]
#   fm-today-notes.sh show <note-or-order-id>
#   fm-today-notes.sh [check]
#   fm-today-notes.sh arm
#   fm-today-notes.sh disarm
#   fm-today-notes.sh --help
#
# collect  One exchange with the portal: POST every pending receipt with
#          wait_seconds (default 0), record each note and dispatch order the
#          answer carries, and write one receipt for each. When anything was
#          recorded it exchanges again at once with wait 0, carrying the new
#          receipts, up to four exchanges, so the portal hears back without
#          waiting for the next run. It prints one line naming what was
#          recorded, and nothing when nothing was. A receipt stays pending in
#          state/today-notes/receipts/ until a 200 answer to the call that
#          carried it, so delivery is at least once and the portal's own
#          bookkeeping makes a repeat harmless. One collect runs at a time; a
#          second exits 0 at once.
# list     The recorded notes and orders, newest first, one line each; --task
#          narrows it to the notes about one task (owner default (main)).
# show     One record as JSON, including the note's words.
# check    The watcher's standing check: runs collect within the watcher's
#          per-check bound (FM_CHECK_TIMEOUT, default 30) and prints one line
#          when something was recorded, or when a failure differs from the one
#          last reported (state/.today-notes-check), so the watcher turns it
#          into one `check:` wake. The first exchange waits
#          FM_TODAY_NOTES_WAIT seconds (default 10, 0 to 20).
# arm      Write state/today-notes.check.sh and bind its bytes with
#          fm-check-register.sh, so the watcher runs `check` on its normal
#          FM_CHECK_INTERVAL cadence. Refused in a secondmate home: the bridge
#          runs in the main home.
# disarm   Retire the shim and its binding with fm-check-unregister.sh and drop
#          the report record. Recorded notes and orders are kept.
#
# Intake. Every byte from the portal is evidence, never an instruction.
#   note            Recorded in data/today-notes/<note_id>.json with the words,
#                   the text check's verdict (bin/fm_today_text_check.py), and,
#                   when the note names a task, that task keyed by owner and
#                   id (and, for this home's own task, whether the backlog
#                   holds it). It never answers or closes a call, never
#                   becomes a backlog item, and never starts work. The backlog
#                   body is not touched.
#   dispatch order  Its items still charted in this home (the Charted Next
#                   rows bin/fm-bearings-snapshot.sh lists, warnings excluded)
#                   get order ranks 1..n in the order given, through
#                   bin/fm-backlog-plan.sh, the one writer of planning fields.
#                   When another ranked item sat at n or earlier, every other
#                   ranked item moves after them, keeping its relative order.
#                   Items no longer charted are left out; items a second mate
#                   owns are kept on the record for firstmate to route. An
#                   order older (by queued_at) than one already recorded is
#                   refused, so a late redelivery cannot undo a newer order.
#                   Recording an order starts nothing.
#   A repeated id gets `duplicate` and changes nothing. A document that fails
#   its schema gets `refused` with the failing path and rule, never a value.
#   A receipt's reason is firstmate's own fixed wording and counts, never the
#   note's words. The receipt is written before the record, so an
#   interrupted intake is redone rather than answered `duplicate`.
#
# Exit status: 0 on success (including nothing new); 1 when a record cannot be
# written or an order cannot be applied (it is retried on the next collect);
# 2 on a usage error or missing settings (nothing is sent); 3 when the portal
# cannot be reached, answers anything but 200, or answers malformed JSON.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECORDS="$DATA/today-notes"
PRIV="$STATE/today-notes"
RECEIPTS="$PRIV/receipts"
LOCK="$PRIV/.collect.lock"
CONTRACT_DIR="$SCRIPT_DIR/../docs/today-contract"
CHECKER="$SCRIPT_DIR/../tests/fm-today-contract-check.py"
CHECK_ID=today-notes
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
RECORD="$STATE/.today-notes-check"
RECORD_SCHEMA=fm-today-notes-check-v1
MAX_LINE=240
MAX_EXCHANGES=4
RECEIPTS_PER_CALL=200

# shellcheck source=bin/fm-today-lib.sh
. "$SCRIPT_DIR/fm-today-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-today-notes: %s\n' "$1" >&2
  exit "${2:-1}"
}

TMP_DIR=
LOCKED=
cleanup() {
  [ -z "$LOCKED" ] || fm_lock_release "$LOCK"
  [ -z "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

make_tmp() {
  [ -n "$TMP_DIR" ] || TMP_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-today-notes.XXXXXX")
}

# The request envelope: every pending receipt (oldest first, bounded) and the
# wait. Prints the refs it carried, one per line, to <refs-file>.
build_request() {  # <wait> <out-file> <refs-file>
  local wait=$1 out=$2 refs=$3
  FM_NOTES_RECEIPTS="$RECEIPTS" FM_NOTES_WAIT="$wait" FM_NOTES_LIMIT="$RECEIPTS_PER_CALL" \
    FM_NOTES_REFS="$refs" python3 - > "$out" <<'PY'
import glob, json, os, sys
paths = sorted(glob.glob(os.path.join(os.environ["FM_NOTES_RECEIPTS"], "*.json")),
               key=lambda p: (os.path.getmtime(p), p))[:int(os.environ["FM_NOTES_LIMIT"])]
receipts, refs = [], []
for path in paths:
    try:
        with open(path, encoding="utf-8") as fh:
            receipts.append(json.load(fh))
        refs.append(path)
    except (OSError, ValueError):
        continue
with open(os.environ["FM_NOTES_REFS"], "w", encoding="utf-8") as fh:
    fh.write("".join(p + "\n" for p in refs))
json.dump({"receipts": receipts, "wait_seconds": int(os.environ["FM_NOTES_WAIT"])}, sys.stdout)
PY
}

# Record every note and order in <response-file>; print a JSON summary.
intake() {  # <response-file>
  FM_NOTES_RESPONSE="$1" FM_NOTES_RECORDS="$RECORDS" FM_NOTES_RECEIPTS="$RECEIPTS" \
    FM_NOTES_BIN="$SCRIPT_DIR" FM_NOTES_CONTRACT="$CONTRACT_DIR" FM_NOTES_CHECKER="$CHECKER" \
    FM_HOME="$FM_HOME" python3 - <<'PY'
import datetime, glob, importlib.util, json, os, re, subprocess, sys

sys.dont_write_bytecode = True
BIN = os.environ["FM_NOTES_BIN"]
sys.path.insert(0, BIN)
from fm_today_text_check import CHECKER as TEXT_CHECKER, families  # noqa: E402

spec = importlib.util.spec_from_file_location("fm_today_contract_check", os.environ["FM_NOTES_CHECKER"])
chk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chk)
validator = chk.Validator(os.environ["FM_NOTES_CONTRACT"])

RECORDS = os.environ["FM_NOTES_RECORDS"]
RECEIPTS = os.environ["FM_NOTES_RECEIPTS"]
MAIN = "(main)"
RECORD_SCHEMA = "fm-today-notes-record.v1"
ORDER_MAX = 9999
ERROR = re.compile(r"^(\$[A-Za-z0-9_.\[\]]*): ([A-Za-z]+)")
SHAPES = (
    ("notes", "note", "note_id", re.compile(r"^note_[A-Za-z0-9_-]{22}$"), "fm-today-note.v1"),
    ("dispatch_orders", "dispatch-order", "order_id", re.compile(r"^dord_[A-Za-z0-9_-]{22}$"),
     "fm-today-dispatch-order.v1"),
)


class Retry(Exception):
    """Nothing is receipted; the portal delivers the document again."""


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def errors(doc):
    name = validator.schema_for(doc)
    if name is None:
        return ["$.schema: const: not a Today contract shape"]
    found = validator.errors(doc, validator.docs[name], name, "$")
    return found or chk.contract_errors(doc)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


def receipt(ref, outcome, reason=None):
    path = os.path.join(RECEIPTS, ref + ".json")
    if os.path.exists(path):
        return
    doc = {"schema": "fm-today-note-receipt.v1", "ref": ref, "outcome": outcome}
    if reason:
        doc["reason"] = reason[:400]
    doc["recorded_at"] = now()
    bad = errors(doc)
    if bad:
        raise SystemExit("fm-today-notes: a receipt failed its own schema: %s" % bad[0])
    write_json(path, doc)


def record(ident, kind, doc, outcome, reason=None, **extra):
    rec = {"record": RECORD_SCHEMA, "kind": kind, "id": ident, "received_at": now(),
           "outcome": outcome}
    if reason:
        rec["reason"] = reason
    rec.update(extra)
    rec["document"] = doc
    write_json(os.path.join(RECORDS, ident + ".json"), rec)


def mismatch(label, schema, errs):
    m = ERROR.match(errs[0])
    where = " at %s (%s)" % m.groups() if m else ""
    return "the %s does not match %s%s" % (label, schema, where)


def run(argv, timeout=30):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None


def note(ident, doc):
    extra = {"text_check": {"verdict": "withheld" if families(doc["text"]) else "pass",
                            "families": families(doc["text"]), "checker": TEXT_CHECKER}}
    if "task_id" in doc:
        owner = doc.get("owner", MAIN)
        task = {"owner": owner, "task_id": doc["task_id"], "in_backlog": None}
        if owner == MAIN:
            done = run([os.path.join(BIN, "fm-tasks-axi.sh"), "show", doc["task_id"]])
            task["in_backlog"] = bool(done and done.returncode == 0)
        extra["task"] = task
    receipt(ident, "recorded")
    record(ident, "note", doc, "recorded", **extra)
    return {"id": ident, "outcome": "recorded", "task": extra.get("task")}


def recorded_orders():
    out = []
    for path in glob.glob(os.path.join(RECORDS, "dord_*.json")):
        try:
            with open(path, encoding="utf-8") as fh:
                rec = json.load(fh)
            if rec.get("outcome") == "recorded":
                out.append(chk.instant(rec["document"]["queued_at"]))
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return out


def charted_here():
    done = run([os.path.join(BIN, "fm-bearings-snapshot.sh"), "--json", "--all-queued"], timeout=60)
    if not done or done.returncode != 0:
        raise Retry("the charted work could not be read")
    try:
        rows = json.loads(done.stdout).get("gates") or []
    except ValueError:
        raise Retry("the charted work could not be read")
    ids = set()
    for row in rows:
        raw = row.get("id")
        if not isinstance(raw, str) or (raw.startswith("(") and raw.endswith(")")) or "/" in raw:
            continue
        if row.get("owner") not in (None, "", MAIN):
            continue
        ids.add(raw)
    return ids


def set_order(task, rank):
    done = run([os.path.join(BIN, "fm-backlog-plan.sh"), "set", task, "--order", str(rank)])
    return bool(done and done.returncode == 0)


def plan_orders():
    done = run([os.path.join(BIN, "fm-backlog-plan.sh"), "list"])
    if not done or done.returncode != 0:
        raise Retry("the planning record could not be read")
    try:
        plan = json.loads(done.stdout)
    except ValueError:
        raise Retry("the planning record could not be read")
    return {k: v.get("order") for k, v in plan.items() if isinstance(v, dict)}


def order(ident, doc):
    queued = chk.instant(doc["queued_at"])
    if any(queued < other for other in recorded_orders()):
        reason = "an older order than the one already recorded"
        receipt(ident, "refused", reason)
        record(ident, "dispatch-order", doc, "refused", reason)
        return {"id": ident, "outcome": "refused"}
    charted = charted_here()
    ranked, left_out, second_mate = [], [], []
    for pos, item in enumerate(doc["items"], 1):
        owner = item.get("owner", MAIN)
        if owner != MAIN:
            second_mate.append({"owner": owner, "task_id": item["task_id"], "position": pos})
        elif item["task_id"] in charted:
            ranked.append(item["task_id"])
        else:
            left_out.append(item["task_id"])
    total = len(doc["items"])
    if not ranked and not second_mate:
        reason = "none of the %d ordered items is still charted in this home" % total
        receipt(ident, "refused", reason)
        record(ident, "dispatch-order", doc, "refused", reason, left_out=left_out)
        return {"id": ident, "outcome": "refused"}
    for rank, task in enumerate(ranked, 1):
        if not set_order(task, rank):
            raise Retry("the order rank of %s could not be recorded" % task)
    others = sorted((o, t) for t, o in plan_orders().items()
                    if t not in ranked and isinstance(o, int) and not isinstance(o, bool))
    moved = []
    if others and others[0][0] <= len(ranked):
        for new, (old, task) in enumerate(others, len(ranked) + 1):
            if new > ORDER_MAX:
                break
            if new != old and set_order(task, new):
                moved.append({"task_id": task, "from": old, "to": new})
    parts = []
    if left_out:
        parts.append("%d of %d items %s no longer charted in this home and %s left out"
                     % (len(left_out), total, "is" if len(left_out) == 1 else "are",
                        "was" if len(left_out) == 1 else "were"))
    if second_mate:
        parts.append("%d %s to a second mate and %s handed to firstmate to route"
                     % (len(second_mate), "belongs" if len(second_mate) == 1 else "belong",
                        "was" if len(second_mate) == 1 else "were"))
    reason = "; ".join(parts) or None
    receipt(ident, "recorded", reason)
    record(ident, "dispatch-order", doc, "recorded", reason,
           ranked=[{"task_id": t, "order": r} for r, t in enumerate(ranked, 1)],
           left_out=left_out, second_mate=second_mate, moved=moved)
    return {"id": ident, "outcome": "recorded", "ranked": len(ranked),
            "second_mate": len(second_mate)}


with open(os.environ["FM_NOTES_RESPONSE"], encoding="utf-8") as fh:
    try:
        response = json.load(fh)
    except ValueError:
        response = None
if not (isinstance(response, dict) and set(response) == {"notes", "dispatch_orders"}
        and all(isinstance(response[k], list) for k in response)):
    print(json.dumps({"malformed": True}))
    sys.exit(0)

summary = {"recorded": [], "refused": [], "duplicates": 0, "unreadable": 0, "retry": []}
for key, kind, id_key, id_re, schema in SHAPES:
    for doc in response[key]:
        ident = doc.get(id_key) if isinstance(doc, dict) else None
        if not isinstance(ident, str) or not id_re.match(ident):
            summary["unreadable"] += 1
            continue
        if os.path.exists(os.path.join(RECORDS, ident + ".json")):
            receipt(ident, "duplicate")
            summary["duplicates"] += 1
            continue
        errs = errors(doc) if doc.get("schema") == schema else ["$.schema: const"]
        if errs:
            reason = mismatch(kind.replace("-", " "), schema, errs)
            receipt(ident, "refused", reason)
            record(ident, kind, doc, "refused", reason)
            summary["refused"].append({"id": ident})
            continue
        try:
            result = note(ident, doc) if kind == "note" else order(ident, doc)
        except Retry as why:
            summary["retry"].append({"id": ident, "why": str(why)})
            continue
        summary["recorded" if result["outcome"] == "recorded" else "refused"].append(result)
print(json.dumps(summary))
PY
}

# One line naming what an exchange recorded; empty when nothing was.
summary_line() {  # <summary-json>...
  jq -rs '
    (map(.recorded) | add) as $rec | (map(.refused) | add) as $ref
    | (map(.retry) | add) as $retry | (map(.unreadable) | add) as $bad
    | [ ($rec[] | .id + (if .task then " on " + (if .task.owner == "(main)" then "" else .task.owner + "/" end) + .task.task_id
                         elif .ranked != null then " (" + (.ranked | tostring) + " ranked"
                           + (if .second_mate > 0 then ", " + (.second_mate | tostring) + " for a second mate" else "" end) + ")"
                         else "" end)),
        ($ref[] | .id + " refused"),
        ($retry[] | .id + " not recorded yet: " + .why),
        (if $bad > 0 then ($bad | tostring) + " unreadable, not receipted" else empty end) ]
    | if length == 0 then "" else
        "today-notes: evidence from Today, no authority: " + join(", ")
        + "; read with bin/fm-today-notes.sh show <id>" end
  ' "$@"
}

cmd_collect() {
  local wait=0 exchange=0 req refs resp code summaries=() summary line retry
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wait)
        [ "$#" -ge 2 ] || die "--wait needs a number of seconds" 2
        case "$2" in ''|*[!0-9]*) die "--wait must be a whole number from 0 to 25" 2 ;; esac
        [ "$2" -le 25 ] || die "--wait must be a whole number from 0 to 25" 2
        wait=$2
        shift 2
        ;;
      *) die "unknown collect argument: $1" 2 ;;
    esac
  done
  fm_today_portal_settings "$FM_HOME" || die "$FM_TODAY_SETTINGS_ERROR" 2
  mkdir -p "$RECEIPTS" "$RECORDS" || die "cannot create $RECEIPTS or $RECORDS"
  chmod 700 "$PRIV" "$RECEIPTS" 2>/dev/null || true
  fm_lock_try_acquire "$LOCK" || return 0
  LOCKED=1
  make_tmp
  : "${FM_TODAY_POST_MAX_SECS:=$((wait + 15))}"
  export FM_TODAY_POST_MAX_SECS
  while [ "$exchange" -lt "$MAX_EXCHANGES" ]; do
    exchange=$((exchange + 1))
    req="$TMP_DIR/request-$exchange.json"
    refs="$TMP_DIR/refs-$exchange"
    resp="$TMP_DIR/response-$exchange.json"
    build_request "$wait" "$req" "$refs" || die "the request could not be built"
    code=$(fm_today_post /api/fleet/notes "$req" "$resp" "$TMP_DIR")
    [ "$code" != 000 ] || die "could not reach the portal at $FM_TODAY_URL: $(head -n1 "$TMP_DIR/curl.err" | sed 's/ after [0-9]* ms//')" 3
    [ "$code" = 200 ] \
      || die "the portal answered $code$(jq -r '(.code // empty) | " (" + tostring + ")"' "$resp" 2>/dev/null || true)" 3
    # The portal stored every receipt the call carried.
    while IFS= read -r line; do
      [ -z "$line" ] || rm -f -- "$line"
    done < "$refs"
    summary="$TMP_DIR/summary-$exchange.json"
    intake "$resp" > "$summary" || die "the answer could not be recorded"
    jq -e '.malformed != true' "$summary" >/dev/null || die "the portal answered 200 without the notes envelope" 3
    summaries+=("$summary")
    # Go again only while this exchange left receipts to deliver.
    if ! jq -e '(.recorded + .refused | length) > 0 or .duplicates > 0' "$summary" >/dev/null; then
      break
    fi
    wait=0
  done
  line=$(summary_line "${summaries[@]}") || line=
  [ -z "$line" ] || { fm_cap_line_var "$line" "$MAX_LINE"; printf '%s\n' "$FM_LINE_CAP_LINE"; }
  retry=$(jq -s 'map(.retry | length) | add' "${summaries[@]}")
  [ "$retry" = 0 ] || die "$retry not recorded yet; the portal delivers them again on the next collect"
  return 0
}

cmd_list() {
  local task='' owner='(main)' limit=50
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || die "--task needs an id" 2; task=$2; shift 2 ;;
      --owner) [ "$#" -ge 2 ] || die "--owner needs a home" 2; owner=$2; shift 2 ;;
      --limit)
        [ "$#" -ge 2 ] || die "--limit needs a number" 2
        case "$2" in ''|*[!0-9]*|0) die "--limit must be a positive whole number" 2 ;; esac
        limit=$2
        shift 2
        ;;
      *) die "unknown list argument: $1" 2 ;;
    esac
  done
  local files=()
  shopt -s nullglob
  files=("$RECORDS"/note_*.json "$RECORDS"/dord_*.json)
  shopt -u nullglob
  [ "${#files[@]}" -gt 0 ] || return 0
  jq -rs --arg task "$task" --arg owner "$owner" --argjson limit "$limit" '
        map(select($task == "" or (.task != null and .task.task_id == $task and .task.owner == $owner)))
        | sort_by(.received_at, .id) | reverse | .[:$limit][]
        | [.received_at, .id, .kind, .outcome,
           (if .task then "task=" + .task.owner + "/" + .task.task_id else empty end),
           (if .text_check then "text=" + .text_check.verdict else empty end),
           (if .ranked then "ranked=" + (.ranked | map(.task_id) | join(",")) else empty end),
           (if (.second_mate // []) | length > 0 then "second-mate=" + (.second_mate | map(.owner + "/" + .task_id) | join(",")) else empty end)]
        | join(" ")' "${files[@]}"
}

cmd_show() {
  [ "$#" -eq 1 ] || die "show takes one note or order id" 2
  [[ "$1" =~ ^(note|dord)_[A-Za-z0-9_-]{22}$ ]] || die "not a note or order id: $1" 2
  [ -f "$RECORDS/$1.json" ] || die "no record of $1 in this home" 1
  jq . "$RECORDS/$1.json"
}

record_reported() {
  [ -f "$RECORD" ] || return 0
  sed -n '1{/^'"$RECORD_SCHEMA"'$/!q;}; s/^reported=//p' "$RECORD"
}

record_write() {  # <reported-line>
  local tmp
  tmp=$(umask 077; mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  if ! { printf '%s\nreported=%s\n' "$RECORD_SCHEMA" "$1" > "$tmp" && mv -f -- "$tmp" "$RECORD"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

cmd_check() {
  local timeout budget wait out rc=0 line
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || return 0
  timeout=${FM_CHECK_TIMEOUT:-30}
  case "$timeout" in ''|*[!0-9]*|0) timeout=30 ;; esac
  budget=$((timeout - 3))
  [ "$budget" -ge 1 ] || budget=1
  wait=${FM_TODAY_NOTES_WAIT:-10}
  case "$wait" in ''|*[!0-9]*) wait=10 ;; esac
  [ "$wait" -le 20 ] || wait=20
  [ $((wait + 5)) -lt "$budget" ] || wait=0
  out=$(FM_TODAY_POST_MAX_SECS=$((wait + 5)) fm_run_timed "$budget" "$0" collect --wait "$wait" 2>&1) || rc=$?
  if [ "$rc" -eq 124 ]; then
    line="today-notes: collect did not finish within ${budget}s"
  elif [ "$rc" -ne 0 ]; then
    line=$(printf '%s\n' "$out" | sed -n 's/^fm-today-notes: //p' | tail -n 1)
    line="today-notes: ${line:-collect failed (exit $rc)}"
  else
    line=
  fi
  # What was recorded is news every time; a failure only when it changed.
  printf '%s\n' "$out" | grep '^today-notes: ' || true
  if [ -n "$line" ] && [ "$line" != "$(record_reported)" ]; then
    fm_cap_line_var "$line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  record_write "$line" || true
  return 0
}

cmd_arm() {
  local home tmp
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || die "this is a secondmate home; the Today bridge runs in the main home" 2
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME $FM_HOME"
  mkdir -p "$STATE" || die "cannot create $STATE"
  [ ! -L "$CHECK_SHIM" ] || die "refusing to replace the symlink $CHECK_SHIM"
  tmp=$(umask 077; mktemp "$STATE/.fm-today-notes.XXXXXX") || die "cannot write in $STATE"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-today-notes.sh - Today notes and dispatch order poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-today-notes.sh") check" > "$tmp" || {
    rm -f -- "$tmp"
    die "could not write $CHECK_SHIM"
  }
  if ! { chmod 0700 "$tmp" && mv -f -- "$tmp" "$CHECK_SHIM"; }; then
    rm -f -- "$tmp"
    die "could not write $CHECK_SHIM"
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    die "could not register $CHECK_SHIM"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

cmd_disarm() {
  FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null \
    || die "could not retire $CHECK_SHIM"
  rm -f -- "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  collect) shift; cmd_collect "$@" ;;
  list) shift; cmd_list "$@" ;;
  show) shift; cmd_show "$@" ;;
  check) shift; cmd_check ;;
  arm) shift; cmd_arm ;;
  disarm) shift; cmd_disarm ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $1" 2 ;;
esac
