#!/usr/bin/env bash
# Behavior tests for bin/fm-today-passkey-verify.py, the verifier for the
# captain's passkey on a Today merge or go answer (docs/today-contract.md
# "The passkey"). Answers are signed by the software authenticator
# (tests/fm-today-soft-authenticator.py) with fresh ES256 and RS256 keys, and
# the contract's own signed examples are checked too. Each refusal case breaks
# exactly one thing and asserts the stable reason prefix it earns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTRACT="$ROOT/docs/today-contract"
VALID="$CONTRACT/examples/valid"
VERIFY=(python3 "$ROOT/bin/fm-today-passkey-verify.py" verify)
CHECK=(python3 "$ROOT/tests/fm-today-contract-check.py")
AUTH=(python3 "$ROOT/tests/fm-today-soft-authenticator.py")
RP=relay-api.mmeg.us
ORIGIN=https://relay-api.mmeg.us
TMP_ROOT=$(fm_test_tmproot fm-today-passkey-verify)
KEYS="$TMP_ROOT/keys"
mkdir -p "$KEYS"

# One store entry, in the shape the enrolment writes, for a credential JSON
# ({credential_id, alg, public_key_spki}) as keygen or the example keys print it.
store_entry() { # <credential.json> <label> [status] [sign_count]
  python3 - "$1" "$2" "${3:-active}" "${4:-0}" <<'PY'
import base64, json, sys, textwrap
cred, label, status, count = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], int(sys.argv[4])
der = base64.urlsafe_b64decode(cred["public_key_spki"] + "=" * (-len(cred["public_key_spki"]) % 4))
pem = "-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n" % "\n".join(
    textwrap.wrap(base64.b64encode(der).decode("ascii"), 64))
print(json.dumps({"credential_id": cred["credential_id"], "public_key_pem": pem, "alg": cred["alg"],
                  "rp_id": "relay-api.mmeg.us", "origin": "https://relay-api.mmeg.us",
                  "label": label, "enrolled_at": "2026-09-28T12:00:00Z", "enrolled_via": "portal",
                  "backup_eligible": True, "sign_count": count, "status": status,
                  "revoked_at": "2026-09-29T12:00:00Z" if status == "revoked" else None}))
PY
}

# A store holding the given entries.
write_store() { # <out> <entry.json>...
  local out=$1
  shift
  jq -s '{credentials: .}' "$@" > "$out"
}

"${AUTH[@]}" keygen "$KEYS/es.pem" es256 > "$KEYS/es.json" || fail "es256 keygen failed"
"${AUTH[@]}" keygen "$KEYS/rs.pem" rs256 > "$KEYS/rs.json" || fail "rs256 keygen failed"
"${AUTH[@]}" keygen "$KEYS/other.pem" es256 > "$KEYS/other.json" || fail "other keygen failed"
"${AUTH[@]}" keygen "$KEYS/gone.pem" es256 > "$KEYS/gone.json" || fail "revoked keygen failed"
store_entry "$KEYS/es.json" "iPhone passkey" > "$KEYS/es.entry"
store_entry "$KEYS/rs.json" "Backup key" > "$KEYS/rs.entry"
store_entry "$KEYS/gone.json" "Old phone" revoked > "$KEYS/gone.entry"
# The contract's example credentials, which signed its valid examples.
jq '.credentials[0]' "$CONTRACT/examples/software-authenticator.keys.json" > "$KEYS/ex-es.json"
jq '.credentials[1]' "$CONTRACT/examples/software-authenticator.keys.json" > "$KEYS/ex-rs.json"
store_entry "$KEYS/ex-es.json" "iPhone passkey" > "$KEYS/ex-es.entry"
store_entry "$KEYS/ex-rs.json" "Backup key" > "$KEYS/ex-rs.entry"
STORE="$TMP_ROOT/today-passkeys.json"
write_store "$STORE" "$KEYS/es.entry" "$KEYS/rs.entry" "$KEYS/gone.entry" "$KEYS/ex-es.entry" "$KEYS/ex-rs.entry"

N=0
# A fresh case directory with its own ledger.
new_case() {
  N=$((N + 1))
  CASE="$TMP_ROOT/case-$N"
  mkdir -p "$CASE"
}

# The example merge card re-raised with a fresh nonce, and its card_hash recomputed.
merge_card() { # <out> [nonce]
  local nonce=${2:-$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(16)).decode().rstrip("="))')}
  jq --arg n "$nonce" '.proof.nonce = $n' "$VALID/card-merge.json" > "$1.tmp"
  jq --arg h "$("${CHECK[@]}" hash "$1.tmp")" '.card_hash = $h' "$1.tmp" > "$1"
  rm -f "$1.tmp"
}

# An answer to <card> signed by <key>'s credential; extra args go to the authenticator.
signed_answer() { # <out> <card> <key> [answer_id] [authenticator options...]
  local out=$1 card=$2 key=$3 aid=${4:-ans_$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(16)).decode().rstrip("="))')}
  shift 4 2>/dev/null || shift $#
  jq --arg id "$aid" --arg h "$(jq -r .card_hash "$card")" \
    'del(.passkey) | .answer_id = $id | .card_hash = $h' "$VALID/answer-merge.json" > "$out.unsigned"
  "${AUTH[@]}" assert "$KEYS/$key.pem" "$(jq -r .credential_id "$KEYS/$key.json")" "$RP" "$ORIGIN" \
    "$out.unsigned" "$@" > "$out" || fail "the authenticator could not sign $out"
}

# Run the verifier on the case's ledger; sets OUT and RC.
run_verify() { # <answer> <card> [store]
  RC=0
  OUT=$("${VERIFY[@]}" "$1" "$2" --store "${3:-$STORE}" --ledger "$CASE/ledger" 2>&1) || RC=$?
}

expect_verdict() { # <verdict> <reason prefix or -> <what>
  local verdict reason
  verdict=$(jq -r .verdict <<< "$OUT" 2>/dev/null) || fail "$3: not a verdict: $OUT"
  [ "$verdict" = "$1" ] || fail "$3: expected $1, got: $OUT"
  if [ "$1" = verified ]; then
    [ "$RC" -eq 0 ] || fail "$3: verified but exit $RC"
  else
    [ "$RC" -eq 1 ] || fail "$3: $1 but exit $RC"
  fi
  if [ "$2" != - ]; then
    reason=$(jq -r .reason <<< "$OUT")
    case "$reason" in
      "$2" | "$2; "*) ;;
      *) fail "$3: expected reason $2, got: $reason" ;;
    esac
  fi
}

test_good_assertions_verify() {
  local key
  for key in es rs; do
    new_case
    merge_card "$CASE/card.json"
    signed_answer "$CASE/answer.json" "$CASE/card.json" "$key"
    run_verify "$CASE/answer.json" "$CASE/card.json"
    expect_verdict verified - "a fresh $key assertion"
    [ "$(jq -r .credential.credential_id <<< "$OUT")" = "$(jq -r .credential_id "$KEYS/$key.json")" ] \
      || fail "the $key verdict names the wrong credential: $OUT"
  done
  # The contract's own signed examples, ES256 on a merge and RS256 on a go.
  new_case
  run_verify "$VALID/answer-merge.json" "$VALID/card-merge.json"
  expect_verdict verified - "the contract's signed merge example"
  run_verify "$VALID/answer-go-later.json" "$VALID/card-go.json"
  expect_verdict verified - "the contract's signed go example"
  pass "good ES256 and RS256 assertions verify, fresh and from the contract's examples"
}

# Each case signs a good answer, breaks one thing, and checks the reason.
test_client_data_refusals() {
  new_case
  merge_card "$CASE/card.json"
  signed_answer "$CASE/a1.json" "$CASE/card.json" es "" --cross-origin
  run_verify "$CASE/a1.json" "$CASE/card.json"
  expect_verdict refused "passkey: client data" "crossOrigin true"

  signed_answer "$CASE/a2.json" "$CASE/card.json" es
  "${AUTH[@]}" assert "$KEYS/es.pem" "$(jq -r .credential_id "$KEYS/es.json")" "$RP" https://evil.example \
    "$CASE/a2.json.unsigned" > "$CASE/a2.json" || fail "could not sign for another origin"
  run_verify "$CASE/a2.json" "$CASE/card.json"
  expect_verdict refused "passkey: origin" "a wrong origin"

  signed_answer "$CASE/a3.json" "$CASE/card.json" es "" --type webauthn.create
  run_verify "$CASE/a3.json" "$CASE/card.json"
  expect_verdict refused "passkey: client data" "a webauthn.create client data"

  # An answer_id changed after signing no longer derives the signed challenge.
  signed_answer "$CASE/a4.json" "$CASE/card.json" es
  jq '.answer_id = "ans_changedAfterSigning00"' "$CASE/a4.json" > "$CASE/a4b.json"
  run_verify "$CASE/a4b.json" "$CASE/card.json"
  expect_verdict refused "passkey: challenge" "a challenge the answer does not derive"
  pass "wrong origin, crossOrigin true, wrong type, and a foreign challenge are refused"
}

test_authenticator_data_refusals() {
  new_case
  merge_card "$CASE/card.json"
  signed_answer "$CASE/a1.json" "$CASE/card.json" es
  "${AUTH[@]}" assert "$KEYS/es.pem" "$(jq -r .credential_id "$KEYS/es.json")" mmeg.us "$ORIGIN" \
    "$CASE/a1.json.unsigned" > "$CASE/a1.json" || fail "could not sign for another relying party"
  run_verify "$CASE/a1.json" "$CASE/card.json"
  expect_verdict refused "passkey: relying party" "a wrong RP ID hash"

  signed_answer "$CASE/a2.json" "$CASE/card.json" es "" --flags 0x01
  run_verify "$CASE/a2.json" "$CASE/card.json"
  expect_verdict refused "passkey: user not verified" "UV unset"

  signed_answer "$CASE/a3.json" "$CASE/card.json" es "" --flags 0x04
  run_verify "$CASE/a3.json" "$CASE/card.json"
  expect_verdict refused "passkey: user not verified" "UP unset"
  pass "a wrong RP ID hash and an unset UV or UP flag are refused"
}

test_signature_and_credential_refusals() {
  new_case
  merge_card "$CASE/card.json"
  # Signed by another key under the enrolled credential's id.
  signed_answer "$CASE/a1.json" "$CASE/card.json" es
  "${AUTH[@]}" assert "$KEYS/other.pem" "$(jq -r .credential_id "$KEYS/es.json")" "$RP" "$ORIGIN" \
    "$CASE/a1.json.unsigned" > "$CASE/a1.json" || fail "could not sign with another key"
  run_verify "$CASE/a1.json" "$CASE/card.json"
  expect_verdict refused "passkey: signature did not verify" "a bad ES256 signature"

  signed_answer "$CASE/a2.json" "$CASE/card.json" rs
  "${AUTH[@]}" assert "$KEYS/other.pem" "$(jq -r .credential_id "$KEYS/rs.json")" "$RP" "$ORIGIN" \
    "$CASE/a2.json.unsigned" > "$CASE/a2.json" || fail "could not sign with another key"
  run_verify "$CASE/a2.json" "$CASE/card.json"
  expect_verdict refused "passkey: signature did not verify" "an ES256 signature on an RS256 credential"

  signed_answer "$CASE/a3.json" "$CASE/card.json" other
  run_verify "$CASE/a3.json" "$CASE/card.json"
  expect_verdict refused "passkey: unknown credential" "an unenrolled credential"

  signed_answer "$CASE/a4.json" "$CASE/card.json" gone
  run_verify "$CASE/a4.json" "$CASE/card.json"
  expect_verdict refused "passkey: unknown credential" "a revoked credential"
  pass "a bad signature and an unknown or revoked credential are refused"
}

test_replay_refusals() {
  new_case
  merge_card "$CASE/card.json"
  signed_answer "$CASE/a1.json" "$CASE/card.json" es
  run_verify "$CASE/a1.json" "$CASE/card.json"
  expect_verdict verified - "the first answer"
  run_verify "$CASE/a1.json" "$CASE/card.json"
  expect_verdict duplicate - "a replayed answer_id"
  [ "$(jq -r .first_verdict <<< "$OUT")" = verified ] || fail "the duplicate does not name the first verdict: $OUT"

  # A second, differently identified answer signed under the same nonce.
  signed_answer "$CASE/a2.json" "$CASE/card.json" rs
  run_verify "$CASE/a2.json" "$CASE/card.json"
  expect_verdict refused "passkey: proof already used" "a reused nonce"

  # A refused answer_id is spent too: resending it is a duplicate.
  run_verify "$CASE/a2.json" "$CASE/card.json"
  expect_verdict duplicate - "a resent refused answer"
  pass "a replayed answer_id is a duplicate and a reused nonce is refused"
}

test_sign_count() {
  new_case
  local store="$CASE/store.json"
  store_entry "$KEYS/es.json" "Counting key" active 5 > "$CASE/counting.entry"
  write_store "$store" "$CASE/counting.entry"
  merge_card "$CASE/c1.json"
  signed_answer "$CASE/a1.json" "$CASE/c1.json" es "" --sign-count 5
  run_verify "$CASE/a1.json" "$CASE/c1.json" "$store"
  expect_verdict refused "passkey: sign count" "a counter equal to the stored one"

  signed_answer "$CASE/a2.json" "$CASE/c1.json" es "" --sign-count 6
  run_verify "$CASE/a2.json" "$CASE/c1.json" "$store"
  expect_verdict verified - "a counter above the stored one"

  # The verified counter becomes the stored one for the next call.
  merge_card "$CASE/c2.json"
  signed_answer "$CASE/a3.json" "$CASE/c2.json" es "" --sign-count 6
  run_verify "$CASE/a3.json" "$CASE/c2.json" "$store"
  expect_verdict refused "passkey: sign count" "a counter that did not increase since the last verified answer"

  # A stored counter of zero skips the check, as synced passkeys report zero.
  signed_answer "$CASE/a4.json" "$CASE/c2.json" rs "" --sign-count 0
  run_verify "$CASE/a4.json" "$CASE/c2.json"
  expect_verdict verified - "a zero counter against a zero stored counter"
  pass "a signature counter that does not increase is refused, and zero skips the check"
}

test_card_refusals() {
  new_case
  merge_card "$CASE/card.json"
  merge_card "$CASE/reraised.json"
  signed_answer "$CASE/a1.json" "$CASE/card.json" es
  run_verify "$CASE/a1.json" "$CASE/reraised.json"
  expect_verdict set-aside - "an answer to an earlier raising"
  [ "$(jq -r .current_card_hash <<< "$OUT")" = "$(jq -r .card_hash "$CASE/reraised.json")" ] \
    || fail "set-aside does not carry the current card_hash: $OUT"

  # A card with no proof: a merge card without head_sha, hash recomputed.
  jq 'del(.head_sha)' "$CASE/card.json" > "$CASE/bare.tmp"
  jq --arg h "$("${CHECK[@]}" hash "$CASE/bare.tmp")" '.card_hash = $h' "$CASE/bare.tmp" > "$CASE/bare.json"
  signed_answer "$CASE/a2.json" "$CASE/bare.json" es
  run_verify "$CASE/a2.json" "$CASE/bare.json"
  expect_verdict refused "passkey: card carries no proof" "a card without head_sha"

  jq '.value = "ship-it"' "$CASE/a1.json" > "$CASE/a3.unsigned"
  "${AUTH[@]}" assert "$KEYS/es.pem" "$(jq -r .credential_id "$KEYS/es.json")" "$RP" "$ORIGIN" \
    <(jq '.answer_id = "ans_notOfferedValue0000"' "$CASE/a3.unsigned") > "$CASE/a3.json" || fail "could not sign"
  run_verify "$CASE/a3.json" "$CASE/card.json"
  expect_verdict refused "answer: the card did not offer ship-it" "a value the card did not offer"

  run_verify "$VALID/answer-decision.json" "$VALID/card-decision.json"
  expect_verdict refused "answer: a decision answer carries no passkey" "an unsigned kind"

  jq 'del(.passkey)' "$CASE/a1.json" > "$CASE/a5.json"
  run_verify "$CASE/a5.json" "$CASE/card.json"
  expect_verdict refused "answer: not a valid answer" "a merge answer without a passkey"
  pass "a stale card is set aside, and no proof, an unoffered value, and a bad shape are refused"
}

test_undecidable_records_nothing() {
  new_case
  merge_card "$CASE/card.json"
  signed_answer "$CASE/a1.json" "$CASE/card.json" es
  run_verify "$CASE/a1.json" "$CASE/card.json" "$CASE/missing-store.json"
  [ "$RC" -eq 2 ] || fail "a missing store did not exit 2: $RC $OUT"
  run_verify "$CASE/a1.json" "$CASE/card.json"
  expect_verdict verified - "the same answer once the store is readable"
  pass "an unreadable store exits 2 and spends neither the answer nor the nonce"
}

test_unwritable_ledger_records_nothing() {
  new_case
  merge_card "$CASE/card.json"
  signed_answer "$CASE/a1.json" "$CASE/card.json" es
  mkdir -p "$CASE/ledger"
  : > "$CASE/ledger/answers.jsonl"
  chmod 400 "$CASE/ledger/answers.jsonl"
  run_verify "$CASE/a1.json" "$CASE/card.json"
  [ "$RC" -eq 2 ] || fail "an unwritable answer ledger did not exit 2: $RC $OUT"
  chmod 600 "$CASE/ledger/answers.jsonl"
  run_verify "$CASE/a1.json" "$CASE/card.json"
  expect_verdict verified - "the resent answer after a failed ledger write"
  pass "a failed ledger write exits 2 and spends neither the answer nor the nonce"
}

test_store_must_be_a_credentials_object() {
  new_case
  merge_card "$CASE/card.json"
  signed_answer "$CASE/a1.json" "$CASE/card.json" es
  jq -s . "$KEYS/es.entry" > "$CASE/bare-store.json"
  run_verify "$CASE/a1.json" "$CASE/card.json" "$CASE/bare-store.json"
  [ "$RC" -eq 2 ] || fail "a bare-array store did not exit 2: $RC $OUT"
  grep -q "passkey: the store" <<< "$OUT" || fail "a bare-array store was not named unreadable: $OUT"
  run_verify "$CASE/a1.json" "$CASE/card.json"
  expect_verdict verified - "the same answer against the credentials object"
  pass "a store that is not a credentials object is unreadable and records nothing"
}

test_good_assertions_verify
test_client_data_refusals
test_authenticator_data_refusals
test_signature_and_credential_refusals
test_replay_refusals
test_sign_count
test_card_refusals
test_undecidable_records_nothing
test_unwritable_ledger_records_nothing
test_store_must_be_a_credentials_object

echo "all fm-today-passkey-verify tests passed"
