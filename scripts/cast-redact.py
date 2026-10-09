#!/usr/bin/env python3
"""
cast-redact.py — CAST Phase 7f PII redaction pipeline using Microsoft Presidio.

Usage:
  echo "text with PII" | python3 cast-redact.py
  python3 cast-redact.py --text "Contact john@example.com or call 555-1234"
  python3 cast-redact.py --mode analyze --text "..."
  python3 cast-redact.py --file input.txt
  python3 cast-redact.py --help

Output (JSON):
  {
    "redacted_text": "Contact <EMAIL_ADDRESS> or call <PHONE_NUMBER>",
    "entities": [
      {"entity_type": "EMAIL_ADDRESS", "start": 8, "end": 24, "score": 0.85, "original": "john@example.com"},
      ...
    ],
    "entity_count": 2,
    "mode": "redact",
    "engine": "presidio"  // or "regex-fallback"
  }

Modes:
  redact    Replace PII with <ENTITY_TYPE> tags (default)
  analyze   Return entity list only, no redaction
  mask      Replace PII with *** asterisks

Exit codes:
  0  Success
  1  Error (see stderr)

Config:
  Custom patterns loaded from ~/.claude/config/pii-patterns.json
  Overridable with --patterns-file <path>
"""

from __future__ import annotations

import sys
import json
import re
import hashlib
import argparse
import os
import unicodedata
from datetime import datetime, timezone
from typing import Any

PATTERNS_CONFIG = os.path.expanduser("~/.claude/config/pii-patterns.json")

# Unicode categories removed from the matching VIEW (never from the output): Cf = format
# (zero-width / BOM / soft hyphen), Mn = nonspacing combining marks, Me = enclosing marks
# (U+20DD, U+20E3 ...).
_VIEW_STRIPPED_CATEGORIES = frozenset(("Cf", "Mn", "Me"))


def _hash16(original: str) -> str:
    """sha256 prefix of matched text.  `surrogatepass`: input may hold lone surrogates
    (e.g. JSON `\\ud800`); a plain .encode() would raise and crash the hook (fail-open)."""
    return hashlib.sha256(original.encode("utf-8", "surrogatepass")).hexdigest()[:16]

# ── Built-in fallback regex patterns (used when Presidio is unavailable) ─────

_STANDARD_FALLBACK_PATTERNS = [
    # Standard PII
    # Local part capped at 64 (RFC 5321) and domain at 253: the unbounded `+` was
    # quadratic on long no-@ runs. No leading \b: it would stop a >64-char local part
    # from matching mid-run (leak); instead the last 64 chars + domain are redacted.
    ("EMAIL_ADDRESS",   r"[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,253}\.[A-Za-z]{2,}\b"),
    ("PHONE_NUMBER",    r"\b(?:\+1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b"),
    ("US_SSN",          r"\b\d{3}-\d{2}-\d{4}\b"),
    ("CREDIT_CARD",     r"\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13}|6011[0-9]{12}|3(?:0[0-5]|[68][0-9])[0-9]{11})\b"),
    ("IP_ADDRESS",      r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
    # Secrets / tokens
    ("AWS_ACCESS_KEY",  r"(?<![A-Z0-9])(AKIA[0-9A-Z]{16})(?![A-Z0-9])"),
    ("GITHUB_TOKEN",    r"(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{36,}"),
    # Context-anchored ONLY: a bare 40-char base64 run is indistinguishable from a git SHA / hash.
    # GENERIC_SECRET cannot cover this name (its \b does not hold inside `aws_secret_access_key`, and it
    # needs the operator right after `secret`). Trigger: "secret" is already in _PII_CANDIDATES.
    ("AWS_SECRET_ACCESS_KEY", r"aws[_-]?secret[_-]?(?:access[_-]?)?key['\"]?\s*[:=]\s*['\"]?([A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=])"),
    ("ANTHROPIC_KEY",   r"sk-ant-[A-Za-z0-9_\-]{32,}"),
    ("OPENAI_KEY",      r"sk-(?:proj-)?[A-Za-z0-9]{32,}"),
    ("BEARER_TOKEN",    r"(?i)bearer\s+([A-Za-z0-9_\-\.]{20,})"),
    ("JWT",             r"eyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"),
    # user/password bounded (256/1024): the unbounded `+` runs before the required `:` / `@`
    # were quadratic on repeated `scheme://x-` input (3-4 s on 120 KB). Host stays `[^\s]+`:
    # it is last and needs no following literal, so it cannot backtrack. User may be empty
    # (`redis://:pw@h`). Scheme takes an optional `+driver` suffix (+srv, +psycopg2, ...).
    ("DATABASE_URL",    r"(?i)(?:postgres(?:ql)?|mysql|mongodb|rediss?|sqlite)(?:\+[a-z0-9_]{1,24})?://[^:@\s]{0,256}:[^@\s]{1,1024}@[^\s]+"),
    # OVERSIZE companion (same entity type): a user >256 or password >1024 chars would
    # otherwise leak the whole URL. Nothing required follows an unbounded run, so it stays
    # linear; redacts scheme -> next whitespace. (No possessive quantifiers: py3.9 support.)
    ("DATABASE_URL",    r"(?i)(?:postgres(?:ql)?|mysql|mongodb|rediss?|sqlite)(?:\+[a-z0-9_]{1,24})?://(?:[^:@\s]{257,}|[^:@\s]{0,256}:[^@\s]{1025,})[^\s]*"),
    ("PRIVATE_KEY",     r"-----BEGIN[A-Z ]+(?:PRIVATE KEY|CERTIFICATE)-----"),
    ("API_KEY",         r"(?i)(?:api[_-]?key|apikey|x-api-key)[:\s=]+['\"]?([A-Za-z0-9_\-]{20,})['\"]?"),
    # Paths and URLs
    ("ABSOLUTE_PATH",   r"(?:/Users/|(?<![\w.\-])/home/)[^/\s]+/[^\s]*"),
    ("BITBUCKET_URL",   r"bitbucket\.org/[^\s]+"),
    ("SLACK_WEBHOOK",   r"hooks\.slack\.com/[^\s]+"),
    # C1b: additional secret/token vendors (closing redaction-engine gaps for the
    # SubagentStop free-form prose surface)
    ("STRIPE_KEY",      r"(?:sk_live|sk_test|pk_live|rk_live)_[A-Za-z0-9]{24,}"),
    # xoxa- is not a documented Slack token type (bot/user/refresh/app tokens are
    # xoxb/xoxp/xoxr/xoxs) — kept deliberately for conservative future-proofing;
    # do not "clean up" by removing it.
    ("SLACK_TOKEN",     r"xox[abprs]-[A-Za-z0-9\-]{10,}"),
    ("NPM_TOKEN",       r"npm_[A-Za-z0-9]{36,}"),
    ("SENDGRID_KEY",    r"SG\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}"),
    ("GOOGLE_API_KEY",  r"AIza[A-Za-z0-9_\-]{35}"),
    # S-3: Resend (re_) and GitLab tokens are prefix-anchored. The Resend body must be long
    # and contain an uppercase letter, a lowercase letter AND a digit, evaluated
    # case-sensitively via (?-i:...) (the module compiles with IGNORECASE, so plain [A-Z]
    # would not discriminate) — this excludes snake_case identifiers (no uppercase) and
    # UPPER_SNAKE constants (no lowercase), e.g. re_compile_pattern_v2_handler.
    # GitLab prefixes per https://docs.gitlab.com/security/tokens/ ("Token prefixes");
    # no lengths are documented, so a 20+ char body is kept.
    ("RESEND_KEY",      r"\bre_(?-i:(?=[A-Za-z0-9_]*[A-Z])(?=[A-Za-z0-9_]*[a-z])(?=[A-Za-z0-9_]*\d)[A-Za-z0-9_]{20,})"),
    ("GITLAB_TOKEN",    r"\bgl(?:pat|oas|dt|rtr?|cbt|ptt|ft|imt|agent|wt|soat|ffct)-[A-Za-z0-9_\-]{20,}"),
    # Zenodo and Cloudflare API tokens have NO distinctive prefix: a bare token is
    # uncoverable by regex without surrounding context (a bare high-entropy catch-all
    # would false-positive everywhere). Only context-anchored assignments are matched.
    ("VENDOR_TOKEN_ASSIGNMENT",
     r"""(?i)(?:zenodo|cloudflare|cf)[_-]?(?:api[_-]?)?(?:access[_-]?)?token['"]?\s*[:=]\s*['"]?([A-Za-z0-9_\-]{30,})"""),
]

# GENERIC_SECRET's tag-placeholder lookahead (below) is DERIVED from the entity-type
# names of every other pattern, rather than hardcoded, so it can never silently go
# stale as new FALLBACK_PATTERNS entries are added — plus the redactor's own generic
# placeholder words (REDACTED/MASKED) and GENERIC_SECRET's own tag.
_KNOWN_ENTITY_TAGS = "|".join(
    re.escape(etype) for etype, _ in _STANDARD_FALLBACK_PATTERNS
) + "|REDACTED|MASKED|GENERIC_SECRET"

# GENERIC_SECRET: keyword, then an optional closing quote/backtick/whitespace before
# the operator (handles JSON `"password":`, PHP `'password' =>`, and markdown
# `` `password`: ``), an assignment operator (=, :, or the PHP fat-arrow =>), then an
# optional opening quote/backtick (so markdown-fenced values like `` password: `X` ``
# are caught — security found this regression 2026-08-16: excluding the backtick from
# the VALUE charset last round, to kill markdown-prose false positives, accidentally
# also excluded it as a value DELIMITER, so backtick-fenced real secrets went
# undetected entirely), two negative lookaheads — one for known placeholder/null
# values (so `token: None`, `secret: null`, `password: undefined` are not flagged)
# and one for the redactor's OWN emitted <ENTITY_TYPE> tags, case-SENSITIVE via
# (?-i:...) (a plain [A-Z_] class inherits the module's re.IGNORECASE compile flag
# and matches lowercase too — security found `token=<PROD>abc123realvalue` evaded
# detection entirely under the case-insensitive version, 2026-08-16) — then the value
# itself. Value charset is a denylist (anything but whitespace/quotes/backtick) per
# corpus sweep measurement (2026-08-16, 2437 real agent responses, contamination-free
# slice): 1 true positive + 1 false positive ("WebSearch" quoted in prose) — team-lead
# decision: prefer recall over precision here, do not add an entropy/charset
# heuristic to chase 0 FP, since that also kills real all-alphabetic passphrases like
# "password=correcthorse". Trailing sentence punctuation is trimmed in
# analyze_regex(), not here, since the regex alone can't distinguish "part of the
# secret" from "end of sentence" — and analyze_regex() keeps the UNTRIMMED span
# rather than dropping the entity if trimming would take it under the 6-char floor
# (over-redacting a trailing period is strictly safer than leaking the value).
_GENERIC_SECRET_PATTERN = (
    r"(?i)\b(?:access_token|client_secret|password|passwd|secret|token)"
    r"['\"`]?\s*(?:=>|[:=])\s*['\"`]?"
    r"(?!(?:null|undefined|none|nil|redacted|masked|hidden|empty)\b)"
    rf"(?!(?-i:<(?:{_KNOWN_ENTITY_TAGS})>))"
    r"([^\s'\"`]{6,})['\"`]?"
)

FALLBACK_PATTERNS = _STANDARD_FALLBACK_PATTERNS + [
    ("GENERIC_SECRET", _GENERIC_SECRET_PATTERN),
]

# F2: Precompile FALLBACK_PATTERNS at module load to avoid per-call re.compile overhead.
_COMPILED_PATTERNS: list[tuple[str, re.Pattern]] = [
    (etype, re.compile(pat, re.IGNORECASE)) for etype, pat in FALLBACK_PATTERNS
]

# F3: Fast short-circuit — skip regex scan entirely when text contains none of the
# characters/prefixes that any FALLBACK_PATTERNS entry can match.
#
# Superset coverage rationale (one entry per pattern):
#   EMAIL_ADDRESS  → @
#   PHONE_NUMBER   → \d
#   US_SSN         → \d
#   CREDIT_CARD    → \d
#   IP_ADDRESS     → \d
#   AWS_ACCESS_KEY → AKIA  (the AKIA followed by [0-9A-Z]{16} body may be ALL LETTERS —
#                    a digit is NOT guaranteed; the explicit "AKIA" prefix is the trigger)
#   GITHUB_TOKEN   → ghp_|gho_|ghu_|ghs_|ghr_|github_pat_  (pure-alpha prefix, no digits/@ required)
#   ANTHROPIC_KEY  → sk-
#   OPENAI_KEY     → sk-
#   BEARER_TOKEN   → bearer\s  (keyword; value may be pure-alpha with no digit/@)
#   JWT            → eyJ
#   DATABASE_URL   → /  (scheme://user:pass@host always has /)
#   PRIVATE_KEY    → BEGIN  (the [A-Z ]+ body between "BEGIN" and "PRIVATE KEY"/
#                    "CERTIFICATE" is letters-OR-spaces, so a space right after
#                    BEGIN is NOT guaranteed, e.g. "-----BEGINRSA PRIVATE KEY-----"
#                    matches the pattern with no whitespace touching "BEGIN" —
#                    trigger on the bare literal, not "BEGIN\s")
#   API_KEY        → api.{0,1}key or x-api-key  (keyword; value may be pure-alpha)
#   ABSOLUTE_PATH  → /
#   BITBUCKET_URL  → /
#   SLACK_WEBHOOK  → /
#   STRIPE_KEY     → sk_|pk_|rk_  (prefix is pure-alpha+underscore, no digit/@//sk- guaranteed)
#   SLACK_TOKEN    → xox[abprs]-  (bot/user/etc token prefix, distinct from the sk- OPENAI_KEY trigger)
#   NPM_TOKEN      → npm_  (prefix alone; the 36+-char body may be pure-alpha with no digit)
#   SENDGRID_KEY   → SG\.  (prefix; body segments may be pure-alpha)
#   GOOGLE_API_KEY → AIza  (prefix; 35-char body may be pure-alpha)
#   RESEND_KEY     → \d  (the body requires a digit, so the existing \d trigger already covers it;
#                    no re_ trigger — it would widen exposure to the quadratic EMAIL_ADDRESS regex)
#   GITLAB_TOKEN   → gl(?:pat|oas|...)-  (prefix; body may be pure-alpha)
#   VENDOR_TOKEN_ASSIGNMENT → token  (keyword, already covered by the GENERIC_SECRET trigger)
#   GENERIC_SECRET → password|passwd|secret|token  (keyword; "client_secret" is caught via
#                    "secret" and "access_token" via "token" — value may be pure-alpha, e.g.
#                    password=hunter has no @, digit, or / and would be missed without this)
#
# GITHUB_TOKEN, BEARER_TOKEN, and API_KEY can all match text with no @, digit, /, sk-, eyJ, or
# BEGIN, so their keyword prefixes are added explicitly to ensure the candidate is a
# strict superset of every pattern's trigger set.
#
# BEGIN (not BEGIN\s): the \s was dropped because it was not actually guaranteed (see
# PRIVATE_KEY rationale above) — widening the trigger only makes the regex SCAN run in
# more cases, which is always safe: _PII_CANDIDATES only gates whether the scan runs at
# all, never what gets redacted, so a wider trigger can only turn a false negative
# (dead pattern) into a correct detection or a harmless extra scan — it cannot itself
# cause a false redaction (that's solely decided by FALLBACK_PATTERNS matching or not).
_PII_CANDIDATES: re.Pattern = re.compile(
    r'[@\d/]|sk-|eyJ|BEGIN|AKIA'
    r'|(?:ghp|gho|ghu|ghs|ghr|github_pat)_'
    r'|bearer\s'
    r'|api[_\-]?key|x-api-key'
    r'|sk_|pk_|rk_'
    r'|xox[abprs]-'
    r'|npm_'
    r'|SG\.'
    r'|AIza'
    r'|gl(?:pat|oas|dt|rtr?|cbt|ptt|ft|imt|agent|wt|soat|ffct)-'
    r'|password|passwd|secret|token',
    re.IGNORECASE,
)


def load_custom_patterns(patterns_file: str) -> list[dict]:
    """Load custom regex patterns from the CAST pii-patterns.json config."""
    if not os.path.exists(patterns_file):
        return []
    try:
        with open(patterns_file) as f:
            config = json.load(f)
        return config.get("patterns", [])
    except Exception as e:
        print(f"[cast-redact] Warning: could not load patterns from {patterns_file}: {e}", file=sys.stderr)
        return []


def build_presidio_analyzer(custom_patterns: list[dict]):
    """Build a Presidio AnalyzerEngine with built-in + custom recognizers."""
    from presidio_analyzer import AnalyzerEngine, Pattern, PatternRecognizer

    analyzer = AnalyzerEngine()

    for p in custom_patterns:
        try:
            regex = p.get("regex", "")
            entity_type = p.get("entity_type", "CUSTOM")
            score = float(p.get("score", 0.7))
            name = p.get("name", entity_type)

            pattern = Pattern(name=name, regex=regex, score=score)
            recognizer = PatternRecognizer(
                supported_entity=entity_type,
                patterns=[pattern],
                name=f"custom_{name}",
            )
            analyzer.registry.add_recognizer(recognizer)
        except Exception as e:
            print(f"[cast-redact] Warning: skipping custom pattern '{p.get('name', '?')}': {e}", file=sys.stderr)

    return analyzer


def analyze_presidio(text: str, custom_patterns: list[dict]) -> tuple[Any, list[dict]]:
    """Run Presidio analysis. Returns (analyzer_results, entity_dicts)."""
    from presidio_analyzer import AnalyzerEngine  # noqa: F401 — verify importable

    analyzer = build_presidio_analyzer(custom_patterns)
    results = analyzer.analyze(text=text, language="en")

    entities = []
    for r in results:
        original = text[r.start:r.end]
        entities.append({
            "entity_type": r.entity_type,
            "start": r.start,
            "end": r.end,
            "score": round(r.score, 4),
            "original": original,
            "original_hash": _hash16(original),
        })

    return results, entities


def redact_presidio(text: str, analyzer_results, mode: str) -> str:
    """Apply Presidio anonymizer to replace detected entities."""
    from presidio_anonymizer import AnonymizerEngine
    from presidio_anonymizer.entities import OperatorConfig

    anonymizer = AnonymizerEngine()

    if mode == "mask":
        operators = {
            "DEFAULT": OperatorConfig("mask", {"chars_to_mask": 999, "masking_char": "*", "from_end": False})
        }
    else:
        # redact mode: replace with <ENTITY_TYPE>
        operators = {"DEFAULT": OperatorConfig("replace", {"new_value": None})}
        # None new_value means Presidio uses the default "<ENTITY_TYPE>" format

    result = anonymizer.anonymize(text=text, analyzer_results=analyzer_results, operators=operators)
    return result.text


def _normalized_view(text: str) -> tuple[str, list[int] | None]:
    """Return (view, index_map) where view is NFKC(text) with every Unicode `Cf`
    (format), `Mn` (combining mark) and `Me` (enclosing mark) char removed, and
    index_map[i] is the index in `text` of the source char that produced view[i].  Returns (text, None) when the view equals the text
    (all plain ASCII, the common case, short-circuits without allocating a map).

    Why: a zero-width / format char (U+200B/C/D, U+2060, U+FEFF, U+00AD ...) spliced
    into a secret, or fullwidth/compatibility forms, evade the ASCII-oriented
    FALLBACK_PATTERNS.  NFKC is applied PER CHARACTER so every view char maps back to
    exactly one source char; callers translate view spans to original-text spans via
    the map, so the text that is finally redacted is NEVER normalised -- non-secret
    text (cafe, CJK, ligatures, invisible chars outside a secret) is returned
    byte-for-byte.

    Boundaries, by design: stripped chars INSIDE a match are covered by the mapped span
    and TRAILING ones glued to its end are absorbed (see analyze_regex), but LEADING
    Cf/Mn/Me chars before a match are NOT absorbed -- they are invisible/combining, carry
    no secret material, and the output must change as little as possible.
    """
    if text.isascii():
        return text, None
    chars: list[str] = []
    idx: list[int] = []
    for i, ch in enumerate(text):
        # No pre-NFKC skip of stripped-category chars: verified over all of Unicode that no
        # Cf/Mn/Me char NFKC-maps to anything outside those categories, so the per-output
        # filter below already drops them.  That filter IS load-bearing: e.g. U+FF9E
        # (halfwidth voiced sound mark, Lm) NFKC-maps to U+3099 (Mn), which must go.
        for n in unicodedata.normalize("NFKC", ch):
            if unicodedata.category(n) not in _VIEW_STRIPPED_CATEGORIES:
                chars.append(n)
                idx.append(i)
    view = "".join(chars)
    if view == text:
        return text, None
    return view, idx


def _scan(text: str, compiled: list[tuple[str, re.Pattern]]) -> list[tuple[str, int, int]]:
    """Run compiled patterns over `text`; return (entity_type, start, end) spans
    in `text` coordinates, in pattern-then-finditer order (the pre-existing order)."""
    found: list[tuple[str, int, int]] = []
    for entity_type, pattern in compiled:
        try:
            for m in pattern.finditer(text):
                # Use group 1 if capturing group, else full match
                start = m.start(1) if m.lastindex else m.start()
                end = m.end(1) if m.lastindex else m.end()
                if entity_type == "GENERIC_SECRET":
                    # Trim trailing sentence punctuation (period/comma/close-paren) that
                    # the denylist value charset would otherwise swallow into the redacted
                    # span — e.g. "(password=Secret123)." must not capture ")." as part of
                    # the secret. Deliberately does NOT trim "!" or similar — those are
                    # common in real passwords and should stay inside the redaction.
                    # If trimming would take the span under the 6-char floor, KEEP the
                    # untrimmed span rather than discarding the entity — security found
                    # (2026-08-16) that "The password=Abcde." was dropping to zero
                    # entities entirely (a full plaintext leak), which is strictly worse
                    # than over-redacting a trailing period.
                    trimmed_end = end
                    while trimmed_end > start and text[trimmed_end - 1] in ".,)":
                        trimmed_end -= 1
                    if trimmed_end - start >= 6:
                        end = trimmed_end
                found.append((entity_type, start, end))
        except re.error:
            continue
    return found


def _union_same_type_view_spans(
    raw: list[tuple[str, int, int]], view: list[tuple[str, int, int]]
) -> list[tuple[str, int, int]]:
    """Combine raw-text spans with mapped view spans, in discovery order (raw first).

    A view span usually re-finds a raw match but a little wider (it absorbs the invisible
    chars the raw regex stopped at), which would otherwise be reported as TWO entities and
    inflate entity_count.  Same-entity-type spans that overlap or touch AND include at
    least one view span are replaced by their union.  Groups made only of raw spans (all
    that exists for plain ASCII) are left exactly as the raw scan produced them, and
    different-type overlaps are untouched (redact_regex merges those).
    """
    tagged = [(t, s, e, False) for t, s, e in raw] + [(t, s, e, True) for t, s, e in view]
    if not view:
        return [(t, s, e) for t, s, e, _ in tagged]
    by_type: dict[str, list[tuple[int, int, bool, int]]] = {}
    for n, (t, s, e, v) in enumerate(tagged):
        by_type.setdefault(t, []).append((s, e, v, n))
    out: list[tuple[int, str, int, int]] = []

    def flush(t: str, group: list[tuple[int, int, bool, int]]) -> None:
        if len(group) > 1 and any(v for _, _, v, _ in group):
            out.append((min(n for *_, n in group), t,
                        min(s for s, *_ in group), max(e for _, e, *_ in group)))
        else:
            out.extend((n, t, s, e) for s, e, _, n in group)

    for t, items in by_type.items():
        items.sort()
        group = [items[0]]
        group_end = items[0][1]
        for it in items[1:]:
            if it[0] <= group_end:  # overlap or adjacent
                group.append(it)
                group_end = max(group_end, it[1])
            else:
                flush(t, group)
                group, group_end = [it], it[1]
        flush(t, group)
    return [(t, s, e) for _, t, s, e in sorted(out)]


def analyze_regex(text: str, custom_patterns: list[dict]) -> list[dict]:
    """Fallback: detect PII using built-in + custom regex patterns.

    F3: short-circuits immediately when text lacks any characters that could
    trigger a FALLBACK_PATTERNS match (see _PII_CANDIDATES superset rationale above).
    F2: uses precompiled _COMPILED_PATTERNS rather than compiling per-call.

    Unicode evasion (S4-1 R1): patterns run over BOTH the raw text and, for non-ASCII
    text, an NFKC + Cf-stripped view (see _normalized_view); view spans are mapped back
    to original-text offsets.  The result is the UNION, so detection only ever widens
    relative to raw-text matching, and plain-ASCII input takes the exact pre-existing
    path.  Entity offsets/`original` always refer to the ORIGINAL text.
    """
    view, idx = _normalized_view(text)

    # F3: fast exit — no PII trigger characters present in text (or its normalised view)
    if not _PII_CANDIDATES.search(text) and (idx is None or not _PII_CANDIDATES.search(view)):
        return []

    # F2: use precompiled built-in patterns; compile custom patterns on demand
    compiled: list[tuple[str, re.Pattern]] = list(_COMPILED_PATTERNS)
    for p in custom_patterns:
        entity_type = p.get("entity_type", "CUSTOM")
        regex = p.get("regex", "")
        if regex:
            try:
                compiled.append((entity_type, re.compile(regex, re.IGNORECASE)))
            except re.error:
                continue

    spans = _scan(text, compiled)
    view_spans: list[tuple[str, int, int]] = []
    if idx is not None:
        for entity_type, vstart, vend in _scan(view, compiled):
            if vend <= vstart:
                # Zero-width view match: no source chars to cover; map to a point.
                ostart = oend = idx[vstart] if vstart < len(idx) else len(text)
            else:
                ostart, oend = idx[vstart], idx[vend - 1] + 1
                # Also swallow stripped chars (Cf/Mn) glued to the end of the secret, so a
                # trailing combining mark does not survive as an orphan next to the tag.
                while oend < len(text) and unicodedata.category(text[oend]) in _VIEW_STRIPPED_CATEGORIES:
                    oend += 1
            view_spans.append((entity_type, ostart, oend))

    entities = []
    seen_spans = set()
    # Raw-text matches come first, in the original pattern order; first span wins.
    for entity_type, start, end in _union_same_type_view_spans(spans, view_spans):
        span = (start, end)
        if span in seen_spans:
            continue
        seen_spans.add(span)
        original = text[start:end]
        entities.append({
            "entity_type": entity_type,
            "start": start,
            "end": end,
            "score": 0.8,
            "original": original,
            "original_hash": _hash16(original),
        })

    return sorted(entities, key=lambda e: e["start"])


# Custom replacement strings for specific entity types (redact mode only).
# Entities not listed here fall back to the standard <ENTITY_TYPE> format.
_CUSTOM_REPLACEMENTS: dict[str, str] = {
    "ABSOLUTE_PATH": "~/",
    "BITBUCKET_URL": "[BITBUCKET_URL]",
    "SLACK_WEBHOOK": "[SLACK_WEBHOOK]",
}


def _merge_overlapping_spans(entities: list[dict]) -> list[dict]:
    """Merge overlapping/nested entity spans into non-overlapping spans.

    analyze_regex does NOT guarantee non-overlapping spans (e.g. an IP_ADDRESS
    nested inside a DATABASE_URL) — redact_regex previously assumed it did, and
    spliced text at the ORIGINAL (pre-shift) offsets after an inner replacement's
    length delta had already shifted the string, leaking a plaintext tail of the
    outer secret. Merging spans here restores the precondition redact_regex needs.

    Where one span contains another, the OUTER (broader) span's entity_type wins.
    For partial (non-nesting) overlaps, the WIDEST constituent span's entity_type
    wins the replacement tag for the unioned range.

    Only used internally by redact_regex for text substitution — the caller's
    original `entities` list (used for reporting/counts elsewhere) is untouched.
    """
    if not entities:
        return []
    ordered = sorted(entities, key=lambda e: (e["start"], -(e["end"] - e["start"])))
    merged: list[dict] = []
    for e in ordered:
        width = e["end"] - e["start"]
        if merged and e["start"] < merged[-1]["end"]:
            prev = merged[-1]
            if e["end"] > prev["end"]:
                prev["end"] = e["end"]
            if width > prev["_width"]:
                prev["_width"] = width
                prev["entity_type"] = e["entity_type"]
        else:
            merged.append({"start": e["start"], "end": e["end"], "entity_type": e["entity_type"], "_width": width})
    for m in merged:
        del m["_width"]
    return merged


def redact_regex(text: str, entities: list[dict], mode: str) -> str:
    """Apply redactions to text based on entity spans, right-to-left.

    Spans are merged first (see _merge_overlapping_spans) since analyze_regex
    does not guarantee non-overlapping spans. Processing the merged, now
    non-overlapping spans right-to-left keeps earlier spans valid after each
    substitution. Uses string slicing (immutable str) rather than list mutation
    to avoid index drift when replacement length differs from original span.
    """
    merged = _merge_overlapping_spans(entities)
    result = text
    for entity in sorted(merged, key=lambda e: e["start"], reverse=True):
        start, end = entity["start"], entity["end"]
        if mode == "mask":
            replacement = "*" * (end - start)
        else:
            replacement = _CUSTOM_REPLACEMENTS.get(entity["entity_type"], f"<{entity['entity_type']}>")
        result = result[:start] + replacement + result[end:]
    return result


def _emit(output: dict, field: str | None = None) -> None:
    """Print output as JSON (default) or as a single plain-text field (--field mode).

    In --field mode:
      - field present: print its value as plain text, then exit 0
      - field absent:  print nothing, exit 1 (triggers the caller's ``|| fallback``)

    Default behavior (field=None) is byte-identical to the prior ``print(json.dumps(output))``
    so existing callers and tests are unaffected.
    """
    if field is not None:
        if field not in output:
            sys.exit(1)
        print(output[field])
        sys.exit(0)
    print(json.dumps(output, ensure_ascii=False))


def _run_hook_mode() -> None:
    """Claude Code PreToolUse hook mode.

    Contract:
      - exit 0, no stdout  → silent allow (no PII found)
      - exit 2, one-line   → block the tool call (PII detected)

    Never prints JSON. Never raises an unhandled exception. Only input that is not valid
    JSON at all (empty, whitespace, truncated, garbled -> json.JSONDecodeError) is allowed
    (exit 0); every other parse failure (RecursionError, MemoryError, the 4300-digit int
    ValueError, invalid UTF-8, ...) fails closed (exit 2).
    """
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
    except json.JSONDecodeError:
        # Not JSON at all (empty, whitespace, truncated, garbled) — allow silently.
        # Deliberately NOT ValueError/UnicodeDecodeError: JSONDecodeError is the only
        # failure that proves there is no parseable payload to hold a secret.
        sys.exit(0)
    except Exception as exc:
        # Anything else is NOT "malformed input": the payload may well carry a secret.
        # Includes RecursionError (deep nesting), MemoryError, the int-digit-limit
        # ValueError (3.11+: JSON integer literal > 4300 digits), and UnicodeDecodeError
        # (Claude Code always sends valid UTF-8, so blocking it cannot false-positive).
        # Fail closed.
        print(
            f"[CAST-REDACT] Blocked: could not parse tool input ({type(exc).__name__}); failing closed.",
            file=sys.stderr,
        )
        sys.exit(2)

    # FAIL CLOSED: any error while analysing (lone surrogates, non-dict payload, ...) must
    # BLOCK.  An uncaught exception exits 1, which Claude Code treats as non-blocking, so a
    # co-located real secret would pass.  SystemExit/KeyboardInterrupt are not `Exception`
    # and still propagate (the sys.exit(0) "clean" path below relies on that).
    try:
        tool_name = data.get("tool_name", "")
        tool_input = data.get("tool_input", {})

        # Extract the text to scan
        if tool_name == "Bash":
            text = tool_input.get("command", "") if isinstance(tool_input, dict) else ""
        else:
            # ensure_ascii=False: this text is ANALYSED only (never stored/returned), and the
            # default ensure_ascii=True would turn a zero-width char inside a secret into the
            # ASCII text `\\u200b`, hiding it from analyze_regex's Unicode-evasion view.
            text = json.dumps(tool_input, ensure_ascii=False) if tool_input is not None else ""

        if not text or not text.strip():
            sys.exit(0)

        # Detection only — regex engine for speed (no Presidio startup cost in hook path)
        entities = analyze_regex(text, [])
        entities = [e for e in entities if e["score"] >= 0.5]

        # Strip known-safe system addresses (git attribution, CI bots) before blocking.
        # Exact-match set — avoids substring bypass (e.g. noreply@anthropic.com.badactor.com).
        _SAFE_EMAILS = {"noreply@anthropic.com", "noreply@github.com", "actions@github.com"}
        entities = [e for e in entities if e["original"].lower() not in _SAFE_EMAILS]
    except Exception as exc:
        print(
            f"[CAST-REDACT] Blocked: could not analyse tool input ({type(exc).__name__}); failing closed.",
            file=sys.stderr,
        )
        sys.exit(2)

    if not entities:
        sys.exit(0)

    # PII detected — write audit entry then block
    entity_types = sorted(set(e["entity_type"] for e in entities))

    audit_path = os.path.expanduser("~/.claude/logs/audit.jsonl")
    try:
        os.makedirs(os.path.dirname(audit_path), exist_ok=True)
        entry = {
            "timestamp": datetime.now(tz=timezone.utc).isoformat().replace("+00:00", "Z"),
            "tool": tool_name,
            "destination": "cloud",
            "redacted": True,
            "entity_types": entity_types,
        }
        with open(audit_path, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass  # Audit write failure must never block the block itself

    print(
        f"[CAST-REDACT] Blocked: PII detected in {tool_name} — "
        f"{', '.join(entity_types)}. Remove before running.",
        file=sys.stderr,
    )
    sys.exit(2)


def main():
    parser = argparse.ArgumentParser(
        description="CAST PII redaction using Microsoft Presidio",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--text", help="Input text to redact (alternative to stdin)")
    parser.add_argument("--file", help="Input file to redact")
    parser.add_argument(
        "--mode",
        choices=["redact", "analyze", "mask"],
        default="redact",
        help="redact=replace with <TAG>, analyze=detect only, mask=replace with ***",
    )
    parser.add_argument(
        "--patterns-file",
        default=PATTERNS_CONFIG,
        help=f"Path to pii-patterns.json (default: {PATTERNS_CONFIG})",
    )
    parser.add_argument(
        "--engine",
        choices=["auto", "presidio", "regex"],
        default="auto",
        help="Detection engine: auto tries Presidio first, falls back to regex",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.5,
        help="Minimum confidence score to redact (0.0–1.0, default: 0.5)",
    )
    parser.add_argument(
        "--hook",
        action="store_true",
        help=(
            "Run as a Claude Code PreToolUse hook: "
            "exit 0 (no stdout) when clean, exit 2 (plain-text reason) when PII found"
        ),
    )
    parser.add_argument(
        "--field",
        metavar="NAME",
        default=None,
        help=(
            "Print a single field from the output dict as plain text (no JSON wrapper). "
            "Exits non-zero if the field is absent (triggers caller's || fallback). "
            "Use to collapse two-process pipes into one invocation."
        ),
    )
    args = parser.parse_args()

    # ── Hook mode (PreToolUse) ─────────────────────────────────────────────────
    if args.hook:
        _run_hook_mode()
        return

    # ── Read input ─────────────────────────────────────────────────────────────
    if args.file:
        try:
            with open(args.file) as f:
                text = f.read()
        except Exception as e:
            _emit({"error": str(e)}, args.field)
            sys.exit(1)
    elif args.text:
        text = args.text
    elif not sys.stdin.isatty():
        text = sys.stdin.read()
    else:
        parser.print_help()
        sys.exit(1)

    if not text.strip():
        _emit({
            "redacted_text": text,
            "entities": [],
            "entity_count": 0,
            "mode": args.mode,
            "engine": "none",
        }, args.field)
        return

    # F4: texts under 10 chars cannot contain any supported PII pattern — skip engines entirely.
    if len(text) < 10:
        _emit({
            "redacted_text": text,
            "entities": [],
            "entity_count": 0,
            "mode": args.mode,
            "engine": "none",
        }, args.field)
        return

    # ── Load custom patterns ───────────────────────────────────────────────────
    custom_patterns = load_custom_patterns(args.patterns_file)

    # ── Detect + Redact ────────────────────────────────────────────────────────
    engine_used = "regex-fallback"
    entities = []
    redacted_text = text

    presidio_available = False
    if args.engine in ("auto", "presidio"):
        try:
            import presidio_analyzer  # noqa: F401
            import presidio_anonymizer  # noqa: F401
            presidio_available = True
        except ImportError:
            if args.engine == "presidio":
                print(
                    "[cast-redact] Error: presidio not installed. Run: pip install presidio-analyzer presidio-anonymizer",
                    file=sys.stderr,
                )
                sys.exit(1)
            # else: silently fall through to regex

    if presidio_available and args.engine != "regex":
        try:
            analyzer_results, entities = analyze_presidio(text, custom_patterns)
            # Apply threshold filter
            entities = [e for e in entities if e["score"] >= args.threshold]
            if args.mode != "analyze":
                # Re-filter analyzer_results to match threshold
                filtered_results = [r for r in analyzer_results if r.score >= args.threshold]
                redacted_text = redact_presidio(text, filtered_results, args.mode)
            engine_used = "presidio"
        except Exception as e:
            print(f"[cast-redact] Presidio error, falling back to regex: {e}", file=sys.stderr)
            # fall through to regex
            presidio_available = False

    if not presidio_available or args.engine == "regex":
        entities = analyze_regex(text, custom_patterns)
        entities = [e for e in entities if e["score"] >= args.threshold]
        if args.mode != "analyze":
            redacted_text = redact_regex(text, entities, args.mode)
        engine_used = "regex-fallback"

    # ── Output ─────────────────────────────────────────────────────────────────
    output = {
        "redacted_text": redacted_text if args.mode != "analyze" else text,
        "entities": entities,
        "entity_count": len(entities),
        "mode": args.mode,
        "engine": engine_used,
    }

    if args.mode == "analyze":
        output["note"] = "analyze mode: text unchanged, entities listed only"

    _emit(output, args.field)


if __name__ == "__main__":
    main()
