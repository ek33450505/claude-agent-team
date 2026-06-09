# Work Projects — Reference

> Rationale and detailed deploy mechanics moved off the always-on `rules/work-projects.md` surface
> (v7.5 Phase 1, 2026-06-09). The behavioral guardrails (Bitbucket/no-gh, Model B rebuild-before-push,
> no Co-Author trailer, never push-agent, branch→env) stay in `rules/work-projects.md`.

## Deploy rhythm (detail)

```bash
# edit source
npm run build         # regenerates build/
git add src/ build/   # stage BOTH source and build artifacts
git commit -m "feat/fix/...: ..."
git push
```
Or use `npm run build:deploy` if the project has it (CWS does as of 2026-04-20) — runs build then prints the reminder commands.

## `.gitignore` implications

- `build/` must NOT be in `.gitignore` on work projects. If it is, the deploy breaks silently (pipeline serves stale/empty content). **Keep `dist/` ignored** (Vite's default output; unused here since we override to `build/`).
- Vite projects need `build.outDir = 'build'` in `vite.config.js` so `npm run build` produces the folder the pipeline expects. CRA projects already use `build/` by default.

## Environment-specific builds

- `VITE_API_URL` (and any other `VITE_*` var) is baked into `build/` at build time.
- If QA and prod use different API URLs, the build on QA branch must bake QA URL; the build on master must bake prod URL. Swap `.env.local` before each build if environments diverge.
- If QA and prod share the same API backend (a single shared API host across environments), no swap needed.

## Why Model B at all?

Legacy / enterprise pattern: servers don't run Node, don't have build toolchains, don't have internet access to npm. They can only clone git and serve static files. Common in EdTech, gov, healthcare, anywhere with locked-down hosting. Painful but real. Don't fight it — match the contract.

## Per-Repo CAST Config (manual setup)

Create `<repo-root>/.claude/cast.json` to configure CAST behavior per repo:

```json
{ "repo_class": "work", "co_author_trailer": "none" }
```

For work repos this eliminates the need to inline `Co-Authored-By` override in every commit prompt.
Manual creation (no CLI helper yet — add `cast init-repo` to backlog):
```bash
mkdir -p .claude && echo '{"repo_class":"work","co_author_trailer":"none"}' > .claude/cast.json
```

Apply this to each work repo under `~/Projects/work/` as needed.
