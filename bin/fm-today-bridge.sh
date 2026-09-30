#!/usr/bin/env bash
# fm-today-bridge.sh - the Today bridge: build the fleet's
# fm-today-snapshot.v1 document and send it to the admin portal, and carry the
# captain's answers from the portal back into firstmate's hold lifecycle.
#
# docs/today-contract.md owns the contract this implements: every field's
# meaning, the card_hash definition, the privacy rules, and the portal's
# POST /api/fleet/bridge/snapshot and POST /api/fleet/answers endpoints. Every
# connection is opened from this machine, outward; nothing here listens.
#
# Usage:
#   fm-today-bridge.sh snapshot
#   fm-today-bridge.sh push [--dry-run <out.json>]
#   fm-today-bridge.sh answers once [--wait <0-25>]
#   fm-today-bridge.sh answers poll [--wait <1-25>] [--retries <n>]
#   fm-today-bridge.sh answers check
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
#           A call's kind comes from its hold (bin/fm-captain-hold.sh hold
#           --call, carried as bearings' decisions_open call): a `merge` card
#           names its pull request as `pr_url` and offers `merge`, a `go` card
#           offers `go`, a `credential` card offers nothing, and every other
#           call is a `decision` card. A decision card offers, in order, the
#           hold's structured options when bearings records them
#           (decisions_open options), then the standard `reconcile` option,
#           labelled "Already settled"; until options are recorded a decision
#           card offers only `reconcile`, and the portal adds `later`; a merge
#           or go card offers its recorded options in place of its standard
#           one. A recorded option the card cannot
#           carry is left out and named on stderr, and a withheld card shows
#           each recorded option as `Option <n>`, its hint as neutral text.
#           A merge call whose pull request the card cannot carry goes out as a
#           decision and is named on stderr. The portal adds `later` itself.
#           Every card and work row carries `repo`: `owner/name` when one is
#           found, otherwise `null`; a merge card's comes from its pull
#           request, and bearings records none for any other call.
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
# answers once
#           One call to POST ${FM_TODAY_PORTAL_URL}/api/fleet/answers, with the
#           same token and URL rule as push. The body carries every receipt not
#           yet sent and `wait_seconds` (default 0). On a 200 those receipts
#           are marked sent, and each answer returned is carried as below and
#           printed as one `answer-json: <summary>` line; an answer already
#           received prints `duplicate: <answer_id>` instead. Exit 3 when the
#           portal cannot be reached or answers anything but 200, 4 when
#           another exchange is running in this home.
# answers poll
#           The blocking child bin/fm-procevent-today-answers.sh arms; never
#           run it in a conversational turn. It repeats that call with
#           `wait_seconds` --wait (default 25) until a call carries answers,
#           calls again at once so their receipts leave, then prints one
#           result (`status: answers`, the count, and the answer-json lines)
#           and exits. A portal that cannot be reached is retried --retries
#           times (default 8) with a growing pause; after that, or at once on
#           a refused token or unusable setting, it prints `status: error` with
#           the reason. Answers already carried are still reported when a later
#           call fails, and their receipts wait for the next call.
# answers check
#           Check the URL and token settings and print the portal origin.
#
# Carrying an answer. The store lives in $STATE/today-answers/ (private):
# answers/<answer_id>.json keeps each answer as received, receipts/ keeps its
# one receipt, written before the next call, with a .sent marker once a 200
# confirmed the portal has it, and dups/ holds `duplicate` receipts not yet
# sent. A receipt is never re-derived, so a crash or a failed call re-sends the
# stored receipt and never carries the answer again; an answer stored with no
# receipt was interrupted mid-carry, and is refused with the reason to check
# the call at the machine rather than carried again. Each new answer is
# checked against the call as it stands now (a fresh snapshot), in this order:
#   0. An answer that does not declare schema fm-today-answer.v1 or lacks
#      kind, value, or card_hash is refused.
#   1. A merge or go answer is refused with reason `proof_required: ...`
#      before its card or any hold is read, and so is any other answer to a
#      merge or go card. Until
#      firstmate checks the captain's passkey itself, a merge word or a go to
#      build from the portal never merges, releases, dispatches, or closes
#      anything; it is recorded and receipted, and the captain gives that word
#      at the machine.
#   2. Any other answer must pass the answer schema, or it is refused.
#   3. A second mate's answer is recorded and refused with the fixed reason
#      MATE_REFUSAL; nothing is applied in this home or the mate's, and the
#      captain answers a second mate's call at the machine for now.
#   4. A call no longer in the snapshot is refused; a card_hash that is not
#      the current card's is `set-aside` with `current_card_hash`, and the call
#      is asked again in the next snapshot. A value the card did not offer, or
#      a note over 512 bytes, is refused.
#   5. Nothing is applied in this home unless its bridge source id
#      `today-bridge` is bound (bin/fm-captain-hold.sh bind, which
#      bin/fm-procevent-today-answers.sh arm does before arming); an unbound
#      home refuses the answer.
#   6. `later` re-holds the call with bin/fm-captain-hold.sh hold --until the
#      captain's local date of later_until; `seen` on a credential card is
#      recorded and the call stays open; `reconcile` files a reconcile request
#      through bin/fm-captain-hold.sh reconcile-requests under the bound
#      source id `today-bridge`, never a close; any other value goes to
#      bin/fm-captain-hold.sh answers, the one keyed-answer intake, with the
#      option's label and close mode `done` when the call is a captain
#      question (backlog kind captain). An option answer on held work, whose
#      close would be `release`, frees gated work, so until the passkey
#      verifier lands it is recorded and refused with the same
#      `proof_required: ...` reason as a merge or go answer, whatever the
#      hold's --call tag, and never reaches the intake. The answer id, device,
#      and any note are recorded as the answer's provenance; the note is the
#      captain's words and never an instruction.
# Each answer is checked and carried on its own: an error while doing so, such
# as a later_until that names no real date, refuses that answer with reason
# `could not carry the answer: ...`, and the rest of the batch is still
# carried, so every answer gets a receipt.
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
# the portal cannot be reached or answers anything but 200; 4 when another
# answers exchange holds this home's store.
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
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

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

URL=''
TOKEN=''
CONFIG_ERROR=''
# load_config_quiet: set URL and TOKEN, or set CONFIG_ERROR to why not and
# return 1. load_config exits 2 with that reason instead.
load_config_quiet() {
  local missing=''
  CONFIG_ERROR=''
  URL=$(config_value FM_TODAY_PORTAL_URL)
  TOKEN=$(config_value FM_TODAY_BRIDGE_TOKEN)
  [ -n "$URL" ] || missing="FM_TODAY_PORTAL_URL"
  [ -n "$TOKEN" ] || missing="${missing:+$missing and }FM_TODAY_BRIDGE_TOKEN"
  if [ -n "$missing" ]; then
    CONFIG_ERROR="missing $missing; nothing was sent"
    return 1
  fi
  if [[ ! "$URL" =~ ^https://|^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?(/.*)?$ ]]; then
    CONFIG_ERROR="FM_TODAY_PORTAL_URL must be https://, or http:// only to 127.0.0.1 or localhost; nothing was sent"
    return 1
  fi
  case "$TOKEN" in
    *[[:space:]]*) CONFIG_ERROR="FM_TODAY_BRIDGE_TOKEN must not contain whitespace; nothing was sent"; return 1 ;;
  esac
  URL=${URL%/}
}

load_config() { load_config_quiet || die "$CONFIG_ERROR" 2; }

# portal_post <path> <body-file> <out-file> <max-seconds>: print the HTTP
# status, 000 when the portal could not be reached. The bearer header lives
# only in a private file for the length of the call.
portal_post() {
  local hdr code
  make_tmp
  hdr="$TMP_DIR/headers"
  (umask 077; printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$TOKEN" > "$hdr") \
    || { printf '000\n'; return; }
  code=$(curl -sS --max-time "$4" -o "$3" -w '%{http_code}' -H @"$hdr" \
    --data-binary @"$2" "$URL$1" 2>"$TMP_DIR/curl.err") || code=000
  rm -f -- "$hdr"
  case "$code" in [0-9][0-9][0-9]) printf '%s\n' "$code" ;; *) printf '000\n' ;; esac
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
cleanup() {
  [ "${EXCHANGE_LOCK_HELD:-0}" != 1 ] || fm_lock_release "$STATE/today-answers/.exchange.lock" || true
  [ -z "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

make_tmp() {
  [ -n "$TMP_DIR" ] || TMP_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-today-bridge.XXXXXX")
}

build_snapshot() {  # <out-file> [<private-calls-out>]
  local out=$1 calls_out=${2:-} bearings supervision
  make_tmp
  bearings="$TMP_DIR/bearings.json"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json --all-in-flight \
    --all-decisions --all-queued --all-unhealthy > "$bearings" \
    || die "the bearings snapshot failed; nothing was built"
  supervision=$(supervision_state)
  FM_TODAY_BEARINGS="$bearings" FM_TODAY_SUPERVISION="$supervision" FM_TODAY_CALLS_OUT="$calls_out" \
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

GENERATOR_VERSION = "1.3.0"
CHECKER = "fm-today-text-check@1.0.0"
# docs/today-contract.md owns this definition.
CARD_HASH_FIELDS = ("schema", "task_id", "owner", "kind", "title", "question",
                    "options", "repo", "pr_url", "due")
MAIN = "(main)"
WORK_LIMIT = 1000
TASK_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
OPTION_VALUE = TASK_ID
OWNER = re.compile(r"^(\(main\)|[A-Za-z0-9._-]{1,128})$")
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
# The options a card of each kind offers; a credential card offers none.
KIND_OPTIONS = {
    "decision": [RECONCILE],
    "merge": [{"value": "merge", "label": "Merge",
               "hint": "Merge this pull request once its checks are green", "recommended": True}],
    "go": [{"value": "go", "label": "Go", "hint": "Start building", "recommended": True}],
    "credential": [],
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
private_calls = []
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
    call = dec.get("call") if isinstance(dec.get("call"), dict) else {}
    kind, pr = "decision", None
    if call.get("kind") == "merge":
        pr = pr_for(call.get("pr_url"))
        if pr:
            kind = "merge"
        else:
            skipped.append("call %s/%s: merge call without a usable pull request, sent as a decision"
                           % (owner, tid))
    elif call.get("kind") in ("go", "credential"):
        kind = call["kind"]
    recorded = [] if kind == "credential" else recorded_options(dec.get("options"), tid)
    if kind == "decision":
        options = recorded + [dict(RECONCILE)]
    else:
        options = recorded or [dict(o) for o in KIND_OPTIONS[kind]]
    shown = [title, question] + [o["label"] for o in options] + [o.get("hint", "") for o in options]
    verdict = "withheld" if tripped(*shown) else "pass"
    if verdict == "withheld":
        title, question = WITHHELD_TITLE, WITHHELD_QUESTION
        options = [withheld_option(o, i) if any(o is r for r in recorded) else o
                   for i, o in enumerate(options, 1)]
    card = {"schema": "fm-today-card.v1", "task_id": tid, "owner": owner, "kind": kind,
            "title": title, "question": question, "options": options,
            "repo": repo_for(None, pr) if pr else None}
    if pr:
        card["pr_url"] = pr
    card["text_check"] = {"verdict": verdict, "checker": CHECKER, "checked_at": now}
    card["card_hash"] = card_hash(card)
    calls.append(card)
    # A captain question closes when answered; until the passkey verifier
    # lands, an answer on held work is refused for proof.
    private_calls.append({"owner": owner, "task_id": tid,
                          "close": "done" if dec.get("task_kind") == "captain" else "release"})

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
if os.environ.get("FM_TODAY_CALLS_OUT"):
    with open(os.environ["FM_TODAY_CALLS_OUT"], "w", encoding="utf-8") as fh:
        json.dump(private_calls, fh)
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
  local dry='' snap body code heard
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) [ "$#" -ge 2 ] || die "--dry-run needs an output file" 2; dry=$2; shift 2 ;;
      *) die "unknown push argument: $1" 2 ;;
    esac
  done
  [ -n "$dry" ] || load_config
  make_tmp
  snap="$TMP_DIR/snapshot.json"
  build_snapshot "$snap"
  check_snapshot "$snap"
  if [ -n "$dry" ]; then
    cp -- "$snap" "$dry" || die "cannot write $dry"
    printf 'dry-run: wrote %s; nothing was sent\n' "$dry"
    return 0
  fi
  body="$TMP_DIR/body"
  code=$(portal_post /api/fleet/bridge/snapshot "$snap" "$body" 30)
  if [ "$code" = 000 ]; then
    die "could not reach the portal at $URL: $(head -n1 "$TMP_DIR/curl.err" 2>/dev/null)" 3
  fi
  if [ "$code" != 200 ]; then
    die "the portal answered $code$(jq -r '(.code // empty) | " (" + tostring + ")"' "$body" 2>/dev/null || true)" 3
  fi
  heard=$(jq -r '.heard_at // empty | strings' "$body" 2>/dev/null || true)
  [ -n "$heard" ] || die "the portal answered 200 without a heard_at stamp" 3
  printf 'heard_at: %s\n' "$heard"
}

# --- answers -----------------------------------------------------------------
# The inward half: long-poll the portal for the captain's answers, carry each
# into firstmate's own hold lifecycle, and send one receipt per answer back.

ANSWERS_DIR="$STATE/today-answers"
RECONCILE_SOURCE_ID=today-bridge

ensure_answers_dir() {
  (umask 077; mkdir -p "$ANSWERS_DIR/answers" "$ANSWERS_DIR/receipts" "$ANSWERS_DIR/dups") \
    || die "cannot create $ANSWERS_DIR"
}

# answers_py <mode> <args...>: the answer store and the per-answer rules.
#   request <wait> <request-out> <sent-out>  build the next call's body from
#                                            every receipt not yet sent
#   sent <sent-file>                         mark those receipts sent
#   apply <response> <cards> <calls>         record, check, and carry each new
#                                            answer; print one answer-json:
#                                            line for each
answers_py() {
  FM_TODAY_ANSWERS_DIR="$ANSWERS_DIR" FM_TODAY_BIN="$SCRIPT_DIR" FM_TODAY_CHECKER="$CHECKER" \
    FM_TODAY_CONTRACT_DIR="$CONTRACT_DIR" FM_TODAY_RECONCILE_SOURCE="$RECONCILE_SOURCE_ID" \
    FM_HOME="$FM_HOME" python3 - "$@" <<'PY'
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

os.umask(0o077)
DIR = os.environ["FM_TODAY_ANSWERS_DIR"]
BIN = os.environ["FM_TODAY_BIN"]
HOLD = os.path.join(BIN, "fm-captain-hold.sh")
MAIN = "(main)"
ID = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
TASK_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
OWNER = re.compile(r"^(\(main\)|[A-Za-z0-9._-]{1,128})$")
RECEIPT_BATCH = 200
# Until firstmate can check the captain's passkey itself, no merge word or go
# to build from the portal is ever carried: it is recorded and refused here,
# before any card or hold is read.
PROOF_KINDS = ("merge", "go")
PROOF_REFUSAL = ("proof_required: a merge or go answer needs the captain's passkey signature, "
                 "which firstmate cannot check yet; nothing was merged, released, or started. "
                 "Give this word at the machine.")
# Slice 0 applies no second mate's answer anywhere: it is recorded and refused.
MATE_REFUSAL = "answer a second mate's call at the machine for now; nothing was applied"
# An answer stored with no receipt was being carried when the bridge stopped;
# it may already have been applied, so it is refused rather than carried again.
INTERRUPTED_REFUSAL = ("the bridge stopped while carrying this answer, so it may or may not "
                       "have been applied; check the call at the machine")


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_json(path, value):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(value, fh, ensure_ascii=False)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def pending():
    out = []
    for path in sorted(glob.glob(os.path.join(DIR, "receipts", "*.json"))):
        if not os.path.exists(path[:-len(".json")] + ".sent"):
            out.append(("receipt", path))
    for path in sorted(glob.glob(os.path.join(DIR, "dups", "*.json"))):
        out.append(("dup", path))
    return out[:RECEIPT_BATCH]


def cmd_request(wait, req_out, sent_out):
    receipts, sent = [], []
    for kind, path in pending():
        try:
            with open(path, encoding="utf-8") as fh:
                receipts.append(json.load(fh))
        except (OSError, ValueError):
            print("fm-today-bridge: an unreadable stored receipt was left out: %s" % path, file=sys.stderr)
            continue
        sent.append("%s\t%s" % (kind, path))
    with open(req_out, "w", encoding="utf-8") as fh:
        json.dump({"receipts": receipts, "wait_seconds": int(wait)}, fh, ensure_ascii=False)
    with open(sent_out, "w", encoding="utf-8") as fh:
        fh.write("".join(line + "\n" for line in sent))


def cmd_sent(sent_file):
    with open(sent_file, encoding="utf-8") as fh:
        for line in fh.read().splitlines():
            kind, _, path = line.partition("\t")
            if kind == "receipt":
                open(path[:-len(".json")] + ".sent", "a").close()
            elif kind == "dup":
                try:
                    os.remove(path)
                except FileNotFoundError:
                    pass


def first_line(text, fallback):
    for raw in (text or "").splitlines():
        raw = raw.strip()
        if raw:
            return raw
    return fallback


def run(argv, stdin=""):
    try:
        proc = subprocess.run(argv, input=stdin, capture_output=True, text=True,
                              env=dict(os.environ), timeout=300)
    except subprocess.TimeoutExpired:
        return 124, "", "%s did not finish in 300 seconds" % os.path.basename(argv[0])
    return proc.returncode, proc.stdout, proc.stderr


def one_line(text):
    """Text safe inside one tab-separated intake row."""
    return " ".join((text or "").split())


def schema_errors(answer):
    fd, tmp = tempfile.mkstemp(dir=DIR, prefix=".check.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(answer, fh)
        rc, out, _err = run(["python3", os.environ["FM_TODAY_CHECKER"], "check",
                             os.environ["FM_TODAY_CONTRACT_DIR"], tmp])
    finally:
        os.remove(tmp)
    return None if rc == 0 else first_line(out, "does not match fm-today-answer.v1")


def later_date(stamp):
    """The captain's local date of a later_until instant: the day to ask again."""
    when = datetime.datetime.fromisoformat(re.sub(r"\.[0-9]+", "", stamp).replace("Z", "+00:00"))
    return when.astimezone().date().isoformat()


def carry(answer, cards, closes):
    """One valid, new answer: returns (outcome, reason, current_card_hash, action)."""
    owner = answer.get("owner", MAIN)
    task, value = answer["task_id"], answer["value"]
    card = cards.get((owner, task))
    if answer["kind"] in PROOF_KINDS or (card and card["kind"] in PROOF_KINDS):
        return "refused", PROOF_REFUSAL, None, "refused"
    if owner != MAIN:
        return "refused", MATE_REFUSAL, None, "refused"
    if card is None:
        return "refused", "the call is no longer open", None, "refused"
    if answer["card_hash"] != card["card_hash"]:
        return ("set-aside", "the call changed after it was shown; it is asked again",
                card["card_hash"], "set-aside")
    offered = ["seen"] if card["kind"] == "credential" else [o["value"] for o in card["options"]]
    if value != "later" and value not in offered:
        return "refused", "the card did not offer %s" % value, None, "refused"
    if len((answer.get("note") or "").encode("utf-8")) > 512:
        return "refused", "the note is over 512 bytes", None, "refused"
    rc, _out, _err = run([HOLD, "binding", os.environ["FM_TODAY_RECONCILE_SOURCE"]])
    if rc != 0:
        return ("refused", "the Today source is not bound in this home; nothing was applied",
                None, "refused")
    source = "Today answer %s on device %s" % (answer["answer_id"], answer["device"])
    if value == "later":
        until = later_date(answer["later_until"])
        rc, _out, err = run([HOLD, "hold", task, "--until", until])
        if rc != 0:
            return "refused", "could not defer the call: %s" % first_line(err, "hold failed"), None, "refused"
        return "applied", "deferred until %s" % until, None, "deferred"
    if card["kind"] == "credential":
        return ("applied", "seen recorded; the credential is still needed at the machine",
                None, "seen-recorded")
    if value == "reconcile":
        rc, out, err = run([HOLD, "reconcile-requests", "--source-id",
                            os.environ["FM_TODAY_RECONCILE_SOURCE"], "--source", source],
                           "%s\t%s\n" % (task, one_line(answer.get("note"))))
        if rc == 0 and ("reconcile: %s" % task) in out.splitlines():
            return ("applied", "reconcile requested; firstmate re-checks the call before closing it",
                    None, "reconcile-requested")
        return ("refused", "could not record the reconcile request: %s"
                % first_line(out if rc == 0 else (out + err), "refused"), None, "refused")
    if closes.get((owner, task)) != "done":
        return "refused", PROOF_REFUSAL, None, "refused"
    label = next((o["label"] for o in card["options"] if o["value"] == value), value)
    if answer.get("note"):
        source += "; captain note: " + one_line(answer["note"])
    rc, out, err = run([HOLD, "answers", "--source", source],
                       "%s\t%s\t%s\tdone\n" % (task, value, one_line(label)))
    if rc == 0 and ("closed: %s" % task) in out.splitlines():
        return "applied", None, None, "closed"
    return ("refused", "not applied: %s" % first_line(out + err, "the hold lifecycle refused it"),
            None, "refused")


def cmd_apply(response, cards_file, calls_file):
    with open(response, encoding="utf-8") as fh:
        answers = json.load(fh).get("answers")
    cards, closes = {}, {}
    if answers:
        with open(cards_file, encoding="utf-8") as fh:
            for card in json.load(fh)["sections"]["calls"]:
                cards[(card.get("owner", MAIN), card["task_id"])] = card
        with open(calls_file, encoding="utf-8") as fh:
            for call in json.load(fh):
                closes[(call["owner"], call["task_id"])] = call["close"]
    seen = set()
    for answer in answers or []:
        aid = answer.get("answer_id") if isinstance(answer, dict) else None
        task = answer.get("task_id") if isinstance(answer, dict) else None
        owner = answer.get("owner", MAIN) if isinstance(answer, dict) else None
        if (not isinstance(aid, str) or not ID.fullmatch(aid) or not isinstance(task, str)
                or not TASK_ID.fullmatch(task) or not isinstance(owner, str)
                or not OWNER.fullmatch(owner)):
            print("fm-today-bridge: an answer with no usable answer_id, task_id, or owner "
                  "cannot be receipted and was left out", file=sys.stderr)
            continue
        receipt_path = os.path.join(DIR, "receipts", aid + ".json")
        base = {"schema": "fm-today-receipt.v1", "answer_id": aid, "task_id": task}
        if "owner" in answer:
            base["owner"] = owner
        if aid in seen:
            continue
        if os.path.exists(receipt_path):
            # Received before: once its receipt has gone out, the portal is
            # told `duplicate`; until then the stored receipt is still on its way.
            if os.path.exists(receipt_path[:-len(".json")] + ".sent"):
                if not glob.glob(os.path.join(DIR, "dups", glob.escape(aid) + ".*.json")):
                    dup = dict(base, outcome="duplicate", recorded_at=now())
                    write_json(os.path.join(DIR, "dups", "%s.%d.json" % (aid, os.getpid())), dup)
            print("duplicate: %s" % aid)
            continue
        seen.add(aid)
        answer_path = os.path.join(DIR, "answers", aid + ".json")
        if os.path.exists(answer_path):
            outcome, reason, current, action = "refused", INTERRUPTED_REFUSAL, None, "refused"
        else:
            write_json(answer_path, answer)
            try:
                if (answer.get("schema") != "fm-today-answer.v1"
                        or not all(isinstance(answer.get(k), str) for k in ("kind", "value", "card_hash"))):
                    why = "not an fm-today-answer.v1 with kind, value, and card_hash"
                elif answer.get("kind") in PROOF_KINDS:
                    why = None
                else:
                    why = schema_errors(answer)
                if why:
                    outcome, reason, current, action = "refused", "invalid answer: " + why, None, "refused"
                else:
                    outcome, reason, current, action = carry(answer, cards, closes)
            except Exception as exc:
                outcome, reason, current, action = ("refused", "could not carry the answer: %s"
                                                    % first_line(str(exc), type(exc).__name__), None, "refused")
        receipt = dict(base, outcome=outcome)
        if reason:
            receipt["reason"] = reason[:400]
        if current:
            receipt["current_card_hash"] = current
        receipt["recorded_at"] = now()
        write_json(receipt_path, receipt)
        summary = {"answer_id": aid, "owner": owner, "task_id": task,
                   "kind": answer.get("kind"), "value": answer.get("value")}
        for key in ("later_until", "note"):
            if key in answer:
                summary[key] = answer[key]
        summary.update({"outcome": outcome, "action": action})
        if reason:
            summary["reason"] = reason
        print("answer-json: " + json.dumps(summary, ensure_ascii=False))


mode = sys.argv[1]
if mode == "request":
    cmd_request(*sys.argv[2:5])
elif mode == "sent":
    cmd_sent(sys.argv[2])
elif mode == "apply":
    cmd_apply(*sys.argv[2:5])
else:
    sys.exit(2)
PY
}

EXCHANGE_ERROR=''
EXCHANGE_RETURNED=0
# answers_exchange <wait-seconds> <report-file>: one call to the portal. Sends
# every unsent receipt, marks them sent on a 200, then carries each answer it
# returns, appending its lines to <report-file>. Returns 0 on success, 2 when
# the portal refused the token, 3 when it could not be reached or answered
# anything else, and 1 on a local failure; EXCHANGE_ERROR says why.
answers_exchange() {
  local wait=$1 report=$2 req sent resp code n
  make_tmp
  ensure_answers_dir
  req="$TMP_DIR/answers-request.json"
  sent="$TMP_DIR/answers-sent"
  resp="$TMP_DIR/answers-response.json"
  EXCHANGE_ERROR=''
  EXCHANGE_RETURNED=0
  answers_py request "$wait" "$req" "$sent" \
    || { EXCHANGE_ERROR="could not read the stored receipts"; return 1; }
  code=$(portal_post /api/fleet/answers "$req" "$resp" $((wait + 20)))
  case "$code" in
    200) ;;
    000) EXCHANGE_ERROR="could not reach the portal at $URL"; return 3 ;;
    401) EXCHANGE_ERROR="the portal refused the bridge token (401)"; return 2 ;;
    *) EXCHANGE_ERROR="the portal answered $code to the answers call"; return 3 ;;
  esac
  answers_py sent "$sent" || { EXCHANGE_ERROR="could not mark the sent receipts"; return 1; }
  n=$(jq -er '.answers | if type == "array" then length else error end' "$resp" 2>/dev/null) \
    || { EXCHANGE_ERROR="the portal answered 200 without an answers list"; return 3; }
  EXCHANGE_RETURNED=$n
  [ "$n" -gt 0 ] || return 0
  # Every answer is checked against the call as it stands now. The subshell
  # keeps a failed build from ending a poll without its result.
  ( build_snapshot "$TMP_DIR/current.json" "$TMP_DIR/current-calls.json" ) \
    || { EXCHANGE_ERROR="could not build the snapshot to check the answers against"; return 1; }
  answers_py apply "$resp" "$TMP_DIR/current.json" "$TMP_DIR/current-calls.json" >> "$report" \
    || { EXCHANGE_ERROR="could not carry the answers"; return 1; }
}

EXCHANGE_LOCK_HELD=0
exchange_lock_take() {  # <wait-0-or-1>
  ensure_answers_dir
  while ! fm_lock_try_acquire "$ANSWERS_DIR/.exchange.lock"; do
    [ "$1" = 1 ] || return 1
    sleep 1
  done
  EXCHANGE_LOCK_HELD=1
}

exchange_lock_drop() {
  [ "$EXCHANGE_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$ANSWERS_DIR/.exchange.lock" || true
  EXCHANGE_LOCK_HELD=0
}

wait_arg() {  # <value> <min>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$2" ] && [ "$1" -le 25 ]
}

cmd_answers_once() {
  local wait=0 report rc=0 code=3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wait) wait_arg "${2-}" 0 || die "--wait needs 0 to 25 seconds" 2; wait=$2; shift 2 ;;
      *) die "unknown answers once argument: $1" 2 ;;
    esac
  done
  load_config
  make_tmp
  report="$TMP_DIR/report"
  : > "$report"
  exchange_lock_take 0 || die "another answers exchange is running in this home" 4
  answers_exchange "$wait" "$report" || rc=$?
  exchange_lock_drop
  cat "$report"
  [ "$rc" -ne 1 ] || code=1
  [ "$rc" -eq 0 ] || die "$EXCHANGE_ERROR" "$code"
}

print_answers_result() {  # <status> <detail> <report>
  printf 'today-answers: today-answers\n'
  printf 'status: %s\n' "$1"
  [ -z "$2" ] || printf 'detail: %s\n' "$2"
  printf 'answers: %s\n' "$(grep -c '^answer-json: ' "$3" || true)"
  grep '^answer-json: ' "$3" || true
}

cmd_answers_poll() {
  local wait=25 retries=8 report round failures=0 reported=0 rc new
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wait) wait_arg "${2-}" 1 || die "--wait needs 1 to 25 seconds" 2; wait=$2; shift 2 ;;
      --retries) case "${2-}" in ''|*[!0-9]*) die "--retries needs a whole number" 2 ;; esac
                 retries=$2; shift 2 ;;
      *) die "unknown answers poll argument: $1" 2 ;;
    esac
  done
  make_tmp
  report="$TMP_DIR/poll-report"
  round="$TMP_DIR/poll-round"
  : > "$report"
  while :; do
    if ! load_config_quiet; then
      print_answers_result error "$CONFIG_ERROR" "$report"
      exit 0
    fi
    : > "$round"
    rc=0
    exchange_lock_take 1
    # After a round that carried answers, call again at once so their
    # receipts leave now, then report.
    if [ "$reported" -gt 0 ]; then answers_exchange 0 "$round" || rc=$?
    else answers_exchange "$wait" "$round" || rc=$?; fi
    exchange_lock_drop
    cat "$round" >> "$report"
    new=$(grep -c '^answer-json: ' "$round" || true)
    if [ "$rc" -ne 0 ]; then
      if [ "$reported" -gt 0 ] || [ "$rc" -eq 2 ] || [ "$failures" -ge "$retries" ]; then
        if [ "$reported" -gt 0 ]; then
          print_answers_result answers "their receipts wait for the next call: $EXCHANGE_ERROR" "$report"
        else
          print_answers_result error "$EXCHANGE_ERROR" "$report"
        fi
        exit 0
      fi
      failures=$((failures + 1))
      sleep $((failures * 15 < 120 ? failures * 15 : 120))
      continue
    fi
    failures=0
    if [ "$new" -gt 0 ]; then
      reported=$((reported + new))
    elif [ "$reported" -gt 0 ]; then
      print_answers_result answers '' "$report"
      exit 0
    elif [ "$EXCHANGE_RETURNED" -gt 0 ] && ! grep -q '^duplicate: ' "$round"; then
      # Answers came back that could not be receipted, so the portal would
      # hand them straight back; wait rather than spin.
      sleep "$wait"
    fi
  done
}

cmd_answers_check() {
  [ "$#" -eq 0 ] || die "answers check takes no arguments" 2
  load_config
  printf 'portal: %s\n' "$URL"
}

cmd_answers() {
  case "${1:-}" in
    once) shift; cmd_answers_once "$@" ;;
    poll) shift; cmd_answers_poll "$@" ;;
    check) shift; cmd_answers_check "$@" ;;
    *) die "answers needs once, poll, or check" 2 ;;
  esac
}

case "${1:-}" in
  snapshot) shift; cmd_snapshot "$@" ;;
  push) shift; cmd_push "$@" ;;
  answers) shift; cmd_answers "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command: $1" 2 ;;
esac
