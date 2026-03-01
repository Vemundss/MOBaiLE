# MOBaiLE

<p align="center">
  <img src="ios/VoiceAgentApp/mobaile_logo.png" alt="MOBaiLE logo" width="180" />
</p>

MOBaiLE turns your iPhone into a voice remote for your computer.
Speak a task, MOBaiLE transcribes it, plans it through a backend control plane, executes safely on a target machine, and streams progress/results back to your phone.

If you have ever wanted "Siri, but for real work on my actual machine," this is the repo.

## What problem it solves

- Removes command-line friction when you are away from your keyboard.
- Gives one control plane for voice input, execution, and run history.
- Supports both safe and full-access execution modes depending on trust level.
- Keeps interaction conversational while still exposing diagnostics and logs.

## Setup

### 1) Prerequisites

- macOS or Linux
- Python `3.11+`
- [`uv`](https://docs.astral.sh/uv/)

### 2) Clone and install backend (recommended: safe mode)

```bash
git clone https://github.com/vemundss/MOBaiLE.git
cd MOBaiLE
bash ./scripts/install_backend.sh --mode safe
bash ./scripts/doctor.sh
```

### 3) Start backend API

```bash
cd backend
bash ./run_backend.sh
```

Backend should now respond on:

- `http://127.0.0.1:8000/health`
- `http://127.0.0.1:8000/docs`

### 4) Run iOS app

```bash
cd ios
xcodegen generate
open VoiceAgentApp.xcodeproj
```

In app settings:

1. Set `Server URL` to your reachable backend URL.
2. Set `API Token` from `backend/.env` (`VOICE_AGENT_API_TOKEN`).
3. Start with executor `local` (then try `codex`).
4. Send text or voice input.

## Usage examples

### Example 1: Let the backend execute a simple request

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
    "working_directory": "~/MOBaiLE-workspace"
  }'
```

### Example 2: End-to-end smoke flow

```bash
cd backend
uv run python ../scripts/backend_smoke.py
```

### Example 3: Bootstrap a pairing-ready host/server

```bash
bash ./scripts/bootstrap_server.sh --mode safe
```

This performs clone/update, install, health checks, and pairing QR generation.  
Then scan `backend/pairing-qr.png` and open the `mobaile://pair...` link on iPhone.

## Test, rerun, and nice-to-know

### Run tests

```bash
cd backend
uv run pytest -q
```

### Re-check local environment

```bash
bash ./scripts/doctor.sh
```

### Use macOS background service (optional)

```bash
bash ./scripts/service_macos.sh install
bash ./scripts/service_macos.sh status
bash ./scripts/service_macos.sh logs
```

### Security modes

- `safe` (recommended): restricted workdir + restricted file reads + non-unrestricted codex defaults.
- `full-access`: relaxed restrictions for trusted private hosts only.

### Repo map

- `ios/` SwiftUI app
- `backend/` FastAPI control plane
- `scripts/` setup and operational helpers
- `docs/` deeper usage guides

### Further docs

- Usage details: [`docs/USAGE.md`](docs/USAGE.md)
- iPhone Shortcut MVP testing: [`docs/PHONE_SHORTCUT_MVP.md`](docs/PHONE_SHORTCUT_MVP.md)
- iOS notes: [`ios/README.md`](ios/README.md)
- Backend details: [`backend/README.md`](backend/README.md)
- Architecture: [`ARCHITECTURE.md`](ARCHITECTURE.md)
- Current status: [`STATUS.md`](STATUS.md)
- Planned features: [`NEW_FEATURES.md`](NEW_FEATURES.md)
- Agent/contributor intent: [`AGENT_INTENT.md`](AGENT_INTENT.md)
