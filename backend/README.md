# Backend

This document is backend-scoped. The canonical human setup and operations flow lives in
[`docs/USAGE.md`](../docs/USAGE.md). The root [`README.md`](../README.md) is the product and quick-start entry point.

## What This Folder Owns

- HTTP API and auth in `backend/app/main.py`
- Run orchestration in `backend/app/execution_service.py`
- Runtime/config policy in `backend/app/runtime_environment.py`
- Schemas and generated contracts from `backend/app/models/schemas.py`
- Persistent run storage in `backend/app/storage/run_store.py`

## Runtime Notes

- Default posture is `safe`; `full-access` must be an explicit choice.
- `codex` and `claude` are optional. If neither CLI is available, MOBaiLE keeps the internal `local` executor for smoke and dev flows.
- The iPhone app prefers on-device speech first. Backend `/v1/audio` still needs transcription configuration when that fallback is used.

## Key Files and State

- Config: `backend/.env`
- Safe template: `backend/.env.example`
- Pairing payload: `backend/pairing.json` for `server_url`, `session_id`, and `pair_code` only
- Repo-local agent assets: `../.mobaile/`
- Persistent profiles:
  - `backend/data/profiles/<profile_id>/AGENTS.md`
  - `backend/data/profiles/<profile_id>/MEMORY.md`
- Run history: `backend/data/runs.db` by default, overridable with `VOICE_AGENT_DB_PATH`

## Core Endpoints

- `GET /health`
- `GET /v1/config`
- `POST /v1/utterances`
- `POST /v1/audio`
- `GET /v1/runs/{run_id}`
- `GET /v1/runs/{run_id}/events`
- `POST /v1/runs/{run_id}/cancel`
- `GET /v1/runs/{run_id}/diagnostics`
- `GET /v1/directories`
- `POST /v1/directories`

## Backend-Specific Verification

```bash
cd backend
uv run pytest -q
```

Useful repo-root commands:

```bash
bash ./scripts/doctor.sh
bash ./scripts/service_macos.sh status
bash ./scripts/service_linux.sh status
bash ./scripts/pairing_qr.sh
```
