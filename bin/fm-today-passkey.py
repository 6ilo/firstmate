#!/usr/bin/env python3
"""The Today passkey store and its enrolment; bin/fm-today-passkey.sh is the entry point.

docs/today-contract.md owns the enrolment contract: the snapshot's `passkeys`
and `enrolment` blocks, the fm-today-enrolment.v1 document, and the checks
firstmate makes on it. The schema and enrolment checks run through the
contract's reference checker (tests/fm-today-contract-check.py), as the
bridge's push does, so they are stated once. Standard library plus the openssl
CLI, which turns the checked key into PEM.
"""
import base64
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACT_DIR = os.path.join(HERE, "..", "docs", "today-contract")
_spec = importlib.util.spec_from_file_location(
    "fm_today_contract_check", os.path.join(HERE, "..", "tests", "fm-today-contract-check.py"))
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)

RP_ID = "relay-api.mmeg.us"
ORIGIN = "https://relay-api.mmeg.us"
ENROL_TTL_SECS = 900
MAX_ACTIVE = 16
FLAG_BE = 0x08
STORE_NAME = "today-passkeys.json"
PENDING_NAME = "today-passkey-enrolment.json"
LOCK_NAME = ".today-passkeys.lock"
ALG_NAMES = {check.ES256: "ES256", check.RS256: "RS256"}


class Refusal(Exception):
    """A request the store refuses; the message is the one line the caller prints."""


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def stamp(when):
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def printable(text):
    """Text from the portal, safe to show on the captain's terminal: no control or escape bytes."""
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", "?", str(text))


def fingerprint(spki_der):
    digest = hashlib.sha256(spki_der).hexdigest()
    return "SHA256:" + " ".join(digest[i:i + 4] for i in range(0, len(digest), 4))


class Home:
    def __init__(self, config_dir, state_dir):
        self.config_dir = config_dir
        self.state_dir = state_dir
        self.store_path = os.path.join(config_dir, STORE_NAME)
        self.pending_path = os.path.join(state_dir, PENDING_NAME)
        self._lock = None

    def __enter__(self):
        os.makedirs(self.config_dir, mode=0o700, exist_ok=True)
        os.makedirs(self.state_dir, mode=0o700, exist_ok=True)
        fd = os.open(os.path.join(self.config_dir, LOCK_NAME), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self._lock = fd
        return self

    def __exit__(self, *exc):
        os.close(self._lock)

    @staticmethod
    def _read(path, what):
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as err:
            raise Refusal("the %s at %s is unreadable (%s); nothing was changed" % (what, path, err))

    @staticmethod
    def _write(path, value):
        """Replace path atomically with a private file holding value."""
        fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", dir=os.path.dirname(path))
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(value, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise

    def credentials(self):
        store = self._read(self.store_path, "passkey store")
        if store is None:
            return []
        if not isinstance(store, dict) or not isinstance(store.get("credentials"), list):
            raise Refusal("the passkey store at %s is not {\"credentials\": [...]}; nothing was changed"
                          % self.store_path)
        return store["credentials"]

    def save_credentials(self, credentials):
        self._write(self.store_path, {"credentials": credentials})

    def pending(self):
        record = self._read(self.pending_path, "enrolment record")
        if record is not None and not isinstance(record, dict):
            raise Refusal("the enrolment record at %s is not an object" % self.pending_path)
        return record

    def save_pending(self, record):
        self._write(self.pending_path, record)


def open_enrolment(record, at):
    """The pending record when it is still waiting for the portal, else None."""
    if not record or record.get("status") != "open":
        return None
    if check.instant(record["expires_at"]) < at:
        return None
    return record


def enrolment_block(record):
    return {k: record[k] for k in ("enrol_id", "challenge", "rp_id", "origin", "user_handle", "expires_at")}


def passkeys_block(credentials):
    active = [c for c in credentials if c.get("status") == "active"]
    if not active:
        return None
    return {"rp_id": RP_ID, "origin": ORIGIN,
            "credentials": [{"credential_id": c["credential_id"], "label": c["label"]}
                            for c in active[:MAX_ACTIVE]]}


def cmd_enrol(home, label):
    if not label or len(label) > 120 or printable(label) != label or label.strip() != label:
        raise Refusal("--label must be 1 to 120 printable characters with no leading or trailing space")
    with home:
        credentials = home.credentials()
        if sum(1 for c in credentials if c.get("status") == "active") >= MAX_ACTIVE:
            raise Refusal("%d credentials are already active; revoke one before enrolling another"
                          % MAX_ACTIVE)
        at = now()
        record = {
            "enrol_id": "enr_" + check.b64url(os.urandom(16)),
            "challenge": check.b64url(os.urandom(32)),
            "rp_id": RP_ID,
            "origin": ORIGIN,
            "user_handle": check.b64url(os.urandom(16)),
            "expires_at": stamp(at + datetime.timedelta(seconds=ENROL_TTL_SECS)),
            "label": label,
            "opened_at": stamp(at),
            "status": "open",
        }
        home.save_pending(record)
    print("enrol_id: %s" % record["enrol_id"])
    print("expires_at: %s" % record["expires_at"])
    print("The next Today snapshot asks for this passkey. Register it on Today before it expires,")
    print("then confirm it here with: bin/fm-today-passkey.sh confirm <enrolment.json>")
    return 0


def cmd_list(home, as_json):
    with home:
        credentials = home.credentials()
    if as_json:
        print(json.dumps({"credentials": credentials}, indent=2, ensure_ascii=False))
        return 0
    if not credentials:
        print("no passkeys enrolled")
        return 0
    for c in credentials:
        spki = base64.b64decode("".join(c["public_key_pem"].strip().splitlines()[1:-1]))
        print("%s  %-7s  %s  %s" % (c["credential_id"], c["status"], c["enrolled_at"], printable(c["label"])))
        print("    %s %s%s" % (ALG_NAMES.get(c["alg"], c["alg"]), fingerprint(spki),
                               "  revoked_at %s" % c["revoked_at"] if c.get("revoked_at") else ""))
    return 0


def cmd_revoke(home, credential_id):
    with home:
        credentials = home.credentials()
        entry = next((c for c in credentials if c.get("credential_id") == credential_id), None)
        if entry is None:
            raise Refusal("no enrolled credential %s" % credential_id)
        if entry.get("status") == "revoked":
            print("%s was already revoked at %s" % (credential_id, entry.get("revoked_at")))
            return 0
        entry["status"] = "revoked"
        entry["revoked_at"] = stamp(now())
        home.save_credentials(credentials)
        active = sum(1 for c in credentials if c.get("status") == "active")
    print("revoked %s (%s)" % (credential_id, printable(entry["label"])))
    if active < 2:
        sys.stderr.write("fm-today-passkey: warning: only %d active credential%s left; enrol another so"
                         " Today keeps a working passkey\n" % (active, "" if active == 1 else "s"))
    return 0


def cmd_blocks(home):
    with home:
        credentials = home.credentials()
        record = open_enrolment(home.pending(), now())
    out = {}
    passkeys = passkeys_block(credentials)
    if passkeys:
        out["passkeys"] = passkeys
    if record:
        out["enrolment"] = enrolment_block(record)
    print(json.dumps(out, indent=2))
    return 0


def load_enrolment(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as err:
        raise Refusal("the enrolment %s is unreadable (%s)" % (path, err))


def enrolment_errors(home, enrolment, at):
    """Every reason firstmate refuses this enrolment now; empty when it may be confirmed."""
    validator = check.Validator(CONTRACT_DIR)
    if not isinstance(enrolment, dict) or enrolment.get("schema") != "fm-today-enrolment.v1":
        return ["$.schema: schema: not an fm-today-enrolment.v1 document"]
    errs = validator.errors(enrolment, validator.docs["fm-today-enrolment.v1.schema.json"],
                            "fm-today-enrolment.v1.schema.json", "$")
    if errs:
        return errs
    record = home.pending()
    if not record or record.get("enrol_id") != enrolment["enrol_id"]:
        return ["$.enrol_id: enrolment: firstmate opened no such enrolment"]
    if record.get("status") != "open":
        return ["$.enrol_id: enrolment: already used"]
    if check.instant(record["expires_at"]) < at:
        return ["$.enrol_id: enrolment: expired at %s" % record["expires_at"]]
    credentials = home.credentials()
    if any(c.get("credential_id") == enrolment["credential_id"] for c in credentials):
        return ["$.credential_id: credential: already enrolled"]
    snapshot = {"enrolment": enrolment_block(record)}
    passkeys = passkeys_block(credentials)
    if passkeys:
        snapshot["passkeys"] = passkeys
    return check.enrolment_errors(enrolment, snapshot)


def attested_facts(enrolment):
    """(backup_eligible, sign_count) from the checked attestation's authenticator data."""
    attestation, _ = check.cbor_decode(check.b64url_decode(enrolment["attestation_object"]))
    auth = attestation["authData"]
    return bool(auth[32] & FLAG_BE), int.from_bytes(auth[33:37], "big")


def public_pem(spki_der):
    try:
        return subprocess.run(("openssl", "pkey", "-pubin", "-inform", "DER", "-outform", "PEM"),
                              input=spki_der, check=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE).stdout.decode("ascii")
    except (OSError, subprocess.CalledProcessError) as err:
        raise Refusal("openssl could not read the public key (%s)" % err)


def cmd_check(home, path):
    enrolment = load_enrolment(path)
    with home:
        errs = enrolment_errors(home, enrolment, now())
    for err in errs:
        print("error: " + err)
    if errs:
        return 1
    print("ok")
    return 0


def ask_at_machine(summary):
    """The captain's answer typed at this machine's terminal, or None when there is no terminal.

    The answer is read from the controlling terminal only, never from stdin, a
    file, an environment variable, or anything the portal sent.
    """
    try:
        fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return None
    try:
        if not os.isatty(fd):
            return None
        os.write(fd, summary.encode("utf-8"))
        line = b""
        while not line.endswith(b"\n"):
            chunk = os.read(fd, 1)
            if not chunk:
                break
            line += chunk
        return line.decode("utf-8", "replace")
    finally:
        os.close(fd)


def cmd_confirm(home, path):
    enrolment = load_enrolment(path)
    with home:
        errs = enrolment_errors(home, enrolment, now())
        for err in errs:
            print("error: " + err)
        if errs:
            print("refused: nothing was enrolled")
            return 1
        label = home.pending()["label"]
    spki = check.b64url_decode(enrolment["public_key_spki"])
    pem = public_pem(spki)
    backup_eligible, sign_count = attested_facts(enrolment)
    summary = "\n".join([
        "",
        "Trust this passkey to sign the merge word and the go from Today?",
        "  label:       %s" % printable(label),
        "  device:      %s (as the portal reports it)" % printable(enrolment["device"]),
        "  registered:  %s (as the portal reports it)" % printable(enrolment["enrolled_at"]),
        "  credential:  %s" % enrolment["credential_id"],
        "  key:         %s %s" % (ALG_NAMES[enrolment["public_key_alg"]], fingerprint(spki)),
        "  synced:      %s" % ("yes, backup eligible" if backup_eligible else "no, this device only"),
        "Confirm only if you registered this passkey on Today just now.",
        "Type yes to trust it, anything else to refuse: ",
    ])
    answer = ask_at_machine(summary)
    if answer is None:
        print("refused: no terminal at this machine to confirm on; nothing was enrolled")
        return 1
    with home:
        at = now()
        record = home.pending()
        ours = bool(record) and record.get("enrol_id") == enrolment["enrol_id"] and record.get("status") == "open"
        if ours:
            record["status"] = "taken"
            record["taken_at"] = stamp(at)
        if answer.strip() != "yes":
            if ours:
                record["decision"] = "refused"
                home.save_pending(record)
            print("refused at the machine: nothing was enrolled")
            return 1
        errs = enrolment_errors(home, enrolment, at)
        if errs:
            for err in errs:
                print("error: " + err)
            if ours:
                record["decision"] = "expired" if check.instant(record["expires_at"]) < at else "refused"
                home.save_pending(record)
            print("refused: the enrolment changed while waiting for the answer; nothing was enrolled")
            return 1
        credentials = home.credentials()
        credentials.append({
            "credential_id": enrolment["credential_id"],
            "public_key_pem": pem,
            "alg": enrolment["public_key_alg"],
            "rp_id": record["rp_id"],
            "origin": record["origin"],
            "label": record["label"],
            "enrolled_at": record["taken_at"],
            "enrolled_via": "portal",
            "backup_eligible": backup_eligible,
            "sign_count": sign_count,
            "status": "active",
            "revoked_at": None,
        })
        home.save_credentials(credentials)
        record["decision"] = "confirmed"
        home.save_pending(record)
    print("enrolled %s (%s)" % (enrolment["credential_id"], printable(record["label"])))
    return 0


USAGE = "usage: fm-today-passkey.sh enrol --label <label> | list [--json] | revoke <credential-id>" \
        " | blocks | check <enrolment.json> | confirm <enrolment.json>\n"


def main(argv):
    config_dir, state_dir, args = argv[1], argv[2], argv[3:]
    home = Home(config_dir, state_dir)
    try:
        if len(args) == 3 and args[0] == "enrol" and args[1] == "--label":
            return cmd_enrol(home, args[2])
        if args in (["list"], ["list", "--json"]):
            return cmd_list(home, len(args) == 2)
        if len(args) == 2 and args[0] == "revoke":
            return cmd_revoke(home, args[1])
        if args == ["blocks"]:
            return cmd_blocks(home)
        if len(args) == 2 and args[0] == "check":
            return cmd_check(home, args[1])
        if len(args) == 2 and args[0] == "confirm":
            return cmd_confirm(home, args[1])
    except Refusal as err:
        sys.stderr.write("fm-today-passkey: %s\n" % err)
        return 1
    sys.stderr.write(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
