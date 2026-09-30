#!/usr/bin/env bash
# fm-today-passkey.sh - the captain's Today passkeys: open an enrolment, confirm
# the passkey the portal hands back at this machine, list, and revoke.
#
# docs/today-contract.md "The passkey" and "The enrolment" own the contract:
# the snapshot's `passkeys` and `enrolment` blocks, the fm-today-enrolment.v1
# document, and the checks firstmate makes on it. The pinned relying party is
# RP ID relay-api.mmeg.us at origin https://relay-api.mmeg.us.
#
# Usage:
#   fm-today-passkey.sh enrol --label <label>
#   fm-today-passkey.sh list [--json]
#   fm-today-passkey.sh revoke <credential-id>
#   fm-today-passkey.sh blocks
#   fm-today-passkey.sh check <enrolment.json>
#   fm-today-passkey.sh confirm <enrolment.json>
#   fm-today-passkey.sh --help
#
# enrol    Open an enrolment: mint an enrol_id, a 32-byte challenge, and a
#          fresh WebAuthn user handle, valid for 15 minutes, and record them
#          with the label in $STATE/today-passkey-enrolment.json. A new
#          enrolment replaces any earlier one, which can then no longer be
#          confirmed. The label is the captain's, typed here; the portal never
#          names the credential. Refused while 16 credentials are active.
# list     Every enrolled credential, active and revoked, with its key
#          fingerprint; --json prints the store's entries as they are.
# revoke   Mark the credential revoked with revoked_at. Entries are never
#          deleted.
# blocks   Print {"passkeys"?, "enrolment"?}, the two optional snapshot
#          members: `passkeys` lists the active credentials and is absent when
#          none is; `enrolment` is the open enrolment and is absent once it is
#          used or expired. The snapshot producer reads them from here.
# check    Check a received fm-today-enrolment.v1 document and print "ok" or
#          one "error: <where>: <why>" line per failure: the schema; that it
#          answers the open enrolment, unexpired and unused, for a credential
#          not already enrolled; and, through the contract's reference checker
#          (tests/fm-today-contract-check.py), webauthn.create with the
#          enrolment's challenge and origin, the RP ID hash with the
#          user-present and user-verified flags, and an attested key equal to
#          public_key_spki under public_key_alg. Changes nothing.
# confirm  Run check, then show the label, the device and time the portal
#          reports, the credential id, and the key fingerprint on this
#          machine's terminal, and write the credential only when the captain
#          types `yes` there. The answer is read from /dev/tty alone, never
#          from stdin, a file, an environment variable, or anything the portal
#          sent; with no terminal nothing is written and the enrolment stays
#          open. Any answer uses the enrolment up, so the snapshot drops it.
#
# Files. The store is $FM_HOME/config/today-passkeys.json (FM_CONFIG_OVERRIDE
# selects the directory), gitignored, holding {"credentials": [...]} with
# credential_id, public_key_pem (SPKI), alg (-7 or -257), rp_id, origin, label,
# enrolled_at, enrolled_via (portal), backup_eligible, sign_count, status
# (active or revoked), and revoked_at. It holds public keys only. Both files are
# replaced atomically, mode 0600, under one lock.
#
# FM_TODAY_ENROL_TTL_SECS shortens the enrolment's lifetime below 900 seconds,
# for tests; it can never lengthen it.
#
# Exit status: 0 on success; 1 when a check fails, the captain refuses, or the
# store cannot be read; 2 on a usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

case "${1:-}" in
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
esac

exec python3 "$SCRIPT_DIR/fm-today-passkey.py" "$CONFIG" "$STATE" "$@"
