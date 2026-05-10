# MOBaiLE Backend Agents

The canonical agent guidance lives in the workspace root `../AGENTS.md` when this repo is checked out inside
`mobaile-workspace`. Use this file only as a backend-specific fallback.

## Backend Scope

- This repo owns the public backend/runtime, installer, host policy, source schemas, public docs, and generated backend contracts.
- The private iOS app lives in sibling `../frontend` during workspace development.
- Do not duplicate frontend behavior or private app assumptions here.

## Read When Relevant

- `README.md`: public product and quick start.
- `backend/README.md`: backend package layout.
- `docs/USAGE.md`: install, pairing, service management, and operations.
- `ARCHITECTURE.md`: current engineering map.
- `.mobaile/runtime/RUNTIME_CONTEXT.md`: runtime context injected into backend-launched agents.

## Verification

- Python changes: `npm run backend:lint`, `cd backend && uvx ruff check app tests`, and targeted `cd backend && uv run pytest ...`.
- Schema/contract changes: `cd backend && uv run python ../scripts/sync_contracts.py --check`.
- Shell changes: `npm run shell:lint` when available; otherwise at least `bash -n <touched script>`.
- Host-runtime changes: after checks, sync/restart the installed service when local availability matters, then confirm `mobaile status`, service status, or `/health`.

## Concurrent Work

- For parallel backend edits, prefer one branch/worktree per agent from this repo; do not share a dirty checkout.
- Merge only after the relevant checks pass, then remove finished worktrees and branches.

## Backend Notes

- `backend/app/models/schemas.py` is the source of truth for API shapes.
- Runtime defaults belong under `.mobaile/runtime/`.
- Mutable profile state under `backend/data/profiles/<profile_id>/` is runtime data, not repo-owned guidance.
- Known hotspots: `backend/app/runtime_session_service.py`, `backend/app/storage/run_store.py`, `backend/app/capability_probes/`, and `backend/tests/test_api.py`.
