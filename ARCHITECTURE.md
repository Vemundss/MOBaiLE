# Architecture

This file is the short engineering map for the current repo.
`README.md` is product/setup oriented; this document focuses on how the app works today.

## Product Shape

MOBaiLE is an iPhone client plus a backend that runs on the user's own machine.
The phone captures prompts by text or voice, the backend executes them, and the app renders a chat-first view with optional logs and artifacts.

## Current Runtime Model

There are three execution paths:

1. `codex`
- Primary agent executor for normal use.
- Backend launches Codex CLI in the requested working directory.
- Backend injects MOBaiLE-specific context and stages profile files into `.mobaile/`.

2. `claude`
- Alternate agent executor with the same phone/backend flow.
- Used when the host has Claude Code CLI installed and configured.

3. `local`
- Structured fallback path used mainly for deterministic local execution and testing.
- Uses a small `ActionPlan` plus policy validation instead of an external coding agent.

A fourth path exists for deterministic calendar requests:
- backend handles "today" calendar queries with a typed adapter instead of a general-purpose agent run.

## Main Components

### iOS app

- SwiftUI client in `ios/VoiceAgentApp/`
- Records audio, uploads files, manages pairing, stores local chat threads
- Renders structured assistant content, artifacts, and raw run logs separately
- Supports widgets and App Intents for quick launch flows

### backend

- FastAPI app in `backend/app/main.py`
- Authenticates requests, starts runs, streams events, stores run history
- Exposes runtime configuration, file browsing, upload, capabilities, pairing, and diagnostics endpoints

### contracts

- Source of truth lives in `backend/app/models/schemas.py`
- Generated artifacts live in `contracts/`
- Refresh with `uv run python ../scripts/sync_contracts.py` from `backend/`

## Core API Surfaces

These are the important live endpoints:

- `POST /v1/pair/exchange`
- `POST /v1/utterances`
- `POST /v1/audio`
- `POST /v1/uploads`
- `GET /v1/runs/{run_id}`
- `GET /v1/runs/{run_id}/events`
- `POST /v1/runs/{run_id}/cancel`
- `GET /v1/runs/{run_id}/diagnostics`
- `GET /v1/config`
- `GET /v1/capabilities`
- `GET /v1/tools/calendar/today`
- `GET /v1/files`
- `GET/POST /v1/directories`

## Message Model

The phone UI is built around a typed chat envelope, not raw terminal text.

- `ChatEnvelope` carries `summary`, `sections`, `agenda_items`, and `artifacts`
- SSE run events include chat-oriented events and log-oriented events
- message IDs and timestamps are part of the schema for stable reconciliation

If you change backend response shapes, update the Pydantic schemas first and then sync the generated contracts.

## State and Persistence

Backend:
- run history is stored in SQLite
- profile-scoped `AGENTS.md` and `MEMORY.md` live under `backend/data/profiles/<profile_id>/`
- profile files are staged into each run working directory under `.mobaile/`

iOS:
- thread metadata and messages are stored locally
- API token is stored in Keychain

## Security Model

Runtime security is explicit and mode-based:

- `safe`: restricted workdir, restricted file reads, safer agent defaults
- `full-access`: intended only for trusted private hosts

Pairing uses one-time `pair_code` exchange, not QR-embedded long-lived API tokens.
For non-local hosts, pairing requires HTTPS.

## Contributor Notes

When changing behavior, keep these rules intact:

- Prefer typed contracts over UI heuristics.
- Keep chat output separate from diagnostic logs.
- Preserve the backend as the control plane; the phone should stay thin.
- Update docs, tests, and contracts together when external behavior changes.
