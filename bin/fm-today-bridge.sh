#!/usr/bin/env bash
# fm-today-bridge.sh - the outward half of the Today bridge: build the fleet's
# fm-today-snapshot.v1 document and send it to the admin portal.
#
# docs/today-contract.md owns the contract this implements: every field's
# meaning, the card_hash definition, the privacy rules, and the portal's
# POST /api/fleet/bridge/snapshot endpoint. Every connection is opened from this
# machine, outward; nothing here listens.
#
# Usage:
#   fm-today-bridge.sh snapshot
#   fm-today-bridge.sh push [--dry-run <out.json>]
#   fm-today-bridge.sh --help
#
# snapshot  Print one fm-today-snapshot.v1 document for the whole fleet. It
#           re-derives nothing the fleet's own owners hold:
#             calls, underway, charted_next, landed, health.unhealthy
#               bin/fm-bearings-snapshot.sh --json --all-in-flight
#               --all-decisions --all-queued --all-unhealthy, including the
#               planning fields it carries (size, urgency, type, order, and
#               outside waits, which become `event` waits)
#             health.supervision
#               fm_supervision_status (bin/fm-supervision-lib.sh): `live` for a
#               fresh watcher beacon, `lapsed` for a stale one, `unknown` when
#               no beacon was ever written
#             boards
#               this home's task-owned Lavish process-event source records
#               (state/procevent/*.source) and their captured rounds
#               (state/procevent-inbox/); the link is the board's saved
#               Lavish session URL. A board whose link cannot be resolved is
#               left out. A board still open in Lavish's store whose source
#               registration is gone is listed when its owner is recovered
#               from the owner-task files its captured rounds left, and is
#               `owner-gone` once that task's record is gone; one whose owner
#               cannot be recovered is left out. Only the owner task, state,
#               round count, last change, and link leave; never a board's
#               title or body.
#             day
#               the calendar day file (below)
#           Every card and work row carries `owner`: `(main)` for this home,
#           otherwise the second mate whose home holds it, with the bare task
#           id in that home (bearings' `mate/task` becomes owner `mate`, id
#           `task`).
#           A row whose id or owner the contract cannot carry is left out
#           rather than rewritten, and work already listed for the same owner
#           in an earlier section is not listed again. Each left-out row is
#           named on stderr.
#           Every card is a `decision` card offering, in order, the options
#           the hold recorded (bin/fm-captain-hold.sh hold --option, carried as
#           bearings' decisions_open options), then the standard `reconcile`
#           option, labelled "Already settled"; a call with none offers
#           `reconcile` alone, and the portal adds `later` itself. A recorded
#           option the card cannot carry is left out and named on stderr.
#           Option labels and hints pass the text check with the rest of the
#           card; a withheld card shows each recorded option as `Option <n>`,
#           its hint as neutral text. Every card and work row carries
#           `repo`: `owner/name` when one is found, otherwise `null`; bearings
#           records no repository for a call, so a card's is always `null`.
#
# push      Build the snapshot, check it with the
#           contract's reference checker (tests/fm-today-contract-check.py), and
#           refuse to send it when the check fails or it is over 512 KiB. Then
#           POST it to ${FM_TODAY_PORTAL_URL}/api/fleet/bridge/snapshot with
#           `Authorization: Bearer $FM_TODAY_BRIDGE_TOKEN`, and print
#           `heard_at: <stamp>` from the portal's 200 answer. The token is
#           passed to curl through a private header file, never on a command
#           line, and is never printed. The URL must be https://, or http://
#           only to 127.0.0.1 or localhost; any other URL sends nothing.
#           --dry-run <out.json> writes the checked document to that file and
#           sends nothing; it needs neither the URL nor the token.
#
# Configuration. Each value comes from the environment when set, otherwise from
# this home's gitignored $FM_HOME/.env (bin/fm-env-lib.sh's fmx_env_get). The
# bridge runs in the main firstmate home, where the token lives.
#   FM_TODAY_PORTAL_URL    the portal's origin, such as https://portal.example
#   FM_TODAY_BRIDGE_TOKEN  the bridge's bearer token
#   FM_TODAY_DAY_FILE      the calendar day file; default
#                          ~/.local/state/firstmate/calendar-day.json
#
# The calendar day file is written by a job outside this repository, as
#   {"date": "YYYY-MM-DD", "ends_at": <instant>, "fetched_at": <any>,
#    "blocks": [{"id", "title", "starts_at", "ends_at"}]}
# with instants carrying an explicit UTC offset. A missing, unreadable, or
# malformed file, or one whose date is not today's local date, yields an empty
# day for today, never an error. A block with an unusable id or times is left
# out; titles are kept (the day shows each block with its title) but collapsed
# to one line and capped at 200 characters.
#
# The text check (fm-today-text-check@1.0.0) keeps learner, family, fee, and
# legal detail on this machine; docs/configuration.md "Today bridge" owns its
# rule families, and RULES below implements them. A tripped card goes out with
# the `withheld` verdict and neutral text of firstmate's own in place of every
# checked field, never partly redacted. Every other free-text field passes the
# same check: a tripped work title becomes the work id and a tripped `doing`,
# `reason`, or wait label becomes neutral text. Day block titles are exempt.
# Wherever a field was cut (a …, from bearings or from the bridge's own length
# cap, at the end or mid-text), the partial word before each … is dropped
# before the check, and the field trips when any of the five words before a
# cut contains a digit.
# Bump the checker version whenever RULES changes.
#
# Exit status: 0 on success; 1 when the snapshot cannot be built or fails the
# check; 2 on a usage error or a missing URL or token (nothing is sent); 3 when
# the portal cannot be reached or answers anything but 200.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONTRACT_DIR="$SCRIPT_DIR/../docs/today-contract"
CHECKER="$SCRIPT_DIR/../tests/fm-today-contract-check.py"
MAX_BYTES=524288

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-today-bridge: %s\n' "$1" >&2
  exit "${2:-1}"
}

# Environment wins over the home .env.
config_value() {  # <key>
  local key=$1
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
  else
    fmx_env_get "$key" "$FM_HOME/.env"
  fi
}

supervision_state() {
  fm_supervision_status "$STATE"
  if [ "$FM_SUP_WATCHER_FRESH" = true ]; then
    printf 'live\n'
  elif [ -e "$STATE/.last-watcher-beat" ]; then
    printf 'lapsed\n'
  else
    printf 'unknown\n'
  fi
}

TMP_DIR=''
cleanup() { [ -z "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

make_tmp() {
  [ -n "$TMP_DIR" ] || TMP_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-today-bridge.XXXXXX")
}

build_snapshot() {  # <out-file>
  local out=$1 bearings supervision
  make_tmp
  bearings="$TMP_DIR/bearings.json"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json --all-in-flight \
    --all-decisions --all-queued --all-unhealthy > "$bearings" \
    || die "the bearings snapshot failed; nothing was built"
  supervision=$(supervision_state)
  FM_TODAY_BEARINGS="$bearings" FM_TODAY_SUPERVISION="$supervision" \
    FM_TODAY_STATE="$STATE" FM_TODAY_HOME_DIR="$FM_HOME" \
    FM_TODAY_DAY_PATH="${FM_TODAY_DAY_FILE:-$HOME/.local/state/firstmate/calendar-day.json}" \
    FM_TODAY_LAVISH_STATE="${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json" \
    python3 - > "$out" <<'PY' || die "the snapshot could not be assembled"
import datetime
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

GENERATOR_VERSION = "1.2.0"
CHECKER = "fm-today-text-check@1.0.0"
# docs/today-contract.md owns this definition.
CARD_HASH_FIELDS = ("schema", "task_id", "owner", "kind", "title", "question",
                    "options", "repo", "pr_url", "due")
MAIN = "(main)"
WORK_LIMIT = 1000
TASK_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
OWNER = re.compile(r"^(\(main\)|[A-Za-z0-9._-]{1,128})$")
OPTION_VALUE = TASK_ID
REF = re.compile(r"^[A-Za-z0-9._:/-]{1,200}$")
REPO = re.compile(r"^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$")
PR_URL = re.compile(r"^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?/[^\s]*$")
LINK = re.compile(r"^https?://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?/[^\s]*$")
GITHUB = re.compile(r"github\.com[:/]([A-Za-z0-9_.-]{1,100})/([A-Za-z0-9_.-]{1,100}?)(?:\.git)?(?:/|$)")
INSTANT = re.compile(r"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,6})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$")
DATE = re.compile(r"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])")

STREET = ("Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Lane|Ln|Drive|Dr|Court|Ct|"
          "Way|Place|Pl|Terrace|Parkway|Pkwy|Highway|Hwy|Circle|Cir")
# The text check's rule set; docs/configuration.md "Today bridge" documents every family.
RULES = (
    ("email", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")),
    ("phone", re.compile(r"\+\d[\d\s().-]{7,}\d|(?:\(\d{3}\)\s?|\b\d{3}[.\s-])\d{3}[.\s-]\d{4}\b")),
    ("money", re.compile(r"[$£€¥]\s?\d|\b\d[\d,]*(?:\.\d+)?\s?(?:USD|EUR|GBP|dollars?|euros?|pounds?)\b",
                         re.IGNORECASE)),
    ("address", re.compile(r"\b\d{1,6}\s+(?:[A-Z][A-Za-z.'-]*\s+){1,4}(?:" + STREET + r")\b"
                           r"|\b(?i:p\.?\s?o\.?\s+box)\s+\d+")),
    ("date-of-birth", re.compile(r"\b(?:date\s+of\s+birth|d\.?o\.?b\b|birth\s?date|birthday|born\s+on)",
                                 re.IGNORECASE)),
    ("word", re.compile(r"\b(?:guardians?|parents?|minors?|learners?|students?|family|families|"
                        r"tuition|fees?|invoices?|counsel|attorneys?|lawyers?|lawsuits?|custody)\b",
                        re.IGNORECASE)),
    ("cut", re.compile(r"\d[^\s…]*(?:\s+[^\s…]+){0,4}…")),
)
CUT_WORD = re.compile(r"\s*[^\s…]*…")

WITHHELD_TITLE = "A call is waiting on the machine"
WITHHELD_QUESTION = "This call's text stays on the machine. Read it there."
WITHHELD_TEXT = "Text kept on the machine"
RECONCILE = {
    "value": "reconcile",
    "label": "Already settled",
    "hint": "Re-check the latest state, then close this with evidence or keep it open with a note",
    "recommended": False,
}

skipped = []


def tripped(*texts):
    for text in texts:
        for _name, rule in RULES:
            if text and rule.search(text):
                return True
    return False


def units(text):
    """Length as the portal counts it: UTF-16 code units."""
    return len(text.encode("utf-16-le")) // 2


def fit(text, limit):
    if units(text) <= limit:
        return text
    cut = text
    while cut and units(cut) > limit - 1:
        cut = cut[:-1]
    return cut.rstrip() + "…"


def whole(text):
    """Without the partial word a cut left before each …; empty when nothing else is left."""
    text = CUT_WORD.sub("…", text)
    return text if re.search(r"[^\s…]", text) else ""


def line(value, limit, fallback=""):
    text = " ".join(str(value if value is not None else "").split())
    if text in ("", "-"):
        text = fallback
    return fit(text, limit) if text else ""


def checked(value, limit, fallback):
    """A free-text field after the text check: neutral text when it trips."""
    text = whole(line(value, limit, fallback))
    return fit(fallback, limit) if not text or tripped(text) else text


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def card_hash(card):
    shown = {k: card[k] for k in CARD_HASH_FIELDS if k in card}
    return hashlib.sha256(canonical(shown).encode("utf-8")).hexdigest()


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_stamp(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def instant(text):
    if not isinstance(text, str) or not INSTANT.match(text):
        return None
    norm = re.sub(r"\.([0-9]+)", lambda m: "." + m.group(1).ljust(6, "0"), text)
    try:
        return datetime.datetime.fromisoformat(norm.replace("Z", "+00:00"))
    except ValueError:
        return None


home_dir = os.environ["FM_TODAY_HOME_DIR"]
state_dir = os.environ["FM_TODAY_STATE"]
with open(os.environ["FM_TODAY_BEARINGS"], encoding="utf-8") as fh:
    bearings = json.load(fh)
now = utc_now()


def repo_for(repo, pr_url=None):
    if isinstance(repo, str) and REPO.match(repo):
        return repo
    for url in (pr_url,):
        m = GITHUB.search(url or "")
        if m:
            return "%s/%s" % m.groups()
    if isinstance(repo, str) and re.match(r"^[A-Za-z0-9_.-]{1,100}$", repo):
        clone = os.path.join(home_dir, "projects", repo)
        if os.path.isdir(clone):
            try:
                origin = subprocess.run(["git", "-C", clone, "remote", "get-url", "origin"],
                                        capture_output=True, text=True, timeout=5).stdout.strip()
            except (OSError, subprocess.SubprocessError):
                origin = ""
            m = GITHUB.search(origin)
            if m:
                return "%s/%s" % m.groups()
    return None


def pr_for(url):
    return url if isinstance(url, str) and PR_URL.match(url) and len(url) <= 500 else None


def event_ref(label):
    return "event-" + hashlib.sha256(label.encode("utf-8")).hexdigest()[:16]


def plan_fields(plan, kind, charted):
    out = {}
    if not isinstance(plan, dict):
        plan = {}
    size = plan.get("size")
    if size in ("S", "M", "L", "XL"):
        out["size"] = size
    urgency = plan.get("urgency")
    if isinstance(urgency, int) and not isinstance(urgency, bool) and 0 <= urgency <= 4:
        out["urgency"] = urgency
    ptype = plan.get("type")
    if ptype in ("fix", "upkeep"):
        out["type"] = ptype
    elif kind in ("ship", "scout", "docs"):
        out["type"] = kind
    elif ptype == "feature":
        out["type"] = "ship"
    waits = []
    for label in plan.get("waits_on") or []:
        text = checked(label, 200, WITHHELD_TEXT)
        if text and len(waits) < 20:
            waits.append({"kind": "event", "ref": event_ref(line(label, 1000)), "label": text})
    if waits:
        out["waits_on"] = waits
    order = plan.get("order")
    if charted and isinstance(order, int) and not isinstance(order, bool) and 0 <= order <= 100000:
        out["order"] = order
    return out


def slug(value, fallback):
    text = re.sub(r"[^a-z-]+", "-", str(value or "").lower()).strip("-")[:32]
    return text or fallback


def split_owner(raw_id, owner=None):
    """Bearings' `mate/task` id as (owner, task); otherwise the row's own owner or (main)."""
    if isinstance(raw_id, str) and "/" in raw_id:
        return tuple(raw_id.split("/", 1))
    return (owner if isinstance(owner, str) and owner else MAIN), raw_id


seen_work = set()


def claim_work(section, owner, raw_id):
    if not isinstance(raw_id, str) or not TASK_ID.match(raw_id):
        skipped.append("%s row %s: id the contract cannot carry" % (section, json.dumps(raw_id)))
        return False
    if not OWNER.match(owner):
        skipped.append("%s row %s: owner %s the contract cannot carry" % (section, raw_id, json.dumps(owner)))
        return False
    if (owner, raw_id) in seen_work:
        skipped.append("%s row %s/%s: already listed" % (section, owner, raw_id))
        return False
    if len(seen_work) >= WORK_LIMIT:
        skipped.append("%s row %s: over the %d-row work limit" % (section, raw_id, WORK_LIMIT))
        return False
    seen_work.add((owner, raw_id))
    return True


recorded_prs = {r.get("id"): r.get("url") for r in bearings.get("recorded_prs") or []
                if isinstance(r, dict)}

def recorded_options(raw, tid):
    """The call's own options as bin/fm-captain-hold.sh recorded them, checked
    against the card's option shape; the contract's reserved values, repeats,
    a second recommendation, and anything past 11 are left out and named."""
    kept, values = [], {RECONCILE["value"]}
    for opt in raw if isinstance(raw, list) else []:
        value = opt.get("value") if isinstance(opt, dict) else None
        if (not isinstance(value, str) or not OPTION_VALUE.match(value)
                or value == "later" or value in values or len(kept) >= 11):
            skipped.append("call %s option %s: a value the card cannot carry" % (tid, json.dumps(value)))
            continue
        values.add(value)
        shown = {"value": value, "label": whole(line(opt.get("label"), 120, value)) or value}
        hint = whole(line(opt.get("hint"), 400))
        if hint:
            shown["hint"] = hint
        recommended = opt.get("recommended") is True and not any(o["recommended"] for o in kept)
        shown["recommended"] = recommended
        kept.append(shown)
    return kept


def withheld_option(opt, index):
    shown = {"value": opt["value"], "label": "Option %d" % index, "recommended": opt["recommended"]}
    if "hint" in opt:
        shown["hint"] = WITHHELD_TEXT
    return shown


# --- calls -------------------------------------------------------------------
calls = []
seen_calls = set()
for dec in bearings.get("decisions_open") or []:
    owner, tid = split_owner(dec.get("id"), dec.get("owner"))
    if not isinstance(tid, str) or not TASK_ID.match(tid) or not OWNER.match(owner):
        skipped.append("call %s: id the contract cannot carry" % json.dumps(dec.get("id")))
        continue
    if (owner, tid) in seen_calls or len(calls) >= 200:
        skipped.append("call %s/%s: already listed or over the 200-call limit" % (owner, tid))
        continue
    seen_calls.add((owner, tid))
    title = whole(line(dec.get("summary"), 200, tid)) or tid
    question = whole(line(dec.get("summary"), 4000, tid)) or tid
    options = recorded_options(dec.get("options"), tid) + [dict(RECONCILE)]
    shown = [title, question] + [o["label"] for o in options] + [o.get("hint", "") for o in options]
    verdict = "withheld" if tripped(*shown) else "pass"
    if verdict == "withheld":
        title, question = WITHHELD_TITLE, WITHHELD_QUESTION
        options = [o if o["value"] == RECONCILE["value"] else withheld_option(o, i)
                   for i, o in enumerate(options, 1)]
    card = {"schema": "fm-today-card.v1", "task_id": tid, "owner": owner, "kind": "decision",
            "title": title, "question": question, "options": options, "repo": None}
    card["text_check"] = {"verdict": verdict, "checker": CHECKER, "checked_at": now}
    card["card_hash"] = card_hash(card)
    calls.append(card)

# --- work --------------------------------------------------------------------
underway = []
for row in bearings.get("in_flight") or []:
    owner, raw = split_owner(row.get("id"))
    if not claim_work("underway", owner, raw):
        continue
    kind = slug(row.get("kind"), "work")
    state = slug(row.get("state"), "unknown")
    pr = pr_for(recorded_prs.get(row.get("id")))
    out = {"id": raw,
           "title": checked(row.get("name"), 200, raw),
           "kind": kind, "state": state,
           "doing": checked(row.get("doing"), 200, state),
           "repo": repo_for(row.get("repo"), pr),
           "owner": owner}
    out.update(plan_fields(row.get("plan"), row.get("kind"), False))
    if pr:
        out["pr_url"] = pr
    underway.append(out)

charted = []
for row in bearings.get("gates") or []:
    raw = row.get("id")
    warning = isinstance(raw, str) and raw.startswith("(") and raw.endswith(")")
    if warning:
        raw = raw[1:-1]
    owner, raw = split_owner(raw, row.get("owner"))
    if not claim_work("charted_next", owner, raw):
        continue
    blocked = [b for b in str(row.get("blocked_by") or "-").split(",")
               if b and b != "-" and TASK_ID.match(b)]
    reason = row.get("reason")
    reason = "" if reason in (None, "-") else checked(reason, 200, WITHHELD_TEXT)
    out = {"id": raw,
           "title": checked(row.get("title"), 200, raw),
           "reason": reason,
           "dispatchable": (not warning) and not blocked and not reason,
           "kind": "warning" if warning else "queued"}
    filed = row.get("filed")
    if isinstance(filed, str) and DATE.match(filed):
        out["filed"] = filed[:10]
    if blocked:
        out["blocked_by"] = blocked
    out["repo"] = repo_for(row.get("repo"))
    out["owner"] = owner
    out.update(plan_fields(row.get("plan"), row.get("kind"), True))
    charted.append(out)

landed = []
for row in bearings.get("landed") or []:
    owner, raw = split_owner(row.get("id"), row.get("owner"))
    if not claim_work("landed", owner, raw):
        continue
    out = {"id": raw,
           "title": checked(row.get("what"), 200, raw),
           "owner": owner}
    pr = pr_for(row.get("artifact"))
    if pr and "/pull/" not in pr:
        pr = None
    out["repo"] = repo_for(None, pr)
    if pr:
        out["pr_url"] = pr
    landed.append(out)

# --- health ------------------------------------------------------------------
unhealthy = []
for row in bearings.get("unhealthy_endpoints") or []:
    uid = row.get("id")
    if not isinstance(uid, str) or not re.match(r"^[A-Za-z0-9._/-]{1,257}$", uid):
        skipped.append("unhealthy row %s: id the contract cannot carry" % json.dumps(uid))
        continue
    agent = row.get("agent")
    alive = True if agent in (True, "alive") else False if agent in (False, "dead") else None
    unhealthy.append({"id": uid, "endpoint_exists": row.get("exists") is True,
                      "agent_alive": alive})
health = {"supervision": os.environ.get("FM_TODAY_SUPERVISION", "unknown"),
          "unhealthy": unhealthy}
if health["supervision"] not in ("live", "lapsed", "unknown"):
    health["supervision"] = "unknown"

# --- boards ------------------------------------------------------------------
sessions, open_files = {}, set()
try:
    with open(os.environ["FM_TODAY_LAVISH_STATE"], encoding="utf-8") as fh:
        for sess in (json.load(fh).get("sessions") or {}).values():
            if isinstance(sess, dict) and isinstance(sess.get("file"), str):
                sessions.setdefault(sess["file"], []).append(sess.get("url"))
                if sess.get("status") == "open":
                    open_files.add(sess["file"])
except (OSError, ValueError, AttributeError):
    sessions, open_files = {}, set()

boards, listed_sources = [], set()
for rec in sorted(glob.glob(os.path.join(state_dir, "procevent", "*.source"))):
    sid = os.path.basename(rec)[:-len(".source")]
    fields, argv = {}, []
    try:
        with open(rec, encoding="utf-8") as fh:
            in_argv = False
            for raw_line in fh.read().splitlines():
                if in_argv:
                    argv.append(raw_line)
                elif raw_line == "argv:":
                    in_argv = True
                elif "=" in raw_line:
                    key, _, value = raw_line.partition("=")
                    fields[key] = value
    except OSError:
        continue
    if fields.get("adapter") != "lavish" or fields.get("kind") != "task-owned":
        continue
    task = fields.get("owner_task", "")
    if not TASK_ID.match(task):
        skipped.append("board %s: owner task the contract cannot carry" % sid)
        continue
    artifact = argv[argv.index("poll") + 1] if "poll" in argv[:-1] else ""
    urls = [u for u in sessions.get(os.path.realpath(artifact) if artifact else "", [])
            if isinstance(u, str) and LINK.match(u) and len(u) <= 500]
    if len(urls) != 1:
        skipped.append("board %s: no single saved session link" % sid)
        continue
    results = glob.glob(os.path.join(state_dir, "procevent-inbox", glob.escape(sid) + ".*.result"))
    results = [r for r in results if re.match(r"^\d+$", r[:-len(".result")].rsplit(".", 1)[-1])]
    pending = [r for r in results if not os.path.exists(r[:-len(".result")] + ".handled")]
    stamps = [os.path.getmtime(p) for p in [rec] + results
              + [r[:-len(".result")] + ".handled" for r in results]
              if os.path.exists(p)]
    if pending:
        bstate = "round-open"
    elif not os.path.exists(os.path.join(state_dir, task + ".meta")):
        bstate = "owner-gone"
    else:
        bstate = "listening"
    boards.append({"owner_task": task, "state": bstate, "round": len(results),
                   "last_changed": utc_stamp(max(stamps)), "link": urls[0]})
    listed_sources.add(sid)

# A board still open in Lavish whose source registration is gone: its task was
# torn down or retired the source, and nothing listens to it any more. Its
# owner is recovered only from the owner-task files its captured rounds left
# behind, and never guessed; a board whose rounds left no owner-task file was
# never task-owned. The source id is Lavish's own derivation
# (bin/fm-procevent-lavish.sh source-id).
for board_file in sorted(open_files):
    real = os.path.realpath(board_file)
    sid = "lavish-" + hashlib.sha256(real.encode("utf-8")).hexdigest()[:16]
    if sid in listed_sources or os.path.exists(
            os.path.join(state_dir, "procevent", sid + ".source")):
        continue
    results = glob.glob(os.path.join(state_dir, "procevent-inbox", glob.escape(sid) + ".*.result"))
    results = [r for r in results if re.match(r"^\d+$", r[:-len(".result")].rsplit(".", 1)[-1])]
    owners = set()
    for r in results:
        try:
            with open(r[:-len(".result")] + ".owner-task", encoding="utf-8") as fh:
                owners.add(tuple(fh.read().splitlines()))
        except OSError:
            pass
    if not owners:
        continue
    lines = next(iter(owners))
    if len(owners) != 1 or len(lines) != 1 or not TASK_ID.match(lines[0]):
        skipped.append("board %s: owner task cannot be recovered" % sid)
        continue
    task = lines[0]
    urls = [u for u in sessions.get(board_file, [])
            if isinstance(u, str) and LINK.match(u) and len(u) <= 500]
    if len(urls) != 1:
        skipped.append("board %s: no single saved session link" % sid)
        continue
    pending = [r for r in results if not os.path.exists(r[:-len(".result")] + ".handled")]
    stamps = [os.path.getmtime(p) for p in results
              + [r[:-len(".result")] + ".handled" for r in results]
              if os.path.exists(p)]
    if pending:
        bstate = "round-open"
    elif not os.path.exists(os.path.join(state_dir, task + ".meta")):
        bstate = "owner-gone"
    else:
        bstate = "listening"
    boards.append({"owner_task": task, "state": bstate, "round": len(results),
                   "last_changed": utc_stamp(max(stamps)), "link": urls[0]})
    listed_sources.add(sid)

# --- day ---------------------------------------------------------------------
local_now = datetime.datetime.now().astimezone()
today = local_now.date()
default_end = datetime.datetime.combine(today + datetime.timedelta(days=1),
                                        datetime.time()).astimezone()
day = {"date": today.isoformat(), "ends_at": default_end.isoformat(timespec="seconds"),
       "blocks": []}
try:
    with open(os.environ["FM_TODAY_DAY_PATH"], encoding="utf-8") as fh:
        raw_day = json.load(fh)
except (OSError, ValueError):
    raw_day = None
if isinstance(raw_day, dict) and raw_day.get("date") == today.isoformat():
    if instant(raw_day.get("ends_at")):
        day["ends_at"] = raw_day["ends_at"]
    block_ids = set()
    for block in raw_day.get("blocks") or []:
        if not isinstance(block, dict):
            continue
        bid = block.get("id")
        start, end = instant(block.get("starts_at")), instant(block.get("ends_at"))
        if (not isinstance(bid, str) or not REF.match(bid) or bid in block_ids
                or start is None or end is None or end < start):
            skipped.append("day block %s: unusable id or times" % json.dumps(bid))
            continue
        if len(day["blocks"]) >= 200:
            skipped.append("day block %s: over the 200-block limit" % bid)
            continue
        block_ids.add(bid)
        day["blocks"].append({"id": bid, "title": line(block.get("title"), 200, "Busy"),
                              "starts_at": block["starts_at"], "ends_at": block["ends_at"]})

snapshot = {
    "schema": "fm-today-snapshot.v1",
    "generator_version": GENERATOR_VERSION,
    "generated_at": now,
    "home": checked(bearings.get("home"), 200, "firstmate"),
    "sections": {"calls": calls, "underway": underway, "charted_next": charted,
                 "landed": landed, "health": health, "boards": boards, "day": day},
}
for note in skipped:
    print("fm-today-bridge: left out %s" % note, file=sys.stderr)
json.dump(snapshot, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY
}

check_snapshot() {  # <file>
  local file=$1 bytes
  bytes=$(wc -c < "$file" | tr -d ' ')
  [ "$bytes" -le "$MAX_BYTES" ] \
    || die "refusing to send: the snapshot is $bytes bytes, over the portal's 512 KiB limit"
  python3 "$CHECKER" check "$CONTRACT_DIR" "$file" >&2 \
    || die "refusing to send: the snapshot fails the Today contract check above"
}

cmd_snapshot() {
  [ "$#" -eq 0 ] || die "snapshot takes no arguments" 2
  make_tmp
  build_snapshot "$TMP_DIR/snapshot.json"
  cat "$TMP_DIR/snapshot.json"
}

cmd_push() {
  local dry='' url token missing='' snap hdr body code heard
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) [ "$#" -ge 2 ] || die "--dry-run needs an output file" 2; dry=$2; shift 2 ;;
      *) die "unknown push argument: $1" 2 ;;
    esac
  done
  if [ -z "$dry" ]; then
    url=$(config_value FM_TODAY_PORTAL_URL)
    token=$(config_value FM_TODAY_BRIDGE_TOKEN)
    [ -n "$url" ] || missing="FM_TODAY_PORTAL_URL"
    [ -n "$token" ] || missing="${missing:+$missing and }FM_TODAY_BRIDGE_TOKEN"
    [ -z "$missing" ] || die "missing $missing; nothing was sent" 2
    [[ "$url" =~ ^https://|^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?(/.*)?$ ]] \
      || die "FM_TODAY_PORTAL_URL must be https://, or http:// only to 127.0.0.1 or localhost; nothing was sent" 2
    case "$token" in
      *[[:space:]]*) die "FM_TODAY_BRIDGE_TOKEN must not contain whitespace; nothing was sent" 2 ;;
    esac
  fi
  make_tmp
  snap="$TMP_DIR/snapshot.json"
  build_snapshot "$snap"
  check_snapshot "$snap"
  if [ -n "$dry" ]; then
    cp -- "$snap" "$dry" || die "cannot write $dry"
    printf 'dry-run: wrote %s; nothing was sent\n' "$dry"
    return 0
  fi
  hdr="$TMP_DIR/headers"
  body="$TMP_DIR/body"
  (umask 077; printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$token" > "$hdr")
  code=$(curl -sS --max-time 30 -o "$body" -w '%{http_code}' -H @"$hdr" \
    --data-binary @"$snap" "${url%/}/api/fleet/bridge/snapshot" 2>"$TMP_DIR/curl.err") || code=000
  rm -f -- "$hdr"
  if [ "$code" = 000 ]; then
    die "could not reach the portal at ${url%/}: $(head -n1 "$TMP_DIR/curl.err")" 3
  fi
  if [ "$code" != 200 ]; then
    die "the portal answered $code$(jq -r '(.code // empty) | " (" + tostring + ")"' "$body" 2>/dev/null || true)" 3
  fi
  heard=$(jq -r '.heard_at // empty | strings' "$body" 2>/dev/null || true)
  [ -n "$heard" ] || die "the portal answered 200 without a heard_at stamp" 3
  printf 'heard_at: %s\n' "$heard"
}

case "${1:-}" in
  snapshot) shift; cmd_snapshot "$@" ;;
  push) shift; cmd_push "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command: $1" 2 ;;
esac
