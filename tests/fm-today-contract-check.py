#!/usr/bin/env python3
"""Check Today contract documents against docs/today-contract/*.schema.json.

Standard library only, so the check runs anywhere python3 does, CI included.
It implements the subset of JSON Schema draft 2020-12 the Today schemas use and
refuses any keyword it does not implement, so a schema can never be checked
more loosely than it reads.
Beyond the schema, it recomputes every card_hash and every passkey challenge
exactly as docs/today-contract.md defines them, and checks passkey assertions
and enrolments: ES256 and RS256 signatures are verified here in pure Python,
so the check depends on no crypto library.

Usage:
  fm-today-contract-check.py check <schema-dir> <document.json>
                                   [--keys <keys.json>] [--snapshot <snapshot.json>]
      Print "ok" and exit 0, or print one "error: <where>: <why>" line per
      failure and exit 1.
      --keys names the credentials firstmate holds, as
      {"rp_id", "origin", "credentials": [{"credential_id", "alg",
      "public_key_spki"}...]}; with it, an answer's passkey assertion is
      checked in full, signature included.
      --snapshot names the snapshot an enrolment answers; with it, an
      enrolment is checked against that snapshot's enrolment block.
  fm-today-contract-check.py hash <card.json>
      Print the card_hash the card's shown fields produce.
  fm-today-contract-check.py challenge <answer.json>
      Print the base64url WebAuthn challenge the answer's fields produce.
"""
import base64
import datetime
import hashlib
import json
import os
import re
import sys

ANNOTATIONS = {"$schema", "$id", "title", "description", "$defs"}
ASSERTIONS = {
    "$ref", "type", "const", "enum", "properties", "required",
    "additionalProperties", "items", "minItems", "maxItems", "contains",
    "minContains", "maxContains", "minLength", "maxLength", "pattern",
    "minimum", "maximum", "oneOf", "allOf", "not", "if", "then", "else",
}

# docs/today-contract.md owns these definitions; keep them in step.
CARD_HASH_FIELDS = ("schema", "task_id", "owner", "kind", "title", "question",
                    "options", "repo", "pr_url", "due", "head_sha",
                    "subject_sha256", "proof")
MAIN = "(main)"
PASSKEY_DOMAIN = "fm-today-passkey.v1"
WORK_LIMIT = 1000
FLAG_UP, FLAG_UV, FLAG_AT = 0x01, 0x04, 0x40
ES256, RS256 = -7, -257

# NIST P-256 (FIPS 186-4 D.1.2.3).
P256_P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff
P256_A = P256_P - 3
P256_B = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b
P256_G = (0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296,
          0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5)
P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551
OID_EC_PUBLIC_KEY = bytes.fromhex("2a8648ce3d0201")
OID_P256 = bytes.fromhex("2a8648ce3d030107")
OID_RSA = bytes.fromhex("2a864886f70d010101")
SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")


def canonical(value):
    """RFC 8785 serialization for number-free JSON with ASCII keys."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"),
                      sort_keys=True)


def card_hash(card):
    shown = {k: card[k] for k in CARD_HASH_FIELDS if k in card}
    return hashlib.sha256(canonical(shown).encode("utf-8")).hexdigest()


def instant(text):
    """An offset timestamp as an aware datetime; the schema has checked its form.

    Raises ValueError when the form names no real instant, such as February 30.
    """
    text = re.sub(r"\.([0-9]+)", lambda m: "." + m.group(1).ljust(6, "0"), text)
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


def ecma_pattern(pattern):
    """The pattern with ECMA-262 anchors: without the m flag, $ matches only at the end."""
    return re.sub(r"(?<!\\)\$", r"\\Z", pattern)


def b64url(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def b64url_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def passkey_challenge(answer):
    parts = [PASSKEY_DOMAIN, answer["answer_id"], answer["task_id"],
             answer["kind"], answer["card_hash"], answer["value"],
             answer.get("later_until", "")]
    return hashlib.sha256("\n".join(parts).encode("utf-8")).digest()


def der_read(buf, pos):
    """One DER TLV at pos: (tag, content, next position)."""
    if pos + 2 > len(buf):
        raise ValueError("DER: truncated")
    tag, length = buf[pos], buf[pos + 1]
    pos += 2
    if length & 0x80:
        count = length & 0x7f
        if count == 0 or count > 4 or pos + count > len(buf):
            raise ValueError("DER: bad length")
        length = int.from_bytes(buf[pos:pos + count], "big")
        pos += count
    if pos + length > len(buf):
        raise ValueError("DER: truncated")
    return tag, buf[pos:pos + length], pos + length


def der_items(body):
    """Every TLV in body, which they must fill exactly: [(tag, content)...]."""
    items, pos = [], 0
    while pos < len(body):
        tag, content, pos = der_read(body, pos)
        items.append((tag, content))
    return items


def der_sequence(buf):
    """The TLVs inside one DER SEQUENCE that fills buf exactly."""
    tag, body, end = der_read(buf, 0)
    if tag != 0x30 or end != len(buf):
        raise ValueError("DER: not one SEQUENCE")
    return der_items(body)


def der_uint(tag, content):
    if tag != 0x02 or not content or content[0] & 0x80:
        raise ValueError("DER: not a positive INTEGER")
    return int.from_bytes(content, "big")


def spki_key(der):
    """A SubjectPublicKeyInfo as ("EC", x, y) for P-256 or ("RSA", n, e)."""
    items = der_sequence(der)
    if len(items) != 2 or items[0][0] != 0x30 or items[1][0] != 0x03:
        raise ValueError("SPKI: not an algorithm and a key")
    alg = der_items(items[0][1])
    if not alg or alg[0][0] != 0x06:
        raise ValueError("SPKI: no algorithm")
    bits = items[1][1]
    if not bits or bits[0] != 0:
        raise ValueError("SPKI: key has unused bits")
    key = bits[1:]
    if alg[0][1] == OID_EC_PUBLIC_KEY:
        if len(alg) != 2 or alg[1] != (0x06, OID_P256):
            raise ValueError("SPKI: EC key not on P-256")
        if len(key) != 65 or key[0] != 4:
            raise ValueError("SPKI: EC point not uncompressed")
        return ("EC", int.from_bytes(key[1:33], "big"), int.from_bytes(key[33:], "big"))
    if alg[0][1] == OID_RSA:
        parts = der_sequence(key)
        if len(parts) != 2:
            raise ValueError("SPKI: RSA key is not a modulus and an exponent")
        return ("RSA", der_uint(*parts[0]), der_uint(*parts[1]))
    raise ValueError("SPKI: algorithm is neither EC nor RSA")


def cbor_decode(buf, pos=0):
    """One definite-length CBOR item at pos: (value, next position).

    Covers what a WebAuthn attestation object uses: integers, byte and text
    strings, arrays, and maps; anything else is refused.
    """
    if pos >= len(buf):
        raise ValueError("CBOR: truncated")
    major, info = buf[pos] >> 5, buf[pos] & 0x1f
    pos += 1
    if info < 24:
        arg = info
    elif info <= 27:
        size = 1 << (info - 24)
        if pos + size > len(buf):
            raise ValueError("CBOR: truncated")
        arg = int.from_bytes(buf[pos:pos + size], "big")
        pos += size
    else:
        raise ValueError("CBOR: indefinite or reserved length")
    if major == 0:
        return arg, pos
    if major == 1:
        return -1 - arg, pos
    if major in (2, 3):
        if pos + arg > len(buf):
            raise ValueError("CBOR: truncated")
        raw = buf[pos:pos + arg]
        return (raw if major == 2 else raw.decode("utf-8")), pos + arg
    if major == 4:
        out = []
        for _ in range(arg):
            item, pos = cbor_decode(buf, pos)
            out.append(item)
        return out, pos
    if major == 5:
        out = {}
        for _ in range(arg):
            key, pos = cbor_decode(buf, pos)
            out[key], pos = cbor_decode(buf, pos)
        return out, pos
    raise ValueError("CBOR: unsupported major type %d" % major)


def cose_key(cose):
    """A COSE public key as (alg, key) with key shaped as spki_key's."""
    if not isinstance(cose, dict):
        raise ValueError("COSE: not a map")
    alg = cose.get(3)
    if cose.get(1) == 2 and alg == ES256 and cose.get(-1) == 1:
        x, y = cose.get(-2), cose.get(-3)
        if not isinstance(x, bytes) or not isinstance(y, bytes) or len(x) != 32 or len(y) != 32:
            raise ValueError("COSE: EC coordinates are not 32 bytes")
        return alg, ("EC", int.from_bytes(x, "big"), int.from_bytes(y, "big"))
    if cose.get(1) == 3 and alg == RS256:
        n, e = cose.get(-1), cose.get(-2)
        if not isinstance(n, bytes) or not isinstance(e, bytes):
            raise ValueError("COSE: RSA modulus or exponent missing")
        return alg, ("RSA", int.from_bytes(n, "big"), int.from_bytes(e, "big"))
    raise ValueError("COSE: neither an ES256 P-256 key nor an RS256 key")


def p256_add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P256_P == 0:
        return None
    if a == b:
        slope = (3 * a[0] * a[0] + P256_A) * pow(2 * a[1], -1, P256_P)
    else:
        slope = (b[1] - a[1]) * pow(b[0] - a[0], -1, P256_P)
    x = (slope * slope - a[0] - b[0]) % P256_P
    return (x, (slope * (a[0] - x) - a[1]) % P256_P)


def p256_mul(k, point):
    out = None
    while k:
        if k & 1:
            out = p256_add(out, point)
        point = p256_add(point, point)
        k >>= 1
    return out


def es256_verify(x, y, message, signature):
    """ECDSA P-256 with SHA-256 over message; signature is DER, as WebAuthn returns it."""
    if (y * y - (x * x * x + P256_A * x + P256_B)) % P256_P or not (0 <= x < P256_P and 0 <= y < P256_P):
        return False
    try:
        parts = der_sequence(signature)
        if len(parts) != 2:
            return False
        r, s = der_uint(*parts[0]), der_uint(*parts[1])
    except ValueError:
        return False
    if not (0 < r < P256_N and 0 < s < P256_N):
        return False
    e = int.from_bytes(hashlib.sha256(message).digest(), "big")
    w = pow(s, -1, P256_N)
    point = p256_add(p256_mul(e * w % P256_N, P256_G), p256_mul(r * w % P256_N, (x, y)))
    return point is not None and point[0] % P256_N == r


def rs256_verify(n, e, message, signature):
    """RSASSA-PKCS1-v1_5 with SHA-256 over message (RFC 8017 8.2.2)."""
    k = (n.bit_length() + 7) // 8
    t = SHA256_DIGEST_INFO + hashlib.sha256(message).digest()
    if len(signature) != k or k < len(t) + 11:
        return False
    s = int.from_bytes(signature, "big")
    if s >= n:
        return False
    em = pow(s, e, n).to_bytes(k, "big")
    return em == b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t


def signature_ok(alg, key, message, signature):
    if alg == ES256 and key[0] == "EC":
        return es256_verify(key[1], key[2], message, signature)
    if alg == RS256 and key[0] == "RSA":
        return rs256_verify(key[1], key[2], message, signature)
    return False


def origin_within(origin, rp_id):
    """A WebAuthn origin may use an RP ID equal to its host or a parent of it."""
    host = re.sub(r":[0-9]+$", "", origin[len("https://"):])
    return host == rp_id or host.endswith("." + rp_id)


def client_data(where, text, want_type, out):
    """The decoded clientDataJSON, or None after recording why it is unusable."""
    try:
        client = json.loads(b64url_decode(text))
    except ValueError:
        out.append("%s: challenge: not base64url JSON" % where)
        return None
    if not isinstance(client, dict):
        out.append("%s: challenge: not a JSON object" % where)
        return None
    if client.get("type") != want_type:
        out.append("%s: type: expected %s" % (where, want_type))
    return client


def client_origin_errors(where, client, origin):
    out = []
    if client.get("origin") != origin:
        out.append("%s: origin: expected %s" % (where, origin))
    if client.get("crossOrigin", False) is not False or "topOrigin" in client:
        out.append("%s: cross-origin: the ceremony ran inside another origin" % where)
    return out


def authenticator_data_errors(where, raw, rp_id, flags_needed):
    out = []
    if len(raw) < 37:
        return ["%s: authenticator_data: shorter than 37 bytes" % where]
    if raw[:32] != hashlib.sha256(rp_id.encode("utf-8")).digest():
        out.append("%s: rp_id: relying-party hash is not SHA-256 of %s" % (where, rp_id))
    if raw[32] & flags_needed != flags_needed:
        out.append("%s: flags: user-present and user-verified must both be set" % where)
    return out


def assertion_errors(answer, keys):
    """Every check docs/today-contract.md lists for a passkey assertion that needs no state."""
    passkey = answer["passkey"]
    held = {c["credential_id"]: c for c in keys["credentials"]}
    credential = held.get(passkey["credential_id"])
    if credential is None:
        return ["$.passkey.credential_id: credential: not an enrolled credential"]
    out = []
    client = client_data("$.passkey.client_data_json", passkey["client_data_json"], "webauthn.get", out)
    if client is None:
        return out
    out += client_origin_errors("$.passkey.client_data_json", client, keys["origin"])
    auth = b64url_decode(passkey["authenticator_data"])
    out += authenticator_data_errors("$.passkey.authenticator_data", auth, keys["rp_id"],
                                     FLAG_UP | FLAG_UV)
    signed = auth + hashlib.sha256(b64url_decode(passkey["client_data_json"])).digest()
    key = spki_key(b64url_decode(credential["public_key_spki"]))
    if not signature_ok(credential["alg"], key, signed, b64url_decode(passkey["signature"])):
        out.append("$.passkey.signature: signature: does not verify with the enrolled key")
    return out


def enrolment_errors(enrolment, snapshot):
    """The enrolment's own consistency, and with a snapshot, its match to the enrolment asked for."""
    out = []
    client = client_data("$.client_data_json", enrolment["client_data_json"], "webauthn.create", out)
    try:
        attestation, end = cbor_decode(b64url_decode(enrolment["attestation_object"]))
        auth = attestation["authData"]
        if end != len(b64url_decode(enrolment["attestation_object"])) or not isinstance(auth, bytes):
            raise ValueError("attestation object is not one map with authData bytes")
        if len(auth) < 55 or not auth[32] & FLAG_AT:
            raise ValueError("authenticator data carries no attested credential")
        id_len = int.from_bytes(auth[53:55], "big")
        cred_id = auth[55:55 + id_len]
        cose, _ = cbor_decode(auth, 55 + id_len)
        alg, attested = cose_key(cose)
    except (ValueError, KeyError, TypeError) as err:
        return out + ["$.attestation_object: attestation: %s" % err]
    if b64url(cred_id) != enrolment["credential_id"]:
        out.append("$.credential_id: credential: differs from the attested credential id")
    if alg != enrolment["public_key_alg"]:
        out.append("$.public_key_alg: alg: differs from the attested key's algorithm")
    try:
        if spki_key(b64url_decode(enrolment["public_key_spki"])) != attested:
            out.append("$.public_key_spki: key: differs from the attested key")
    except ValueError as err:
        out.append("$.public_key_spki: key: %s" % err)
    if auth[32] & (FLAG_UP | FLAG_UV) != FLAG_UP | FLAG_UV:
        out.append("$.attestation_object: flags: user-present and user-verified must both be set")
    if snapshot is None or client is None:
        return out
    asked = snapshot.get("enrolment")
    if not asked or asked["enrol_id"] != enrolment["enrol_id"]:
        return out + ["$.enrol_id: enrolment: the snapshot asks for no such enrolment"]
    if client.get("challenge") != asked["challenge"]:
        out.append("$.client_data_json: challenge: expected %s" % asked["challenge"])
    out += client_origin_errors("$.client_data_json", client, asked["origin"])
    out += authenticator_data_errors("$.attestation_object", auth, asked["rp_id"], 0)
    if instant(enrolment["enrolled_at"]) > instant(asked["expires_at"]):
        out.append("$.enrolled_at: expires_at: made after the enrolment expired")
    held = [c["credential_id"] for c in snapshot.get("passkeys", {}).get("credentials", [])]
    if enrolment["credential_id"] in held:
        out.append("$.credential_id: credential: already enrolled")
    return out


class Validator:
    def __init__(self, schema_dir):
        self.docs = {}
        for name in os.listdir(schema_dir):
            if name.endswith(".schema.json"):
                with open(os.path.join(schema_dir, name), encoding="utf-8") as fh:
                    self.docs[name] = json.load(fh)

    def resolve(self, ref, base):
        target, _, pointer = ref.partition("#")
        doc_name = target or base
        node = self.docs[doc_name]
        for part in [p for p in pointer.split("/") if p]:
            node = node[part.replace("~1", "/").replace("~0", "~")]
        return node, doc_name

    def schema_for(self, instance):
        name = instance.get("schema") if isinstance(instance, dict) else None
        file_name = "%s.schema.json" % name
        if file_name not in self.docs:
            return None
        return file_name

    def errors(self, inst, schema, base, where):
        if schema is True:
            return []
        if schema is False:
            return ["%s: false schema" % where]
        unknown = set(schema) - ANNOTATIONS - ASSERTIONS
        if unknown:
            raise ValueError("unsupported keyword(s) %s in %s" % (sorted(unknown), base))
        out = []
        if "$ref" in schema:
            node, doc = self.resolve(schema["$ref"], base)
            out += self.errors(inst, node, doc, where)
        if "type" in schema:
            types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(type_ok(inst, t) for t in types):
                out.append("%s: type: expected %s" % (where, "/".join(types)))
                return out
        if "const" in schema and not json_equal(inst, schema["const"]):
            out.append("%s: const: expected %s" % (where, json.dumps(schema["const"])))
        if "enum" in schema and not any(json_equal(inst, e) for e in schema["enum"]):
            out.append("%s: enum: %s is not one of %s" % (where, json.dumps(inst), schema["enum"]))
        if isinstance(inst, str):
            if "minLength" in schema and len(inst) < schema["minLength"]:
                out.append("%s: minLength: shorter than %d" % (where, schema["minLength"]))
            if "maxLength" in schema and len(inst) > schema["maxLength"]:
                out.append("%s: maxLength: longer than %d" % (where, schema["maxLength"]))
            if "pattern" in schema and not re.search(ecma_pattern(schema["pattern"]), inst):
                out.append("%s: pattern: %s does not match" % (where, json.dumps(inst)))
        if is_number(inst):
            if "minimum" in schema and inst < schema["minimum"]:
                out.append("%s: minimum: below %s" % (where, schema["minimum"]))
            if "maximum" in schema and inst > schema["maximum"]:
                out.append("%s: maximum: above %s" % (where, schema["maximum"]))
        if isinstance(inst, dict):
            for key in schema.get("required", []):
                if key not in inst:
                    out.append("%s: required: missing %s" % (where, key))
            props = schema.get("properties", {})
            for key, value in inst.items():
                if key in props:
                    out += self.errors(value, props[key], base, "%s.%s" % (where, key))
                elif "additionalProperties" in schema:
                    sub = self.errors(value, schema["additionalProperties"], base, "%s.%s" % (where, key))
                    if sub:
                        out.append("%s: additionalProperties: %s is not allowed" % (where, key))
        if isinstance(inst, list):
            if "minItems" in schema and len(inst) < schema["minItems"]:
                out.append("%s: minItems: fewer than %d" % (where, schema["minItems"]))
            if "maxItems" in schema and len(inst) > schema["maxItems"]:
                out.append("%s: maxItems: more than %d" % (where, schema["maxItems"]))
            if "items" in schema:
                for i, item in enumerate(inst):
                    out += self.errors(item, schema["items"], base, "%s[%d]" % (where, i))
            if "contains" in schema:
                hits = sum(1 for item in inst if not self.errors(item, schema["contains"], base, where))
                if hits < schema.get("minContains", 1):
                    out.append("%s: minContains: %d match(es)" % (where, hits))
                if "maxContains" in schema and hits > schema["maxContains"]:
                    out.append("%s: maxContains: %d match(es), at most %d allowed" % (where, hits, schema["maxContains"]))
        for sub in schema.get("allOf", []):
            out += self.errors(inst, sub, base, where)
        if "oneOf" in schema:
            passing = [s for s in schema["oneOf"] if not self.errors(inst, s, base, where)]
            if len(passing) != 1:
                out.append("%s: oneOf: %d branches match" % (where, len(passing)))
        if "not" in schema and not self.errors(inst, schema["not"], base, where):
            out.append("%s: not: matches a forbidden shape" % where)
        if "if" in schema:
            if not self.errors(inst, schema["if"], base, where):
                if "then" in schema:
                    out += self.errors(inst, schema["then"], base, where)
            elif "else" in schema:
                out += self.errors(inst, schema["else"], base, where)
        return out


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def type_ok(value, name):
    return {
        "object": lambda v: isinstance(v, dict),
        "array": lambda v: isinstance(v, list),
        "string": lambda v: isinstance(v, str),
        "boolean": lambda v: isinstance(v, bool),
        "null": lambda v: v is None,
        "number": is_number,
        "integer": lambda v: is_number(v) and float(v).is_integer(),
    }[name](value)


def json_equal(a, b):
    if isinstance(a, bool) != isinstance(b, bool):
        return False
    return canonical(a) == canonical(b)


def contract_errors(inst, keys=None, snapshot=None):
    """The rules JSON Schema cannot state: hashes, the challenge, signatures, uniqueness, order."""
    out = []
    cards = []
    if inst.get("schema") == "fm-today-card.v1":
        cards = [("$", inst)]
    elif inst.get("schema") == "fm-today-snapshot.v1":
        cards = [("$.sections.calls[%d]" % i, c) for i, c in enumerate(inst["sections"]["calls"])]
        # A call is keyed by its owning home and task id; absent owner is (main).
        ids = [(c.get("owner", MAIN), c["task_id"]) for _, c in cards]
        if len(ids) != len(set(ids)):
            out.append("$.sections.calls: task_id: a call appears twice")
        work = [(w.get("owner", MAIN), w["id"])
                for k in ("underway", "charted_next", "landed") for w in inst["sections"][k]]
        if len(work) > WORK_LIMIT:
            out.append("$.sections: work: more than %d rows across underway, charted_next and landed" % WORK_LIMIT)
        if len(work) != len(set(work)):
            out.append("$.sections: id: a piece of work appears twice")
        blocks = inst["sections"]["day"]["blocks"]
        if len({b["id"] for b in blocks}) != len(blocks):
            out.append("$.sections.day.blocks: id: a block appears twice")
        for i, block in enumerate(blocks):
            try:
                starts, ends = instant(block["starts_at"]), instant(block["ends_at"])
            except ValueError as err:
                out.append("$.sections.day.blocks[%d]: instant: not a real time (%s)" % (i, err))
                continue
            if ends < starts:
                out.append("$.sections.day.blocks[%d]: ends_at: ends before it starts" % i)
    for where, card in cards:
        want = card_hash(card)
        if card["card_hash"] != want:
            out.append("%s.card_hash: card_hash: expected %s" % (where, want))
        values = [o["value"] for o in card["options"]]
        if len(values) != len(set(values)):
            out.append("%s.options: value: an option value appears twice" % where)
    if inst.get("schema") == "fm-today-snapshot.v1":
        out += relying_party_errors("$.passkeys", inst.get("passkeys"))
        out += relying_party_errors("$.enrolment", inst.get("enrolment"))
        held = [c["credential_id"] for c in inst.get("passkeys", {}).get("credentials", [])]
        if len(held) != len(set(held)):
            out.append("$.passkeys.credentials: credential_id: a credential appears twice")
    if inst.get("schema") == "fm-today-answer.v1" and "passkey" in inst:
        client = client_data("$.passkey.client_data_json", inst["passkey"]["client_data_json"],
                             "webauthn.get", out)
        if client is None:
            return out
        want = b64url(passkey_challenge(inst))
        if client.get("challenge") != want:
            out.append("$.passkey.client_data_json: challenge: expected %s" % want)
        if keys is not None and not out:
            out += assertion_errors(inst, keys)
    if inst.get("schema") == "fm-today-enrolment.v1":
        out += enrolment_errors(inst, snapshot)
    return out


def relying_party_errors(where, block):
    if block is None or origin_within(block["origin"], block["rp_id"]):
        return []
    return ["%s.origin: origin: host is not %s or within it" % (where, block["rp_id"])]


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main(argv):
    if len(argv) >= 4 and argv[1] == "check":
        options = dict(zip(argv[4::2], argv[5::2]))
        if len(argv) % 2 or set(options) - {"--keys", "--snapshot"}:
            sys.stderr.write(__doc__)
            return 2
        keys = load(options["--keys"]) if "--keys" in options else None
        snapshot = load(options["--snapshot"]) if "--snapshot" in options else None
        validator = Validator(argv[2])
        inst = load(argv[3])
        schema_file = validator.schema_for(inst)
        if schema_file is None:
            print("error: $.schema: schema: not a Today contract schema")
            return 1
        errs = validator.errors(inst, validator.docs[schema_file], schema_file, "$")
        if not errs:
            errs = contract_errors(inst, keys, snapshot)
        for err in errs:
            print("error: " + err)
        if errs:
            return 1
        print("ok")
        return 0
    if len(argv) == 3 and argv[1] == "hash":
        print(card_hash(load(argv[2])))
        return 0
    if len(argv) == 3 and argv[1] == "challenge":
        print(b64url(passkey_challenge(load(argv[2]))))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
