#!/usr/bin/env python3
"""CAST Research Cache — file-based URL cache for the researcher agent."""

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

CACHE_DIR = Path(os.path.expanduser("~/.claude/cast/research-cache"))


def cache_key(url: str) -> str:
    return hashlib.sha256(url.encode()).hexdigest()


def cache_path(url: str) -> Path:
    return CACHE_DIR / f"{cache_key(url)}.json"


def cmd_get(url: str, ttl: int) -> int:
    path = cache_path(url)
    if not path.exists():
        return 1
    try:
        entry = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return 1
    if time.time() - entry.get("timestamp", 0) > ttl:
        return 1
    print(entry["content"], end="")
    return 0


def cmd_put(url: str) -> int:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    content = sys.stdin.read()
    entry = {
        "url": url,
        "content": content,
        "timestamp": time.time(),
        "content_length": len(content),
    }
    cache_path(url).write_text(json.dumps(entry))
    return 0


def cmd_stats() -> int:
    if not CACHE_DIR.exists():
        print("Cache directory does not exist. No entries.")
        return 0
    entries = list(CACHE_DIR.glob("*.json"))
    if not entries:
        print("Cache is empty.")
        return 0
    total_size = sum(e.stat().st_size for e in entries)
    timestamps = []
    for e in entries:
        try:
            data = json.loads(e.read_text())
            timestamps.append(data.get("timestamp", 0))
        except (json.JSONDecodeError, OSError):
            pass
    oldest = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(min(timestamps))) if timestamps else "N/A"
    newest = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(max(timestamps))) if timestamps else "N/A"
    print(f"Entries: {len(entries)}")
    print(f"Total size: {total_size:,} bytes")
    print(f"Oldest: {oldest}")
    print(f"Newest: {newest}")
    return 0


def cmd_clear() -> int:
    if not CACHE_DIR.exists():
        print("Nothing to clear.")
        return 0
    count = 0
    for f in CACHE_DIR.glob("*.json"):
        f.unlink()
        count += 1
    print(f"Cleared {count} cache entries.")
    return 0


def main():
    parser = argparse.ArgumentParser(description="CAST Research Cache — URL result cache for researcher agent")
    parser.add_argument("--get", metavar="URL", help="Get cached content for URL (exit 1 on miss)")
    parser.add_argument("--put", metavar="URL", help="Cache content from stdin for URL")
    parser.add_argument("--stats", action="store_true", help="Show cache statistics")
    parser.add_argument("--clear", action="store_true", help="Clear all cached entries")
    parser.add_argument("--ttl", type=int, default=3600, help="Cache TTL in seconds (default: 3600)")
    args = parser.parse_args()

    if args.get:
        sys.exit(cmd_get(args.get, args.ttl))
    elif args.put:
        sys.exit(cmd_put(args.put))
    elif args.stats:
        sys.exit(cmd_stats())
    elif args.clear:
        sys.exit(cmd_clear())
    else:
        parser.print_help()
        sys.exit(0)


if __name__ == "__main__":
    main()
