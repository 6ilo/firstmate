#!/usr/bin/env bash
# fm-plan-board.sh - build a v1 planning board from one items file.
#
# A planning board is the shipped template
# (.agents/skills/plan-board/assets/plan-board-template.html) plus one injected
# fm-plan-board.v1 JSON document. The agent writing a plan writes only that
# items file and its concept picture; this script validates it, fills the
# template's data and title slots, and writes one self-contained HTML file for
# the Artifact tool to publish. The same inputs always produce the same bytes.
#
# Usage:
#   fm-plan-board.sh check <items.json> [--known <record>]
#   fm-plan-board.sh build <items.json> <out.html> [--known <record>]
#   fm-plan-board.sh answers <items.json> <read-db-dir>
#   fm-plan-board.sh learn <items.json> <read-db-dir> <record>
#
# check     Validate the items file and print one summary line.
# build     Validate, then write the board HTML to <out.html> and print its size.
#           A board over 80 KB still builds; the size line flags it.
# --known   The home's what-you-know record (JSON Lines, the newest entry per
#           concept wins). Its entries for the concepts this plan uses are
#           embedded for the opening page, and a quiz question about a concept
#           marked known is refused. An absent record reads as empty.
# answers   Print the captain's saved answers as the text the board's
#           "Copy answers" fallback shows, from a directory written by
#           `Artifact action=read_db ... out_dir=<read-db-dir>` for the
#           collections answers, reopen and check, plus notes/general. Missing
#           collections read as empty. The output is the decision text for
#           `fm-captain-hold.sh answer <task> --decision-file`.
# learn     Append what-you-know entries backed by evidence: each saved quiz
#           answer (right sets known, missed sets to-teach) and each decided
#           call that links a concept (known). An entry already present with
#           the same concept, state and evidence is not appended again, so
#           rerunning after the same read-back changes nothing. Creates the
#           record when absent.
#
# The fm-plan-board.v1 item schema and the what-you-know record are owned by
# .agents/skills/plan-board/SKILL.md; this script enforces them and fills the
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

run() {  # <mode> <items.json> <out-or-dir-or-empty> <record-or-empty>
  python3 - "$TEMPLATE" "$@" <<'PY'
import html, json, os, re, sys

template, mode, src, arg, record = sys.argv[1:6]
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
AUDIENCES = {"public", "team", "agents"}
PICTURES = {"diagram", "mockup", "chart", "photo"}
BAD_SVG = re.compile(r"<\s*script|[\s/\"']on[a-z]+\s*=|j\s*a\s*v\s*a\s*s\s*c\s*r\s*i\s*p\s*t\s*:|<\s*foreignObject|&(?!(?:amp|lt|gt|quot|apos);)", re.I)

def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        sys.exit(f"fm-plan-board: cannot read {what} {path}: {exc}")

doc = load_json(src, "items file")
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
    obj.setdefault(key, [])
    val = obj[key]
    if not isinstance(val, list) or not all(isinstance(x, str) and x.strip() for x in val):
        err(f"{where}: {key} must be a list of non-empty strings")
        obj[key] = []

def date(obj, key, where):
    val = obj.get(key)
    if val is not None and not (isinstance(val, str) and DATE.match(val)):
        err(f"{where}: {key} must be YYYY-MM-DD")

def count(obj, key, where):
    val = obj.get(key)
    if val is not None and (not isinstance(val, int) or isinstance(val, bool) or val < 0):
        err(f"{where}: {key} must be a count")

# ---- top level ----
if doc.get("schema") != "fm-plan-board.v1":
    err('schema must be "fm-plan-board.v1"')
if not (isinstance(doc.get("date"), str) and DATE.match(doc["date"])):
    err("date must be YYYY-MM-DD")
doc.setdefault("round", 1)
if not isinstance(doc["round"], int) or isinstance(doc["round"], bool) or doc["round"] < 1:
    err("round must be a positive integer")
text(doc, "task", "top level", required=False)
text(doc, "home", "top level", required=False)

plans = doc.setdefault("plans", {})
if not isinstance(plans, dict):
    err("plans must be an object")
    plans = doc["plans"] = {}
for pid, p in plans.items():
    where = f"plans.{pid}"
    if not ID.match(pid) or pid.startswith("concept:"):
        err(f"{where}: bad id")
    if not isinstance(p, dict):
        err(f"{where}: must be an object")
        continue
    text(p, "title", where)
    for key in ("home", "owner", "fact", "url"):
        text(p, key, where, required=False)
    count(p, "open", where)
    if "ruled" in p:
        strlist(p, "ruled", where)
    if isinstance(p.get("url"), str) and not p["url"].startswith("https://"):
        err(f"{where}: url must start with https://")

concepts = doc.setdefault("concepts", [])
if not isinstance(concepts, list):
    err("concepts must be a list")
    concepts = doc["concepts"] = []
library = {"answer": {"kind": "diagram"}}
for n, c in enumerate(concepts):
    if not isinstance(c, dict):
        err(f"concepts[{n}]: must be an object")
        continue
    cid = c.get("id")
    where = f"concept {cid if isinstance(cid, str) else n}"
    if not (isinstance(cid, str) and re.match(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", cid)):
        err(f"{where}: id must be letters, digits, _ and -")
        continue
    if cid in library:
        err(f"{where}: id is used twice")
    library[cid] = c
    text(c, "title", where)
    text(c, "caption", where, required=False)
    if c.get("kind") not in PICTURES:
        err(f"{where}: kind must be diagram, mockup, chart or photo")
    if "used_by" in c:
        strlist(c, "used_by", where)
    svg, asset = c.get("svg"), c.get("asset")
    if (svg is None) == (asset is None):
        err(f"{where}: give exactly one of svg or asset")
    elif svg is not None:
        if not (isinstance(svg, str) and svg.lstrip().startswith("<svg") and svg.rstrip().endswith("</svg>")):
            err(f"{where}: svg must be one inline <svg> element")
        elif BAD_SVG.search(svg):
            err(f"{where}: svg must carry no script, event handler, foreignObject, javascript: URL or character reference")
    elif not (isinstance(asset, str) and (asset.startswith("/_blob/") or asset.startswith("data:image/"))):
        err(f"{where}: asset must be an artifact /_blob/ path or a data:image/ URL")

evidence = doc.setdefault("evidence", [])
if not (isinstance(evidence, list) and all(isinstance(r, list) and len(r) == 3 and all(isinstance(x, str) for x in r) for r in evidence)):
    err("evidence must be a list of [signal, seen, source] rows")

def target_ok(to):
    if isinstance(to, str) and to.startswith("concept:"):
        return to[8:] in library
    return to in plans

# ---- items ----
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
    for key in ("start", "due", "until"):
        date(it, key, iid)
    if kind != "call" and "unsure" in it:
        err(f"{iid}: only a call carries unsure")
    if kind != "task":
        for key in ("aud", "visible", "until"):
            if key in it:
                err(f"{iid}: only a task carries {key}")
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
            opts = it["options"] = []
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
        if not isinstance(it.get("unsure", False), bool):
            err(f"{iid}: unsure must be true or false")
    else:
        it.setdefault("status", "decided")
        it.setdefault("state", "todo")
        it.setdefault("size", "M")
        it.setdefault("aud", "agents")
        it.setdefault("visible", False)
        if it["status"] == "open":
            err(f"{iid}: only a call can be open; hold the task on the call it waits for")
        if it["state"] not in STATES:
            err(f"{iid}: state must be todo, underway or done")
        if it["size"] not in SIZES:
            err(f"{iid}: size must be S, M or L")
        if it["aud"] not in AUDIENCES:
            err(f"{iid}: aud must be public, team or agents")
        if not isinstance(it["visible"], bool):
            err(f"{iid}: visible must be true or false")
        elif it["visible"] and it["aud"] == "agents":
            err(f"{iid}: only a public or team change can be visible")
        elif it["visible"] and not any(
                isinstance(l, dict) and isinstance(l.get("to"), str) and l["to"].startswith("concept:")
                and library.get(l["to"][8:], {}).get("kind") == "mockup" for l in it["links"]):
            err(f"{iid}: a visible change must link at least one mockup")
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
        if not target_ok(l.get("to")):
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

# ---- the opening page ----
calls = [i for i in items if isinstance(i, dict) and i.get("kind") == "call"]
opening = doc.get("opening")
quiz = []
if opening is not None:
    if not isinstance(opening, dict):
        err("opening must be an object")
        opening = doc["opening"] = {}
    mission = opening.get("mission")
    if not isinstance(mission, dict):
        err("opening.mission must be an object")
        mission = opening["mission"] = {}
    text(mission, "why", "opening.mission")
    strlist(mission, "success", "opening.mission")
    strlist(mission, "out", "opening.mission")
    gloss = opening.setdefault("glossary", [])
    terms = {}
    if not isinstance(gloss, list):
        err("opening.glossary must be a list")
        gloss = opening["glossary"] = []
    for n, g in enumerate(gloss):
        if not isinstance(g, dict) or not isinstance(g.get("term"), str) or not g["term"].strip():
            err(f"opening.glossary[{n}]: term is required")
            continue
        if g["term"] in terms:
            err(f"glossary term {g['term']}: used twice")
        terms[g["term"]] = g
        text(g, "def", f"glossary term {g['term']}")
        strlist(g, "related", f"glossary term {g['term']}")
    for t, g in terms.items():
        if g.get("parent") is not None and g["parent"] not in terms:
            err(f"glossary term {t}: parent {g['parent']} is not a term")
        for r in g.get("related", []):
            if r not in terms:
                err(f"glossary term {t}: related {r} is not a term")
        seen, p = {t}, g.get("parent")
        while p in terms:
            if p in seen:
                err(f"glossary term {t}: parents form a loop")
                break
            seen.add(p)
            p = terms[p].get("parent")
    pics = opening.setdefault("concepts", [])
    if not (isinstance(pics, list) and all(isinstance(x, str) for x in pics)):
        err("opening.concepts must be a list of concept ids")
        pics = opening["concepts"] = []
    for cid in pics:
        if cid not in library or cid == "answer":
            err(f"opening.concepts: unknown concept {cid}")
    quiz = opening.setdefault("quiz", [])
    if not isinstance(quiz, list) or len(quiz) > 3:
        err("opening.quiz must hold at most three questions")
        quiz = opening["quiz"] = []
    qids = set()
    for n, q in enumerate(quiz):
        if not isinstance(q, dict) or not (isinstance(q.get("id"), str) and ID.match(q["id"])):
            err(f"opening.quiz[{n}]: bad or missing id")
            continue
        where = f"quiz {q['id']}"
        if q["id"] in qids:
            err(f"{where}: id is used twice")
        qids.add(q["id"])
        text(q, "question", where)
        text(q, "why", where)
        if q.get("concept") not in library or q.get("concept") == "answer":
            err(f"{where}: concept must name a library concept")
        opts = q.get("options")
        if not (isinstance(opts, list) and len(opts) == 3 and all(isinstance(o, str) and o.strip() for o in opts)):
            err(f"{where}: options must be three non-empty strings")
        else:
            words = [len(o.split()) for o in opts]
            if max(words) - min(words) > 1:
                err(f"{where}: options must have the same number of words, within one (have {words})")
        if q.get("answer") not in (0, 1, 2) or isinstance(q.get("answer"), bool):
            err(f"{where}: answer must be the right option's index, 0 to 2")

homes = {doc.get("home")} | {plans[l["to"]].get("home") for i in by_id.values() for l in i.get("links", [])
                             if isinstance(l, dict) and l.get("to") in plans}
homes.discard(None)
unsure = [c["id"] for c in calls if c.get("unsure") is True and c.get("status") == "open"]
if opening is None and (len(homes) >= 2 or len(calls) >= 5 or unsure):
    err(f"this plan needs an opening page: it touches {len(homes)} homes, has {len(calls)} calls"
        f" and {len(unsure)} not-sure answers")

# ---- what-you-know record ----
def read_record(path):
    latest, entries = {}, []
    if not path or not os.path.exists(path):
        return latest, entries
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                e = json.loads(line)
            except ValueError:
                sys.exit(f"fm-plan-board: {path}:{n}: not a JSON line")
            if not (isinstance(e, dict) and isinstance(e.get("concept"), str) and e.get("state") in ("known", "to-teach")
                    and isinstance(e.get("evidence"), str) and isinstance(e.get("at"), str)):
                sys.exit(f"fm-plan-board: {path}:{n}: an entry is {{concept, state: known|to-teach, evidence, at}}")
            latest[e["concept"]] = e
            entries.append(e)
    return latest, entries

if mode in ("check", "build") and record:
    latest, _ = read_record(record)
    for q in quiz:
        if isinstance(q, dict) and latest.get(q.get("concept"), {}).get("state") == "known":
            err(f"quiz {q.get('id')}: concept {q['concept']} is already known; ask about a concept still to teach")
    used = {l["to"][8:] for i in by_id.values() for l in i.get("links", []) if isinstance(l, dict) and str(l.get("to", "")).startswith("concept:")}
    if isinstance(opening, dict):
        used |= set(opening.get("concepts", [])) | {q.get("concept") for q in quiz if isinstance(q, dict)}
    doc["known"] = [{k: latest[c][k] for k in ("concept", "state", "evidence")} for c in sorted(used) if c in latest]

if errors:
    sys.stderr.write("".join(f"fm-plan-board: {e}\n" for e in errors))
    sys.exit(1)

root = roots[0]

def load_dir(coll):
    found = {}
    d = os.path.join(arg, coll)
    if os.path.isdir(d):
        for name in sorted(os.listdir(d)):
            if name.endswith(".json"):
                found[name[:-5]] = load_json(os.path.join(d, name), "saved document")
    return found

def right(q, saved):
    return saved.get("choice") == q["answer"] and not isinstance(saved.get("choice"), bool)

if mode == "check":
    print(f"ok: {len(items)} items, {sum(i['kind'] == 'plan' for i in items)} plans, "
          f"{sum(i['status'] == 'open' for i in calls)} open calls, "
          f"opening page {'present' if opening is not None else 'absent'}")
elif mode == "build":
    with open(template, encoding="utf-8") as fh:
        page = fh.read()
    for slot in ("__FM_PLAN_BOARD_DATA__", "__FM_PLAN_BOARD_TITLE__"):
        if page.count(slot) != 1:
            sys.exit(f"fm-plan-board: template must carry exactly one {slot}")
    data = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    page = page.replace("__FM_PLAN_BOARD_TITLE__", html.escape(root["title"], quote=False))
    page = page.replace("__FM_PLAN_BOARD_DATA__", data)
    tmp = arg + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(page)
    os.replace(tmp, arg)
    kb = len(page.encode("utf-8")) / 1024
    note = " (over the 80 KB target: trim items or pictures)" if kb > 80 else ""
    print(f"built {arg}: {kb:.0f} KB{note}")
elif mode == "answers":
    answers, reopen, notes, checks = load_dir("answers"), load_dir("reopen"), load_dir("notes"), load_dir("check")
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
    for q in quiz:
        saved = checks.get(q["id"])
        if saved and isinstance(saved.get("choice"), int):
            lines.append(f"Check {q['id']} ({q['concept']}) -> {'right' if right(q, saved) else 'missed'}")
    general = notes.get("general", {}).get("note")
    if general:
        lines.append(f"General note: {general}")
    print("\n".join(lines))
else:
    _, entries = read_record(record)
    have = {(e["concept"], e["state"], e["evidence"]) for e in entries}
    new = []
    for c in calls:
        if c["status"] == "decided":
            for l in c["links"]:
                if l["to"].startswith("concept:") and l["to"] != "concept:answer":
                    new.append({"concept": l["to"][8:], "state": "known",
                                "evidence": f"call {c['id']} decided {c['pick']}", "at": doc["date"] + "T00:00:00Z"})
    checks = load_dir("check")
    for q in quiz:
        saved = checks.get(q["id"])
        if saved and isinstance(saved.get("choice"), int):
            ok = right(q, saved)
            new.append({"concept": q["concept"], "state": "known" if ok else "to-teach",
                        "evidence": f"quiz {q['id']} {'right' if ok else 'missed'}",
                        "at": str(saved.get("at") or doc["date"] + "T00:00:00Z")})
    added = 0
    with open(record, "a", encoding="utf-8") as fh:
        for e in new:
            key = (e["concept"], e["state"], e["evidence"])
            if key not in have:
                have.add(key)
                fh.write(json.dumps(e, ensure_ascii=False, sort_keys=True) + "\n")
                added += 1
    print(f"learned {added} new entr{'y' if added == 1 else 'ies'} into {record}")
PY
}

case "${1-}" in
  check|build)
    mode=$1
    shift
    items=${1-}
    out=""
    record=""
    [ -n "$items" ] || die "usage: fm-plan-board.sh $mode <items.json>$([ "$mode" = build ] && echo ' <out.html>') [--known <record>]"
    shift
    if [ "$mode" = build ]; then
      [ $# -ge 1 ] || die "usage: fm-plan-board.sh build <items.json> <out.html> [--known <record>]"
      out=$1
      shift
      [ -f "$TEMPLATE" ] || die "board template is missing: $TEMPLATE"
    fi
    if [ $# -gt 0 ]; then
      [ $# -eq 2 ] && [ "$1" = --known ] || die "unexpected arguments: $*"
      record=$2
    fi
    run "$mode" "$items" "$out" "$record"
    ;;
  answers)
    [ $# -eq 3 ] || die "usage: fm-plan-board.sh answers <items.json> <read-db-dir>"
    [ -d "$3" ] || die "not a directory: $3"
    run answers "$2" "$3" ""
    ;;
  learn)
    [ $# -eq 4 ] || die "usage: fm-plan-board.sh learn <items.json> <read-db-dir> <record>"
    [ -d "$3" ] || die "not a directory: $3"
    run learn "$2" "$3" "$4"
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
