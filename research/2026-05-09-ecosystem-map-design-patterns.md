# OSS Ecosystem Map Design Patterns
**Date:** 2026-05-09
**Question:** How do successful multi-repo OSS projects present their ecosystem on a canonical README?

---

## Projects Surveyed

| Project | Repo type | Key pattern |
|---|---|---|
| uv / ruff (Astral) | Multi-tool, single repo | Benchmark SVG hero, emoji bullets, testimonials |
| Effect-TS | True monorepo (40+ packages) | 3-column package table |
| Nx | Monorepo tooling | Centered stack: logo → tagline → badges → nav |
| Turborepo (Vercel) | Monorepo tooling | Minimal hero + single CTA, dark/light logo |
| Bun | Runtime | Centered logo, nested bullet nav map |
| Deno | Runtime | Right-aligned mascot + inline code as diagram |
| Terraform (HashiCorp) | Multi-repo plugin ecosystem | Registry-delegated: links out, doesn't enumerate |

---

## Pattern Analysis

### 1. Hero Stack — Nx / Turborepo pattern (most polished)
Both use: logo image → one-line tagline → badge row → dot-separated nav links. Turborepo adds a dark/light responsive logo via `<picture>` + `prefers-color-scheme`.

Nx badge row example (for-the-badge style):
```markdown
[![NPM Version](https://img.shields.io/npm/v/nx?style=for-the-badge)](https://www.npmjs.com/package/nx)
[![GitHub Stars](https://img.shields.io/github/stars/nrwl/nx?style=for-the-badge)](https://github.com/nrwl/nx)
[![License](https://img.shields.io/github/license/nrwl/nx?style=for-the-badge)](LICENSE)
[![Discord](https://img.shields.io/discord/...?style=for-the-badge&logo=discord)](https://discord.gg/...)
```

Turborepo responsive logo pattern:
```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
  <img alt="Turborepo" src="assets/logo-light.svg" height="60">
</picture>
```

### 2. Package / Repo Table — Effect-TS pattern (best for multi-repo)
Effect uses a 3-column table: `Package | Description | Link`. Clean, scannable for 10-40 entries. Descriptions use natural language (not feature lists).

```markdown
| Package | Description | |
|---|---|---|
| [cast](./cast) | Core agent pipeline + hook system | [README](./cast/README.md) |
| [cast-agents](https://github.com/ek33450505/cast-agents) | 30 agent definitions | [README](https://github.com/ek33450505/cast-agents#readme) |
| [cast-hooks](https://github.com/ek33450505/cast-hooks) | Hook scripts framework (13 hooks) | [README](https://github.com/ek33450505/cast-hooks#readme) |
| [cast-dash](https://github.com/ek33450505/cast-dash) | TUI dashboard (Textual) | [README](https://github.com/ek33450505/cast-dash#readme) |
```

### 3. "Start Here" Navigation — Turborepo / Bun pattern
One primary CTA before any feature list. Both projects resist the temptation to link everything at once. Turborepo: single `Visit https://turborepo.dev to get started`. Bun: nested bullet tree that acts as a site map.

Adaptable pattern for CAST:
```markdown
**New to CAST?** → [Quickstart](docs/quickstart.md) · [Concepts](docs/concepts.md) · [Agent Catalog](docs/agents.md)

Already using CAST? → [Changelog](CHANGELOG.md) · [Roadmap](research/cast-v7-master-plan.md) · [Discord](...)
```

### 4. Performance / Proof Block — ruff / uv pattern
Both Astral projects lead with a benchmark SVG (not a table). The image has dark/light variants and a caption that contextualizes the measurement. This is the highest-polish pattern for a tool with a concrete speed claim.

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/benchmark-dark.svg">
  <img alt="CAST dispatch latency benchmark" src="assets/benchmark-light.svg">
</picture>
<p align="center"><em>Hook pipeline latency on a warm cache (M2 MacBook Pro)</em></p>
```

### 5. Testimonials / Social Proof — ruff pattern
ruff embeds 3-4 attributed developer quotes near the top. For CAST this maps to: quotes from the Anthropic job thread, or from early community users once they exist. Skip until there's authentic copy.

---

## 3-5 Patterns to Borrow for CAST Ecosystem Map

**P1 — Centered hero stack (Nx model)**
Logo → tagline "A multi-agent framework for Claude Code" → `for-the-badge` badges (version, license, BATS tests, GitHub stars) → dot-nav: `Docs · Quickstart · Changelog · Discord`

**P2 — Responsive dark/light logo (Turborepo model)**
Create SVG assets in two variants; use `<picture>` + `prefers-color-scheme`. No extra tooling needed — pure GitHub Markdown.

**P3 — 3-column ecosystem table (Effect-TS model)**
One row per repo. Columns: Package (linked) | Description (one plain-English sentence) | README link. Cap at ~10 rows; link to an `ecosystem.md` for the full list.

**P4 — Two-audience "Start Here" block (Bun/Turborepo fusion)**
New user path vs. returning user path. One short paragraph each, not a wall of links.

**P5 — Benchmark proof block (ruff/uv model)**
If/when CAST has a dispatch latency or BATS run-time stat worth showing, use a captioned SVG (dark+light) rather than a plain number. Adds significant credibility at a glance. Defer until metric exists.

---

## What to Skip

- Mermaid diagrams: none of the surveyed projects use them in their canonical README. They render poorly on GitHub mobile and are hard to maintain. Use SVG exports instead.
- Collapsible `<details>` for core content: only Deno uses it lightly (contribution guide). Avoid for top-level ecosystem structure — GitHub collapses by default on mobile.
- Animated SVGs: only niche projects use these (e.g., Warp terminal). Not appropriate yet for CAST.

---

## Sources

- uv README: https://raw.githubusercontent.com/astral-sh/uv/main/README.md (fetched 2026-05-09)
- ruff README: https://raw.githubusercontent.com/astral-sh/ruff/main/README.md (fetched 2026-05-09)
- Effect-TS README: https://raw.githubusercontent.com/Effect-TS/effect/main/README.md (fetched 2026-05-09)
- Nx README: https://raw.githubusercontent.com/nrwl/nx/master/README.md (fetched 2026-05-09)
- Turborepo README: https://raw.githubusercontent.com/vercel/turbo/main/README.md (fetched 2026-05-09)
- Bun README: https://raw.githubusercontent.com/oven-sh/bun/main/README.md (fetched 2026-05-09)
- Deno README: https://raw.githubusercontent.com/denoland/deno/main/README.md (fetched 2026-05-09)
- Hashicorp Terraform ecosystem: https://github.com/hashicorp/terraform (via WebSearch 2026-05-09)

Status: DONE
