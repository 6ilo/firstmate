#!/usr/bin/env bash
# Behavior tests for the Today contract v1 (docs/today-contract.md): every valid
# example of all seven shapes passes its schema and the contract rules, every
# invalid example fails for its stated reason, and card_hash and the passkey challenge recompute from
# the definitions the page publishes, checked against an independent openssl
# digest of the literal canonical bytes. Passkey signatures in the examples
# verify under openssl as well as the reference checker, fresh software
# authenticator keys of both algorithms round-trip, the passkey fields stay
# additive, and when FM_TODAY_PORTAL_DIR names a portal checkout, the portal's
# ajv compiles these schemas and accepts every valid example.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTRACT="$ROOT/docs/today-contract"
CHECK=(python3 "$ROOT/tests/fm-today-contract-check.py")
AUTH=(python3 "$ROOT/tests/fm-today-soft-authenticator.py")
KEYS="$CONTRACT/examples/software-authenticator.keys.json"
SNAPSHOT="$CONTRACT/examples/valid/snapshot.json"
# Every example is checked with the example credentials and the example
# snapshot, so signatures and enrolments are checked in full.
CONTEXT=(--keys "$KEYS" --snapshot "$SNAPSHOT")
TMP_ROOT=$(fm_test_tmproot fm-today-contract)

sha256_hex() { openssl dgst -sha256 -r | cut -d' ' -f1; }
sha256_b64url() { openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='; }

test_valid_examples_pass() {
  local f out n=0
  for f in "$CONTRACT"/examples/valid/*.json; do
    out=$("${CHECK[@]}" check "$CONTRACT" "$f" "${CONTEXT[@]}" 2>&1) \
      || fail "valid example $(basename "$f") was refused: $out"
    n=$((n + 1))
  done
  [ "$n" -ge 8 ] || fail "expected valid examples for all eight schemas, found $n files"
  for schema in snapshot card answer receipt enrolment note dispatch-order note-receipt; do
    compgen -G "$CONTRACT/examples/valid/$schema*.json" >/dev/null \
      || fail "no valid $schema example"
  done
  pass "all $n valid examples pass their schema and the contract rules"
}

# Each invalid example fails for exactly the reason its name states. The reason
# is the keyword the checker names, so a file that fails for an unrelated
# reason (a typo, a second defect) cannot pass this case vacuously.
test_invalid_examples_fail_for_their_reason() {
  local expected f name reason out n=0
  expected=$(cat <<'EOF'
answer--answer-id-trailing-line-feed $.answer_id: pattern
answer--credential-not-seen $.value: enum
answer--later-without-time required: missing later_until
answer--malformed-card-hash $.card_hash: pattern
answer--merge-without-passkey required: missing passkey
answer--note-too-long $.note: maxLength
answer--passkey-authenticator-data-not-base64url $.passkey.authenticator_data: base64url
answer--passkey-cross-origin $.passkey.client_data_json: cross-origin
answer--passkey-on-decision $: not:
answer--passkey-other-origin $.passkey.client_data_json: origin
answer--passkey-other-relying-party $.passkey.authenticator_data: rp_id
answer--passkey-unknown-credential $.passkey.credential_id: credential: not an enrolled credential
answer--passkey-user-not-verified $.passkey.authenticator_data: flags
answer--passkey-wrong-key $.passkey.signature: signature
answer--signed-for-another-value $.passkey.client_data_json: challenge
card--credential-with-options $.options: maxItems
dispatch-order--empty $.items: minItems
dispatch-order--item-twice $.items: task_id: an item appears twice
dispatch-order--owner-qualified $.items[0].owner: pattern
dispatch-order--start-flag additionalProperties: start
card--duplicate-option-value $.options: value: an option value appears twice
card--extra-field additionalProperties: body
card--head-sha-on-decision $: not:
card--later-as-option $.options[1].value: not:
card--merge-without-pr-url required: missing pr_url
card--missing-repo required: missing repo
card--owner-not-hashed $.card_hash: card_hash
card--owner-qualified $.owner: pattern
card--proof-not-hashed $.card_hash: card_hash
card--proof-short-nonce $.proof.nonce: pattern
card--stale-hash $.card_hash: card_hash
card--two-recommended $.options: maxContains
card--unknown-kind $.kind: enum
card--unknown-verdict $.text_check.verdict: enum
enrolment--after-expiry $.enrolled_at: expires_at
enrolment--already-enrolled $.credential_id: credential: already enrolled
enrolment--impossible-day $.enrolled_at: instant: not a real time
enrolment--attestation-nested-too-deep $.attestation_object: attestation: CBOR: nested more than
enrolment--credential-not-attested $.credential_id: credential: differs from the attested
enrolment--key-mismatch $.public_key_spki: key
enrolment--other-challenge $.client_data_json: challenge
enrolment--user-not-verified $.attestation_object: flags
note--authority-granted $.authority: const
note--blank-text $.text: blank
note--control-character $.text: pattern
note--owner-without-task required: missing task_id
note--text-over-2000-bytes $.text: bytes
note-receipt--applied $.outcome: enum
note-receipt--refused-without-reason required: missing reason
receipt--refused-without-reason required: missing reason
receipt--set-aside-without-current-hash required: missing current_card_hash
receipt--unknown-outcome $.outcome: enum
snapshot--board-title $.sections.boards[0]: additionalProperties: title
snapshot--call-listed-twice-for-owner $.sections.calls: task_id: a call appears twice
snapshot--call-stale-hash $.sections.calls[0].card_hash: card_hash
snapshot--day-attendees $.sections.day.blocks[0]: additionalProperties: attendees
snapshot--day-block-ends-before-start $.sections.day.blocks[1]: ends_at: ends before it starts
snapshot--day-block-impossible-date $.sections.day.blocks[0]: instant: not a real time
snapshot--event-wait-without-label $.sections.charted_next[0].waits_on[2]: required: missing label
snapshot--missing-day $.sections: required: missing day
snapshot--passkeys-credential-twice $.passkeys.credentials: credential_id: a credential appears twice
snapshot--passkeys-origin-outside-relying-party $.passkeys.origin: origin
snapshot--underway-extra-field $.sections.underway[0]: additionalProperties: body
snapshot--urgency-out-of-range $.sections.charted_next[0].urgency: maximum
snapshot--work-listed-twice $.sections: id: a piece of work appears twice
snapshot--work-listed-twice-for-owner $.sections: id: a piece of work appears twice
EOF
)
  for f in "$CONTRACT"/examples/invalid/*.json; do
    name=$(basename "$f" .json)
    reason=$(printf '%s\n' "$expected" | awk -v n="$name" '$1 == n { sub(/^[^ ]+ /, ""); print; exit }')
    [ -n "$reason" ] || fail "invalid example $name has no stated reason in this test"
    if out=$("${CHECK[@]}" check "$CONTRACT" "$f" "${CONTEXT[@]}" 2>&1); then
      fail "invalid example $name was accepted"
    fi
    case "$out" in
      "error: "*) ;;
      *) fail "invalid example $name failed without a contract error: $out" ;;
    esac
    printf '%s\n' "$out" | grep -qF -- "$reason" \
      || fail "invalid example $name failed for another reason: $out (expected: $reason)"
    n=$((n + 1))
  done
  [ "$n" -eq "$(printf '%s\n' "$expected" | wc -l | tr -d ' ')" ] \
    || fail "the stated reasons name a file that is not in examples/invalid"
  pass "all $n invalid examples fail for their stated reason"
}

# card_hash is SHA-256 over the RFC 8785 serialization of the shown fields.
# The literal below is that serialization written out by hand: sorted keys, no
# whitespace, raw UTF-8, the newline escaped, a null repo kept as null, and
# text_check and card_hash left out. openssl digests it independently of the
# checker.
test_card_hash_matches_published_definition() {
  local card canonical want got
  card="$TMP_ROOT/card.json"
  cat > "$card" <<'EOF'
{
  "text_check": {"verdict": "pass", "checker": "fm-today-text-check@1.0.0", "checked_at": "2026-09-28T14:05:00Z"},
  "task_id": "t-1",
  "schema": "fm-today-card.v1",
  "question": "Ship it?\nSay “yes”.",
  "options": [
    {"recommended": true, "value": "yes", "label": "Yes"},
    {"value": "no", "label": "No", "hint": "Hold", "recommended": false}
  ],
  "kind": "decision",
  "title": "Ship",
  "repo": null,
  "due": "2026-10-01",
  "card_hash": "unused"
}
EOF
  canonical='{"due":"2026-10-01","kind":"decision","options":[{"label":"Yes","recommended":true,"value":"yes"},{"hint":"Hold","label":"No","recommended":false,"value":"no"}],"question":"Ship it?\nSay “yes”.","repo":null,"schema":"fm-today-card.v1","task_id":"t-1","title":"Ship"}'
  want=$(printf '%s' "$canonical" | sha256_hex)
  got=$("${CHECK[@]}" hash "$card") || fail "hash refused the fixture card"
  [ "$got" = "$want" ] || fail "card_hash $got does not match the published definition $want"
  # An owner is hashed in its sorted place; a card without one hashes as above.
  jq '. + {owner: "relay-platform"}' "$card" > "$card.owned"
  canonical='{"due":"2026-10-01","kind":"decision","options":[{"label":"Yes","recommended":true,"value":"yes"},{"hint":"Hold","label":"No","recommended":false,"value":"no"}],"owner":"relay-platform","question":"Ship it?\nSay “yes”.","repo":null,"schema":"fm-today-card.v1","task_id":"t-1","title":"Ship"}'
  want=$(printf '%s' "$canonical" | sha256_hex)
  got=$("${CHECK[@]}" hash "$card.owned") || fail "hash refused the owned fixture card"
  [ "$got" = "$want" ] || fail "owned card_hash $got does not match the published definition $want"
  # A merge card's head_sha and proof are hashed in their sorted places.
  jq '.kind = "merge" | . + {pr_url: "https://github.com/o/r/pull/1",
      head_sha: "3f786850e387550fdab836ed7e6dc881de23001b",
      proof: {nonce: "vMM-gkKD5svHq8C6asxpLg", expires_at: "2026-09-29T14:05:00Z"}}' "$card" > "$card.proved"
  canonical='{"due":"2026-10-01","head_sha":"3f786850e387550fdab836ed7e6dc881de23001b","kind":"merge","options":[{"label":"Yes","recommended":true,"value":"yes"},{"hint":"Hold","label":"No","recommended":false,"value":"no"}],"pr_url":"https://github.com/o/r/pull/1","proof":{"expires_at":"2026-09-29T14:05:00Z","nonce":"vMM-gkKD5svHq8C6asxpLg"},"question":"Ship it?\nSay “yes”.","repo":null,"schema":"fm-today-card.v1","task_id":"t-1","title":"Ship"}'
  want=$(printf '%s' "$canonical" | sha256_hex)
  got=$("${CHECK[@]}" hash "$card.proved") || fail "hash refused the proved fixture card"
  [ "$got" = "$want" ] || fail "proved card_hash $got does not match the published definition $want"
  # A go card's subject_sha256 likewise.
  jq '.kind = "go" | . + {subject_sha256: "9f2c5a1e0b7d4c3e8a6f1b2d3c4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60"}' "$card" > "$card.go"
  canonical='{"due":"2026-10-01","kind":"go","options":[{"label":"Yes","recommended":true,"value":"yes"},{"hint":"Hold","label":"No","recommended":false,"value":"no"}],"question":"Ship it?\nSay “yes”.","repo":null,"schema":"fm-today-card.v1","subject_sha256":"9f2c5a1e0b7d4c3e8a6f1b2d3c4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60","task_id":"t-1","title":"Ship"}'
  want=$(printf '%s' "$canonical" | sha256_hex)
  got=$("${CHECK[@]}" hash "$card.go") || fail "hash refused the go fixture card"
  [ "$got" = "$want" ] || fail "go card_hash $got does not match the published definition $want"
  pass "card_hash matches SHA-256 of the hand-written canonical serialization, with and without an owner, head_sha, subject_sha256 and proof"
}

# The card example a call or answer names: same task_id and same owner, an
# absent owner read as (main).
card_example_for() {  # <owner> <task_id>
  local f
  for f in "$CONTRACT"/examples/valid/card-*.json; do
    jq -e --arg o "$1" --arg t "$2" '(.owner // "(main)") == $o and .task_id == $t' "$f" >/dev/null \
      && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

test_example_hashes_recompute() {
  local f stored got card_file task owner n=0
  for f in "$CONTRACT"/examples/valid/card-*.json; do
    stored=$(jq -r .card_hash "$f")
    got=$("${CHECK[@]}" hash "$f") || fail "hash refused $(basename "$f")"
    [ "$got" = "$stored" ] || fail "$(basename "$f") stores card_hash $stored, recomputes to $got"
    n=$((n + 1))
  done
  # Each call in the snapshot is the same card a card example publishes.
  while IFS=$'\t' read -r owner task; do
    card_file=$(card_example_for "$owner" "$task") || fail "snapshot call $owner $task has no card example"
    jq -e --arg o "$owner" --arg t "$task" --slurpfile c "$card_file" \
      '.sections.calls[] | select((.owner // "(main)") == $o and .task_id == $t) | . == $c[0]' \
      "$CONTRACT/examples/valid/snapshot.json" >/dev/null \
      || fail "snapshot call $owner $task differs from $(basename "$card_file")"
  done < <(jq -r '.sections.calls[] | [(.owner // "(main)"), .task_id] | @tsv' "$CONTRACT/examples/valid/snapshot.json")
  # Each answer carries the hash of the card it answers, as shown.
  for f in "$CONTRACT"/examples/valid/answer-*.json; do
    task=$(jq -r .task_id "$f")
    owner=$(jq -r '.owner // "(main)"' "$f")
    card_file=$(card_example_for "$owner" "$task") \
      || fail "$(basename "$f") answers $owner $task, which has no card example"
    [ "$(jq -r .card_hash "$f")" = "$(jq -r .card_hash "$card_file")" ] \
      || fail "$(basename "$f") carries a card_hash other than $(basename "$card_file")'s"
    [ "$(jq -r .kind "$f")" = "$(jq -r .kind "$card_file")" ] \
      || fail "$(basename "$f") carries a kind other than $(basename "$card_file")'s"
  done
  pass "all $n example card hashes recompute, and snapshot calls and answers carry them"
}

# The passkey challenge is SHA-256 over the LF-joined answer fields, and the
# WebAuthn clientDataJSON carries it base64url without padding.
test_passkey_challenge_matches_published_definition() {
  local f want got client
  for f in "$CONTRACT"/examples/valid/answer-merge.json "$CONTRACT"/examples/valid/answer-go-later.json; do
    want=$(printf 'fm-today-passkey.v1\n%s\n%s\n%s\n%s\n%s\n%s' \
      "$(jq -r .answer_id "$f")" "$(jq -r .task_id "$f")" "$(jq -r .kind "$f")" \
      "$(jq -r .card_hash "$f")" "$(jq -r .value "$f")" "$(jq -r '.later_until // ""' "$f")" \
      | sha256_b64url)
    got=$("${CHECK[@]}" challenge "$f") || fail "challenge refused $(basename "$f")"
    [ "$got" = "$want" ] || fail "$(basename "$f") challenge $got does not match the published definition $want"
    client=$(jq -r .passkey.client_data_json "$f" | tr '_-' '/+')
    while [ $(( ${#client} % 4 )) -ne 0 ]; do client="$client="; done
    [ "$(printf '%s' "$client" | openssl base64 -d -A | jq -r .challenge)" = "$want" ] \
      || fail "$(basename "$f") clientDataJSON does not carry the derived challenge"
  done
  pass "the passkey challenge matches the published derivation and the example clientDataJSON"
}

b64url_to_bin() { local t; t=$(printf '%s' "$1" | tr '_-' '/+'); while [ $(( ${#t} % 4 )) -ne 0 ]; do t="$t="; done; printf '%s' "$t" | openssl base64 -d -A; }

# openssl, independently of the reference checker's own ECDSA and RSA code,
# verifies every signed example over authenticator_data followed by the
# SHA-256 of client_data_json, with the example credential it names.
test_example_signatures_verify_under_openssl() {
  local f cred spki n=0 dir=$TMP_ROOT/openssl
  mkdir -p "$dir"
  for f in "$CONTRACT"/examples/valid/answer-*.json; do
    jq -e 'has("passkey")' "$f" >/dev/null || continue
    cred=$(jq -r .passkey.credential_id "$f")
    spki=$(jq -r --arg c "$cred" '.credentials[] | select(.credential_id == $c) | .public_key_spki' "$KEYS")
    [ -n "$spki" ] || fail "$(basename "$f") is signed by a credential the example keys do not hold"
    b64url_to_bin "$spki" | openssl pkey -pubin -inform DER -out "$dir/key.pem" 2>/dev/null \
      || fail "the example key for $(basename "$f") is not a public key openssl reads"
    { b64url_to_bin "$(jq -r .passkey.authenticator_data "$f")"
      b64url_to_bin "$(jq -r .passkey.client_data_json "$f")" | openssl dgst -sha256 -binary; } > "$dir/signed"
    b64url_to_bin "$(jq -r .passkey.signature "$f")" > "$dir/sig"
    openssl dgst -sha256 -verify "$dir/key.pem" -signature "$dir/sig" "$dir/signed" >/dev/null \
      || fail "openssl does not verify the signature on $(basename "$f")"
    n=$((n + 1))
  done
  [ "$n" -ge 2 ] || fail "expected signed merge and go examples, found $n"
  [ "$(jq -c '[.credentials[].alg] | unique' "$KEYS")" = '[-257,-7]' ] \
    || fail "the example credentials do not cover both ES256 and RS256"
  [ "$(jq -c '[.passkeys.credentials[].credential_id]' "$SNAPSHOT")" = "$(jq -c '[.credentials[].credential_id]' "$KEYS")" ] \
    || fail "the example snapshot's passkeys differ from the example credentials"
  pass "openssl verifies all $n signed examples, and the snapshot lists the example credentials"
}

# Fresh software-authenticator keys of both algorithms: a signed answer and an
# enrolment pass, a signature by another key under the same credential id and
# an answer changed after signing fail.
test_fresh_keys_round_trip() {
  local dir=$TMP_ROOT/fresh alg cred out
  mkdir -p "$dir"
  "${AUTH[@]}" keygen "$dir/other.pem" es256 > "$dir/other.json" || fail "keygen failed"
  for alg in es256 rs256; do
    "${AUTH[@]}" keygen "$dir/$alg.pem" "$alg" > "$dir/$alg.json" || fail "keygen $alg failed"
    cred=$(jq -r .credential_id "$dir/$alg.json")
    jq -n --slurpfile c "$dir/$alg.json" '{rp_id: "portal.example.org", origin: "https://portal.example.org", credentials: $c}' > "$dir/keys.json"
    "${AUTH[@]}" assert "$dir/$alg.pem" "$cred" portal.example.org https://portal.example.org \
      "$CONTRACT/examples/valid/answer-merge.json" > "$dir/answer.json" || fail "assert $alg failed"
    out=$("${CHECK[@]}" check "$CONTRACT" "$dir/answer.json" --keys "$dir/keys.json" 2>&1) \
      || fail "a fresh $alg assertion was refused: $out"
    "${AUTH[@]}" assert "$dir/other.pem" "$cred" portal.example.org https://portal.example.org \
      "$CONTRACT/examples/valid/answer-merge.json" > "$dir/forged.json" || fail "assert by another key failed"
    out=$("${CHECK[@]}" check "$CONTRACT" "$dir/forged.json" --keys "$dir/keys.json" 2>&1) \
      && fail "a $alg credential accepted another key's signature"
    printf '%s\n' "$out" | grep -qF '$.passkey.signature: signature' || fail "another key's signature failed for another reason: $out"
    jq '.note = "The note is not signed."' "$dir/answer.json" > "$dir/noted.json"
    "${CHECK[@]}" check "$CONTRACT" "$dir/noted.json" --keys "$dir/keys.json" >/dev/null \
      || fail "a note added after signing broke a $alg assertion, but the note is not signed"
    # Character 46 lies in the signature counter, so the flags stay valid.
    jq '.passkey.authenticator_data |= (.[:46] + (if .[46:47] == "A" then "B" else "A" end) + .[47:])' "$dir/answer.json" > "$dir/tampered.json"
    out=$("${CHECK[@]}" check "$CONTRACT" "$dir/tampered.json" --keys "$dir/keys.json" 2>&1) \
      && fail "a $alg assertion with a changed signature counter was accepted"
    printf '%s\n' "$out" | grep -qF '$.passkey.signature: signature' || fail "a changed counter failed for another reason: $out"
    "${AUTH[@]}" enrol "$dir/$alg.pem" "$cred" "$SNAPSHOT" 2026-09-28T14:12:40Z user_2captain mac-studio \
      > "$dir/enrolment.json" || fail "enrol $alg failed"
    out=$("${CHECK[@]}" check "$CONTRACT" "$dir/enrolment.json" --snapshot "$SNAPSHOT" 2>&1) \
      || fail "a fresh $alg enrolment was refused: $out"
  done
  pass "fresh ES256 and RS256 keys sign answers and enrolments the checker accepts, and forged or changed ones fail"
}

# The passkey fields are optional: every valid card without them, rehashed,
# and the snapshot without passkeys and enrolment still pass, so a document
# valid before they existed stays valid.
test_passkey_fields_are_additive() {
  local f bare=$TMP_ROOT/bare.json out n=0
  for f in "$CONTRACT"/examples/valid/card-*.json; do
    jq 'del(.head_sha, .subject_sha256, .proof)' "$f" > "$bare"
    jq --arg h "$("${CHECK[@]}" hash "$bare")" '.card_hash = $h' "$bare" > "$bare.hashed"
    out=$("${CHECK[@]}" check "$CONTRACT" "$bare.hashed" 2>&1) \
      || fail "$(basename "$f") without its passkey fields was refused: $out"
    n=$((n + 1))
  done
  jq 'del(.passkeys, .enrolment)' "$SNAPSHOT" > "$bare"
  jq '.sections.calls |= map(del(.head_sha, .subject_sha256, .proof))' "$bare" > "$bare.cards"
  while IFS= read -r i; do
    jq --argjson i "$i" '.sections.calls[$i]' "$bare.cards" > "$bare.card"
    jq --argjson i "$i" --arg h "$("${CHECK[@]}" hash "$bare.card")" '.sections.calls[$i].card_hash = $h' "$bare.cards" > "$bare.next"
    mv "$bare.next" "$bare.cards"
  done < <(jq -r '.sections.calls | keys[]' "$bare.cards")
  out=$("${CHECK[@]}" check "$CONTRACT" "$bare.cards" 2>&1) \
    || fail "the snapshot without its passkey fields was refused: $out"
  pass "all $n cards and the snapshot stay valid without the passkey fields"
}

# The portal compiles its snapshot validator from the card and snapshot
# schemas alone, so the snapshot schema may reference no other file.
test_snapshot_needs_only_the_card_schema() {
  local dir=$TMP_ROOT/card-and-snapshot out
  mkdir -p "$dir"
  cp "$CONTRACT/fm-today-card.v1.schema.json" "$CONTRACT/fm-today-snapshot.v1.schema.json" "$dir/"
  out=$("${CHECK[@]}" check "$dir" "$SNAPSHOT" 2>&1) \
    || fail "the example snapshot does not validate with only the card and snapshot schemas: $out"
  pass "the snapshot schema resolves with only the card schema beside it"
}

# When FM_TODAY_PORTAL_DIR names a relay-platform checkout with its
# dependencies installed, the portal's own ajv, with the options the portal's
# validator uses, compiles every schema here without a warning and accepts
# every valid example. Unset, the
# reference checker above is the check and this case skips. The byte-identity
# of the portal's vendored copies is checked by tests/fm-today-bridge.test.sh.
test_portal_ajv_accepts_the_examples() {
  local out
  if [ -z "${FM_TODAY_PORTAL_DIR:-}" ]; then
    echo "skip - portal ajv cross-check: FM_TODAY_PORTAL_DIR is not set"
    return 0
  fi
  [ -d "$FM_TODAY_PORTAL_DIR/node_modules/ajv" ] \
    || fail "no ajv under $FM_TODAY_PORTAL_DIR/node_modules: install the portal's dependencies"
  command -v node >/dev/null 2>&1 || fail "node is required for the portal ajv cross-check"
  out=$(node - "$FM_TODAY_PORTAL_DIR" "$CONTRACT" 2>&1 <<'JS'
const [portal, dir] = process.argv.slice(2);
const Ajv2020 = require(portal + "/node_modules/ajv/dist/2020").default;
const fs = require("fs");
const read = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
const ajv = new Ajv2020({ allErrors: false });
for (const f of fs.readdirSync(dir).filter((f) => f.endsWith(".schema.json"))) ajv.addSchema(read(dir + "/" + f));
let bad = 0;
for (const f of fs.readdirSync(dir + "/examples/valid")) {
  const doc = read(dir + "/examples/valid/" + f);
  const check = ajv.getSchema(doc.schema + ".schema.json") || ajv.getSchema("https://github.com/6ilo/firstmate/docs/today-contract/" + doc.schema + ".schema.json");
  if (!check) { console.log(f + ": no schema " + doc.schema); bad++; continue; }
  if (!check(doc)) { console.log(f + ": " + JSON.stringify(check.errors.map((e) => [e.instancePath, e.keyword]))); bad++; }
}
process.exit(bad ? 1 : 0);
JS
) || fail "the portal's ajv refused a valid example: $out"
  [ -z "$out" ] || fail "the portal's ajv warned on these schemas: $out"
  pass "the portal's ajv compiles every schema and accepts every valid example"
}

test_valid_examples_pass
test_invalid_examples_fail_for_their_reason
test_card_hash_matches_published_definition
test_example_hashes_recompute
test_passkey_challenge_matches_published_definition
test_example_signatures_verify_under_openssl
test_fresh_keys_round_trip
test_passkey_fields_are_additive
test_snapshot_needs_only_the_card_schema
test_portal_ajv_accepts_the_examples

echo "all fm-today-contract tests passed"
