#!/usr/bin/env python3
"""Check Today contract documents against docs/today-contract/*.schema.json.

Standard library only, so the check runs anywhere python3 does, CI included.
It implements the subset of JSON Schema draft 2020-12 the Today schemas use and
refuses any keyword it does not implement, so a schema can never be checked
more loosely than it reads.
Beyond the schema, it recomputes every card_hash and every passkey challenge
exactly as docs/today-contract.md defines them.

Usage:
  fm-today-contract-check.py check <schema-dir> <document.json>
      Print "ok" and exit 0, or print one "error: <where>: <why>" line per
      failure and exit 1.
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

# docs/today-contract.md owns these two definitions; keep them in step.
CARD_HASH_FIELDS = ("schema", "task_id", "kind", "title", "question",
                    "options", "repo", "pr_url", "due")
PASSKEY_DOMAIN = "fm-today-passkey.v1"
WORK_LIMIT = 1000


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


def contract_errors(inst):
    """The rules JSON Schema cannot state: hashes, the challenge, uniqueness, order."""
    out = []
    cards = []
    if inst.get("schema") == "fm-today-card.v1":
        cards = [("$", inst)]
    elif inst.get("schema") == "fm-today-snapshot.v1":
        cards = [("$.sections.calls[%d]" % i, c) for i, c in enumerate(inst["sections"]["calls"])]
        ids = [c["task_id"] for _, c in cards]
        if len(ids) != len(set(ids)):
            out.append("$.sections.calls: task_id: a call appears twice")
        work = [w["id"] for k in ("underway", "charted_next", "landed") for w in inst["sections"][k]]
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
    if inst.get("schema") == "fm-today-answer.v1" and "passkey" in inst:
        try:
            client = json.loads(b64url_decode(inst["passkey"]["client_data_json"]))
        except ValueError:
            return out + ["$.passkey.client_data_json: challenge: not base64url JSON"]
        if client.get("type") != "webauthn.get":
            out.append("$.passkey.client_data_json: type: expected webauthn.get")
        want = b64url(passkey_challenge(inst))
        if client.get("challenge") != want:
            out.append("$.passkey.client_data_json: challenge: expected %s" % want)
    return out


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main(argv):
    if len(argv) == 4 and argv[1] == "check":
        validator = Validator(argv[2])
        inst = load(argv[3])
        schema_file = validator.schema_for(inst)
        if schema_file is None:
            print("error: $.schema: schema: not a Today contract schema")
            return 1
        errs = validator.errors(inst, validator.docs[schema_file], schema_file, "$")
        if not errs:
            errs = contract_errors(inst)
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
