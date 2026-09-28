#!/usr/bin/env bash
# Behavior tests for the Today contract v1 (docs/today-contract.md): every valid
# example passes its schema and the contract rules, every invalid example fails
# for its stated reason, and card_hash and the passkey challenge recompute from
# the definitions the page publishes, checked against an independent openssl
# digest of the literal canonical bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTRACT="$ROOT/docs/today-contract"
CHECK=(python3 "$ROOT/tests/fm-today-contract-check.py")
TMP_ROOT=$(fm_test_tmproot fm-today-contract)

sha256_hex() { openssl dgst -sha256 -r | cut -d' ' -f1; }
sha256_b64url() { openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='; }

test_valid_examples_pass() {
  local f out n=0
  for f in "$CONTRACT"/examples/valid/*.json; do
    out=$("${CHECK[@]}" check "$CONTRACT" "$f" 2>&1) \
      || fail "valid example $(basename "$f") was refused: $out"
    n=$((n + 1))
  done
  [ "$n" -ge 4 ] || fail "expected valid examples for all four schemas, found $n files"
  for schema in snapshot card answer receipt; do
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
answer--later-without-time required: missing later_until
answer--malformed-card-hash $.card_hash: pattern
answer--merge-without-passkey required: missing passkey
answer--note-too-long $.note: maxLength
answer--passkey-on-decision $: not:
answer--signed-for-another-value $.passkey.client_data_json: challenge
card--duplicate-option-value $.options: value: an option value appears twice
card--extra-field additionalProperties: body
card--later-as-option $.options[1].value: not:
card--merge-without-pr-url required: missing pr_url
card--stale-hash $.card_hash: card_hash
card--two-recommended $.options: maxContains
card--unknown-kind $.kind: enum
card--unknown-verdict $.text_check.verdict: enum
receipt--refused-without-reason required: missing reason
receipt--set-aside-without-current-hash required: missing current_card_hash
receipt--unknown-outcome $.outcome: enum
snapshot--board-title $.sections.boards[0]: additionalProperties: title
snapshot--call-stale-hash $.sections.calls[0].card_hash: card_hash
snapshot--day-attendees $.sections.day.blocks[0]: additionalProperties: attendees
snapshot--day-block-ends-before-start $.sections.day.blocks[1]: start: not before end
snapshot--event-wait-without-label $.sections.charted_next[0].waits_on[2]: required: missing label
snapshot--missing-day $.sections: required: missing day
snapshot--underway-extra-field $.sections.underway[0]: additionalProperties: body
snapshot--urgency-out-of-range $.sections.charted_next[0].urgency: maximum
EOF
)
  for f in "$CONTRACT"/examples/invalid/*.json; do
    name=$(basename "$f" .json)
    reason=$(printf '%s\n' "$expected" | awk -v n="$name" '$1 == n { sub(/^[^ ]+ /, ""); print; exit }')
    [ -n "$reason" ] || fail "invalid example $name has no stated reason in this test"
    if out=$("${CHECK[@]}" check "$CONTRACT" "$f" 2>&1); then
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
# whitespace, raw UTF-8, the newline escaped, and text_check and card_hash left
# out. openssl digests it independently of the checker.
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
  pass "card_hash matches SHA-256 of the hand-written canonical serialization"
}

test_example_hashes_recompute() {
  local f stored got card_file task n=0
  for f in "$CONTRACT"/examples/valid/card-*.json; do
    stored=$(jq -r .card_hash "$f")
    got=$("${CHECK[@]}" hash "$f") || fail "hash refused $(basename "$f")"
    [ "$got" = "$stored" ] || fail "$(basename "$f") stores card_hash $stored, recomputes to $got"
    n=$((n + 1))
  done
  # Each call in the snapshot is the same card a card example publishes.
  while IFS= read -r task; do
    card_file=$(grep -l "\"task_id\": \"$task\"" "$CONTRACT"/examples/valid/card-*.json | head -1)
    [ -n "$card_file" ] || fail "snapshot call $task has no card example"
    jq -e --arg t "$task" --slurpfile c "$card_file" \
      '.sections.calls[] | select(.task_id == $t) | . == $c[0]' \
      "$CONTRACT/examples/valid/snapshot.json" >/dev/null \
      || fail "snapshot call $task differs from $(basename "$card_file")"
  done < <(jq -r '.sections.calls[].task_id' "$CONTRACT/examples/valid/snapshot.json")
  # Each answer carries the hash of the card it answers, as shown.
  for f in "$CONTRACT"/examples/valid/answer-*.json; do
    task=$(jq -r .task_id "$f")
    card_file=$(grep -l "\"task_id\": \"$task\"" "$CONTRACT"/examples/valid/card-*.json | head -1)
    [ -n "$card_file" ] || fail "$(basename "$f") answers $task, which has no card example"
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

test_valid_examples_pass
test_invalid_examples_fail_for_their_reason
test_card_hash_matches_published_definition
test_example_hashes_recompute
test_passkey_challenge_matches_published_definition

echo "all fm-today-contract tests passed"
