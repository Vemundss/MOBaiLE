# Usage

This document explains how to run the current backend MVP locally.

## Quick Setup (recommended)

From project root:

```bash
bash ./scripts/install_backend.sh
bash ./scripts/doctor.sh
```

`install_backend.sh` performs initial `uv sync`, creates `backend/.env`, and writes pairing info to `backend/pairing.json`.
By default, Codex executor runs in unrestricted mode (`VOICE_AGENT_CODEX_UNRESTRICTED=true`).

## Prerequisites

- macOS/Linux shell
- Python 3.11+
- `uv` installed

Check versions:

```bash
python3 --version
uv --version
```

## 1) Sync backend environment with uv

From project root:

```bash
cd backend
uv sync
```

## 2) Run the backend API

From `backend/`:

```bash
uv run uvicorn app.main:app --reload
```

API will be available at:
- `http://127.0.0.1:8000/health`
- `http://127.0.0.1:8000/docs`

## 3) Try the current flow

In a second terminal:

```bash
cd backend
uv run python ../scripts/backend_smoke.py
```

Expected behavior:
- A run is created (`status=accepted`, message `Run started`).
- Backend writes `backend/sandbox/workspace/hello.py`.
- Backend executes the script and returns `hello from voice agent` in event output.
- Script polls `GET /v1/runs/{run_id}` until terminal status.

## 4) Optional manual API test with curl

Create an utterance:

```bash
curl -s -X POST http://127.0.0.1:8000/v1/utterances \
  -H 'Content-Type: application/json' \
  -d '{
    "session_id": "demo-session",
    "utterance_text": "create a hello python script and run it",
    "mode": "execute",
    "executor": "local"
  }'
```

Then fetch the run by id:

```bash
curl -s http://127.0.0.1:8000/v1/runs/<run_id>
```

Stream run events (SSE):

```bash
curl -N http://127.0.0.1:8000/v1/runs/<run_id>/events
```

Try Codex executor mode:

```bash
curl -s -X POST http://127.0.0.1:8000/v1/utterances \
  -H 'Content-Type: application/json' \
  -d '{
    "session_id": "demo-session",
    "utterance_text": "inspect this repo and propose next coding task",
    "executor": "codex"
  }'
```

Codex executor config (`backend/.env`):
- `VOICE_AGENT_CODEX_UNRESTRICTED=true` enables unrestricted Codex execution (default).
- `VOICE_AGENT_CODEX_MODEL=<model-id>` optionally forces a specific model.

## Current Limitations

- Planner is a stub (rule-based), not a real LLM yet.
- Run storage is in-memory (lost on server restart).
- No auth on non-health endpoints yet.
- Codex executor success depends on local Codex CLI auth/model access.
- iOS client is not implemented yet.
