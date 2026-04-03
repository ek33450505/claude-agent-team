#!/usr/bin/env python3
"""CAST Dashboard — Terminal UI for CAST observability.

An 'htop for CAST' that reads cast.db and ~/.claude/ filesystem directly.
Requires: textual (pip install textual)

Usage: cast dash
   or: python3 cast-dash.py
"""

import os
import json
import sqlite3
import sys
from datetime import datetime

try:
    from textual.app import App, ComposeResult
    from textual.containers import Vertical
    from textual.widgets import DataTable, Footer, Header, Static
    from textual import work
except ImportError:
    print("Error: textual is not installed.")
    print("  Install: ~/.claude/venv/bin/pip install textual")
    print("  Or run:  bash install.sh  (from claude-agent-team repo)")
    sys.exit(1)


# ── Paths ────────────────────────────────────────────────────────────────────

CAST_DB_PATH = os.environ.get("CAST_DB_PATH", os.path.expanduser("~/.claude/cast.db"))
CLAUDE_DIR = os.path.expanduser("~/.claude")
AGENTS_DIR = os.path.join(CLAUDE_DIR, "agents")
SKILLS_DIR = os.path.join(CLAUDE_DIR, "skills")
PLANS_DIR = os.path.join(CLAUDE_DIR, "plans")
SETTINGS_FILE = os.path.join(CLAUDE_DIR, "settings.json")


# ── Formatting helpers ───────────────────────────────────────────────────────

def fmt_duration(seconds):
    """Format seconds as human-readable duration."""
    if seconds is None:
        return "-"
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m {s % 60}s"
    h = s // 3600
    m = (s % 3600) // 60
    return f"{h}h {m}m"


def fmt_elapsed(started_at):
    """Format a timestamp as relative elapsed time."""
    if not started_at:
        return "-"
    try:
        start = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
        now = datetime.now(start.tzinfo) if start.tzinfo else datetime.now()
        delta = (now - start).total_seconds()
        if delta < 60:
            return "now"
        if delta < 3600:
            return f"{int(delta // 60)}m ago"
        if delta < 86400:
            return f"{int(delta // 3600)}h ago"
        return f"{int(delta // 86400)}d ago"
    except (ValueError, TypeError):
        return "-"


def fmt_cost(val):
    """Format cost in USD."""
    if val is None:
        return "$0.00"
    return f"${val:.2f}"


def fmt_tokens(val):
    """Format token count as human-readable."""
    if val is None or val == 0:
        return "0"
    if val >= 1_000_000:
        return f"{val / 1_000_000:.1f}M"
    if val >= 1_000:
        return f"{val / 1_000:.0f}K"
    return str(int(val))


def status_color(status):
    """Return Rich markup color for a status string."""
    if not status:
        return "dim"
    s = status.upper()
    if s == "DONE":
        return "green"
    if s == "DONE_WITH_CONCERNS":
        return "yellow"
    if s == "BLOCKED":
        return "red"
    if s == "RUNNING":
        return "bold blue"
    return "dim"


# ── Database access ──────────────────────────────────────────────────────────

class CastDB:
    """Read-only access to cast.db with graceful fallbacks."""

    def __init__(self, db_path):
        self.db_path = db_path
        self._conn = None

    def _connect(self):
        if not os.path.exists(self.db_path):
            return None
        try:
            conn = sqlite3.connect(
                f"file:{self.db_path}?mode=ro",
                uri=True,
                timeout=5,
            )
            conn.row_factory = sqlite3.Row
            return conn
        except sqlite3.Error:
            return None

    def query(self, sql, params=()):
        """Run a read-only query, return list of dicts."""
        try:
            conn = self._connect()
            if conn is None:
                return []
            cur = conn.execute(sql, params)
            rows = [dict(r) for r in cur.fetchall()]
            conn.close()
            return rows
        except sqlite3.Error:
            return []

    def query_one(self, sql, params=()):
        """Run a query expecting one row, return dict or empty dict."""
        rows = self.query(sql, params)
        return rows[0] if rows else {}

    @property
    def exists(self):
        return os.path.exists(self.db_path)


# ── Filesystem counts ───────────────────────────────────────────────────────

def count_md_files(directory):
    """Count .md files in a directory."""
    try:
        return len([f for f in os.listdir(directory) if f.endswith(".md")])
    except (FileNotFoundError, PermissionError):
        return 0


def count_dirs(directory):
    """Count subdirectories in a directory."""
    try:
        return len([d for d in os.listdir(directory)
                     if os.path.isdir(os.path.join(directory, d))])
    except (FileNotFoundError, PermissionError):
        return 0


def count_hooks():
    """Count hooks defined in settings.json."""
    try:
        with open(SETTINGS_FILE) as f:
            settings = json.load(f)
        hooks = settings.get("hooks", {})
        count = 0
        for _event_type, hook_list in hooks.items():
            if isinstance(hook_list, list):
                count += len(hook_list)
        return count
    except (FileNotFoundError, json.JSONDecodeError, PermissionError):
        return 0


# ── Sparkline ────────────────────────────────────────────────────────────────

SPARK_CHARS = " \u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588"


def sparkline(values):
    """Render a list of floats as a sparkline string."""
    if not values or all(v == 0 for v in values):
        return ""
    max_val = max(values) if max(values) > 0 else 1
    return "".join(
        SPARK_CHARS[min(int(v / max_val * (len(SPARK_CHARS) - 1)), len(SPARK_CHARS) - 1)]
        for v in values
    )


# ── CSS ──────────────────────────────────────────────────────────────────────

DASHBOARD_CSS = """
Screen {
    layout: grid;
    grid-size: 2 2;
    grid-gutter: 1;
    padding: 1;
}

#active-agents {
    height: 100%;
    border: solid $accent;
    padding: 0 1;
}

#today-stats {
    height: 100%;
    border: solid $accent;
    padding: 1;
}

#recent-runs {
    height: 100%;
    border: solid $accent;
    padding: 0 1;
}

#system-health {
    height: 100%;
    border: solid $accent;
    padding: 1;
}

.panel-title {
    text-style: bold;
    color: $text;
    margin-bottom: 1;
}

.stat-line {
    margin-bottom: 0;
}

.sparkline-row {
    margin-top: 1;
    color: $accent;
}

.empty-state {
    color: $text-muted;
    text-style: italic;
}

Footer {
    dock: bottom;
}
"""


# ── Widgets ──────────────────────────────────────────────────────────────────

class ActiveAgentsPanel(Vertical):
    """Top-left: currently running agents."""

    def compose(self) -> ComposeResult:
        yield Static("[b]Active Agents[/b]", classes="panel-title")
        yield DataTable(id="active-agents-table")

    def on_mount(self) -> None:
        table = self.query_one("#active-agents-table", DataTable)
        table.add_columns("Agent", "Model", "Status", "Elapsed")
        table.cursor_type = "row"


class TodayStatsPanel(Vertical):
    """Top-right: today's aggregated statistics."""

    def compose(self) -> ComposeResult:
        yield Static("[b]Today's Stats[/b]", classes="panel-title")
        yield Static("Loading...", id="stats-content")
        yield Static("", id="stats-sparkline", classes="sparkline-row")


class RecentRunsPanel(Vertical):
    """Bottom-left: last 20 agent runs."""

    def compose(self) -> ComposeResult:
        yield Static("[b]Recent Runs[/b]", classes="panel-title")
        yield DataTable(id="recent-runs-table")

    def on_mount(self) -> None:
        table = self.query_one("#recent-runs-table", DataTable)
        table.add_columns("Agent", "Status", "Model", "Cost", "Duration", "When")
        table.cursor_type = "row"


class SystemHealthPanel(Vertical):
    """Bottom-right: filesystem and DB health counts."""

    def compose(self) -> ComposeResult:
        yield Static("[b]System Health[/b]", classes="panel-title")
        yield Static("Loading...", id="health-content")


# ── Main App ─────────────────────────────────────────────────────────────────

class CastDashboard(App):
    """CAST Terminal Dashboard — htop for CAST."""

    CSS = DASHBOARD_CSS

    TITLE = "CAST Dashboard"
    SUB_TITLE = datetime.now().strftime("%Y-%m-%d %H:%M")

    BINDINGS = [
        ("q", "quit", "Quit"),
        ("r", "refresh", "Refresh"),
        ("tab", "focus_next", "Next Panel"),
    ]

    def __init__(self):
        super().__init__()
        self.db = CastDB(CAST_DB_PATH)

    def compose(self) -> ComposeResult:
        yield Header()
        yield ActiveAgentsPanel(id="active-agents")
        yield TodayStatsPanel(id="today-stats")
        yield RecentRunsPanel(id="recent-runs")
        yield SystemHealthPanel(id="system-health")
        yield Footer()

    def on_mount(self) -> None:
        """Start the 5-second refresh cycle."""
        self.refresh_data()
        self.set_interval(5, self.refresh_data)

    def action_refresh(self) -> None:
        """Force immediate refresh (r key)."""
        self.refresh_data()

    @work(thread=True)
    def refresh_data(self) -> None:
        """Fetch all data and schedule UI updates."""
        if not self.db.exists:
            self.call_from_thread(self._show_no_db)
            return

        # Active agents
        active = self.db.query(
            """SELECT agent, model, status, started_at,
                 CAST((julianday('now') - julianday(started_at)) * 86400 AS INTEGER) AS elapsed_s
               FROM agent_runs
               WHERE status = 'running' AND started_at >= datetime('now', '-15 minutes')
               ORDER BY started_at DESC"""
        )

        # Today's stats
        stats = self.db.query_one(
            """SELECT COUNT(*) AS runs,
                 COALESCE(SUM(cost_usd), 0) AS cost,
                 COALESCE(SUM(input_tokens + output_tokens), 0) AS tokens,
                 SUM(CASE WHEN UPPER(status) = 'BLOCKED' THEN 1 ELSE 0 END) AS errors
               FROM agent_runs
               WHERE date(started_at) = date('now')"""
        )

        # Hourly cost sparkline
        hourly = self.db.query(
            """SELECT strftime('%H', started_at) AS hour,
                 COALESCE(SUM(cost_usd), 0) AS cost
               FROM agent_runs
               WHERE date(started_at) = date('now')
               GROUP BY hour ORDER BY hour"""
        )

        # Recent runs
        recent = self.db.query(
            """SELECT agent, status, model, cost_usd, started_at, ended_at,
                 CASE WHEN ended_at IS NOT NULL
                   THEN CAST((julianday(ended_at) - julianday(started_at)) * 86400 AS INTEGER)
                   ELSE NULL END AS duration_s
               FROM agent_runs
               ORDER BY started_at DESC LIMIT 20"""
        )

        # System health (filesystem)
        health = {
            "agents": count_md_files(AGENTS_DIR),
            "hooks": count_hooks(),
            "skills": count_dirs(SKILLS_DIR),
            "plans": count_md_files(PLANS_DIR),
            "db_runs": 0,
            "db_sessions": 0,
        }
        db_stats = self.db.query_one("SELECT COUNT(*) AS c FROM agent_runs")
        health["db_runs"] = db_stats.get("c", 0)
        db_sess = self.db.query_one("SELECT COUNT(*) AS c FROM sessions")
        health["db_sessions"] = db_sess.get("c", 0)

        # Schedule UI updates on the main thread
        self.call_from_thread(self._update_active_agents, active)
        self.call_from_thread(self._update_today_stats, stats, hourly)
        self.call_from_thread(self._update_recent_runs, recent)
        self.call_from_thread(self._update_system_health, health)
        self.call_from_thread(self._update_subtitle)

    def _show_no_db(self) -> None:
        """Display when cast.db is missing."""
        try:
            self.query_one("#stats-content", Static).update(
                "[dim italic]No cast.db found[/]\n\n"
                "Run [bold]cast seed[/bold] or use Claude Code\nto generate data."
            )
            self.query_one("#health-content", Static).update(
                f"[dim]DB path: {CAST_DB_PATH}[/]"
            )
        except Exception:
            pass

    def _update_active_agents(self, rows) -> None:
        try:
            table = self.query_one("#active-agents-table", DataTable)
            table.clear()
            if not rows:
                table.add_row("(none)", "-", "-", "-")
                return
            for r in rows:
                status_txt = r.get("status", "-")
                table.add_row(
                    r.get("agent", "-"),
                    r.get("model", "-"),
                    f"[{status_color(status_txt)}]{status_txt}[/]",
                    fmt_duration(r.get("elapsed_s")),
                )
        except Exception:
            pass

    def _update_today_stats(self, stats, hourly) -> None:
        try:
            runs = stats.get("runs", 0) or 0
            cost = stats.get("cost", 0) or 0
            tokens = stats.get("tokens", 0) or 0
            errors = stats.get("errors", 0) or 0

            lines = [
                f"  Runs:   [bold]{runs}[/]       Cost:   [bold]{fmt_cost(cost)}[/]",
                f"  Tokens: [bold]{fmt_tokens(tokens)}[/]     Errors: [bold]{'[red]' + str(errors) + '[/]' if errors else str(errors)}[/]",
            ]
            self.query_one("#stats-content", Static).update("\n".join(lines))

            # Sparkline
            if hourly:
                costs = [r.get("cost", 0) or 0 for r in hourly]
                spark = sparkline(costs)
                hours_range = f"{hourly[0].get('hour', '?')}h-{hourly[-1].get('hour', '?')}h"
                self.query_one("#stats-sparkline", Static).update(
                    f"  Hourly cost: {spark}  ({hours_range})"
                )
            else:
                self.query_one("#stats-sparkline", Static).update(
                    "  [dim]No activity today[/]"
                )
        except Exception:
            pass

    def _update_recent_runs(self, rows) -> None:
        try:
            table = self.query_one("#recent-runs-table", DataTable)
            table.clear()
            if not rows:
                table.add_row("(none)", "-", "-", "-", "-", "-")
                return
            for r in rows:
                status_txt = r.get("status", "-") or "-"
                table.add_row(
                    r.get("agent", "-") or "-",
                    f"[{status_color(status_txt)}]{status_txt}[/]",
                    r.get("model", "-") or "-",
                    fmt_cost(r.get("cost_usd")),
                    fmt_duration(r.get("duration_s")),
                    fmt_elapsed(r.get("started_at")),
                )
        except Exception:
            pass

    def _update_system_health(self, health) -> None:
        try:
            lines = [
                f"  Agents: [bold]{health['agents']}[/]     Hooks:    [bold]{health['hooks']}[/]",
                f"  Skills: [bold]{health['skills']}[/]     Plans:    [bold]{health['plans']}[/]",
                "",
                f"  DB runs:     [bold]{health['db_runs']}[/]",
                f"  DB sessions: [bold]{health['db_sessions']}[/]",
                "",
                f"  [dim]{CAST_DB_PATH}[/]",
            ]
            self.query_one("#health-content", Static).update("\n".join(lines))
        except Exception:
            pass

    def _update_subtitle(self) -> None:
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.sub_title = f"Last refresh: {now}"


# ── Entry point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    app = CastDashboard()
    app.run()
