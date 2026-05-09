# Documentation Policy

This repo separates documentation by audience.

## Humans First

Visible checked-in docs are for humans by default.

Canonical docs:

- `README.md`: product overview and fastest path
- `docs/USAGE.md`: canonical setup and operations guide
- `ARCHITECTURE.md`: engineering map

Folder-local `README.md` files should stay short and only explain local ownership or usage.

## Agent Files

This repo separates repo-development agent guidance from product runtime agent assets.

Use:

- top-level `AGENTS.md` for agents working on the MOBaiLE repository itself
- `.mobaile/runtime/` for checked-in runtime context injected into backend-launched agents

Do not use visible top-level Markdown other than `AGENTS.md` for agent-only instructions.

Do not use `.codex/` for repo-owned assets unless they are truly Codex-specific and intended to mirror Codex home layout. In this repo, the assets are MOBaiLE-owned and can be consumed by multiple agent backends, so `.mobaile/` is the correct home.

## Runtime Memory

Runtime memory should not live in visible repo docs.

Use:

- `backend/data/profiles/<profile_id>/AGENTS.md`
- `backend/data/profiles/<profile_id>/MEMORY.md`
- staged workdir files under `.mobaile/AGENTS.md` and `.mobaile/MEMORY.md`

These are runtime artifacts, not canonical project documentation.

## Historical Docs

Historical or superseded notes belong in `docs/archive/`.

Examples:

- status logs
- temporary feature tracking notes
- old MVP or pre-product workflows

Archived docs should not be linked as primary references from `README.md`.

## Anti-Drift Rules

- Prefer one canonical doc over repeated setup instructions.
- If a doc duplicates `README.md` or `docs/USAGE.md`, shrink it to a scoped index or remove it.
- Add prose only where reading the code would otherwise be disproportionately expensive.
- When behavior changes, update canonical docs and delete stale duplicates instead of patching every narrative copy.
