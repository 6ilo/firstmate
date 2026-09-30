#!/usr/bin/env python3
"""A software WebAuthn authenticator for the Today contract's passkey tests.

It makes the bytes a browser's passkey would return, so tests and the committed
examples can carry real signatures that tests/fm-today-contract-check.py and
firstmate's verifier check.
Standard library plus the openssl CLI, which makes the keys and signs.
A private key lives only in the key file the caller names; the committed
examples were signed with keys that were never committed.

Usage:
  fm-today-soft-authenticator.py keygen <key.pem> [es256|rs256]
      Write a new private key and print its credential as JSON:
      credential_id, alg, public_key_spki.
  fm-today-soft-authenticator.py assert <key.pem> <credential_id> <rp_id> <origin>
                                        <answer.json> [--flags <n>] [--type <t>]
                                        [--cross-origin]
      Print the answer with a passkey assertion over the challenge its fields
      derive. --flags sets the authenticator flags byte (default 0x1d:
      user present, user verified, backup eligible, backed up); --type sets
      clientDataJSON's type (default webauthn.get).
  fm-today-soft-authenticator.py enrol <key.pem> <credential_id> <snapshot.json>
                                       <enrolled_at> <person> <device> [--flags <n>]
      Print the fm-today-enrolment.v1 document registering the key for the
      snapshot's enrolment block, with attestation "none".
"""
import base64
import hashlib
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "fm_today_contract_check", os.path.join(HERE, "fm-today-contract-check.py"))
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)

DEFAULT_FLAGS = 0x1d


def openssl(*args, data=None):
    return subprocess.run(("openssl",) + args, input=data, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def public_spki(key_file):
    return openssl("pkey", "-in", key_file, "-pubout", "-outform", "DER")


def alg_of(key_file):
    return check.ES256 if check.spki_key(public_spki(key_file))[0] == "EC" else check.RS256


def sign(key_file, message):
    """DER ECDSA for an EC key, PKCS#1 v1.5 for an RSA key: what WebAuthn returns."""
    return openssl("dgst", "-sha256", "-sign", key_file, data=message)


def cbor(value):
    """Canonical CBOR for the ints, byte and text strings, and maps a COSE key and attestation use."""
    def head(major, arg):
        if arg < 24:
            return bytes([major << 5 | arg])
        for info, size in ((24, 1), (25, 2), (26, 4), (27, 8)):
            if arg < 1 << (8 * size):
                return bytes([major << 5 | info]) + arg.to_bytes(size, "big")
        raise ValueError("CBOR: integer too large")
    if isinstance(value, int):
        return head(0, value) if value >= 0 else head(1, -1 - value)
    if isinstance(value, bytes):
        return head(2, len(value)) + value
    if isinstance(value, str):
        raw = value.encode("utf-8")
        return head(3, len(raw)) + raw
    if isinstance(value, dict):
        items = sorted((cbor(k), cbor(v)) for k, v in value.items())
        return head(5, len(items)) + b"".join(k + v for k, v in items)
    raise ValueError("CBOR: unsupported value")


def cose(key_file):
    key = check.spki_key(public_spki(key_file))
    if key[0] == "EC":
        return {1: 2, 3: check.ES256, -1: 1,
                -2: key[1].to_bytes(32, "big"), -3: key[2].to_bytes(32, "big")}
    n, e = key[1], key[2]
    return {1: 3, 3: check.RS256, -1: n.to_bytes((n.bit_length() + 7) // 8, "big"),
            -2: e.to_bytes((e.bit_length() + 7) // 8, "big")}


def client_json(kind, challenge, origin, cross_origin):
    return json.dumps({"type": kind, "challenge": challenge, "origin": origin,
                       "crossOrigin": cross_origin}, separators=(",", ":")).encode("utf-8")


def options(args, names):
    """Flag options after the positional arguments: {name: value or True}."""
    out, i = {}, 0
    while i < len(args):
        if args[i] not in names:
            raise SystemExit("unknown option %s" % args[i])
        if names[args[i]]:
            out[args[i]] = args[i + 1]
            i += 2
        else:
            out[args[i]] = True
            i += 1
    return out


def keygen(key_file, alg="es256"):
    if alg == "es256":
        openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", key_file)
    elif alg == "rs256":
        openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", key_file)
    else:
        raise SystemExit("alg must be es256 or rs256")
    os.chmod(key_file, 0o600)
    print(json.dumps({"credential_id": check.b64url(os.urandom(20)), "alg": alg_of(key_file),
                      "public_key_spki": check.b64url(public_spki(key_file))}, indent=2))


def assertion(key_file, credential_id, rp_id, origin, answer_file, *rest):
    opts = options(rest, {"--flags": True, "--type": True, "--cross-origin": False})
    answer = check.load(answer_file)
    auth = (hashlib.sha256(rp_id.encode("utf-8")).digest()
            + bytes([int(opts.get("--flags", str(DEFAULT_FLAGS)), 0)]) + (0).to_bytes(4, "big"))
    client = client_json(opts.get("--type", "webauthn.get"),
                         check.b64url(check.passkey_challenge(answer)), origin,
                         "--cross-origin" in opts)
    signature = sign(key_file, auth + hashlib.sha256(client).digest())
    answer["passkey"] = {"credential_id": credential_id, "authenticator_data": check.b64url(auth),
                         "client_data_json": check.b64url(client),
                         "signature": check.b64url(signature)}
    print(json.dumps(answer, indent=2, ensure_ascii=False))


def enrol(key_file, credential_id, snapshot_file, enrolled_at, person, device, *rest):
    opts = options(rest, {"--flags": True})
    asked = check.load(snapshot_file)["enrolment"]
    cred = base64.urlsafe_b64decode(credential_id + "=" * (-len(credential_id) % 4))
    flags = int(opts.get("--flags", str(DEFAULT_FLAGS)), 0) | check.FLAG_AT
    auth = (hashlib.sha256(asked["rp_id"].encode("utf-8")).digest() + bytes([flags])
            + (0).to_bytes(4, "big") + bytes(16) + len(cred).to_bytes(2, "big") + cred
            + cbor(cose(key_file)))
    attestation = cbor({"fmt": "none", "attStmt": {}, "authData": auth})
    print(json.dumps({
        "schema": "fm-today-enrolment.v1",
        "enrol_id": asked["enrol_id"],
        "credential_id": credential_id,
        "client_data_json": check.b64url(client_json("webauthn.create", asked["challenge"],
                                                     asked["origin"], False)),
        "attestation_object": check.b64url(attestation),
        "public_key_spki": check.b64url(public_spki(key_file)),
        "public_key_alg": alg_of(key_file),
        "transports": ["hybrid", "internal"],
        "enrolled_at": enrolled_at,
        "person": person,
        "device": device,
    }, indent=2))


def main(argv):
    commands = {"keygen": (keygen, 1, 2), "assert": (assertion, 5, 10), "enrol": (enrol, 6, 8)}
    if len(argv) < 2 or argv[1] not in commands:
        sys.stderr.write(__doc__)
        return 2
    run, least, most = commands[argv[1]]
    if not least <= len(argv) - 2 <= most:
        sys.stderr.write(__doc__)
        return 2
    run(*argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
