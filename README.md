# MOBaiLE

<p align="center">
  <img src="ios/VoiceAgentApp/mobaile_logo.png" alt="MOBaiLE logo" width="180" />
</p>

MOBaiLE lets you talk to your computer from your iPhone.
Think of it as a practical "remote teammate in your pocket": you speak or type a task, the backend runs it on your machine, and the app streams progress/results live.

## Quick Start

### What this solves

- Run real tasks on your own computer while away from your desk.
- Keep a single control plane for auth, run history, and live event updates.
- Choose a safer default mode (`safe`) or unlock full power on trusted hosts (`full-access`).

## Privacy Policy URL (App Store Connect)

Apple requires a public privacy policy URL for App Store submissions.

This repo includes a privacy page at `docs/privacy-policy.html` and a deploy workflow:
`.github/workflows/deploy-privacy-policy.yml`

### Publish it

1. Push `main` to GitHub.
2. In GitHub repo settings, enable Pages and select `GitHub Actions` as source.
3. Wait for the `Deploy Privacy Policy` workflow to complete.

### Use this URL in App Store Connect

- `https://vemundss.github.io/MOBaiLE/privacy-policy.html`

Also include the same URL inside the app (Settings -> App -> Privacy Policy).

## Setup For On-The-Go Use (Outside Local Network)

This is the recommended end-to-end setup for most users.

### 1) Install required apps/tools

On your computer:
- `git`, `python3`, `curl`
- [`uv`](https://docs.astral.sh/uv/) (auto-installed by bootstrap if missing)
- [Tailscale](https://tailscale.com/download) (recommended for remote access without port forwarding)

On your iPhone:
- **Tailscale** app from App Store
- **MOBaiLE** iOS app
  - if distributed: install from TestFlight/App Store
  - if developing locally: build from `ios/` in Xcode and run on your phone

### 2) Sign in to Tailscale on both computer and iPhone

Use the same Tailscale account/tailnet on both devices.

On computer, verify Tailscale is connected:

```bash
tailscale status
tailscale ip -4
```

### 3) Install and bootstrap MOBaiLE backend on your computer

Option A (one command, installs into `~/MOBaiLE`):

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/bootstrap_server.sh | bash -s -- --mode safe
```

Option B (manual, if you want full control):

```bash
git clone https://github.com/vemundss/MOBaiLE.git
cd MOBaiLE
bash ./scripts/install_backend.sh --mode safe --expose-network
bash ./scripts/service_macos.sh install   # macOS only
bash ./scripts/doctor.sh
bash ./scripts/pairing_qr.sh
```

What bootstrap does:
- clones/updates repo to `~/MOBaiLE`
- installs backend deps and creates `backend/.env`
- creates `backend/pairing.json` (uses Tailscale URL when available)
- on macOS: installs and starts background service
- generates `backend/pairing-qr.png`

### 4) Verify backend is healthy

```bash
curl http://127.0.0.1:8000/health
```

Expected: JSON response with status `ok`.

### 5) Pair your iPhone with backend

On computer:
1. Open `backend/pairing-qr.png` from your MOBaiLE repo folder.
2. If missing, regenerate:
   ```bash
   bash ./scripts/pairing_qr.sh
   ```

On iPhone:
1. Open Camera and scan the QR.
2. Tap the `mobaile://pair...` deep link.
3. Confirm in MOBaiLE app.

Manual fallback (in MOBaiLE app settings):
1. `Server URL`: Tailscale URL from `backend/pairing.json`
2. `API Token`: `VOICE_AGENT_API_TOKEN` from `backend/.env`
3. `Session ID`: default `iphone-app` is fine

### 6) Validate remote access over cellular

1. Turn off Wi-Fi on iPhone (use cellular).
2. Keep Tailscale connected on iPhone.
3. Open MOBaiLE and run a small prompt (for example: "create and run a hello script").
4. Confirm you see live run events and final result.

If this works on cellular, your on-the-go setup is complete.

## On-The-Go Power Features

These are built in and can be enabled in a few minutes.

### 1) Lock screen / Home screen widget: "Start Voice Task"

On iPhone:
1. Long-press Home or Lock Screen.
2. Tap `Edit` / `Customize`.
3. Add widget: **MOBaiLE**.
4. Pick the widget variant you prefer.
5. Tap the widget to launch MOBaiLE and start recording immediately.

### 2) Haptic + audio recording cues

In MOBaiLE app:
1. Open `Settings` (slider icon).
2. In `App` section:
   - enable `Haptic Cues`
   - enable `Audio Cues`
3. Tap `Done`.

Behavior:
- short cue when recording starts
- success cue when audio is sent
- error cue if recording/send fails

### 3) Hands-free mode: auto-send after silence

In MOBaiLE app:
1. Open `Settings` -> `App`.
2. Enable `Auto-send After Silence`.
3. Set `Silence seconds` (recommended: `1.0` to `1.5`).
4. Tap `Done`.

Now recording will auto-submit when you stop speaking for the configured time.

### 4) Siri / Shortcuts intents

Available intents:
- `Start Voice Task`
- `Send Last Prompt`

On iPhone:
1. Open `Shortcuts` app.
2. Tap `+` -> `Add Action`.
3. Search for `MOBaiLE`.
4. Add one of the actions above.
5. (Optional) assign a Siri phrase and/or pin it as a Home Screen shortcut.

Tip: You can combine this with AirPods click-to-record for near hands-free usage.

## Usage Examples

### Example 1: Send a task through backend API

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

### Example 2: Run connectivity smoke test

```bash
bash ./scripts/phone_connectivity_smoke.sh
```

### Example 3: Open iOS project locally (developer workflow)

```bash
cd ios
xcodegen generate
open VoiceAgentApp.xcodeproj
```

## Test, Rerun, and Maintenance

```bash
bash ./scripts/doctor.sh             # environment + API checks
bash ./scripts/pairing_qr.sh         # regenerate pairing QR
cd backend && bash ./run_backend.sh  # start backend in foreground
```

macOS service control:

```bash
bash ./scripts/service_macos.sh status
bash ./scripts/service_macos.sh restart
bash ./scripts/service_macos.sh logs
```

Backend tests:

```bash
cd backend
uv run pytest -q
```

Optional: enable commit-time secret scanning:

```bash
uv tool install pre-commit
pre-commit install
pre-commit run --all-files
```

## Troubleshooting

- Pairing QR contains `127.0.0.1` instead of Tailscale URL:
  - ensure Tailscale is connected on computer, then re-run:
    ```bash
    bash ./scripts/install_backend.sh --mode safe --expose-network
    bash ./scripts/pairing_qr.sh
    ```
- iPhone can pair on Wi-Fi but not on cellular:
  - confirm Tailscale is connected on iPhone and computer
  - confirm backend is running (`bash ./scripts/doctor.sh`)
- Audio uploads fail:
  - set `OPENAI_API_KEY` in `backend/.env`
  - or set `VOICE_AGENT_TRANSCRIBE_PROVIDER=mock` for deterministic local tests

Optional npm wrappers (if you use Node):

```bash
npm run setup:server
npm run backend:start
npm run doctor
npm run pair:qr
```

## More Docs

- Usage guide: [`docs/USAGE.md`](docs/USAGE.md)
- Backend details and endpoints: [`backend/README.md`](backend/README.md)
- iOS details: [`ios/README.md`](ios/README.md)
- Scripts reference: [`scripts/README.md`](scripts/README.md)
- Architecture: [`ARCHITECTURE.md`](ARCHITECTURE.md)
- Current status: [`STATUS.md`](STATUS.md)
- Planned features: [`NEW_FEATURES.md`](NEW_FEATURES.md)

## License

This project is licensed under the Apache License, Version 2.0.
See [`LICENSE`](LICENSE) for the full text.
