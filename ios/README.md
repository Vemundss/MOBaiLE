# iOS App (Layman-First)

This is the iPhone app for MOBaiLE.
You use it to send text/voice requests and watch the run progress from your phone.

## Quick Start

### 1) Open the iOS project

From repo root:

```bash
cd ios
xcodegen generate
open VoiceAgentApp.xcodeproj
```

### 2) Run the app in Xcode

In Xcode:
1. Select scheme `VoiceAgentApp`
2. Choose a simulator (for example `iPhone 17`) or a real iPhone
3. Press Run

### 3) Connect app to backend

Best option:
1. Generate/open `backend/pairing-qr.png`
2. Scan with iPhone camera
3. Open the `mobaile://pair...` link
4. Confirm pairing inside the app

Manual option in app Settings:
1. Set `Server URL` to your backend URL
2. Set `API Token` to `VOICE_AGENT_API_TOKEN` from `backend/.env`
3. Keep `Session ID` as `iphone-app` (or set your own)

### 4) Send a request

- Type a prompt and tap `Send`
- Or use the mic button for audio input

## What You Need

- macOS + Xcode
- `xcodegen` (`brew install xcodegen`)
- Running backend server
- For real audio transcription: backend must have `OPENAI_API_KEY`

## Common Problems (Fast Fixes)

- App on real iPhone cannot reach backend:
  - do not use `127.0.0.1`; use LAN/Tailscale URL
- Pairing link opens but app does not connect:
  - verify backend is running and token/session in pairing file are current
- Audio fails but text works:
  - check backend `OPENAI_API_KEY` or switch backend transcription to mock

## Technical Notes

- App code: `ios/VoiceAgentApp/`
- Tests: `ios/VoiceAgentAppTests/`
- Runtime flow:
  - create run via `/v1/utterances` or `/v1/audio`
  - stream events from `/v1/runs/{run_id}/events`
  - fallback polling from `/v1/runs/{run_id}`
- Run logs are available in-app via the logs screen

## Test Command

From `ios/`:

```bash
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' test
```
