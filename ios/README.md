# iOS App (Layman-First)

This is the iPhone app for MOBaiLE.
You use it to send text/voice requests and watch the run progress from your phone.

## What You Need

- macOS + Xcode
- running backend server
- for simulator use: no Apple Developer signing changes are usually needed
- for real iPhone use: your own Apple signing team may be required
- `xcodegen` only when you change `ios/project.yml` or need to regenerate the checked-in Xcode project
- the app asks for microphone and Speech Recognition permission
- on a real iPhone, voice input uses Apple Speech Recognition first, so backend `OPENAI_API_KEY` is not required for the normal path
- backend `OPENAI_API_KEY` is still useful as a fallback for `/v1/audio`, especially from Simulator or non-iOS clients
- if the backend has no Codex/Claude CLI installed, the app can still follow the backend's internal `local` smoke/dev fallback

## Quick Start

### 1) Open the iOS project

From repo root:

```bash
cd ios
open VoiceAgentApp.xcodeproj
```

If you changed `ios/project.yml`, run `xcodegen generate` first.

### 2) Run the app in Xcode on a simulator first

In Xcode:
1. Select scheme `VoiceAgentApp`
2. Choose a simulator (for example `iPhone 17`)
3. Press Run

Starting on a simulator is the least friction path because it avoids signing and device-trust issues.

### 3) Run on a real iPhone (optional)

If you want to install on your own iPhone, expect one-time signing setup:

1. Open target `VoiceAgentApp` -> `Signing & Capabilities`
2. Select your own Apple development team
3. Repeat for `VoiceTaskWidgetExtension`
4. If Xcode reports bundle identifier conflicts, change them to unique values under your team
5. Rebuild for your phone

The checked-in project no longer hard-codes a development team, so Xcode should let you choose your own signing team cleanly.

### 4) Connect app to backend

Best option:
1. Generate/open `backend/pairing-qr.png`
2. Scan with iPhone camera
3. Open the `mobaile://pair...` link
4. Confirm pairing inside the app

Manual option in app Settings:
1. Set `Server URL` to your backend URL
2. Set `API Token` to `VOICE_AGENT_API_TOKEN` from `backend/.env`
3. Keep `Session ID` as `iphone-app` (or set your own)

If you are using a real iPhone, `127.0.0.1` will not work. Use a LAN or Tailscale URL from `backend/pairing.json`.

### 5) Send a request

- Type a prompt and tap `Send`
- Or use the mic button for audio input

## Common Problems (Fast Fixes)

- Code signing or provisioning errors on a real iPhone:
  - set your own team for both app targets and use unique bundle identifiers if needed
- App on real iPhone cannot reach backend:
  - do not use `127.0.0.1`; use LAN/Tailscale URL and make sure backend was installed with `--expose-network`
- Pairing link opens but app does not connect:
  - verify backend is running and token/session in pairing file are current
- Audio fails but text works:
  - enable `Speech Recognition` for MOBaiLE in iOS Settings
  - if you are on Simulator or local speech is unavailable, configure backend `OPENAI_API_KEY` for audio upload fallback

## Technical Notes

- `ios/VoiceAgentApp.xcodeproj` is checked in; `ios/project.yml` is the xcodegen source
- App code: `ios/VoiceAgentApp/`
- Tests: `ios/VoiceAgentAppTests/`
- Runtime flow:
  - record locally, transcribe with Apple Speech Recognition first, then create a run via `/v1/utterances`
  - if local speech is unavailable and backend transcription is configured, fall back to `/v1/audio`
  - stream events from `/v1/runs/{run_id}/events`
  - fallback polling from `/v1/runs/{run_id}`
- Run logs are available in-app via the logs screen

## Test Command

From `ios/`:

```bash
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' test
```

If `iPhone 17` is not available on your Xcode version, replace it with any available iPhone simulator from `xcrun simctl list devices available`.
