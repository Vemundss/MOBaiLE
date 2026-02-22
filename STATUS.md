# Project Status

Last updated: 2026-02-19

## 1) Snapshot

Project stage: MVP vertical slice implementation.
Current objective: complete phone-to-backend-to-executor loop for remote "vibe coding".

Updates (2026-02-18 to 2026-02-19):
- Created an initial lean monorepo scaffold:
  - `contracts/`
  - `backend/` (FastAPI starter + `pyproject.toml`)
  - `ios/` (placeholder structure/docs)
  - `infra/` (optional, documented)
  - `scripts/`
- Implemented minimal backend execution loop:
  - `POST /v1/utterances` for request intake and synchronous execution.
  - `GET /v1/runs/{run_id}` for run/result retrieval.
  - Planner stub that maps utterance text to an `ActionPlan`.
  - Policy checks for allowlisted binaries and path safety.
  - Local sandbox executor for `write_file` and `run_command`.
  - Smoke script: `scripts/backend_smoke.py`.
- Switched local backend workflow to `uv`:
  - `cd backend && uv sync`
  - `uv run uvicorn app.main:app --reload`
  - `uv run python ../scripts/backend_smoke.py`
- Fixed backend packaging for `uv sync` by restricting setuptools package discovery to `app*`.
- Fixed smoke script import path so it works reliably from `backend/`.
- Refined MVP consensus:
  - iPhone = voice input/output client.
  - Backend = LLM planning + execution control plane.
  - Codex CLI runs unrestricted with full access on the target machine.
- Added product distribution requirement:
  - iOS app distribution + one-command backend install from repo.
  - Setup must produce pairing info (URL + token/QR) for app onboarding.
- Added setup scripts:
  - `scripts/install_backend.sh` for one-command backend setup + pairing file generation.
  - `scripts/doctor.sh` for dependency/runtime health checks.
- Added asynchronous run execution in backend:
  - `POST /v1/utterances` now starts runs and returns immediately with `Run started`.
  - Run status now includes `running` before terminal state.
- Added SSE endpoint:
  - `GET /v1/runs/{run_id}/events` for live event streaming.
- Added Codex executor path:
  - `executor="codex"` on utterance requests.
  - Codex CLI invoked via backend executor.
- Set Codex executor to unrestricted by default:
  - backend now passes `--dangerously-bypass-approvals-and-sandbox`
  - env toggle: `VOICE_AGENT_CODEX_UNRESTRICTED` (default `true`)
  - optional env override: `VOICE_AGENT_CODEX_MODEL`
- Implemented bearer token auth for all `/v1/*` endpoints:
  - token sourced from `VOICE_AGENT_API_TOKEN` (env or `backend/.env`)
  - `/health` remains open for liveness checks
- Added `POST /v1/audio` endpoint:
  - accepts multipart audio upload
  - performs MVP transcription via server adapter
  - starts run using same async execution pipeline
- Added transcription provider modes:
  - `mock` (default)
  - `openai` (`/v1/audio/transcriptions` with API key)
- Added SQLite run persistence:
  - runs/events now survive backend restart
  - default DB path: `backend/data/runs.db`
- Added backend API test suite (`pytest`) for:
  - auth requirements
  - local utterance flow
  - `/v1/audio` mock flow
  - `/v1/audio` openai misconfig handling
- Added macOS launchd service management:
  - `scripts/service_macos.sh` (`install/start/stop/restart/status/logs/sync`)
  - service runs from synced runtime path:
    `~/Library/Application Support/MOBaiLE/backend-runtime`
  - verified health/auth checks through service process
- Added pairing-based end-to-end connectivity smoke script:
  - `scripts/phone_connectivity_smoke.sh`
  - verifies health, auth enforcement, `/v1/audio`, and terminal run status
- Added immediate iPhone test path without native app code:
  - `docs/PHONE_SHORTCUT_MVP.md` (Shortcuts workflow: dictate -> run -> poll -> speak)
- Added native iOS app scaffold files:
  - SwiftUI app entry + content view
  - API client for `/v1/utterances` and `/v1/runs/{id}`
  - run polling + TTS in view model
  - model decoding test template
- Extended native iOS scaffold with audio upload path:
  - local microphone recording in app
  - upload recorded file to `/v1/audio`
  - show transcript + run events + spoken summary
- Added native iOS SSE event streaming:
  - app now streams `/v1/runs/{run_id}/events` for live updates
  - automatic fallback to polling when stream fails
- Added GitHub Actions backend CI:
  - `.github/workflows/backend-tests.yml`
  - runs `uv sync` + `uv run pytest -q` on push/PR
- Added Xcode project generation/wiring:
  - `ios/project.yml` (xcodegen spec)
  - generated `ios/VoiceAgentApp.xcodeproj`
  - simulator build + test verified via `xcodebuild`

## 2) What Exists

- `README.md`: project intent and document map.
- `ARCHITECTURE.md`: detailed architecture and phased implementation plan.
- `STATUS.md`: current state tracker (this file).
- `MEMORY.md`: persistent project memory log.

## 3) Working vs Not Working

Working:
- Shared vision and architecture documented.
- Phased roadmap defined with exit criteria.
- Initial data contracts and action schema documented.
- Baseline folder layout and backend starter app created.
- Minimal backend request -> plan -> validate -> execute -> result flow is functional.
- `uv` local workflow is verified end-to-end.
- SSE event stream endpoint is implemented and verified.
- Codex executor integration path is implemented (runtime success depends on local Codex auth/model access).
- `/v1/audio` is implemented and verified end-to-end (auth, run creation, run completion).
- Run history persistence across backend restarts is implemented and verified.
- Always-on backend service flow is implemented and verified on macOS.
- Pairing-based connection smoke passes end-to-end.
- iPhone Shortcuts-based voice loop is documented for immediate device testing.
- Native iOS scaffold exists for direct backend testing in Xcode.
- Native iOS project builds and tests successfully on simulator.
- Native iOS app now receives run updates in real time via SSE.

Not implemented yet:
- Production-ready native iOS project wiring (Xcode target + signing + permissions setup).
- LLM integration.
- Production-ready speech-to-text tuning/retry/error UX (openai mode is implemented, not hardened).
- SSH executor.
- CI automation for running tests on push/PR.
- Service hardening for internet exposure (reverse proxy/TLS/rate limiting).

## 4) Risks / Unknowns

- Unrestricted execution increases blast radius; target should be isolated/dedicated.
- iOS speech-to-text mode (on-device vs cloud) needs explicit decision.
- LLM placement choice (backend-only vs partial phone-side) impacts security and key handling.
- Public internet exposure requires auth + transport hardening before non-local use.

## 5) Immediate Next Steps

1. Add automated tests for current backend flow and unrestricted executor path.
2. Add simple backend LLM planner integration behind current planner stub.
3. Add SSE endpoint for live run events.
4. Add service auto-start setup (systemd/launchd) to installer.
5. Build minimal iOS client loop:
- speech capture + transcription
- send utterance to backend
- show events/final text
- speak final response

## 6) Definition of Done for MVP

MVP is done when:
- Spoken request from iPhone can trigger code creation/execution on the target machine (structured mode or unrestricted Codex mode).
- Output is returned to phone (polling or streaming), then summarized.
- Final response is read aloud in app.
- Each run has a complete audit trail.

## 7) Tracking Rules

Update this file after each meaningful milestone:
- What changed.
- What works now.
- What broke or is blocked.
- Exact next actions.
