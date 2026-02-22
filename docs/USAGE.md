# Usage

This document explains how to run the current backend MVP locally.

## Quick Setup (recommended)

From project root:

```bash
bash ./scripts/install_backend.sh
bash ./scripts/doctor.sh
bash ./scripts/service_macos.sh install   # macOS only
```

`install_backend.sh` performs initial `uv sync`, creates `backend/.env`, and writes pairing info to `backend/pairing.json`.
By default, Codex executor runs in unrestricted mode (`VOICE_AGENT_CODEX_UNRESTRICTED=true`).
All `/v1/*` endpoints require bearer auth using `VOICE_AGENT_API_TOKEN`.

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
bash ./run_backend.sh
```

API will be available at:
- `http://127.0.0.1:8000/health`
- `http://127.0.0.1:8000/docs`

Service management on macOS:

```bash
bash ./scripts/service_macos.sh status
bash ./scripts/service_macos.sh sync
bash ./scripts/service_macos.sh restart
bash ./scripts/service_macos.sh logs
```

Notes:
- Service runtime is synced to `~/Library/Application Support/MOBaiLE/backend-runtime`.
- Run `sync` after backend code/config changes, then `restart`.

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
TOKEN="$(awk -F= '/^VOICE_AGENT_API_TOKEN=/{print $2}' backend/.env)"
curl -s -X POST http://127.0.0.1:8000/v1/utterances \
  -H "Authorization: Bearer ${TOKEN}" \
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
curl -s -H "Authorization: Bearer ${TOKEN}" http://127.0.0.1:8000/v1/runs/<run_id>
```

Stream run events (SSE):

```bash
curl -N -H "Authorization: Bearer ${TOKEN}" http://127.0.0.1:8000/v1/runs/<run_id>/events
```

Try Codex executor mode:

```bash
curl -s -X POST http://127.0.0.1:8000/v1/utterances \
  -H "Authorization: Bearer ${TOKEN}" \
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
- `VOICE_AGENT_DB_PATH=data/runs.db` controls SQLite run persistence path.

## 5) Audio upload flow (`/v1/audio`)

This endpoint accepts multipart audio and starts a run from server-side transcription.

```bash
TOKEN="$(awk -F= '/^VOICE_AGENT_API_TOKEN=/{print $2}' backend/.env)"
printf 'fakewav' > /tmp/voice_sample.wav

curl -s -X POST http://127.0.0.1:8000/v1/audio \
  -H "Authorization: Bearer ${TOKEN}" \
  -F 'session_id=audio-session' \
  -F 'executor=local' \
  -F 'transcript_hint=create a hello python script and run it' \
  -F 'audio=@/tmp/voice_sample.wav;type=audio/wav'
```

Notes:
- `transcript_hint` is optional and useful for deterministic MVP testing.
- Default provider is mock (`VOICE_AGENT_TRANSCRIBE_PROVIDER=mock`).
- For real STT, set in `backend/.env`:
  - `VOICE_AGENT_TRANSCRIBE_PROVIDER=openai`
  - `OPENAI_API_KEY=<your-key>`
  - optional: `VOICE_AGENT_TRANSCRIBE_MODEL=whisper-1`
- Response includes `transcript_text` and run metadata (`run_id`, `status`, `message`).

## 6) Run automated tests

```bash
cd backend
uv run pytest -q
```

## 7) Connectivity smoke (pairing-based)

After install + service start:

```bash
bash ./scripts/phone_connectivity_smoke.sh
```

This script reads `backend/pairing.json`, validates auth behavior, uploads audio to `/v1/audio`, and waits for terminal run status.

## 8) iPhone voice testing (no app code)

Use the Shortcuts-based workflow in:

`docs/PHONE_SHORTCUT_MVP.md`

## 9) Pairing QR (optional)

Generate a local QR image from `backend/pairing.json`:

```bash
bash ./scripts/pairing_qr.sh
```

By default this writes:
- `backend/pairing-qr.png`

## Current Limitations

- Planner is a stub (rule-based), not a real LLM yet.
- Codex executor success depends on local Codex CLI auth/model access.
- iOS client is not implemented yet.
