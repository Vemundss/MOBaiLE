# iPhone App

<p align="center">
  <img src="../docs/readme-screens/conversation.png" alt="MOBaiLE conversation screen on iPhone" width="250" />
</p>

MOBaiLE on iPhone is the handheld client for your paired backend.
You open the app, connect it to your own machine, send text or voice requests, and follow the run without going back to your laptop.

## What You Can Do From The Phone

- Send a text prompt to your paired backend
- Record a voice task instead of typing
- Watch progress and final result inside the same thread
- Reuse the same workspace and thread context across runs

You do not need to understand agents, Xcode, or internal backend details to use the app once it is paired.

## If You Just Want To Use MOBaiLE

This is the shortest human path:

1. Make sure your backend is already running.
2. Open `backend/pairing-qr.png` on your computer.
3. Scan it with the iPhone camera.
4. Open the `mobaile://pair...` link.
5. Confirm the pairing inside MOBaiLE.
6. Send a prompt or tap the mic button.

Manual fallback inside app Settings:

1. Set `Server URL` to the value from `backend/pairing.json`
2. Set `API Token` to `VOICE_AGENT_API_TOKEN` from `backend/.env`
3. Keep `Session ID` as `iphone-app` unless you want a custom one

Important:

- if you are using a real iPhone, `127.0.0.1` will not work
- use a LAN or Tailscale URL from `backend/pairing.json`
- the app asks for microphone and Speech Recognition permission

## If You Are Building It From This Repo

### Fastest path: simulator first

From repo root:

```bash
cd ios
open VoiceAgentApp.xcodeproj
```

In Xcode:

1. Select scheme `VoiceAgentApp`
2. Choose a simulator such as `iPhone 17`
3. Press Run

Starting on Simulator is the least-friction path because it avoids signing and device trust issues.

If you changed `ios/project.yml`, run `xcodegen generate` first.

### Real iPhone install

If you want to run the app on your own iPhone, expect one-time signing setup:

1. Open target `VoiceAgentApp` -> `Signing & Capabilities`
2. Select your Apple development team
3. Repeat for `VoiceTaskWidgetExtension`
4. If Xcode reports bundle identifier conflicts, change them to unique values under your team
5. Rebuild for your phone

The checked-in project does not hard-code a development team, so Xcode should let you choose your own signing team cleanly.

## Features Worth Turning On

- **Widget:** add `Start Voice Task` to jump straight into recording
- **Haptic and audio cues:** helpful when you are using the app while walking or multitasking
- **Auto-send after silence:** useful for hands-free voice capture
- **Siri and Shortcuts:** supports `Start Voice Task` and `Send Last Prompt`

## Fast Fixes

- App on real iPhone cannot reach backend:
  - do not use `127.0.0.1`
  - use a LAN or Tailscale URL
  - make sure the backend was installed with `--expose-network`

- Real iPhone shows `App Transport Security requires the use of a secure connection`:
  - Debug builds allow plain `http://` backend URLs
  - Release-style builds still require `https://` or a local Bonjour host such as `*.local`

- Pairing link opens but app does not connect:
  - verify the backend is running
  - verify the pair code and session in `backend/pairing.json` are current
  - verify `VOICE_AGENT_API_TOKEN` in `backend/.env` matches the running backend
  - if pairing fails immediately, rotate the pairing file first with `bash ./scripts/rotate_api_token.sh`

- Audio fails but text works:
  - enable `Speech Recognition` for MOBaiLE in iOS Settings
  - if you are on Simulator or local speech is unavailable, configure backend `OPENAI_API_KEY` for audio-upload fallback

## Developer Notes

- `ios/VoiceAgentApp.xcodeproj` is checked in
- `ios/project.yml` is the xcodegen source
- app code lives in `ios/VoiceAgentApp/`
- tests live in `ios/VoiceAgentAppTests/`
- local speech recognition is attempted first on real iPhone, with backend `/v1/audio` as fallback when configured
- run logs are available in-app through the logs screen

## Test Command

From `ios/`:

```bash
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' test
```

If `iPhone 17` is not available on your Xcode version, replace it with any available iPhone simulator from `xcrun simctl list devices available`.

For App Store release prep, see [`docs/APP_STORE_SUBMISSION.md`](../docs/APP_STORE_SUBMISSION.md).
