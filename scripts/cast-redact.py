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

import sys
import json
import re
import hashlib
import argparse
import os
from typing import Any

PATTERNS_CONFIG = os.path.expanduser("~/.claude/config/pii-patterns.json")

# ── Built-in fallback regex patterns (used when Presidio is unavailable) ─────

FALLBACK_PATTERNS = [
    # Standard PII
    ("EMAIL_ADDRESS",   r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"),
    ("PHONE_NUMBER",    r"\b(?:\+1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b"),
    ("US_SSN",          r"\b\d{3}-\d{2}-\d{4}\b"),
    ("CREDIT_CARD",     r"\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13}|6011[0-9]{12}|3(?:0[0-5]|[68][0-9])[0-9]{11})\b"),
    ("IP_ADDRESS",      r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
    # Secrets / tokens
    ("AWS_ACCESS_KEY",  r"(?<![A-Z0-9])(AKIA[0-9A-Z]{16})(?![A-Z0-9])"),
    ("GITHUB_TOKEN",    r"(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{36,}"),
    ("ANTHROPIC_KEY",   r"sk-ant-[A-Za-z0-9_\-]{32,}"),
    ("OPENAI_KEY",      r"sk-(?:proj-)?[A-Za-z0-9]{32,}"),
    ("BEARER_TOKEN",    r"(?i)bearer\s+([A-Za-z0-9_\-\.]{20,})"),
    ("JWT",             r"eyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"),
    ("DATABASE_URL",    r"(?i)(?:postgres|mysql|mongodb|redis)(?:ql)?://[^:@\s]+:[^@\s]+@[^\s]+"),
    ("PRIVATE_KEY",     r"-----BEGIN[A-Z ]+(?:PRIVATE KEY|CERTIFICATE)-----"),
    ("API_KEY",         r"(?i)(?:api[_-]?key|apikey|x-api-key)[:\s=]+['\"]?([A-Za-z0-9_\-]{20,})['\"]?"),
]


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
            "original_hash": hashlib.sha256(original.encode()).hexdigest()[:16],
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


def analyze_regex(text: str, custom_patterns: list[dict]) -> list[dict]:
    """Fallback: detect PII using built-in + custom regex patterns."""
    all_patterns = list(FALLBACK_PATTERNS)
    for p in custom_patterns:
        entity_type = p.get("entity_type", "CUSTOM")
        regex = p.get("regex", "")
        if regex:
            all_patterns.append((entity_type, regex))

    entities = []
    seen_spans = set()

    for entity_type, pattern in all_patterns:
        try:
            for m in re.finditer(pattern, text, re.IGNORECASE):
                # Use group 1 if capturing group, else full match
                start = m.start(1) if m.lastindex else m.start()
                end = m.end(1) if m.lastindex else m.end()
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
                    "original_hash": hashlib.sha256(original.encode()).hexdigest()[:16],
                })
        except re.error:
            continue

    return sorted(entities, key=lambda e: e["start"])


def redact_regex(text: str, entities: list[dict], mode: str) -> str:
    """Apply redactions to text based on entity spans (non-overlapping, right-to-left).

    Processes entities right-to-left so earlier spans remain valid after each
    substitution. Uses string slicing (immutable str) rather than list mutation
    to avoid index drift when replacement length differs from original span.
    """
    result = text
    for entity in sorted(entities, key=lambda e: e["start"], reverse=True):
        start, end = entity["start"], entity["end"]
        replacement = "*" * (end - start) if mode == "mask" else f"<{entity['entity_type']}>"
        result = result[:start] + replacement + result[end:]
    return result


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
    args = parser.parse_args()

    # ── Read input ─────────────────────────────────────────────────────────────
    if args.file:
        try:
            with open(args.file) as f:
                text = f.read()
        except Exception as e:
            print(json.dumps({"error": str(e)}))
            sys.exit(1)
    elif args.text:
        text = args.text
    elif not sys.stdin.isatty():
        text = sys.stdin.read()
    else:
        parser.print_help()
        sys.exit(1)

    if not text.strip():
        print(json.dumps({
            "redacted_text": text,
            "entities": [],
            "entity_count": 0,
            "mode": args.mode,
            "engine": "none",
        }))
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

    print(json.dumps(output, ensure_ascii=False))


if __name__ == "__main__":
    main()
