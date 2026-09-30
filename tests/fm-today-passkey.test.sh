#!/usr/bin/env bash
# Behavior tests for bin/fm-today-passkey.sh: an enrolment opened at the
# machine, registered by a software authenticator (tests/fm-today-soft-authenticator.py)
# as the portal would, checked, and written to the store only on a `yes` typed
# at a real terminal. The confirm runs under a pseudo-terminal the test drives;
# a refused answer, no terminal at all, an expired or reused enrolment, and a
# failed check each leave the store without the key.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PASSKEY="$ROOT/bin/fm-today-passkey.sh"
AUTH=(python3 "$ROOT/tests/fm-today-soft-authenticator.py")
TMP_ROOT=$(fm_test_tmproot fm-today-passkey)

# Run the rest of the command line with a fresh pseudo-terminal as its
# controlling terminal, type <answer> once it asks, and print everything it
# wrote; exit with its status.
TTY_DRIVER="$TMP_ROOT/tty-driver.py"
cat > "$TTY_DRIVER" <<'PY'
import os, pty, select, sys
answer, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
buf, sent = b"", False
while True:
    ready, _, _ = select.select([fd], [], [], 30)
    if not ready:
        break
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    buf += data
    if not sent and b"Type yes" in buf:
        os.write(fd, answer.encode() + b"\n")
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace"))
sys.exit(os.waitstatus_to_exitcode(status))
PY

# Run the rest of the command line in a new session, with no controlling terminal.
NO_TTY="$TMP_ROOT/no-tty.py"
cat > "$NO_TTY" <<'PY'
import subprocess, sys
sys.exit(subprocess.run(sys.argv[1:], start_new_session=True).returncode)
PY

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' "$home"
}

pk() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$PASSKEY" "$@"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# register <home> <key.pem> <out.json> [--flags n]: open an enrolment, and make
# the fm-today-enrolment.v1 document the portal would hand back for it.
register() {
  local home=$1 key=$2 out=$3 cred
  shift 3
  pk "$home" enrol --label "iPhone passkey" >/dev/null || fail "enrol failed"
  pk "$home" blocks > "$home/blocks.json" || fail "blocks failed"
  cred=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["credential_id"])' "$key.cred")
  "${AUTH[@]}" enrol "$key" "$cred" "$home/blocks.json" "$(now_utc)" user_2captain mac-studio "$@" \
    > "$out" || fail "the software authenticator could not register"
}

keygen() {  # <key.pem> [es256|rs256]
  "${AUTH[@]}" keygen "$1" "${2:-es256}" > "$1.cred" || fail "keygen failed"
}

field() {  # <json-file> <python expression over d>
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

test_enrol_opens_a_pinned_enrolment() {
  local home out
  home=$(new_home enrol)
  out=$(pk "$home" enrol --label "iPhone passkey") || fail "enrol exited nonzero"
  assert_contains "$out" "enrol_id: enr_" "enrol prints its enrol_id"
  pk "$home" blocks > "$home/b.json"
  assert_equals "relay-api.mmeg.us" "$(field "$home/b.json" 'd["enrolment"]["rp_id"]')" "rp_id is pinned"
  assert_equals "https://relay-api.mmeg.us" "$(field "$home/b.json" 'd["enrolment"]["origin"]')" "origin is pinned"
  assert_equals 43 "$(field "$home/b.json" 'len(d["enrolment"]["challenge"])')" "the challenge is 32 bytes"
  assert_equals False "$(field "$home/b.json" '"passkeys" in d')" "no passkeys block before any enrolment"
  python3 - "$home/b.json" <<'PY' || fail "the enrolment does not expire within 15 minutes"
import datetime, json, sys
exp = datetime.datetime.fromisoformat(json.load(open(sys.argv[1]))["enrolment"]["expires_at"].replace("Z", "+00:00"))
left = (exp - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
sys.exit(0 if 880 < left <= 900 else 1)
PY
  expect_code 1 "$(pk "$home" enrol --label $'bad\033label' >/dev/null 2>&1; echo $?)" "a label with a control byte"
  pass "enrol opens a 15-minute enrolment pinned to relay-api.mmeg.us"
}

test_confirm_yes_writes_the_key() {
  local home out mode
  home=$(new_home yes)
  keygen "$home/k.pem"
  register "$home" "$home/k.pem" "$home/e.json"
  out=$(pk "$home" check "$home/e.json") || fail "a good enrolment failed its check: $out"
  assert_equals ok "$out" "check prints ok"
  [ ! -e "$home/config/today-passkeys.json" ] || fail "check wrote the store"
  out=$(python3 "$TTY_DRIVER" yes env FM_HOME="$home" "$PASSKEY" confirm "$home/e.json") \
    || fail "confirm with yes failed: $out"
  assert_contains "$out" "label:       iPhone passkey" "the confirm shows the label"
  assert_contains "$out" "device:      mac-studio" "the confirm shows the device"
  assert_contains "$out" "key:         ES256 SHA256:" "the confirm shows the key fingerprint"
  pk "$home" list --json > "$home/l.json"
  assert_equals 1 "$(field "$home/l.json" 'len(d["credentials"])')" "one credential stored"
  assert_equals "$(field "$home/k.pem.cred" 'd["credential_id"]')" \
    "$(field "$home/l.json" 'd["credentials"][0]["credential_id"]')" "the stored credential id"
  assert_equals "active portal -7 relay-api.mmeg.us https://relay-api.mmeg.us iPhone passkey True 0 None" \
    "$(field "$home/l.json" '" ".join(str(d["credentials"][0][k]) for k in ("status","enrolled_via","alg","rp_id","origin","label","backup_eligible","sign_count","revoked_at"))')" \
    "the stored entry"
  openssl pkey -pubin -in <(field "$home/l.json" 'd["credentials"][0]["public_key_pem"]') -outform DER 2>/dev/null \
    | cmp -s - <(openssl pkey -in "$home/k.pem" -pubout -outform DER) \
    || fail "the stored PEM is not the authenticator's public key"
  assert_no_grep "PRIVATE" "$home/config/today-passkeys.json" "the store holds a private key"
  mode=$(stat -f %Lp "$home/config/today-passkeys.json" 2>/dev/null || stat -c %a "$home/config/today-passkeys.json")
  assert_equals 600 "$mode" "the store is private"
  pk "$home" blocks > "$home/b.json"
  assert_equals False "$(field "$home/b.json" '"enrolment" in d')" "the used enrolment leaves the snapshot"
  assert_equals "iPhone passkey" "$(field "$home/b.json" 'd["passkeys"]["credentials"][0]["label"]')" \
    "the snapshot lists the active credential"
  pass "a yes typed at the machine writes the checked public key"
}

test_refused_confirm_writes_nothing() {
  local home out code
  home=$(new_home no)
  keygen "$home/k.pem"
  register "$home" "$home/k.pem" "$home/e.json"
  out=$(python3 "$TTY_DRIVER" y env FM_HOME="$home" "$PASSKEY" confirm "$home/e.json"); code=$?
  expect_code 1 "$code" "confirm answered y"
  assert_contains "$out" "refused at the machine" "the refusal is named"
  [ ! -e "$home/config/today-passkeys.json" ] || fail "a refused confirm wrote the store"
  pk "$home" blocks > "$home/b.json"
  assert_equals False "$(field "$home/b.json" '"enrolment" in d')" "a refused enrolment leaves the snapshot"
  out=$(python3 "$TTY_DRIVER" yes env FM_HOME="$home" "$PASSKEY" confirm "$home/e.json"); code=$?
  expect_code 1 "$code" "confirm of a refused enrolment"
  assert_contains "$out" "already used" "a refused enrolment cannot be confirmed later"
  [ ! -e "$home/config/today-passkeys.json" ] || fail "a reused enrolment wrote the store"
  pass "anything but yes refuses, and the enrolment is used up"
}

test_no_terminal_writes_nothing() {
  local home out code
  home=$(new_home notty)
  keygen "$home/k.pem"
  register "$home" "$home/k.pem" "$home/e.json"
  out=$(printf 'yes\n' | FM_HOME="$home" python3 "$NO_TTY" "$PASSKEY" confirm "$home/e.json"); code=$?
  expect_code 1 "$code" "confirm with yes on stdin and no terminal"
  assert_contains "$out" "no terminal" "the missing terminal is named"
  [ ! -e "$home/config/today-passkeys.json" ] || fail "confirm took its answer from stdin"
  pk "$home" blocks > "$home/b.json"
  assert_equals True "$(field "$home/b.json" '"enrolment" in d')" "the enrolment stays open for the machine"
  pass "with no terminal the answer is never taken from stdin, and nothing is written"
}

test_reused_enrolment_is_refused() {
  local home out code
  home=$(new_home reuse)
  keygen "$home/k.pem"
  keygen "$home/k2.pem"
  register "$home" "$home/k.pem" "$home/e.json"
  python3 "$TTY_DRIVER" yes env FM_HOME="$home" "$PASSKEY" confirm "$home/e.json" >/dev/null \
    || fail "the first confirm failed"
  # The portal hands back a second key for the same, already used enrolment.
  "${AUTH[@]}" enrol "$home/k2.pem" "$(field "$home/k2.pem.cred" 'd["credential_id"]')" "$home/blocks.json" \
    "$(now_utc)" user_2captain mac-studio > "$home/e2.json"
  out=$(pk "$home" check "$home/e2.json"); code=$?
  expect_code 1 "$code" "check of a reused enrolment"
  assert_contains "$out" "already used" "the reuse is named"
  out=$(python3 "$TTY_DRIVER" yes env FM_HOME="$home" "$PASSKEY" confirm "$home/e2.json"); code=$?
  expect_code 1 "$code" "confirm of a reused enrolment"
  assert_not_contains "$out" "Type yes" "a reused enrolment is never offered for confirmation"
  pk "$home" list --json > "$home/l.json"
  assert_equals 1 "$(field "$home/l.json" 'len(d["credentials"])')" "still one credential"
  pass "an enrolment is used once"
}

test_expired_enrolment_is_refused() {
  local home out code
  home=$(new_home expired)
  keygen "$home/k.pem"
  FM_TODAY_ENROL_TTL_SECS=1 register "$home" "$home/k.pem" "$home/e.json"
  sleep 2
  out=$(pk "$home" check "$home/e.json"); code=$?
  expect_code 1 "$code" "check of an expired enrolment"
  assert_contains "$out" "expired" "the expiry is named"
  pk "$home" blocks > "$home/b.json"
  assert_equals False "$(field "$home/b.json" '"enrolment" in d')" "an expired enrolment leaves the snapshot"
  out=$(python3 "$TTY_DRIVER" yes env FM_HOME="$home" "$PASSKEY" confirm "$home/e.json"); code=$?
  expect_code 1 "$code" "confirm of an expired enrolment"
  [ ! -e "$home/config/today-passkeys.json" ] || fail "an expired enrolment wrote the store"
  pass "an expired enrolment is refused"
}

test_failed_checks_are_refused() {
  local home out code
  home=$(new_home checks)
  keygen "$home/k.pem"
  keygen "$home/other.pem"
  register "$home" "$home/k.pem" "$home/uv.json" --flags 0x01
  out=$(pk "$home" check "$home/uv.json"); code=$?
  expect_code 1 "$code" "check without user verification"
  assert_contains "$out" "flags" "the missing user verification is named"

  register "$home" "$home/k.pem" "$home/e.json"
  python3 - "$home/e.json" "$(field "$home/other.pem.cred" 'd["public_key_spki"]')" > "$home/swap.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["public_key_spki"] = sys.argv[2]; print(json.dumps(d))
PY
  out=$(pk "$home" check "$home/swap.json"); code=$?
  expect_code 1 "$code" "check of a key other than the attested one"
  assert_contains "$out" "differs from the attested key" "the key mismatch is named"

  python3 - "$home/e.json" > "$home/origin.json" <<'PY'
import base64, json, sys
d = json.load(open(sys.argv[1]))
c = json.loads(base64.urlsafe_b64decode(d["client_data_json"] + "=="))
c["origin"] = "https://learn.mmeg.us"
d["client_data_json"] = base64.urlsafe_b64encode(json.dumps(c).encode()).decode().rstrip("=")
print(json.dumps(d))
PY
  out=$(pk "$home" check "$home/origin.json"); code=$?
  expect_code 1 "$code" "check of another origin"
  assert_contains "$out" "origin" "the origin is named"

  cp "$home/e.json" "$home/stale.json"
  pk "$home" enrol --label "iPhone passkey" >/dev/null
  out=$(pk "$home" check "$home/stale.json"); code=$?
  expect_code 1 "$code" "check of a superseded enrolment"
  assert_contains "$out" "no such enrolment" "the superseded enrolment is named"
  out=$(python3 "$TTY_DRIVER" yes env FM_HOME="$home" "$PASSKEY" confirm "$home/swap.json"); code=$?
  expect_code 1 "$code" "confirm of a failed check"
  assert_not_contains "$out" "Type yes" "a failed check is never offered for confirmation"
  [ ! -e "$home/config/today-passkeys.json" ] || fail "a failed check wrote the store"
  pass "a failed check is refused before the captain is asked"
}

test_rs256_and_revoke() {
  local home out cred
  home=$(new_home revoke)
  keygen "$home/k.pem" rs256
  register "$home" "$home/k.pem" "$home/e.json"
  out=$(python3 "$TTY_DRIVER" yes env FM_HOME="$home" "$PASSKEY" confirm "$home/e.json") \
    || fail "an RS256 enrolment failed: $out"
  assert_contains "$out" "RS256" "the confirm names the algorithm"
  cred=$(field "$home/k.pem.cred" 'd["credential_id"]')
  out=$(pk "$home" revoke "$cred") || fail "revoke failed"
  pk "$home" list --json > "$home/l.json"
  assert_equals "revoked" "$(field "$home/l.json" 'd["credentials"][0]["status"]')" "revoked status"
  assert_not_equals "None" "$(field "$home/l.json" 'd["credentials"][0]["revoked_at"]')" "revoked_at is set"
  assert_equals 1 "$(field "$home/l.json" 'len(d["credentials"])')" "revoke keeps the entry"
  pk "$home" blocks > "$home/b.json"
  assert_equals False "$(field "$home/b.json" '"passkeys" in d')" "no passkeys block once none is active"
  out=$(pk "$home" list)
  assert_contains "$out" "revoked" "list shows the revoked credential"
  expect_code 1 "$(pk "$home" revoke nosuchcredential >/dev/null 2>&1; echo $?)" "revoke of an unknown credential"
  pass "an RS256 passkey enrols, and revoke marks it without deleting it"
}

test_enrol_opens_a_pinned_enrolment
test_confirm_yes_writes_the_key
test_refused_confirm_writes_nothing
test_no_terminal_writes_nothing
test_reused_enrolment_is_refused
test_expired_enrolment_is_refused
test_failed_checks_are_refused
test_rs256_and_revoke

echo "all fm-today-passkey tests passed"
