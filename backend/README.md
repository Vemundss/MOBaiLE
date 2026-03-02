# Backend (Layman-First)

This is the local server that does the heavy lifting for MOBaiLE.
Your iPhone app talks to this backend to run tasks, stream progress, and return results.

## Quick Start

If you want the backend running with minimal setup:

From repo root:

```bash
bash ./scripts/install_backend.sh --mode safe
cd backend
bash ./run_backend.sh
```

If you have Node/npm and prefer one command wrappers:

```bash
npm run backend:install
npm run backend:start
```

## Check That It Works

Open a new terminal:

```bash
curl http://127.0.0.1:8000/health
```

You should see a small JSON response with `ok`.

Interactive API docs are available at:
- `http://127.0.0.1:8000/docs`

## Where Token and Settings Live

- Config file: `backend/.env`
- API token key: `VOICE_AGENT_API_TOKEN`
- Pairing info: `backend/pairing.json`

Important:
- `/v1/*` endpoints require `Authorization: Bearer <VOICE_AGENT_API_TOKEN>`
- `/health` does not require auth

## Common Problems (Fast Fixes)

- `address already in use` on `8000`:
  - another backend instance is already running; stop it or change `VOICE_AGENT_PORT` in `.env`
- iPhone cannot connect to `127.0.0.1`:
  - use your computer LAN/Tailscale URL as `Server URL` in the app
- Audio endpoint failing:
  - set `OPENAI_API_KEY` in `.env` (or use mock transcription provider for testing)

## Technical Details

### Core endpoints

- `GET /health`
- `POST /v1/utterances` (start run; supports `executor=local|codex`)
- `POST /v1/audio` (audio upload, transcription, then run)
- `GET /v1/runs/{run_id}` (run state + events)
- `GET /v1/runs/{run_id}/events` (SSE event stream)
- `GET /v1/directories` (list existing directory contents)
- `POST /v1/directories` (explicitly create directory)

### Storage

- Run records are stored in SQLite (`data/runs.db` by default)
- Override with `VOICE_AGENT_DB_PATH`

### Transcription provider

- `VOICE_AGENT_TRANSCRIBE_PROVIDER=openai` (default)
- Requires `OPENAI_API_KEY`
- `VOICE_AGENT_TRANSCRIBE_PROVIDER=mock` is available for local deterministic testing

### Working directory behavior

- Default workdir uses `VOICE_AGENT_DEFAULT_WORKDIR` (defaults to `~`)
- Per-run override via `working_directory` on `/v1/utterances` and `/v1/audio`

### Tests

```bash
uv run pytest -q
```

### Helpful scripts

From repo root:

```bash
bash ./scripts/doctor.sh
bash ./scripts/pairing_qr.sh
bash ./scripts/service_macos.sh status
```
