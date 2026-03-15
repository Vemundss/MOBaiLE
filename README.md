# MOBaiLE

<p align="center">
  <img src="ios/VoiceAgentApp/mobaile_logo.png" alt="MOBaiLE logo" width="180" />
</p>

<p align="center"><strong>Your computer, in your pocket.</strong></p>

<p align="center">Talk to your Mac or Linux box from your iPhone, let it do real work, and watch the run stream back live.</p>

<p align="center">
  <img src="docs/readme-hero.svg" alt="MOBaiLE flow from iPhone prompt to backend execution to live result stream" width="920" />
</p>

MOBaiLE is for the moment when opening your laptop feels like too much friction, but the task is still real.
Ask from your phone, run on your own machine, use your own files/tools/network, and get progress plus a result back in the app.

## Great First Prompts

- `create a hello python script and run it`
- `inspect this repo and tell me where onboarding feels rough`
- `check my calendar today and summarize conflicts`
- `fix the failing test and explain the patch`

## Quick Start

Choose the shortest path that matches what you need.

### Backend on this machine

If you already have `python3`:

```bash
bash ./scripts/install_backend.sh --mode safe
cd backend
bash ./run_backend.sh
curl http://127.0.0.1:8000/health
```

`install_backend.sh` now installs `uv` for you if it is missing.

If you prefer a no-clone / managed install in `~/MOBaiLE`, use the bootstrap flow instead:

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/bootstrap_server.sh | bash -s -- --mode safe
```

`bootstrap_server.sh` installs into `~/MOBaiLE` by default, so use `install_backend.sh` when you want to work from this checkout.
If no Codex/Claude CLI is installed, MOBaiLE keeps the internal `local` executor available for smoke/dev text requests.

### iOS app on simulator

```bash
cd ios
open VoiceAgentApp.xcodeproj
```

Use `xcodegen generate` only after editing `ios/project.yml` or if the checked-in Xcode project gets out of sync.

### iPhone + backend over Tailscale

Install Tailscale on both devices, then follow the full on-the-go setup below.

Need more detail? Jump to [`docs/USAGE.md`](docs/USAGE.md), [`backend/README.md`](backend/README.md), [`ios/README.md`](ios/README.md), or [`scripts/README.md`](scripts/README.md).

## Why It Feels Useful

- Turn a spare minute in line, on a train, or between meetings into a real work session on your own machine.
- Use your real repo, files, credentials, and network instead of a toy remote environment.
- Watch live progress and final results instead of sending work into a black box and hoping it finished.
- Start with a safer default mode (`safe`), then unlock more power on machines you trust (`full-access`).

## Setup For On-The-Go Use (Outside Local Network)

This is the recommended end-to-end setup for most users.

### 1) Install required apps/tools

On your computer:
- `git`, `python3`, `curl`
- [`uv`](https://docs.astral.sh/uv/) (auto-installed by `install_backend.sh` / bootstrap if missing)
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
bash ./scripts/service_macos.sh install   # macOS
# or on Linux:
bash ./scripts/service_linux.sh install
bash ./scripts/doctor.sh
bash ./scripts/pairing_qr.sh
```

What bootstrap does:
- clones/updates repo to `~/MOBaiLE`
- installs backend deps and creates `backend/.env`
- creates `backend/pairing.json` (uses Tailscale URL when available)
- on macOS: installs and starts `launchd` background service
- on Linux: installs and starts `systemd --user` background service when available
- generates `backend/pairing-qr.png`
- keeps the internal `local` executor available for smoke/dev requests if no Codex/Claude CLI is installed

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
    "executor": "codex",
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
open VoiceAgentApp.xcodeproj
```

If you changed `ios/project.yml`, run `xcodegen generate` first.

## Test, Rerun, and Maintenance

```bash
bash ./scripts/doctor.sh             # environment + API checks
bash ./scripts/pairing_qr.sh         # regenerate pairing QR
cd backend && bash ./run_backend.sh  # start backend in foreground
```

Service control:

```bash
# macOS
bash ./scripts/service_macos.sh status
bash ./scripts/service_macos.sh restart
bash ./scripts/service_macos.sh logs

# Linux
bash ./scripts/service_linux.sh status
bash ./scripts/service_linux.sh restart
bash ./scripts/service_linux.sh logs
```

Backend tests:

```bash
cd backend
uv run pytest -q
```

Contract sync/check:

```bash
cd backend
uv run python ../scripts/sync_contracts.py
uv run python ../scripts/sync_contracts.py --check
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
- iPhone voice works on text but not through the mic:
  - enable `Speech Recognition` for MOBaiLE in iOS Settings
  - on a real iPhone, MOBaiLE transcribes locally first; `OPENAI_API_KEY` is only needed for backend audio upload fallback
- Backend audio uploads fail:
  - set `OPENAI_API_KEY` in `backend/.env`
  - text prompts still work without it; `/v1/audio` depends on backend transcription

Optional npm wrappers (if you use Node):

```bash
npm run setup:server
npm run backend:start
npm run doctor
npm run pair:qr
npm run ios:open
```

## More Docs

- Usage guide: [`docs/USAGE.md`](docs/USAGE.md)
- Backend details and endpoints: [`backend/README.md`](backend/README.md)
- iOS details: [`ios/README.md`](ios/README.md)
- Scripts reference: [`scripts/README.md`](scripts/README.md)
- Architecture: [`ARCHITECTURE.md`](ARCHITECTURE.md)
- Current status: [`STATUS.md`](STATUS.md)

## Publishing and Privacy Policy

Apple requires a public privacy policy URL for App Store submissions.

Repo source of truth:
- `docs/privacy-policy.html`

Optional GitHub Pages deploy workflow:
- `.github/workflows/deploy-privacy-policy.yml`

Current public fallback URL:
- `https://gist.github.com/Vemundss/c2ae60485e23c0c8a93115c039b03044`

If you enable GitHub Pages for the repo:

1. Push `main` to GitHub.
2. In GitHub repo settings, enable Pages and select `GitHub Actions` as source.
3. Wait for the `Deploy Privacy Policy` workflow to complete.
4. Prefer the GitHub Pages URL in App Store Connect and inside the app once it is live.

## License

This project is licensed under the Apache License, Version 2.0.
See [`LICENSE`](LICENSE) for the full text.
