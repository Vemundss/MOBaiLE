# Usage

This is the canonical operator/setup document for the repo. If another document disagrees on installation, service management, or runtime configuration, prefer this file.

This document explains how to run the backend that MOBaiLE pairs with on your own Mac or Linux computer.

## Set It Up

If you want the iPhone app working with the least friction, do this first.

### Step 1. Run the installer on the computer you want MOBaiLE to use

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/install.sh | bash
```

The installer asks three quick questions. For the normal setup, keep the defaults:

- `Full Access`
- `Anywhere with Tailscale`
- `Yes` for the background service

This path:

- installs or updates MOBaiLE in `~/MOBaiLE`
- configures the backend for phone pairing
- installs and starts a background service when supported
- writes `backend/pairing.json`
- generates `backend/pairing-qr.png`

If you are already inside this repo and want to run the installer there:

```bash
bash ./scripts/install.sh
```

### Step 2. Pair the iPhone

1. Open `backend/pairing-qr.png` on the computer.
2. Scan it with iPhone Camera.
3. Tap `Open in MOBaiLE`.
4. Send a small prompt to confirm the thread works.

### Step 3. Later, check status with one command

```bash
mobaile status
```

If your shell does not find it yet, run `~/.local/bin/mobaile status`.

### Step 4. Reach for fallback or advanced setup only when you need it

- Local-only testing on the same machine: `bash ./scripts/install_backend.sh --mode safe --phone-access local`
- Backend-only/manual install from a checkout: `bash ./scripts/install_backend.sh --mode full-access --phone-access tailscale`
- Stable public hostname: set `VOICE_AGENT_PUBLIC_SERVER_URL` in `backend/.env` or pass `--public-url https://your-host`
- Trusted private host with more autonomy: use `--with-autonomy-stack` after the backend install path above

`install.sh` is the main setup entry point. `install_backend.sh` is the lower-level backend-only path.
`install_backend.sh` installs `uv` if needed, performs initial `uv sync`, creates `backend/.env`, and writes pairing info to `backend/pairing.json`.
If Tailscale MagicDNS is available, pairing prefers the stable `*.ts.net` hostname automatically before raw `100.x` or LAN IPs.
The iPhone app only talks to this backend. It does not run code on-device.

Safe mode defaults:
- restricted codex execution (`VOICE_AGENT_CODEX_UNRESTRICTED=false`)
- restricted file reads (`VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=false`)
- workdir constrained to default root

Use `full-access` only on trusted private hosts.
All `/v1/*` endpoints require bearer auth using `VOICE_AGENT_API_TOKEN`.

## Prerequisites

- macOS/Linux shell
- Python 3.11+
- `uv` (auto-installed by `install_backend.sh` if missing)

If you are setting this up for the iPhone app, you also need a reachable backend URL. For local testing that can be `127.0.0.1`; for a real phone it should be a Tailscale, LAN, or other reachable host URL.

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

Service management:

```bash
# macOS
bash ./scripts/service_macos.sh status
bash ./scripts/service_macos.sh sync
bash ./scripts/service_macos.sh restart
bash ./scripts/service_macos.sh logs

# Linux
bash ./scripts/service_linux.sh status
bash ./scripts/service_linux.sh sync
bash ./scripts/service_linux.sh restart
bash ./scripts/service_linux.sh logs
```

Notes:
- Service runtime is synced to `~/Library/Application Support/MOBaiLE/backend-runtime`.
- Linux user service runtime is synced to `~/.local/share/MOBaiLE/backend-runtime`.
- Linux service management uses `systemd --user`; on headless hosts you may need `sudo loginctl enable-linger $USER` for reboot persistence.
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
    "executor": "codex",
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

Try Claude executor mode:

```bash
curl -s -X POST http://127.0.0.1:8000/v1/utterances \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{
    "session_id": "demo-session",
    "utterance_text": "inspect this repo and propose next coding task",
    "executor": "claude"
  }'
```

Agent executor config (`backend/.env`):
- `VOICE_AGENT_SECURITY_MODE=safe|full-access` controls security defaults.
- `VOICE_AGENT_DEFAULT_EXECUTOR=codex|claude|local` selects the app/backend default executor.
  - if the selected agent CLI is unavailable, backend falls back to another available agent executor and finally to the internal `local` fallback
- `VOICE_AGENT_CODEX_HOME=~/.codex` selects the Codex home used for auth, MCP config, and skills.
- `VOICE_AGENT_CODEX_UNRESTRICTED=true` enables unrestricted Codex execution (recommended only for private trusted hosts).
- `VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH=true` enables Codex live web search for backend-launched runs.
- `VOICE_AGENT_CODEX_GUARDRAILS=warn` adds prompt-level destructive-op detection (`off|warn|enforce`).
- `VOICE_AGENT_CODEX_DANGEROUS_CONFIRM_TOKEN=[allow-dangerous]` explicit token to bypass guardrail warnings.
- `VOICE_AGENT_CODEX_MODEL=<model-id>` optionally forces a specific model.
- `VOICE_AGENT_CODEX_TIMEOUT_SEC=900` sets max runtime per codex run before backend fails it.
- `VOICE_AGENT_CODEX_USE_CONTEXT=true` prepends MOBaiLE context to Codex prompts.
- `VOICE_AGENT_CODEX_CONTEXT_FILE=../.mobaile/AGENT_CONTEXT.md` points to the repo-local hidden agent context file.
- `VOICE_AGENT_CLAUDE_BINARY=claude` selects the Claude Code CLI binary.
- `VOICE_AGENT_CLAUDE_MODEL=<model-id>` optionally forces a Claude model.
- `VOICE_AGENT_CLAUDE_TIMEOUT_SEC=900` sets max runtime per Claude run before backend fails it.
- `VOICE_AGENT_CLAUDE_PERMISSION_MODE=acceptEdits` controls Claude headless permission mode in safe mode.
- `VOICE_AGENT_CLAUDE_SKIP_PERMISSIONS=true` bypasses Claude permission prompts (recommended only for trusted private hosts).
- `VOICE_AGENT_DEFAULT_WORKDIR=~` sets default working directory for `local`, `codex`, and `claude` runs.
- `VOICE_AGENT_WORKDIR_ROOT=/path` optionally constrains all requested working directories to a root.
- `VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=false` blocks absolute `/v1/files` access in safe mode.
- `VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR=data/playwright` stores Playwright artifacts and persisted session output.
- `VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR=data/playwright-profile` stores the persistent Playwright browser profile.
- `VOICE_AGENT_FILE_ROOTS=/path1,/path2` restricts readable file roots for `/v1/files`.
  - in `full-access` mode with absolute reads enabled and no explicit `VOICE_AGENT_FILE_ROOTS`, file browsing stays unrestricted
- `VOICE_AGENT_DB_PATH=data/runs.db` controls SQLite run persistence path.

Notes:
- Context injection affects agent runs launched via MOBaiLE backend only.
- Direct terminal usage (`codex ...` / `claude ...`) is unchanged unless you configure that separately.
- Runtime config advertises agent executors (`codex`, `claude`) for normal UX; `local` is kept for internal smoke/dev flows.
- `/v1/capabilities` now reports autonomy readiness for Codex MCP, managed skills, Peekaboo permissions, and Playwright persistence paths.
- `GET /v1/config` now includes a generic `executors[]` descriptor list so clients can render executor availability/default/model data without provider-specific fields.
- Per-run request controls:
  - `response_mode=concise` is the current supported mobile chat mode.
  - `response_profile=guided|minimal` controls prompt shaping:
    - `guided`: applies MOBaiLE formatting/context guidance.
    - `minimal`: only runtime-awareness hint, otherwise near-default agent behavior.

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

Provision Codex for autonomous remote control:

```bash
python3 ./scripts/provision_codex_autonomy.py --mode full-access
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
The iPhone app now prefers Apple Speech Recognition first and only falls back to this endpoint when backend transcription is configured.

```bash
TOKEN="$(awk -F= '/^VOICE_AGENT_API_TOKEN=/{print $2}' backend/.env)"
printf 'fakewav' > /tmp/voice_sample.wav

curl -s -X POST http://127.0.0.1:8000/v1/audio \
  -H "Authorization: Bearer ${TOKEN}" \
  -F 'session_id=audio-session' \
  -F 'executor=codex' \
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
- For deterministic internal smoke/dev testing, you can still set `executor=local`.
- Text prompts do not depend on transcription configuration.
- The iPhone app does not need this path for normal voice use on a real device; it uses Apple Speech Recognition first.
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

## 8) Legacy no-app voice testing

If you still need the old Shortcuts-only workflow, see the archived note:

`docs/archive/PHONE_SHORTCUT_MVP.md`

## 9) Pairing QR (optional)

Generate a local QR image from `backend/pairing.json`:

```bash
bash ./scripts/pairing_qr.sh
```

By default this writes:
- `backend/pairing-qr.png`
- QR payload format is `mobaile://pair?server_url=...&server_url=...&pair_code=...&session_id=...`

Phone onboarding with QR:
1. Open iPhone Camera and scan the generated QR.
2. Tap the `mobaile://pair...` banner.
3. iOS opens MOBaiLE, exchanges one-time pair code with backend, then stores API token locally.

Notes:
- App now confirms pairing details before applying server/session changes.
- Pairing can advertise multiple candidate server URLs; the app stores them and automatically retries another endpoint if the current host stops responding.
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
# or on Linux:
bash ./scripts/service_linux.sh restart
```

This updates:
- `backend/.env` (`VOICE_AGENT_API_TOKEN`)
- `backend/pairing.json` (`pair_code`, `pair_code_expires_at`, and removes any legacy `api_token` export)

## 11) Switch security mode

```bash
bash ./scripts/set_security_mode.sh safe
bash ./scripts/set_security_mode.sh full-access
```

Then restart backend:

```bash
bash ./scripts/service_macos.sh restart
# or on Linux:
bash ./scripts/service_linux.sh restart
```

## 12) Remote phone access hardening (recommended)

For use beyond local network:

1. Do not expose raw `:8000` directly to the internet.
2. Place backend behind TLS (e.g., Tailscale HTTPS, Cloudflare Tunnel, or reverse proxy with HTTPS).
3. Keep bearer token secret and rotate it periodically (`rotate_api_token.sh`).
4. Keep agent guardrails at least `warn` in production-like usage.
5. Use least-privilege OS account on server when possible.

## Current Limitations

- Planner is a stub (rule-based), not a real LLM yet.
- Agent executor success depends on the selected local CLI (`codex` or `claude`) being installed and authenticated.
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
