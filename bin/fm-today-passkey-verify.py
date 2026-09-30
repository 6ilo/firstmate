#!/usr/bin/env python3
"""fm-today-passkey-verify.py - check the captain's passkey on a Today answer.

A merge word or a go to build from the Today portal carries a WebAuthn
assertion (docs/today-contract.md "The passkey").
This verifier decides whether one such answer may be taken for the call as it
stands now; it releases nothing itself.
The caller acts on the verdict: a `verified` answer is the captain's signed
word for that call, and anything else is sent back as the receipt it names.

Usage:
  fm-today-passkey-verify.py verify <answer.json> <card.json>
                                    [--store <today-passkeys.json>]
                                    [--ledger <dir>]
      <answer.json> is the fm-today-answer.v1 document as the portal sent it.
      <card.json> is the call's current fm-today-card.v1 card, as firstmate
      would show it now; pass it only while the call is open.
      Prints one JSON object and exits 0 for `verified`, 1 for any other
      verdict, and 2 when nothing could be decided (a bad argument, an
      unreadable or malformed store or card, a missing openssl, an
      unwritable ledger); exit 2 records nothing, except that once an answer's
      nonce is recorded it is verified and a resend is its duplicate.

Verdict object:
  {"verdict": "verified" | "refused" | "set-aside" | "duplicate",
   "answer_id", "reason" (refused only), "current_card_hash" (set-aside only),
   "first_verdict" (duplicate only: the verdict this answer_id first got),
   "credential": {"credential_id", "label"} (verified only),
   "sign_count" (verified only)}

Checks, in order; the first failure decides (design: "How firstmate verifies"):
  1. The answer passes fm-today-answer.v1 and its kind is merge or go;
     otherwise refused, reason "answer: ...".
  2. answer_id was never decided before; otherwise duplicate.
  3. The answer's card_hash is the current card's; otherwise set-aside with
     current_card_hash.
     The answer's task_id, owner and kind are the card's, and its value is an
     option the card offers or `later`; otherwise refused, reason "answer: ...".
     The card carries proof, and head_sha on a merge or subject_sha256 on a go;
     otherwise refused "passkey: card carries no proof".
  4. credential_id is an active store entry; otherwise
     "passkey: unknown credential".
  5. client_data_json is a JSON object of type webauthn.get, with neither a
     true crossOrigin nor a topOrigin ("passkey: client data"), the derived
     challenge ("passkey: challenge"), and the entry's origin exactly
     ("passkey: origin").
  6. authenticator_data starts with SHA-256 of the entry's rp_id
     ("passkey: relying party"), has user-present and user-verified set
     ("passkey: user not verified"), and when the stored signature counter is
     above zero, carries a greater one ("passkey: sign count").
  7. The signature verifies with the entry's key under its algorithm, checked
     by the openssl CLI ("passkey: signature did not verify").
  8. No answer was verified before under the card's proof.nonce; otherwise
     "passkey: proof already used".
  A refusal reason is the contract's stable prefix, optionally followed by
  "; " and detail.

State:
  The store (default $FM_HOME/config/today-passkeys.json) is read only.
  It is a JSON object whose `credentials` array holds the enrolled entries
  (a bare array of entries is read the same way); an entry carries at least
  credential_id, public_key_pem (SPKI), alg (-7 ES256 or -257 RS256), rp_id,
  origin, label, sign_count, and status (`active` or `revoked`).
  The ledger directory (default $FM_HOME/data/today-passkey-ledger) is private
  and permanent:
    answers.jsonl      every answer_id decided, with its verdict; the
                       duplicate check reads it.
    nonces.jsonl       every proof.nonce a verified answer used, so one nonce
                       carries at most one verified answer.
    sign-counts.json   the highest signature counter verified per credential;
                       the stored counter is the greater of this and the
                       store entry's sign_count.
  One run holds the ledger's lock from the duplicate check to the last write,
  so two answers under one nonce can never both be verified.
"""
import base64
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCHEMA_DIR = os.path.join(ROOT, "docs", "today-contract")
# The contract's reference checker owns the schema check, card_hash, and the
# challenge derivation; the verifier reuses it rather than restating them.
_spec = importlib.util.spec_from_file_location(
    "fm_today_contract_check", os.path.join(ROOT, "tests", "fm-today-contract-check.py"))
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)

SIGNED_KINDS = ("merge", "go")
PROOF_FIELD = {"merge": "head_sha", "go": "subject_sha256"}


class Undecidable(Exception):
    """Nothing can be decided; the run exits 2 and records nothing."""


class Refused(Exception):
    def __init__(self, reason):
        Exception.__init__(self, reason)
        self.reason = reason


class SetAside(Exception):
    def __init__(self, current_card_hash):
        Exception.__init__(self, current_card_hash)
        self.current_card_hash = current_card_hash


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as err:
        raise Undecidable("%s %s is unreadable: %s" % (what, path, err))


def store_entries(path):
    store = load_json(path, "the passkey store")
    entries = store.get("credentials") if isinstance(store, dict) else store
    if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
        raise Undecidable("the passkey store %s holds no credentials list" % path)
    for entry in entries:
        if entry.get("status") != "active":
            continue
        fields = {"credential_id": str, "public_key_pem": str, "rp_id": str, "origin": str}
        if (any(not isinstance(entry.get(f), t) for f, t in fields.items())
                or entry.get("alg") not in (check.ES256, check.RS256)
                or not isinstance(entry.get("sign_count", 0), int)
                or isinstance(entry.get("sign_count", 0), bool)):
            raise Undecidable("the passkey store %s has a malformed active entry %s"
                              % (path, entry.get("credential_id")))
    return entries


class Ledger:
    def __init__(self, directory):
        self.dir = directory
        try:
            os.makedirs(directory, mode=0o700, exist_ok=True)
            self.lock = os.fdopen(os.open(os.path.join(directory, ".lock"),
                                          os.O_WRONLY | os.O_CREAT, 0o600), "w")
        except OSError as err:
            raise Undecidable("the ledger %s is unusable: %s" % (directory, err))
        fcntl.flock(self.lock, fcntl.LOCK_EX)

    def path(self, name):
        return os.path.join(self.dir, name)

    def rows(self, name):
        try:
            with open(self.path(name), encoding="utf-8") as fh:
                return [json.loads(line) for line in fh if line.strip()]
        except FileNotFoundError:
            return []
        except (OSError, ValueError) as err:
            raise Undecidable("the ledger file %s is unreadable: %s" % (self.path(name), err))

    def append(self, name, row):
        try:
            fd = os.open(self.path(name), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(row, sort_keys=True) + "\n")
                fh.flush()
                os.fsync(fh.fileno())
        except OSError as err:
            raise Undecidable("the ledger file %s is unwritable: %s" % (self.path(name), err))

    def counts(self):
        try:
            with open(self.path("sign-counts.json"), encoding="utf-8") as fh:
                return json.load(fh)
        except FileNotFoundError:
            return {}
        except (OSError, ValueError) as err:
            raise Undecidable("the sign-count ledger is unreadable: %s" % err)

    def write_counts(self, counts):
        try:
            fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".sign-counts.")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(counts, fh, sort_keys=True)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, self.path("sign-counts.json"))
        except OSError as err:
            raise Undecidable("the sign-count ledger is unwritable: %s" % err)


def openssl_verify(public_key_pem, message, signature):
    """True when openssl accepts signature over message with SHA-256 and the key."""
    with tempfile.TemporaryDirectory(prefix="fm-passkey-") as tmp:
        files = {"key.pem": public_key_pem.encode("ascii"), "data": message, "sig": signature}
        for name, raw in files.items():
            with open(os.path.join(tmp, name), "wb") as fh:
                fh.write(raw)
        try:
            run = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", os.path.join(tmp, "key.pem"),
                 "-signature", os.path.join(tmp, "sig"), os.path.join(tmp, "data")],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as err:
            raise Undecidable("openssl could not run: %s" % err)
    return run.returncode == 0 and b"Verified OK" in run.stdout


def key_kind(public_key_pem):
    """"EC" for a P-256 key or "RSA", read from the PEM's SubjectPublicKeyInfo."""
    lines = public_key_pem.strip().splitlines()
    if len(lines) < 3 or lines[0] != "-----BEGIN PUBLIC KEY-----" or lines[-1] != "-----END PUBLIC KEY-----":
        raise ValueError("not a PEM public key")
    return check.spki_key(base64.b64decode("".join(lines[1:-1]), validate=True))[0]


def check_card(answer, card):
    """Step 3: the answer answers this card, as it stands."""
    if card["card_hash"] != answer["card_hash"]:
        raise SetAside(card["card_hash"])
    for field in ("task_id", "owner", "kind"):
        if answer.get(field) != card.get(field):
            raise Refused("answer: %s is not the card's" % field)
    offered = [o["value"] for o in card["options"]] + ["later"]
    if answer["value"] not in offered:
        raise Refused("answer: the card did not offer %s" % answer["value"])
    if "proof" not in card or PROOF_FIELD[card["kind"]] not in card:
        raise Refused("passkey: card carries no proof")


def check_assertion(answer, entry, stored_count):
    """Steps 5 to 7. Returns the assertion's signature counter."""
    passkey = answer["passkey"]
    try:
        raw = {f: check.b64url_decode(passkey[f])
               for f in ("authenticator_data", "client_data_json", "signature")}
    except ValueError:
        raise Refused("passkey: client data; not base64url")
    try:
        client = json.loads(raw["client_data_json"])
    except ValueError:
        raise Refused("passkey: client data; not JSON")
    if not isinstance(client, dict) or client.get("type") != "webauthn.get":
        raise Refused("passkey: client data; not webauthn.get")
    if client.get("crossOrigin", False) is not False or "topOrigin" in client:
        raise Refused("passkey: client data; ran inside another origin")
    if client.get("challenge") != check.b64url(check.passkey_challenge(answer)):
        raise Refused("passkey: challenge")
    if client.get("origin") != entry["origin"]:
        raise Refused("passkey: origin")
    auth = raw["authenticator_data"]
    if len(auth) < 37 or auth[:32] != hashlib.sha256(entry["rp_id"].encode("utf-8")).digest():
        raise Refused("passkey: relying party")
    need = check.FLAG_UP | check.FLAG_UV
    if auth[32] & need != need:
        raise Refused("passkey: user not verified")
    count = int.from_bytes(auth[33:37], "big")
    if stored_count > 0 and count <= stored_count:
        raise Refused("passkey: sign count; %d is not above %d" % (count, stored_count))
    signed = auth + hashlib.sha256(raw["client_data_json"]).digest()
    want = {check.ES256: "EC", check.RS256: "RSA"}[entry["alg"]]
    try:
        kind = key_kind(entry["public_key_pem"])
    except ValueError as err:
        raise Refused("passkey: signature did not verify; the enrolled key is unusable (%s)" % err)
    if kind != want:
        raise Refused("passkey: signature did not verify; the enrolled key is not for its algorithm")
    if not openssl_verify(entry["public_key_pem"], signed, raw["signature"]):
        raise Refused("passkey: signature did not verify")
    return count


def verify(answer_path, card_path, store_path, ledger_dir):
    validator = check.Validator(SCHEMA_DIR)
    card = load_json(card_path, "the card")
    if (not isinstance(card, dict) or card.get("schema") != "fm-today-card.v1"
            or validator.errors(card, validator.docs["fm-today-card.v1.schema.json"],
                                "fm-today-card.v1.schema.json", "$")
            or check.contract_errors(card)):
        raise Undecidable("the card %s is not a valid fm-today-card.v1 card" % card_path)
    answer = load_json(answer_path, "the answer")
    entries = store_entries(store_path)

    # 1. Shape and kind.
    errs = ["$: schema: not fm-today-answer.v1"]
    if isinstance(answer, dict) and answer.get("schema") == "fm-today-answer.v1":
        errs = validator.errors(answer, validator.docs["fm-today-answer.v1.schema.json"],
                                "fm-today-answer.v1.schema.json", "$")
    if errs:
        return {"verdict": "refused", "answer_id": answer.get("answer_id") if isinstance(answer, dict) else None,
                "reason": "answer: not a valid answer; %s" % errs[0]}
    if answer["kind"] not in SIGNED_KINDS:
        return {"verdict": "refused", "answer_id": answer["answer_id"],
                "reason": "answer: a %s answer carries no passkey" % answer["kind"]}

    ledger = Ledger(ledger_dir)
    aid = answer["answer_id"]
    # 2. The permanent answer_id ledger.
    for row in ledger.rows("answers.jsonl"):
        if row.get("answer_id") == aid:
            return {"verdict": "duplicate", "answer_id": aid, "first_verdict": row.get("verdict")}
    for row in ledger.rows("nonces.jsonl"):
        if row.get("answer_id") == aid:
            return {"verdict": "duplicate", "answer_id": aid, "first_verdict": "verified"}

    result = {"answer_id": aid}
    counts = ledger.counts()
    try:
        # 3. The call as it stands.
        check_card(answer, card)
        # 4. The credential.
        cid = answer["passkey"]["credential_id"]
        entry = next((e for e in entries if e.get("credential_id") == cid
                      and e.get("status") == "active"), None)
        if entry is None:
            raise Refused("passkey: unknown credential")
        stored = max(entry.get("sign_count", 0), int(counts.get(cid, 0)))
        # 5 to 7. Client data, authenticator data, signature.
        count = check_assertion(answer, entry, stored)
        # 8. One verified answer per nonce.
        nonce = card["proof"]["nonce"]
        if any(r.get("nonce") == nonce for r in ledger.rows("nonces.jsonl")):
            raise Refused("passkey: proof already used")
        ledger.append("nonces.jsonl", {"nonce": nonce, "answer_id": aid, "task_id": card["task_id"],
                                       "owner": card.get("owner"), "at": now()})
        if count > int(counts.get(cid, 0)):
            counts[cid] = count
            ledger.write_counts(counts)
        result.update(verdict="verified", sign_count=count,
                      credential={"credential_id": cid, "label": entry.get("label")})
    except Refused as refusal:
        result.update(verdict="refused", reason=refusal.reason)
    except SetAside as aside:
        result.update(verdict="set-aside", current_card_hash=aside.current_card_hash)
    ledger.append("answers.jsonl", {"answer_id": aid, "verdict": result["verdict"],
                                    "reason": result.get("reason"), "at": now()})
    return result


def main(argv):
    if len(argv) < 4 or argv[1] != "verify" or len(argv) % 2:
        sys.stderr.write(__doc__)
        return 2
    options = dict(zip(argv[4::2], argv[5::2]))
    if set(options) - {"--store", "--ledger"}:
        sys.stderr.write(__doc__)
        return 2
    home = os.environ.get("FM_HOME") or ROOT
    store = options.get("--store", os.path.join(home, "config", "today-passkeys.json"))
    ledger = options.get("--ledger", os.path.join(home, "data", "today-passkey-ledger"))
    try:
        result = verify(argv[2], argv[3], store, ledger)
    except Undecidable as err:
        sys.stderr.write("fm-today-passkey-verify: %s\n" % err)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0 if result["verdict"] == "verified" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
