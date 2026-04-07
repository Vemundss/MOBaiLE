# Backend App Code Map

This package contains the FastAPI control plane that the iPhone app talks to.

## File Ownership

- `main.py`: API wiring, endpoint handlers, and request-level orchestration.
- `capabilities.py`: capability-report composition and JSON report persistence.
- `capability_probes.py`: concrete capability probes for local binaries, Codex integrations, Playwright state, Peekaboo permissions, and Calendar readiness.
- `agent_run_service.py`: Codex/Claude process lifecycle, streaming output parsing, session linking, and timeout/cancel/block handling.
- `agent_stream_handler.py`: executor stream protocol parsing, agent-session linking, assistant payload capture, and human-unblock detection.
- `agent_process_monitor.py`: stdout draining, queue polling, cancellation/timeout checks, and process shutdown during agent runs.
- `agent_run_finalizer.py`: final run-status/event mapping for success, failure, cancel, block, timeout, and missing-binary exits.
- `execution_service.py`: long-running run execution and executor dispatch.
- `calendar_service.py`: narrow macOS Calendar bridge for today's agenda lookups.
- `chat_attachments.py`: attachment parsing, upload classification, and utterance/attachment prompt rendering.
- `pairing_url.py`: pairing server URL detection and pairing-file refresh flow.
- `pairing_url_policy.py`: server URL normalization, phone-access-mode matching, and IP/host classification helpers.
- `pairing_service.py`: pairing-file persistence, paired-phone credential issuance/refresh, and pairing rate limiting.
- `pairing_state.py`: pairing-file reads/writes, server URL list shaping, and paired-client credential record persistence.
- `phone_access_mode.py`: shared phone access mode type/options normalization.
- `runtime_session_service.py`: slash-command catalog/execution and runtime-setting UX.
- `session_context_service.py`: session-context reads, patch application, normalization, and persistence.
- `runtime_settings_catalog.py`: runtime-setting metadata, slash-command generation, and per-executor setting validation.
- `runtime_executor_catalog.py`: runtime executor descriptors and `/v1/config` projection for available executors and model settings.
- `session_runtime_state.py`: session runtime-setting hydration, legacy override handling, and response serialization.
- `utterance_service.py`: run-submission orchestration for text/audio prompts, guardrails, executor routing, and background launch.
- `workspace_service.py`: file serving, directory management, and upload placement inside allowed roots.
- `runtime_environment.py`: environment parsing, defaults, executor availability, and runtime guardrails.
- `runtime_environment_loader.py`: env-to-settings parsing for workspace, agent runtime, profile state, and resource/storage limits.
- `storage/run_store.py`: SQLite persistence for runs, events, session context, and agent session reuse.
- `profile_store.py`: persistent `AGENTS.md` and `MEMORY.md` profile storage plus workdir staging.
- `models/schemas.py`: typed API contracts. This is the source of truth for request/response shapes.

## Editing Guidelines

- Update `models/schemas.py` first when API shapes change, then sync `contracts/`.
- Keep endpoint behavior thin where possible and push reusable persistence/runtime logic into dedicated modules.
- Compatibility shims are intentionally date-tagged; keep them obvious and easy to delete once migration windows pass.
- Preserve the separation between chat output, diagnostic logs, and persistent run/session state.

## Safe Refactor Boundaries

- Request validation/serialization changes usually stay in `main.py`, `calendar_service.py`, `runtime_session_service.py`, `session_context_service.py`, `runtime_settings_catalog.py`, `runtime_executor_catalog.py`, `session_runtime_state.py`, `utterance_service.py`, `pairing_service.py`, `pairing_state.py`, `pairing_url.py`, `pairing_url_policy.py`, `phone_access_mode.py`, `workspace_service.py`, `chat_attachments.py`, `capabilities.py`, and `models/schemas.py`.
- Storage changes belong in `storage/run_store.py` with tests in `backend/tests/test_run_state.py` or `backend/tests/test_api.py`.
- Executor/runtime behavior changes usually involve `agent_run_service.py`, `agent_stream_handler.py`, `agent_process_monitor.py`, `agent_run_finalizer.py`, `execution_service.py`, `runtime_environment.py`, `runtime_environment_loader.py`, `capability_probes.py`, and the executor modules together.
