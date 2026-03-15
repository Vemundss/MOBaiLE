# Backend (Layman-First)

This is the local server that does the heavy lifting for MOBaiLE.
Your iPhone app talks to this backend to run tasks, stream progress, and return results.

## Before You Start

- `scripts/install_backend.sh` uses this checkout and requires `python3`
- if `uv` is missing, `scripts/install_backend.sh` installs it for you
- `codex` and `claude` are optional; without them, only MOBaiLE's internal `local` smoke/dev fallback is available
- `OPENAI_API_KEY` is optional for text-only runs and normal iPhone voice use, but still required for backend `/v1/audio` transcription
- `Tailscale` is recommended when your phone must reach the backend off-LAN

## Quick Start

### Use this checkout

If you want the backend running from the repo you cloned:

From repo root:

```bash
bash ./scripts/install_backend.sh --mode safe
cd backend
bash ./run_backend.sh
```

For phone pairing over LAN/Tailscale, add `--expose-network` to the install command so the backend binds on `0.0.0.0`.
If Tailscale is not installed, the script tries to use a LAN IP for pairing before falling back to `127.0.0.1`.

### Fresh machine / managed install

If you want a one-command setup that manages a copy in `~/MOBaiLE`:

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/bootstrap_server.sh | bash -s -- --mode safe
```

`bootstrap_server.sh` clones or updates `~/MOBaiLE` by default. Use it for a fresh machine, not when you specifically want to run from your current checkout.

If you have Node/npm and prefer one command wrappers:

```bash
npm run backend:install
npm run backend:start
```

## First-Run Expectations

- `backend/.env` is created if missing; if it already exists, the install script keeps it and only updates relevant MOBaiLE settings
- `backend/.env.example` documents the expected config keys without shipping real secrets
- `backend/pairing.json` is regenerated during install
- `backend/pairing-qr.png` is generated when you run `bash ./scripts/pairing_qr.sh`
- backend default executor automatically falls back to the internal `local` executor if no Codex/Claude CLI is available
- the iPhone app now prefers Apple Speech Recognition first, so normal voice input on a real iPhone does not require `OPENAI_API_KEY`
- backend `/v1/audio` still needs `OPENAI_API_KEY` for real speech-to-text; text prompts work without it

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
- Safe template: `backend/.env.example`
- API token key: `VOICE_AGENT_API_TOKEN`
- Pairing info: `backend/pairing.json`

Persistent profile files (shared across sessions, auto-created):
- `backend/data/profiles/<profile_id>/AGENTS.md` (stable profile)
- `backend/data/profiles/<profile_id>/MEMORY.md` (mutable persistent notes)

Optional env for profile scope:
- `VOICE_AGENT_PROFILE_ID` (default: `default-user`)

Important:
- `/v1/*` endpoints require `Authorization: Bearer <VOICE_AGENT_API_TOKEN>`
- `/health` does not require auth

## Common Problems (Fast Fixes)

- `address already in use` on `8000`:
  - another backend instance is already running; stop it, or check the installed service:
    - macOS: `bash ./scripts/service_macos.sh status`
    - Linux: `bash ./scripts/service_linux.sh status`
  - alternatively change `VOICE_AGENT_PORT` in `.env`
- iPhone cannot connect to `127.0.0.1`:
  - reinstall with `--expose-network` and use your computer LAN/Tailscale URL as `Server URL` in the app
  - if pairing still writes `127.0.0.1`, enter your LAN IP manually in app settings
- Audio endpoint failing:
  - set `OPENAI_API_KEY` in `.env` (or use mock transcription provider for testing)
  - note: this affects backend `/v1/audio`; the iPhone app prefers Apple Speech Recognition first

## Technical Details

### Core endpoints

- `GET /health`
- `GET /v1/config` (runtime defaults, generic executor descriptors, file/workdir limits)
- `POST /v1/utterances` (start run; supports `executor=codex|claude`, plus `local` for internal smoke/dev fallback)
- `POST /v1/audio` (audio upload, transcription, then run)
- `GET /v1/runs/{run_id}` (run state + events)
- `GET /v1/runs/{run_id}/events` (SSE event stream)
- `GET /v1/directories` (list existing directory contents)
- `POST /v1/directories` (explicitly create directory)

### Storage

- Run records are stored in SQLite (`data/runs.db` by default)
- Override with `VOICE_AGENT_DB_PATH`
- Legacy Codex/session compatibility shims are still read during startup migration, with removal targeted after `2026-07-01`

### Transcription provider

- `VOICE_AGENT_TRANSCRIBE_PROVIDER=openai` (default)
- Requires `OPENAI_API_KEY`
- `VOICE_AGENT_TRANSCRIBE_PROVIDER=mock` is available for local deterministic testing

Text prompts and text chat do not depend on transcription setup.
The iPhone app now transcribes with Apple Speech Recognition first and only falls back to `/v1/audio` when backend transcription is actually configured.

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
bash ./scripts/warmup_capabilities.sh
bash ./scripts/pairing_qr.sh
bash ./scripts/service_macos.sh status
bash ./scripts/service_linux.sh status
```
