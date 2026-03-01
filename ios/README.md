# iOS App

SwiftUI app that captures speech, sends transcripts to backend, and reads responses aloud.

Current MVP scaffold:
- App source files under `VoiceAgentApp/`
- test file under `VoiceAgentAppTests/`

## Quick start in Xcode

1. Generate/open project:

```bash
cd ios
xcodegen generate
open VoiceAgentApp.xcodeproj
```

2. In Xcode:
- Select scheme `VoiceAgentApp`
- Choose iOS Simulator (for example `iPhone 17`)
- Build/Run

3. In app UI:
- Set `Server URL` to your reachable backend URL (not `127.0.0.1` when running on phone).
- Set `API Token` from `backend/.env` (`VOICE_AGENT_API_TOKEN`).
- Default mode uses `codex`; enable Developer Mode if you want to switch executor manually.
- Tap `Send Prompt` for text flow.
- Or use `Start Recording` -> `Stop & Send Audio` for `/v1/audio` flow.

4. Expected MVP behavior:
- App creates run via `/v1/utterances`.
- App can upload recorded audio via `/v1/audio`.
- App streams `/v1/runs/{run_id}/events` with polling fallback.
- App shows events and reads summary aloud.

## Notes

- This scaffold currently sends text prompts; on-device speech-to-text capture can be added next.
- Add microphone usage description key in your Xcode target Info settings:
  - already set in generated project (`NSMicrophoneUsageDescription`)
- For immediate phone voice testing today, use `docs/PHONE_SHORTCUT_MVP.md`.
