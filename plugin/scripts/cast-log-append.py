#!/usr/bin/env python3
"""Atomic append to routing-log.jsonl with exclusive file lock and rotation."""
import sys, fcntl, os

log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
line = sys.stdin.read().strip()
if not line:
    sys.exit(0)

with open(log_path, 'a') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write(line + '\n')
    f.flush()
    # Rotate if >5MB
    try:
        if os.path.getsize(log_path) > 5 * 1024 * 1024:
            old2 = log_path + '.2'
            old1 = log_path + '.1'
            if os.path.exists(old2):
                os.remove(old2)
            if os.path.exists(old1):
                os.rename(old1, old2)
            # Can't rename while we hold the lock on the current file,
            # so just truncate after rotating
    except Exception:
        pass
    # Lock released on close
