# Usage

This document explains how to run the current backend MVP locally.

## Quick Setup (recommended)

From project root:

```bash
bash ./scripts/install_backend.sh --mode safe
bash ./scripts/doctor.sh
bash ./scripts/service_macos.sh install   # macOS only
```

Fresh host/server bootstrap (single command after clone):

```bash
bash ./scripts/bootstrap_server.sh --mode safe
```

`install_backend.sh` performs initial `uv sync`, creates `backend/.env`, and writes pairing info to `backend/pairing.json`.
Safe mode defaults:
- restricted codex execution (`VOICE_AGENT_CODEX_UNRESTRICTED=false`)
- restricted file reads (`VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=false`)
- workdir constrained to default root

Full-access mode:

```bash
bash ./scripts/install_backend.sh --mode full-access
```

Use only on trusted private hosts.
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
- Backend writes `<working_directory>/hello.py`.
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
    "executor": "local",
    "working_directory": "~/MOBaiLE-workspace",
    "response_mode": "concise",
    "response_profile": "guided"
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
- `VOICE_AGENT_SECURITY_MODE=safe|full-access` controls security defaults.
- `VOICE_AGENT_CODEX_UNRESTRICTED=true` enables unrestricted Codex execution (recommended only for private trusted hosts).
- `VOICE_AGENT_CODEX_GUARDRAILS=warn` adds prompt-level destructive-op detection (`off|warn|enforce`).
- `VOICE_AGENT_CODEX_DANGEROUS_CONFIRM_TOKEN=[allow-dangerous]` explicit token to bypass guardrail warnings.
- `VOICE_AGENT_CODEX_MODEL=<model-id>` optionally forces a specific model.
- `VOICE_AGENT_CODEX_TIMEOUT_SEC=900` sets max runtime per codex run before backend fails it.
- `VOICE_AGENT_CODEX_USE_CONTEXT=true` prepends MOBaiLE context to Codex prompts.
- `VOICE_AGENT_CODEX_CONTEXT_FILE=AGENT_CONTEXT.md` points to context file under `backend/`.
- `VOICE_AGENT_DEFAULT_WORKDIR=~` sets default working directory for both `local` and `codex` runs.
- `VOICE_AGENT_WORKDIR_ROOT=/path` optionally constrains all requested working directories to a root.
- `VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=false` blocks absolute `/v1/files` access in safe mode.
- `VOICE_AGENT_FILE_ROOTS=/path1,/path2` restricts readable file roots for `/v1/files`.
- `VOICE_AGENT_DB_PATH=data/runs.db` controls SQLite run persistence path.

Notes:
- Context injection affects Codex runs launched via MOBaiLE backend only.
- Direct terminal usage (`codex exec ...`) is unchanged unless you configure that separately.
- Per-run request controls:
  - `response_mode=concise` is the current supported mobile chat mode.
  - `response_profile=guided|minimal` controls prompt shaping:
    - `guided`: applies MOBaiLE formatting/context guidance.
    - `minimal`: only runtime-awareness hint, otherwise near-default Codex behavior.

Cancel a running run:

```bash
curl -s -X POST -H "Authorization: Bearer ${TOKEN}" http://127.0.0.1:8000/v1/runs/<run_id>/cancel
```

List latest runs in a session (for resume UX):

```bash
curl -s -H "Authorization: Bearer ${TOKEN}" \
  "http://127.0.0.1:8000/v1/sessions/demo-session/runs?limit=10"
```

Query deterministic calendar tool (today):

```bash
curl -s -H "Authorization: Bearer ${TOKEN}" \
  "http://127.0.0.1:8000/v1/tools/calendar/today"
```

Get run diagnostics:

```bash
curl -s -H "Authorization: Bearer ${TOKEN}" \
  "http://127.0.0.1:8000/v1/runs/<run_id>/diagnostics"
```

Probe runtime capabilities (light check):

```bash
curl -s -H "Authorization: Bearer ${TOKEN}" \
  "http://127.0.0.1:8000/v1/capabilities"
```

Probe runtime capabilities (deep check, may trigger app permission prompts on macOS):

```bash
curl -s -H "Authorization: Bearer ${TOKEN}" \
  "http://127.0.0.1:8000/v1/capabilities?deep=true&launch_apps=true"
```

List an existing directory (read-only):

```bash
curl -s -H "Authorization: Bearer ${TOKEN}" \
  "http://127.0.0.1:8000/v1/directories?path=/absolute/or/relative/path"
```

Create a directory explicitly:

```bash
curl -s -X POST http://127.0.0.1:8000/v1/directories \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"path":"/absolute/or/relative/path"}'
```

## 5) Audio upload flow (`/v1/audio`)

This endpoint accepts multipart audio and starts a run from server-side transcription.

```bash
TOKEN="$(awk -F= '/^VOICE_AGENT_API_TOKEN=/{print $2}' backend/.env)"
printf 'fakewav' > /tmp/voice_sample.wav

curl -s -X POST http://127.0.0.1:8000/v1/audio \
  -H "Authorization: Bearer ${TOKEN}" \
  -F 'session_id=audio-session' \
  -F 'executor=local' \
  -F 'response_mode=concise' \
  -F 'response_profile=guided' \
  -F 'working_directory=~/MOBaiLE-workspace' \
  -F 'transcript_hint=create a hello python script and run it' \
  -F 'audio=@/tmp/voice_sample.wav;type=audio/wav'
```

Notes:
- `transcript_hint` is optional and useful for deterministic MVP testing.
- Default provider is OpenAI (`VOICE_AGENT_TRANSCRIBE_PROVIDER=openai`).
- `VOICE_AGENT_MAX_AUDIO_MB=20` caps accepted audio payload size.
- For real STT, ensure in `backend/.env`:
  - `OPENAI_API_KEY=<your-key>`
  - optional: `VOICE_AGENT_TRANSCRIBE_MODEL=whisper-1`
- To force deterministic local behavior, opt into mock mode:
  - `VOICE_AGENT_TRANSCRIBE_PROVIDER=mock`
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
- QR payload format is `mobaile://pair?server_url=...&pair_code=...&session_id=...`

Phone onboarding with QR:
1. Open iPhone Camera and scan the generated QR.
2. Tap the `mobaile://pair...` banner.
3. iOS opens MOBaiLE, exchanges one-time pair code with backend, then stores API token locally.

Notes:
- App now confirms pairing details before applying server/session changes.
- Non-local servers must use `https://` for pairing.
- Legacy `api_token` pairing links are disabled by default (developer-mode fallback only).

If needed, generate raw JSON QR instead:

```bash
bash ./scripts/pairing_qr.sh --format json
```

Pairing endpoint:
- `POST /v1/pair/exchange` (unauthenticated, one-time code exchange, rate-limited)

## 10) Rotate API token

```bash
bash ./scripts/rotate_api_token.sh
bash ./scripts/service_macos.sh restart
```

This updates:
- `backend/.env` (`VOICE_AGENT_API_TOKEN`)
- `backend/pairing.json` (`api_token`, `pair_code`, `pair_code_expires_at`)

## 11) Switch security mode

```bash
bash ./scripts/set_security_mode.sh safe
bash ./scripts/set_security_mode.sh full-access
```

Then restart backend:

```bash
bash ./scripts/service_macos.sh restart
```

## 12) Remote phone access hardening (recommended)

For use beyond local network:

1. Do not expose raw `:8000` directly to the internet.
2. Place backend behind TLS (e.g., Tailscale HTTPS, Cloudflare Tunnel, or reverse proxy with HTTPS).
3. Keep bearer token secret and rotate it periodically (`rotate_api_token.sh`).
4. Keep Codex guardrails at least `warn` in production-like usage.
5. Use least-privilege OS account on server when possible.

## Current Limitations

- Planner is a stub (rule-based), not a real LLM yet.
- Codex executor success depends on local Codex CLI auth/model access.
- iOS client currently uses SSE with polling fallback; voice and chat UX are MVP-grade, not production polished.

## iOS Chat UX mode

iOS chat is now always concise by default:
- user-facing chat shows assistant summaries/structured cards.
- noisy execution stream stays out of chat.
- raw backend event output remains available in the `Logs` view (Developer Mode).
- artifact `Open` actions now use authenticated in-app download/preview, so protected `/v1/files` resources open reliably.

Event channel model:
- `chat.message`: user-facing structured assistant envelope.
- `log.message`: raw execution/log stream for diagnostics.
