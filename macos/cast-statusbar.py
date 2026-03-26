#!/usr/bin/env python3
# cast-statusbar.py — CAST macOS menu bar status app
#
# Purpose:
#   Provides real-time CAST daemon/agent status in the macOS menu bar.
#   Polls ~/.claude/cast/castd.state and ~/.claude/agent-status/ every 5 seconds.
#   Fires native notifications for entries in ~/.claude/cast/notify-queue.json.
#
# Install:
#   cp cast-statusbar.py ~/.local/share/cast/
#   pip3 install rumps
#   See cast-statusbar.plist for launchd setup.

import json
import os
import subprocess
import webbrowser
from datetime import datetime
from pathlib import Path

try:
    import rumps
    RUMPS_AVAILABLE = True
except ImportError:
    RUMPS_AVAILABLE = False
    print("ERROR: rumps not installed. Run: pip3 install rumps", flush=True)
    raise SystemExit(1)

CAST_DIR = Path.home() / ".claude" / "cast"
AGENT_STATUS_DIR = Path.home() / ".claude" / "agent-status"
CASTD_STATE_FILE = CAST_DIR / "castd.state"
BUDGET_FILE = CAST_DIR / "budget-today.json"
QUEUE_COUNT_FILE = CAST_DIR / "queue-count"
NOTIFY_QUEUE_FILE = CAST_DIR / "notify-queue.json"
CAST_BIN = Path.home() / ".local" / "bin" / "cast"

TITLE_IDLE = "\u26a1 CAST"
TITLE_RUNNING = "\u2699 CAST"
TITLE_DOWN = "\u26a0 CAST"

MAX_NOTIFY_ENTRIES = 50


def _read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def _daemon_running() -> bool:
    state = _read_json(CASTD_STATE_FILE, {})
    return state.get("status") == "running"


def _active_agents() -> list[str]:
    if not AGENT_STATUS_DIR.exists():
        return []
    active = []
    for f in AGENT_STATUS_DIR.glob("*.json"):
        data = _read_json(f, {})
        if data.get("status") in ("IN_PROGRESS", "running"):
            active.append(data.get("agent", f.stem))
    return active


def _recent_completions(limit: int = 5) -> list[dict]:
    if not AGENT_STATUS_DIR.exists():
        return []
    files = sorted(
        AGENT_STATUS_DIR.glob("*.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    results = []
    for f in files[:limit * 3]:
        data = _read_json(f, {})
        if data.get("status") in ("DONE", "DONE_WITH_CONCERNS"):
            results.append(data)
        if len(results) >= limit:
            break
    return results


def _budget_str() -> str:
    budget = _read_json(BUDGET_FILE, {})
    if not budget:
        return "Budget today: unavailable"
    spent = budget.get("spent", 0.0)
    limit = budget.get("limit", 0.0)
    return f"Budget today: ${spent:.2f} / ${limit:.2f}"


def _queue_count() -> int:
    try:
        return int(QUEUE_COUNT_FILE.read_text().strip())
    except Exception:
        return 0


def _drain_notify_queue() -> list[dict]:
    entries = _read_json(NOTIFY_QUEUE_FILE, [])
    if not isinstance(entries, list) or not entries:
        return []
    unread = [e for e in entries if not e.get("delivered")]
    if not unread:
        return []
    for e in unread:
        e["delivered"] = True
    try:
        NOTIFY_QUEUE_FILE.write_text(json.dumps(entries[-MAX_NOTIFY_ENTRIES:], indent=2))
    except Exception:
        pass
    return unread


class CastStatusBar(rumps.App):
    def __init__(self):
        super().__init__(TITLE_IDLE, quit_button=None)
        self._last_notify_check: list[str] = []

    def _build_menu(self):
        daemon_ok = _daemon_running()
        active = _active_agents()

        # Title
        if not daemon_ok:
            self.title = TITLE_DOWN
        elif active:
            self.title = TITLE_RUNNING
        else:
            self.title = TITLE_IDLE

        # Daemon status item (disabled)
        daemon_label = "Daemon: running" if daemon_ok else "Daemon: stopped"
        daemon_item = rumps.MenuItem(daemon_label)
        daemon_item.set_callback(None)

        # Budget item (disabled)
        budget_item = rumps.MenuItem(_budget_str())
        budget_item.set_callback(None)

        # Recent completions submenu
        completions = _recent_completions()
        if completions:
            sub = rumps.MenuItem("Recent completions")
            for c in completions:
                agent = c.get("agent", "unknown")
                summary = c.get("summary", "")[:60]
                label = f"{agent}: {summary}" if summary else agent
                entry = rumps.MenuItem(label)
                entry.set_callback(None)
                sub.add(entry)
        else:
            sub = rumps.MenuItem("Recent completions: none")
            sub.set_callback(None)

        # Queue count item (disabled)
        qcount = _queue_count()
        queue_item = rumps.MenuItem(f"Queue: {qcount} tasks pending")
        queue_item.set_callback(None)

        self.menu = [
            daemon_item,
            budget_item,
            None,  # separator
            sub,
            queue_item,
            None,  # separator
            rumps.MenuItem("Open Dashboard", callback=self._open_dashboard),
            rumps.MenuItem("Cast status", callback=self._cast_status),
            None,  # separator
            rumps.MenuItem("Quit CAST Status Bar", callback=self._quit),
        ]

    @rumps.timer(5)
    def poll(self, _sender):
        self._build_menu()
        self._fire_notifications()

    def _fire_notifications(self):
        pending = _drain_notify_queue()
        for entry in pending:
            title = entry.get("title", "CAST")
            message = entry.get("message", "")
            rumps.notification(title=title, subtitle=None, message=message)

    def _open_dashboard(self, _sender):
        webbrowser.open("http://localhost:4000")

    def _cast_status(self, _sender):
        # REQUIRES: phase-7e (cast CLI)
        try:
            result = subprocess.run(
                [str(CAST_BIN), "status"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            output = result.stdout.strip() or result.stderr.strip() or "(no output)"
        except FileNotFoundError:
            output = "cast CLI not installed (phase-7e required)"
        except Exception as exc:
            output = f"Error: {exc}"
        rumps.alert(title="Cast Status", message=output)

    def _quit(self, _sender):
        rumps.quit_application()


if __name__ == "__main__":
    CAST_DIR.mkdir(parents=True, exist_ok=True)
    AGENT_STATUS_DIR.mkdir(parents=True, exist_ok=True)
    app = CastStatusBar()
    app._build_menu()
    app.run()
