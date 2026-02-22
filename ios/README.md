# iOS App

SwiftUI app that captures speech, sends transcripts to backend, and reads responses aloud.

Current MVP scaffold:
- App source files under `VoiceAgentApp/`
- test file under `VoiceAgentAppTests/`

## Quick start in Xcode

1. Create a new iOS App project in Xcode:
- Product Name: `VoiceAgentApp`
- Interface: `SwiftUI`
- Language: `Swift`
- Use Swift Testing: unchecked (XCTest is fine)

2. Replace generated app files with files from:
- `ios/VoiceAgentApp/`

3. Add test file:
- `ios/VoiceAgentAppTests/VoiceAgentModelTests.swift`

4. In app UI:
- Set `Server URL` to your reachable backend URL (not `127.0.0.1` when running on phone).
- Set `API Token` from `backend/.env` (`VOICE_AGENT_API_TOKEN`).
- Choose executor (`local` first, then `codex`).
- Tap `Send Prompt` for text flow.
- Or use `Start Recording` -> `Stop & Send Audio` for `/v1/audio` flow.

5. Expected MVP behavior:
- App creates run via `/v1/utterances`.
- App can upload recorded audio via `/v1/audio`.
- App polls `/v1/runs/{run_id}` until completion.
- App shows events and reads summary aloud.

## Notes

- This scaffold currently sends text prompts; on-device speech-to-text capture can be added next.
- Add microphone usage description key in your Xcode target Info settings:
  - `Privacy - Microphone Usage Description`
- For immediate phone voice testing today, use `docs/PHONE_SHORTCUT_MVP.md`.
