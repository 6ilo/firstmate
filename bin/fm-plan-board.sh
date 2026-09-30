#!/usr/bin/env bash
# fm-plan-board.sh - build a v1 planning board from one items file.
#
# A planning board is the shipped template
# (.agents/skills/plan-board/assets/plan-board-template.html) plus one injected
# fm-plan-board.v1 JSON document. The agent writing a plan writes only that
# items file and its concept picture; this script validates it, fills the
# template's data and title slots, and writes one self-contained HTML file for
# the Artifact tool to publish. The same input always produces the same bytes.
#
# Usage:
#   fm-plan-board.sh check <items.json>
#   fm-plan-board.sh build <items.json> <out.html>
#   fm-plan-board.sh answers <items.json> <read-db-dir>
#
# check     Validate the items file and print one summary line.
# build     Validate, then write the board HTML to <out.html> and print its size.
#           A board over 80 KB still builds; the size line flags it.
# answers   Print the captain's saved answers as the text the board's
#           "Copy answers" fallback shows, from a directory written by
#           `Artifact action=read_db ... out_dir=<read-db-dir>` for the
#           collections answers and reopen, plus notes/general. Missing
#           collections read as empty. The output is the decision text for
#           `fm-captain-hold.sh answer <task> --decision-file`.
#
# The fm-plan-board.v1 item schema is owned by
# .agents/skills/plan-board/SKILL.md; this script enforces it and fills the
# defaults the template relies on.
#
# Exit status: 0 on success, 1 on a validation or usage error.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
TEMPLATE="$SCRIPT_DIR/../.agents/skills/plan-board/assets/plan-board-template.html"

usage() {
  sed -n '2,/^# Exit status/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { printf 'fm-plan-board: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is required"

run() {  # <mode> <items.json> [<arg>]
  python3 - "$TEMPLATE" "$@" <<'PY'
import html, json, os, re, sys

template, mode, src = sys.argv[1], sys.argv[2], sys.argv[3]
arg = sys.argv[4] if len(sys.argv) > 4 else None
errors = []

def err(msg):
    errors.append(msg)

ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:@+~-]{0,63}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
KINDS = {"plan", "call", "task"}
STATUSES = {"open", "decided", "parked", "dropped"}
STATES = {"todo", "underway", "done"}
TYPES = {"build", "plan", "fix", "content", "upkeep"}
URGENCY = {"now", "week", "later"}
SIZES = {"S", "M", "L"}
BAD_SVG = re.compile(r"<\s*script|\son[a-z]+\s*=|javascript:|<\s*foreignObject", re.I)

try:
    with open(src, encoding="utf-8") as fh:
        doc = json.load(fh)
except (OSError, ValueError) as exc:
    sys.exit(f"fm-plan-board: cannot read {src}: {exc}")
if not isinstance(doc, dict):
    sys.exit("fm-plan-board: the items file must hold one JSON object")

def text(obj, key, where, required=True):
    val = obj.get(key)
    if val is None:
        if required:
            err(f"{where}: {key} is required")
        return
    if not isinstance(val, str) or not val.strip():
        err(f"{where}: {key} must be a non-empty string")

def strlist(obj, key, where):
    val = obj.get(key, [])
    if not isinstance(val, list) or not all(isinstance(x, str) for x in val):
        err(f"{where}: {key} must be a list of strings")

def date(obj, key, where):
    val = obj.get(key)
    if val is not None and not (isinstance(val, str) and DATE.match(val)):
        err(f"{where}: {key} must be YYYY-MM-DD")

if doc.get("schema") != "fm-plan-board.v1":
    err('schema must be "fm-plan-board.v1"')
if not (isinstance(doc.get("date"), str) and DATE.match(doc["date"])):
    err("date must be YYYY-MM-DD")
doc.setdefault("round", 1)
if not isinstance(doc["round"], int) or isinstance(doc["round"], bool) or doc["round"] < 1:
    err("round must be a positive integer")
if "task" in doc and not (isinstance(doc["task"], str) and doc["task"].strip()):
    err("task must be a non-empty string")

plans = doc.setdefault("plans", {})
if not isinstance(plans, dict):
    err("plans must be an object")
    plans = {}
for pid, p in plans.items():
    where = f"plans.{pid}"
    if not ID.match(pid):
        err(f"{where}: bad id")
    if not isinstance(p, dict):
        err(f"{where}: must be an object")
        continue
    text(p, "title", where)
    for key in ("home", "owner", "fact", "url"):
        text(p, key, where, required=False)
    if "open" in p and (not isinstance(p["open"], int) or isinstance(p["open"], bool) or p["open"] < 0):
        err(f"{where}: open must be a count")
    if "url" in p and isinstance(p["url"], str) and not p["url"].startswith("https://"):
        err(f"{where}: url must start with https://")

concepts = doc.setdefault("concepts", [])
if not isinstance(concepts, list):
    err("concepts must be a list")
    concepts = []
targets = {"c-answer"} | set(plans)
for n, c in enumerate(concepts):
    where = f"concepts[{n}]"
    if not isinstance(c, dict):
        err(f"{where}: must be an object")
        continue
    cid = c.get("id", "")
    where = f"concept {cid or n}"
    if not (isinstance(cid, str) and ID.match(cid) and cid[:2] in ("c-", "m-")):
        err(f'{where}: id must start with "c-" or "m-"')
    elif cid in targets:
        err(f"{where}: id is used twice")
    targets.add(cid)
    text(c, "title", where)
    text(c, "caption", where, required=False)
    c.setdefault("kind", "concept")
    if c["kind"] not in ("concept", "mockup"):
        err(f"{where}: kind must be concept or mockup")
    svg = c.get("svg")
    if not (isinstance(svg, str) and svg.lstrip().startswith("<svg") and svg.rstrip().endswith("</svg>")):
        err(f"{where}: svg must be one inline <svg> element")
    elif BAD_SVG.search(svg):
        err(f"{where}: svg must carry no script, event handler, foreignObject or javascript: URL")

evidence = doc.setdefault("evidence", [])
if not (isinstance(evidence, list) and all(isinstance(r, list) and len(r) == 3 and all(isinstance(x, str) for x in r) for r in evidence)):
    err("evidence must be a list of [signal, seen, source] rows")

items = doc.get("items")
if not isinstance(items, list) or not items:
    err("items must be a non-empty list")
    items = []
by_id = {}
for n, it in enumerate(items):
    if not isinstance(it, dict):
        err(f"items[{n}]: must be an object")
        continue
    iid = it.get("id")
    if not (isinstance(iid, str) and ID.match(iid)):
        err(f"items[{n}]: bad or missing id")
        continue
    if iid in by_id:
        err(f"{iid}: id is used twice")
    by_id[iid] = it

roots = [i for i in by_id.values() if "parent" not in i]
if len(roots) != 1:
    err(f"exactly one item must have no parent (found {len(roots)})")
for iid, it in by_id.items():
    kind = it.get("kind")
    if kind not in KINDS:
        err(f"{iid}: kind must be plan, call or task")
        continue
    text(it, "title", iid)
    text(it, "owner", iid)
    text(it, "why", iid, required=False)
    if "parent" in it:
        parent = by_id.get(it["parent"])
        if parent is None or parent.get("kind") != "plan":
            err(f"{iid}: parent must name a plan item")
    elif kind != "plan":
        err(f"{iid}: the item with no parent must be a plan")
    it.setdefault("type", "plan")
    it.setdefault("urgency", "later")
    it.setdefault("depends", [])
    it.setdefault("links", [])
    if it["type"] not in TYPES:
        err(f"{iid}: type must be one of {', '.join(sorted(TYPES))}")
    if it["urgency"] not in URGENCY:
        err(f"{iid}: urgency must be now, week or later")
    date(it, "start", iid)
    date(it, "due", iid)
    if kind == "plan":
        for key in ("status", "state", "options", "rec", "pick", "depends"):
            if it.get(key):
                err(f"{iid}: a plan carries no {key}; it rolls up from its items")
        text(it, "dest", iid, required=False)
        for key in ("notes", "out", "fog"):
            strlist(it, key, iid)
        it.pop("status", None)
    elif kind == "call":
        it.setdefault("status", "open")
        opts = it.get("options")
        if not (isinstance(opts, list) and 2 <= len(opts) <= 4 and all(isinstance(o, dict) for o in opts)):
            err(f"{iid}: options must be 2 to 4 objects")
            opts = []
        for o in opts:
            text(o, "label", f"{iid} option")
            text(o, "consequence", f"{iid} option", required=False)
        keys = [chr(65 + k) for k in range(len(opts))]
        if it.get("rec") is not None and it["rec"] not in keys:
            err(f"{iid}: rec must be one of {', '.join(keys)}")
        if it["status"] == "open" and it.get("rec") is None:
            err(f"{iid}: an open call needs a recommendation (rec)")
        if it["status"] == "decided" and it.get("pick") not in keys:
            err(f"{iid}: a decided call needs the captain's pick, one of {', '.join(keys)}")
        text(it, "note", iid, required=False)
    else:
        it.setdefault("status", "decided")
        it.setdefault("state", "todo")
        it.setdefault("size", "M")
        if it["status"] == "open":
            err(f"{iid}: only a call can be open; hold the task on the call it waits for")
        if it["state"] not in STATES:
            err(f"{iid}: state must be todo, underway or done")
        if it["size"] not in SIZES:
            err(f"{iid}: size must be S, M or L")
    if it.get("status") is not None and it["status"] not in STATUSES:
        err(f"{iid}: status must be open, decided, parked or dropped")
    deps = it["depends"]
    if not (isinstance(deps, list) and all(isinstance(d, str) for d in deps)):
        err(f"{iid}: depends must be a list of ids")
        it["depends"] = []
    for d in it["depends"]:
        target = by_id.get(d)
        if target is None:
            err(f"{iid}: depends on unknown item {d}")
        elif target.get("kind") == "plan":
            err(f"{iid}: depends on plan {d}; name the call or task inside it")
        elif d == iid:
            err(f"{iid}: depends on itself")
    links = it["links"]
    if not (isinstance(links, list) and all(isinstance(l, dict) for l in links)):
        err(f"{iid}: links must be a list of {{to, why}}")
        it["links"] = []
    for l in it["links"]:
        if l.get("to") not in targets:
            err(f"{iid}: link to unknown plan or concept {l.get('to')}")
        text(l, "why", f"{iid} link")

state = {}
def visit(iid, path):
    if state.get(iid) == 2:
        return
    if state.get(iid) == 1:
        err("dependency cycle: " + " -> ".join(path + [iid]))
        return
    state[iid] = 1
    for d in by_id[iid].get("depends", []):
        if d in by_id and d != iid:
            visit(d, path + [iid])
    state[iid] = 2
for iid in by_id:
    visit(iid, [])

if errors:
    sys.stderr.write("".join(f"fm-plan-board: {e}\n" for e in errors))
    sys.exit(1)

root = roots[0]
calls = [i for i in items if i["kind"] == "call"]

if mode == "check":
    print(f"ok: {len(items)} items, {sum(i['kind'] == 'plan' for i in items)} plans, "
          f"{sum(i['status'] == 'open' for i in calls)} open calls")
elif mode == "build":
    with open(template, encoding="utf-8") as fh:
        page = fh.read()
    for slot in ("__FM_PLAN_BOARD_DATA__", "__FM_PLAN_BOARD_TITLE__"):
        if page.count(slot) != 1:
            sys.exit(f"fm-plan-board: template must carry exactly one {slot}")
    data = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    page = page.replace("__FM_PLAN_BOARD_TITLE__", html.escape(root["title"], quote=False))
    page = page.replace("__FM_PLAN_BOARD_DATA__", data)
    out = arg
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(page)
    os.replace(tmp, out)
    kb = len(page.encode("utf-8")) / 1024
    note = " (over the 80 KB target: trim items or pictures)" if kb > 80 else ""
    print(f"built {out}: {kb:.0f} KB{note}")
else:
    def load(coll):
        found = {}
        d = os.path.join(arg, coll)
        if os.path.isdir(d):
            for name in sorted(os.listdir(d)):
                if name.endswith(".json"):
                    with open(os.path.join(d, name), encoding="utf-8") as fh:
                        found[name[:-5]] = json.load(fh)
        return found
    answers, reopen, notes = load("answers"), load("reopen"), load("notes")
    for key in sorted(set(answers) | set(reopen)):
        if key not in by_id or by_id[key]["kind"] != "call":
            sys.stderr.write(f"fm-plan-board: ignoring saved answer for unknown call {key}\n")
    def label(call, key):
        k = ord(key) - 65 if isinstance(key, str) and len(key) == 1 else -1
        return call["options"][k]["label"] if 0 <= k < len(call["options"]) else ""
    lines = [f"{root['title']} answers, round {doc['round']}"]
    for c in calls:
        if c["status"] == "open":
            a = answers.get(c["id"], {})
            pick = a.get("pick") or ""
            parts = [f"{c['id']} {c['title']} -> " + (f"{pick}: {label(c, pick)}" if pick else "no answer")]
            if a.get("unsure"):
                parts.append("not sure, draw it for me")
            if a.get("note"):
                parts.append(f"note: {a['note']}")
            lines.append(" | ".join(parts))
    for c in calls:
        change = reopen.get(c["id"], {}).get("note") if c["status"] == "decided" else None
        if change:
            lines.append(f"{c['id']} {c['title']} -> change: {change}")
    general = notes.get("general", {}).get("note")
    if general:
        lines.append(f"General note: {general}")
    print("\n".join(lines))
PY
}

case "${1-}" in
  check)
    [ $# -eq 2 ] || die "usage: fm-plan-board.sh check <items.json>"
    run check "$2"
    ;;
  build)
    [ $# -eq 3 ] || die "usage: fm-plan-board.sh build <items.json> <out.html>"
    [ -f "$TEMPLATE" ] || die "board template is missing: $TEMPLATE"
    run build "$2" "$3"
    ;;
  answers)
    [ $# -eq 3 ] || die "usage: fm-plan-board.sh answers <items.json> <read-db-dir>"
    [ -d "$3" ] || die "not a directory: $3"
    run answers "$2" "$3"
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
