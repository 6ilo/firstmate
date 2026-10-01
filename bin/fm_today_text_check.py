"""The Today text check: the rule set that keeps learner, family, fee, and legal
detail on the captain's machine.

docs/configuration.md "Today bridge" documents every rule family. The bridge
(bin/fm-today-bridge.sh) applies it to every free-text field before a snapshot
leaves, and bin/fm-today-notes.sh records its verdict on every note from Today.
Bump CHECKER whenever RULES changes.
"""
import re

CHECKER = "fm-today-text-check@1.0.0"

STREET = ("Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Lane|Ln|Drive|Dr|Court|Ct|"
          "Way|Place|Pl|Terrace|Parkway|Pkwy|Highway|Hwy|Circle|Cir")
RULES = (
    ("email", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")),
    ("phone", re.compile(r"\+\d[\d\s().-]{7,}\d|(?:\(\d{3}\)\s?|\b\d{3}[.\s-])\d{3}[.\s-]\d{4}\b")),
    ("money", re.compile(r"[$£€¥]\s?\d|\b\d[\d,]*(?:\.\d+)?\s?(?:USD|EUR|GBP|dollars?|euros?|pounds?)\b",
                         re.IGNORECASE)),
    ("address", re.compile(r"\b\d{1,6}\s+(?:[A-Z][A-Za-z.'-]*\s+){1,4}(?:" + STREET + r")\b"
                           r"|\b(?i:p\.?\s?o\.?\s+box)\s+\d+")),
    ("date-of-birth", re.compile(r"\b(?:date\s+of\s+birth|d\.?o\.?b\b|birth\s?date|birthday|born\s+on)",
                                 re.IGNORECASE)),
    ("word", re.compile(r"\b(?:guardians?|parents?|minors?|learners?|students?|family|families|"
                        r"tuition|fees?|invoices?|counsel|attorneys?|lawyers?|lawsuits?|custody)\b",
                        re.IGNORECASE)),
    ("cut", re.compile(r"\d[^\s…]*(?:\s+[^\s…]+){0,4}…")),
)


def families(*texts):
    """The rule families any of the texts trips, in rule order."""
    return [name for name, rule in RULES if any(text and rule.search(text) for text in texts)]


def tripped(*texts):
    return bool(families(*texts))

