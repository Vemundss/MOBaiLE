# MEMORY

## 2026-02-18

- Initialized repository memory and planning documents for voice-to-agent iPhone app.
- Added `README.md` with project intent and document references.
- Added `ARCHITECTURE.md` with component architecture, contracts, safety model, and phased roadmap.
- Added `STATUS.md` with current project state, risks, and actionable next steps.
- Scaffolded a lean monorepo structure with `contracts/`, `backend/`, `ios/`, `infra/`, and `scripts/`.
- Added backend starter files: `backend/pyproject.toml`, `backend/app/main.py` (`/health` endpoint), and module placeholders.
- Added explanatory `README.md` files in `backend/`, `ios/`, `contracts/`, `infra/`, and `scripts/`.
- Implemented minimal backend pipeline:
  - `POST /v1/utterances` creates plan, validates policy, executes actions in sandbox.
  - `GET /v1/runs/{run_id}` returns run status/events/summary.
  - Action types implemented: `write_file`, `run_command`.
- Added backend modules for planner (`app/orchestrator/planner.py`), policy (`app/policy/validator.py`), schema models (`app/models/schemas.py`), and local executor (`app/executors/local_executor.py`).
- Added smoke script `scripts/backend_smoke.py` to verify end-to-end flow without iOS.
- Added `.gitignore` for Python artifacts and virtualenv folders.
- Verified smoke run output includes successful file creation and Python execution in sandbox.
- Added `docs/USAGE.md` with local setup, virtualenv, API run steps, smoke test, and curl examples.
- Updated root `README.md` to reference `docs/USAGE.md`.

## 2026-02-19

- Migrated backend local workflow to `uv`.
- Fixed setuptools package discovery in `backend/pyproject.toml` by including only `app*`.
- Verified end-to-end local run with:
  - `cd backend && uv sync`
  - `uv run uvicorn app.main:app --reload`
  - `uv run python ../scripts/backend_smoke.py`
- Fixed smoke script import behavior by prepending `backend/` to `sys.path` in `scripts/backend_smoke.py`.
- Updated `docs/USAGE.md` to document the verified `uv` workflow.
- Refined project MVP consensus:
  - Goal is remote "vibe coding" from iPhone to external computer.
  - iPhone acts as voice UI + result playback.
  - Backend acts as LLM/planning/execution control plane.
  - Codex CLI should run unrestricted with full access on the target machine.
- Updated `README.md`, `ARCHITECTURE.md`, and `STATUS.md` to align with this consensus.
- Normalized remaining architecture/status wording to avoid mixed assumptions between structured-policy mode and unrestricted Codex mode.
- Added backend asynchronous run execution (`running` -> terminal states) instead of blocking response handling.
- Added `GET /v1/runs/{run_id}/events` SSE endpoint for live execution events.
- Added Codex executor integration path in backend (`executor="codex"`).
- Added `backend/app/executors/codex_executor.py` for non-interactive Codex CLI invocation.
- Updated `scripts/backend_smoke.py` to poll until run completion due async execution flow.
- Updated `docs/USAGE.md` with executor selection and SSE usage examples.
- Captured shipping/setup product intent:
  - iOS app as downloadable client.
  - Backend as one-command install from repo on target host.
  - Setup should output pairing data (server URL + token/QR) for app onboarding.
  - Include install/doctor scripts and service auto-start as build requirements.
- Added `scripts/install_backend.sh`:
  - verifies prerequisites
  - runs `uv sync` in backend
  - creates `backend/.env` with generated token
  - writes `backend/pairing.json` for app onboarding
- Added `scripts/doctor.sh` for dependency checks, env checks, and local health endpoint probe.
- Updated usage/readme docs to include install/doctor workflow.
- Updated Codex backend executor defaults:
  - unrestricted mode enabled by default (`VOICE_AGENT_CODEX_UNRESTRICTED=true`)
  - optional model override supported via `VOICE_AGENT_CODEX_MODEL`
- Verified backend-triggered Codex runs report `sandbox: danger-full-access`.
