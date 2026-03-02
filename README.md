# MOBaiLE

<p align="center">
  <img src="ios/VoiceAgentApp/mobaile_logo.png" alt="MOBaiLE logo" width="180" />
</p>

MOBaiLE lets you control coding tasks on your computer from your iPhone.
You can type or speak a request, and the backend runs it safely on your machine while the app shows live progress.

## Quick Start

If you just want it working, copy these steps.

### 1) Install the backend server in one command

This installs everything, sets up tokens, and prepares pairing:

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/bootstrap_server.sh | bash -s -- --mode safe
```

What this does for you:
- installs missing backend prerequisites (`uv`) if needed
- clones MOBaiLE to `~/MOBaiLE`
- installs backend dependencies
- creates backend config + API token + pairing info
- on macOS: installs and starts a background service
- generates pairing QR at `~/MOBaiLE/backend/pairing-qr.png`

If you already cloned this repo and prefer npm-style commands:

```bash
npm run setup:server
```

### 2) Confirm backend is running

```bash
curl http://127.0.0.1:8000/health
```

You should get a small JSON response with `"ok"` status.

### 3) Open the iOS app project

```bash
cd ~/MOBaiLE/ios
xcodegen generate
open VoiceAgentApp.xcodeproj
```

In Xcode:
1. Select scheme `VoiceAgentApp`
2. Pick an iPhone simulator (or your device)
3. Press Run

### 4) Connect app to backend

Easiest way:
1. Open `~/MOBaiLE/backend/pairing-qr.png`
2. Scan with iPhone camera
3. Open the `mobaile://pair...` link
4. Confirm pairing in-app

Manual fallback (Settings in app):
1. `Server URL`: your backend URL
2. `API Token`: from `~/MOBaiLE/backend/.env` (`VOICE_AGENT_API_TOKEN`)
3. `Session ID`: keep default (`iphone-app`) unless you want a custom one

## What You Need

- A Mac (for iOS app build)
- iPhone (for real mobile use; simulator also works for testing)
- Internet access for dependency install
- Xcode
- `xcodegen` (`brew install xcodegen`)

Optional for audio transcription:
- OpenAI API key in `backend/.env` (`OPENAI_API_KEY`)
- If you only use text prompts, this is not required

Optional for npm shortcuts:
- Node.js + npm

## Common Issues (Fast Fixes)

- `address already in use` on port `8000`:
  - another backend is already running; stop it first or change port in `backend/.env`
- App on real iPhone cannot reach `127.0.0.1`:
  - use your computer's LAN/Tailscale URL instead
- Pairing works but audio fails:
  - add `OPENAI_API_KEY` to `backend/.env` (or switch transcription provider to `mock` for testing)

## Useful Commands

From repo root:

```bash
npm run setup:server          # bootstrap safe-mode backend
npm run backend:start         # start backend in foreground
npm run doctor                # connectivity and environment checks
npm run pair:qr               # regenerate pairing QR
npm run ios:open              # regenerate and open iOS project
```

Without npm:

```bash
bash ./scripts/install_backend.sh --mode safe
cd backend && bash ./run_backend.sh
bash ./scripts/doctor.sh
```

## Technical Details (Advanced)

- Usage guide: [`docs/USAGE.md`](docs/USAGE.md)
- Backend details and endpoints: [`backend/README.md`](backend/README.md)
- iOS details: [`ios/README.md`](ios/README.md)
- Scripts reference: [`scripts/README.md`](scripts/README.md)
- Architecture: [`ARCHITECTURE.md`](ARCHITECTURE.md)
- Current status: [`STATUS.md`](STATUS.md)
- Planned features: [`NEW_FEATURES.md`](NEW_FEATURES.md)
