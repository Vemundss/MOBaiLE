# Architecture

This file is the short engineering map for contributors and coding agents.
`README.md` is product/setup oriented; this document focuses on how the app works today.
It is intentionally not a full API reference.

## Product Shape

MOBaiLE is an iPhone client plus a backend that runs on the user's own machine.
The phone captures prompts by text or voice, the backend executes them, and the app renders a chat-first view with optional logs and artifacts.

## Current Runtime Model

There are three execution paths:

1. `codex`
- Primary agent executor for normal use.
- Backend launches Codex CLI in the requested working directory.
- Backend injects repo-owned runtime context from `.mobaile/runtime/` and stages profile files into `.mobaile/`.

2. `claude`
- Alternate agent executor with the same phone/backend flow.
- Used when the host has Claude Code CLI installed and configured.

3. `local`
- Internal structured fallback path used mainly for deterministic local execution and tests when no agent executor is available.
- Uses a small `ActionPlan` plus policy validation; normal user runs should prefer `codex` or `claude`.

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

## Core Backend Flows

These are the important backend surfaces to understand before making changes:

- Pairing, host URLs, and auth: `pairing_service.py`, `pairing_state.py`, `pairing_url.py`, and `/v1/pair/*`
- Prompt submission: `utterance_service.py` plus `/v1/utterances` and `/v1/audio`
- Run execution and streaming: `execution_service.py`, `agent_run_service.py`, and `/v1/runs/*`
- Session/runtime controls: `runtime_session_service.py`, `session_runtime_state.py`, `/v1/config`, `/v1/slash-commands`, and `/v1/sessions/*`
- Workspace and uploads: `workspace_service.py`, `/v1/uploads`, `/v1/files`, and `/v1/directories`
- Typed contracts: `backend/app/models/schemas.py` and generated files in `contracts/`

For the current concrete endpoint list, read [`backend/app/main.py`](backend/app/main.py).

## Message Model

The phone UI is built around a typed chat envelope, not raw terminal text.

- `ChatEnvelope` carries `summary`, `sections`, `agenda_items`, `artifacts`, and typed phone-surface metadata for changed files, commands/tests, warnings, and next actions
- `message_kind` separates replaceable live progress from final user-facing results
- SSE run events include chat-oriented events and log-oriented events
- message IDs and timestamps are part of the schema for stable reconciliation

If you change backend response shapes, update the Pydantic schemas first and then sync the generated contracts.

## State and Persistence

Backend:
- run history is stored in SQLite
- profile-scoped `AGENTS.md` and `MEMORY.md` live under `backend/data/profiles/<profile_id>/`
- those files are private per-user runtime state, not repo-owned defaults
- repo-owned runtime defaults live under `.mobaile/runtime/`
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
