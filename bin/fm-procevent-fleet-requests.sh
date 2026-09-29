#!/usr/bin/env bash
# Fleet request queue process-event adapter: pulls staff requests from the admin
# portal's queue and hands each to firstmate as evidence.
#
# Usage:
#   fm-procevent-fleet-requests.sh arm [--interval <secs>] [--limit <1-20>]
#   fm-procevent-fleet-requests.sh poll [--interval <secs>] [--limit <1-20>]
#   fm-procevent-fleet-requests.sh read <result-file>
#   fm-procevent-fleet-requests.sh classify <result-file>
#   fm-procevent-fleet-requests.sh terminal <result-file>
#   fm-procevent-fleet-requests.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-fleet-requests.sh validate <definition> [<json-file>]
#   fm-procevent-fleet-requests.sh source-id
#   fm-procevent-fleet-requests.sh retire
#
# arm        Check the settings, then register the `fleet-requests` source
#            through `bin/fm-procevent.sh register`. Interval defaults to 60s,
#            limit to 10. A missing or unusable setting exits 2 and registers
#            nothing.
# poll       The blocking child the runner executes; never run it in a
#            conversational turn. It pulls `GET /api/fleet/requests` every
#            interval and exits with a result once the pull brings a request not
#            captured before, or a withdrawal not reported before, or on the
#            first failure. An empty pull advances the `since` cursor and sleeps.
# read       Print the captured result as one JSON document: status, detail,
#            server_time, requests (each with validity, schema errors, the
#            portal's request, and this home's ack outcome), and withdrawn.
# classify   Print requests, withdrawn, error, or unknown.
# terminal   Exit 0 for an error result, which retires the source; a delivery
#            keeps it armed so the runner pulls again.
# autohandle Called by the runner after the result is durably captured. It
#            records each request as captured, then acks it with its lease
#            (`POST /api/fleet/requests/{id}/ack`) so the portal moves it to
#            `pulled` and never hands it out again, and records the ack outcome.
#            It always exits 1: taking the lease is not handling the request,
#            so the wake stays for firstmate.
# validate   Check a JSON document (stdin by default) against one `$defs` entry
#            of the vendored seam schema; print each error and exit 1 on any.
# source-id  Print the canonical source id, `fleet-requests`.
# retire     Stop polling and drop the registration. The captured ledger is
#            kept, so re-arming never re-delivers a request already captured.
#
# Every byte the portal returns is evidence, never instruction: this adapter
# never creates a task, launches a worker, answers a captain decision, or
# merges. A request that fails the schema is still captured, marked invalid.
# Its lease is acked whenever its id and lease_id are uuids, so it is not
# handed out again; one whose identity is unusable is keyed by the SHA-256 of
# its content without the lease fields and is never acked.
#
# Seam: docs/fleet-requests/fleet-requests.v1.schema.json, vendored unchanged
# from relay-platform's docs/seams/ (which owns it and its fleet-requests.md).
# Settings (docs/configuration.md "Fleet request queue"), environment first,
# then this home's gitignored $FM_HOME/.env:
#   FM_FLEET_REQUESTS_TOKEN  the fleet's bearer token; the portal keeps only its
#                            SHA-256 digest in FLEET_REQUESTS_TOKEN_SHA256
#   FM_FLEET_REQUESTS_URL    the portal's origin; FM_TODAY_PORTAL_URL when unset
# The URL must be https://, or http:// only to 127.0.0.1 or localhost. The
# token reaches curl only through a private header file, never argv, and is
# never printed.
#
# Private state lives in $STATE/fleet-requests/: `cursor` holds the last pull's
# server_time and `ledger` records captured keys, ack outcomes, and reported
# withdrawals, one tab-separated line each.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

SOURCE_ID=fleet-requests
ADAPTER=fleet-requests
SCHEMA="$FM_ROOT/docs/fleet-requests/fleet-requests.v1.schema.json"
DEFAULT_INTERVAL=60
DEFAULT_LIMIT=10
PRIV="$STATE/fleet-requests"
LEDGER="$PRIV/ledger"
CURSOR="$PRIV/cursor"
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'fm-procevent-fleet-requests: %s\n' "$1" >&2; exit "${2:-1}"; }

# A subset of JSON Schema 2020-12 - exactly the keywords the seam schema uses -
# evaluated against the vendored file, so the schema stays the one owner of
# every enum, pattern, and bound. Emits one error string per violation.
# shellcheck disable=SC2016
VALIDATOR='
def jtype: if type == "number" then (if . == floor then "integer" else "number" end) else type end;
def type_ok($t): jtype as $j | [($t | if type == "array" then .[] else . end)] | any(. == $j or (. == "number" and $j == "integer"));
def uuid: test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
def check($root; $schema; $p):
  (if ($schema | type) == "object" and ($schema | has("$ref"))
   then $root["$defs"][$schema["$ref"] | ltrimstr("#/$defs/")] else $schema end) as $s
  | . as $x
  | if ($s | has("type")) and ($x | type_ok($s.type) | not) then "\($p): expected \($s.type | tostring)"
    elif ($s | has("const")) and $x != $s.const then "\($p): must be \($s.const | tojson)"
    elif ($s | has("enum")) and ([$s.enum[] | select(. == $x)] | length) == 0 then "\($p): not an allowed value"
    else
      (if ($s | has("oneOf")) then
         ([$s.oneOf[] as $b | [$x | check($root; $b; $p)] | select(length == 0)] | length) as $n
         | if $n != 1 then "\($p): matches \($n) of its allowed shapes, not exactly one" else empty end
       else empty end),
      (if ($x | type) == "string" then
         (if ($s | has("minLength")) and ($x | length) < $s.minLength then "\($p): shorter than \($s.minLength)" else empty end),
         (if ($s | has("maxLength")) and ($x | length) > $s.maxLength then "\($p): longer than \($s.maxLength)" else empty end),
         (if ($s | has("pattern")) and ($x | test($s.pattern) | not) then "\($p): does not match its pattern" else empty end),
         (if $s.format == "uuid" and ($x | uuid | not) then "\($p): not a uuid" else empty end)
       else empty end),
      (if ($x | type) == "number" and ($s | has("minimum")) and $x < $s.minimum then "\($p): below \($s.minimum)" else empty end),
      (if ($x | type) == "array" then
         (if ($s | has("maxItems")) and ($x | length) > $s.maxItems then "\($p): more than \($s.maxItems) items" else empty end),
         (if ($s | has("items")) then range(0; $x | length) as $i | $x[$i] | check($root; $s.items; "\($p)[\($i)]") else empty end)
       else empty end),
      (if ($x | type) == "object" then
         (($s.required // [])[] | select(. as $k | $x | has($k) | not) | "\($p).\(.): required"),
         (($s.properties // {}) | to_entries[] | select(.key as $k | $x | has($k)) | .key as $k | .value as $ps | $x[$k] | check($root; $ps; "\($p).\($k)")),
         (if $s.additionalProperties == false then
            ($x | keys[]) as $k | select(($s.properties // {}) | has($k) | not) | "\($p).\($k): not allowed"
          else empty end)
       else empty end)
    end;
'

# validate_json <definition> <json-file>: print errors, exit 1 on any.
validate_json() {
  local def=$1 file=$2 errors
  errors=$(jq -r --slurpfile root "$SCHEMA" --arg def "$def" \
    "$VALIDATOR"' . as $x | $root[0] as $r | [$x | check($r; $r["$defs"][$def]; "$")] | .[]' "$file" 2>/dev/null) \
    || { printf '$: not JSON\n'; return 1; }
  [ -z "$errors" ] || { printf '%s\n' "$errors"; return 1; }
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
# load_config: set URL and TOKEN, or set CONFIG_ERROR to why not and return 1.
load_config() {
  local missing=''
  CONFIG_ERROR=''
  URL=$(config_value FM_FLEET_REQUESTS_URL)
  [ -n "$URL" ] || URL=$(config_value FM_TODAY_PORTAL_URL)
  TOKEN=$(config_value FM_FLEET_REQUESTS_TOKEN)
  [ -n "$URL" ] || missing="FM_FLEET_REQUESTS_URL (or FM_TODAY_PORTAL_URL)"
  [ -n "$TOKEN" ] || missing="${missing:+$missing and }FM_FLEET_REQUESTS_TOKEN"
  if [ -n "$missing" ]; then
    CONFIG_ERROR="missing $missing; nothing was sent"
    return 1
  fi
  if [[ ! "$URL" =~ ^https://|^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?(/.*)?$ ]]; then
    CONFIG_ERROR="the portal URL must be https://, or http:// only to 127.0.0.1 or localhost; nothing was sent"
    return 1
  fi
  case "$TOKEN" in
    *[[:space:]]*) CONFIG_ERROR="FM_FLEET_REQUESTS_TOKEN must not contain whitespace; nothing was sent"; return 1 ;;
  esac
  URL=${URL%/}
}

TMP_DIR=''
cleanup() { [ -z "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
make_tmp() {
  [ -n "$TMP_DIR" ] || TMP_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-fleet-requests.XXXXXX") \
    || die "cannot create a private temporary directory"
}

# portal <method> <path> <body-out> [<json-body-file>]: print the HTTP status,
# 000 when the portal could not be reached. The bearer header lives only in a
# private file for the length of the call.
portal() {
  local method=$1 path=$2 out=$3 data=${4:-} hdr code
  make_tmp
  hdr="$TMP_DIR/headers"
  (umask 077; printf 'Authorization: Bearer %s\nAccept: application/json\n' "$TOKEN" > "$hdr") || { printf '000\n'; return; }
  if [ -n "$data" ]; then
    printf 'Content-Type: application/json\n' >> "$hdr"
    code=$(curl -sS --max-time 30 -X "$method" -o "$out" -w '%{http_code}' -H @"$hdr" \
      --data-binary @"$data" "$URL$path" 2>/dev/null) || code=000
  else
    code=$(curl -sS --max-time 30 -X "$method" -o "$out" -w '%{http_code}' -H @"$hdr" \
      "$URL$path" 2>/dev/null) || code=000
  fi
  rm -f -- "$hdr"
  case "$code" in [0-9][0-9][0-9]) printf '%s\n' "$code" ;; *) printf '000\n' ;; esac
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

ensure_priv() { (umask 077; mkdir -p "$PRIV") || die "cannot create $PRIV"; }

ledger_append() {  # <kind> <key> <value>
  ensure_priv
  (umask 077; printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$LEDGER")
}

# ledger_last <kind> <key>: the newest value recorded, empty when none.
ledger_last() {
  [ -f "$LEDGER" ] || return 0
  awk -F '\t' -v k="$1" -v key="$2" '$2 == k && $3 == key { v = $4 } END { if (v != "") print v }' "$LEDGER"
}

# ack <id> <lease-id>: take the request's lease and record the outcome.
ack() {
  local id=$1 lease=$2 body code
  make_tmp
  body="$TMP_DIR/ack-body.json"
  jq -nc --arg l "$lease" '{lease_id: $l}' > "$TMP_DIR/ack.json"
  code=$(portal POST "/api/fleet/requests/$id/ack" "$body" "$TMP_DIR/ack.json")
  ledger_append ack "$id" "$code"
}

print_error() {  # <detail>
  printf 'fleet-requests: %s\n' "$SOURCE_ID"
  printf 'status: error\n'
  printf 'detail: %s\n' "$1"
}

positive_int() { case "${1-}" in ''|*[!0-9]*|0) return 1 ;; *) return 0 ;; esac }
positive_number() { [[ "${1-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ ! "$1" =~ ^0+(\.0+)?$ ]]; }

parse_poll_args() {
  INTERVAL=$DEFAULT_INTERVAL
  LIMIT=$DEFAULT_LIMIT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) positive_number "${2-}" || die "--interval needs a positive number" 2; INTERVAL=$2; shift 2 ;;
      --limit) { positive_int "${2-}" && [ "$2" -le 20 ]; } || die "--limit needs a number from 1 to 20" 2; LIMIT=$2; shift 2 ;;
      *) usage ;;
    esac
  done
}

cmd_arm() {
  parse_poll_args "$@"
  [ -f "$SCHEMA" ] || die "the seam schema is missing: $SCHEMA"
  load_config || die "$CONFIG_ERROR" 2
  "$SCRIPT_DIR/fm-procevent.sh" register "$ADAPTER" "$SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-fleet-requests.sh" poll --interval "$INTERVAL" --limit "$LIMIT" || exit 1
  printf 'armed: %s\n' "$SOURCE_ID"
  printf 'portal: %s\n' "$URL"
  printf 'interval: %ss\n' "$INTERVAL"
}

cmd_poll() {
  local why since code body env items rec key id lease validity item n_req n_inv n_wd server_time wid
  parse_poll_args "$@"
  make_tmp
  body="$TMP_DIR/pull.json"
  while :; do
    why=''
    if ! load_config; then print_error "$CONFIG_ERROR"; exit 0; fi
    since=''
    [ ! -f "$CURSOR" ] || since=$(cat "$CURSOR" 2>/dev/null)
    case "$since" in *[!0-9]*) since='' ;; esac
    code=$(portal GET "/api/fleet/requests?limit=$LIMIT${since:+&since=$since}" "$body")
    case "$code" in
      200) ;;
      000) print_error "could not reach the portal at $URL; nothing else was sent"; exit 0 ;;
      401) print_error "the portal refused the fleet token (401); nothing else was sent"; exit 0 ;;
      *) print_error "the portal answered $code to the pull; nothing else was sent"; exit 0 ;;
    esac
    # The envelope is checked with its request items set aside, so one bad
    # request is captured as invalid evidence rather than failing the pull.
    env="$TMP_DIR/envelope.json"
    if ! jq '(.requests |= (if type == "array" then [] else . end))' "$body" > "$env" 2>/dev/null \
      || ! why=$(validate_json PullResponse "$env"); then
      print_error "the pull response does not match seam v1: $(printf '%s' "${why:-not JSON}" | head -n 3 | paste -sd ';' -); nothing else was sent"
      exit 0
    fi
    server_time=$(jq -r '.server_time' "$body")
    items="$TMP_DIR/items"
    : > "$items"
    jq -c '.requests[]' "$body" > "$TMP_DIR/raw-items"
    while IFS= read -r item; do
      printf '%s\n' "$item" > "$TMP_DIR/item.json"
      id=$(jq -r '.id // "" | strings' "$TMP_DIR/item.json")
      lease=$(jq -r '.lease_id // "" | strings' "$TMP_DIR/item.json")
      if [[ "$id" =~ $UUID_RE ]]; then
        key=$id
      else
        jq -cS 'del(.lease_id, .lease_expires_at)' "$TMP_DIR/item.json" > "$TMP_DIR/item-key.json"
        key="sha256:$(sha256_file "$TMP_DIR/item-key.json")"
      fi
      if [ -n "$(ledger_last captured "$key")" ]; then
        # Captured before but handed out again: an earlier ack did not land.
        # The request is already durable evidence, so only the lease is taken.
        if [[ "$id" =~ $UUID_RE ]] && [[ "$lease" =~ $UUID_RE ]] && [ "$(ledger_last ack "$id")" != 200 ]; then
          ack "$id" "$lease"
        fi
        continue
      fi
      if why=$(validate_json LeasedRequest "$TMP_DIR/item.json"); then
        validity=valid
      else
        validity=invalid
      fi
      jq -c --arg key "$key" --arg validity "$validity" --arg errors "${why:-}" \
        '{key: $key, validity: $validity, errors: ($errors | split("\n") | map(select(length > 0))), request: .}' \
        "$TMP_DIR/item.json" >> "$items"
      why=''
    done < "$TMP_DIR/raw-items"
    : > "$TMP_DIR/withdrawn"
    while IFS= read -r rec; do
      wid=$(printf '%s' "$rec" | jq -r '.id')
      [ -n "$(ledger_last withdrawn "$wid")" ] || printf '%s\n' "$rec" >> "$TMP_DIR/withdrawn"
    done < <(jq -c '.withdrawn | unique_by(.id)[]' "$body")
    n_req=$(grep -c . "$items")
    n_wd=$(grep -c . "$TMP_DIR/withdrawn")
    if [ "$n_req" -eq 0 ] && [ "$n_wd" -eq 0 ]; then
      ensure_priv
      (umask 077; printf '%s\n' "$server_time" > "$CURSOR.tmp") && mv -f -- "$CURSOR.tmp" "$CURSOR"
      sleep "$INTERVAL"
      continue
    fi
    n_inv=$(jq -s 'map(select(.validity == "invalid")) | length' "$items")
    printf 'fleet-requests: %s\n' "$SOURCE_ID"
    if [ "$n_req" -gt 0 ]; then printf 'status: requests\n'; else printf 'status: withdrawn\n'; fi
    printf 'server_time: %s\n' "$server_time"
    printf 'requests: %s\n' "$n_req"
    printf 'invalid: %s\n' "$n_inv"
    printf 'withdrawals: %s\n' "$n_wd"
    sed 's/^/request-json: /' "$items"
    sed 's/^/withdrawn-json: /' "$TMP_DIR/withdrawn"
    exit 0
  done
}

result_field() {  # <file> <field>
  awk -v f="$2: " 'index($0, f) == 1 { print substr($0, length(f) + 1); exit }' "$1"
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(result_field "$file" status)
  case "$status" in
    requests|withdrawn|error) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_terminal() {
  [ -n "${1-}" ] || usage
  [ "$(cmd_classify "$1")" = error ]
}

cmd_autohandle() {
  local file=${3-} rec key id lease server_time
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  server_time=$(result_field "$file" server_time)
  while IFS= read -r rec; do
    key=$(printf '%s' "$rec" | jq -r '.key')
    id=$(printf '%s' "$rec" | jq -r '.request.id // "" | strings')
    lease=$(printf '%s' "$rec" | jq -r '.request.lease_id // "" | strings')
    [ -n "$(ledger_last captured "$key")" ] || ledger_append captured "$key" "$(printf '%s' "$rec" | jq -r '.validity')"
    if [[ "$id" =~ $UUID_RE ]] && [[ "$lease" =~ $UUID_RE ]]; then
      [ "$(ledger_last ack "$id")" = 200 ] || { load_config && ack "$id" "$lease"; }
    fi
  done < <(sed -n 's/^request-json: //p' "$file")
  while IFS= read -r rec; do
    id=$(printf '%s' "$rec" | jq -r '.id')
    [ -n "$(ledger_last withdrawn "$id")" ] || ledger_append withdrawn "$id" "$(printf '%s' "$rec" | jq -r '.withdrawn_at')"
  done < <(sed -n 's/^withdrawn-json: //p' "$file")
  case "$server_time" in
    ''|*[!0-9]*) ;;
    *) ensure_priv; (umask 077; printf '%s\n' "$server_time" > "$CURSOR.tmp") && mv -f -- "$CURSOR.tmp" "$CURSOR" ;;
  esac
  # Taking the lease is not handling the request; the wake stays for firstmate.
  exit 1
}

cmd_read() {
  local file=${1-} acks='{}'
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  if [ -f "$LEDGER" ]; then
    acks=$(awk -F '\t' '$2 == "ack" { a[$3] = $4 } END { for (k in a) print k "\t" a[k] }' "$LEDGER" \
      | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries')
  fi
  jq -n --argjson acks "$acks" \
    --arg status "$(result_field "$file" status)" \
    --arg detail "$(result_field "$file" detail)" \
    --arg server_time "$(result_field "$file" server_time)" \
    --rawfile body "$file" '
    def ack_outcome($r):
      ($r.request.id // null) as $id
      | if ($id | type) != "string" or ($r.request.lease_id | type) != "string" then "not sent: no usable id or lease"
        elif $acks[$id] == null then "pending"
        elif $acks[$id] == "200" then "accepted"
        elif $acks[$id] == "000" then "portal unreachable"
        else "refused: " + $acks[$id] end;
    ($body | split("\n")) as $lines
    | {
        status: $status,
        detail: (if $detail == "" then null else $detail end),
        server_time: (if $server_time == "" then null else ($server_time | tonumber) end),
        requests: [$lines[] | select(startswith("request-json: ")) | ltrimstr("request-json: ") | fromjson | . + {ack: ack_outcome(.)}],
        withdrawn: [$lines[] | select(startswith("withdrawn-json: ")) | ltrimstr("withdrawn-json: ") | fromjson]
      }'
}

cmd_validate() {
  local def=${1-} file=${2:-/dev/stdin}
  [ -n "$def" ] || usage
  jq -e --arg d "$def" '.["$defs"] | has($d)' "$SCHEMA" >/dev/null || die "no such definition: $def" 2
  make_tmp
  cat -- "$file" > "$TMP_DIR/doc.json" || die "cannot read $file"
  validate_json "$def" "$TMP_DIR/doc.json"
}

case "${1-}" in
  arm)        shift; cmd_arm "$@" ;;
  poll)       shift; cmd_poll "$@" ;;
  read)       shift; cmd_read "$@" ;;
  classify)   shift; cmd_classify "$@" ;;
  terminal)   shift; cmd_terminal "$@" ;;
  autohandle) shift; cmd_autohandle "$@" ;;
  validate)   shift; cmd_validate "$@" ;;
  source-id)  printf '%s\n' "$SOURCE_ID" ;;
  retire)     "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" 2 ;;
esac
