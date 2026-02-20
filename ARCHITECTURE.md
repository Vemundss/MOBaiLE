# Architecture and Implementation Plan

## 1) Product Goal

Build a voice-first iPhone assistant that can convert speech to text, reason over requests with an AI, execute coding operations on a machine (structured mode and/or unrestricted Codex mode), then stream results back to the user and speak them aloud.

## 1.1) MVP Consensus (2026-02-19)

Primary user outcome:
- Start "vibe coding" on an external computer from an iPhone.

MVP pipeline:
1. iPhone captures voice input.
2. Speech is converted to text (on-device or cloud speech-to-text).
3. Transcript is sent to backend over HTTPS.
4. Backend uses an LLM to turn intent into structured actions.
5. Backend executes actions on target machine.
6. Backend returns step events and final result text to iPhone.
7. iPhone displays result and reads final response aloud.

Boundary decision for MVP:
- Keep orchestration and action execution authority on backend.
- Codex CLI runs in unrestricted mode with full access to the target machine.
- Safety boundary is environment-level isolation (dedicated host/VM) plus audit logging.

## 2) Core Principles

- Safety before autonomy: execute only validated structured actions.
- Determinism over free-form shelling: LLM emits action JSON, not arbitrary shell.
- Explainability: each step is logged and inspectable.
- Iterative delivery: ship a vertical slice first, then expand capabilities.
- Reproducibility: everything needed to continue work is captured in repo docs.

## 3) High-Level System Design

## Components

1. iOS Client (SwiftUI)
- Audio capture, speech-to-text, user interaction.
- Sends transcript and metadata to backend.
- Receives streamed execution events and final response.
- Speaks response via text-to-speech.

2. API Gateway / Orchestrator (FastAPI)
- Authenticates app requests.
- Maintains session and conversation context.
- Calls LLM for planning into structured actions.
- Applies policy checks in structured mode; enforces auth/isolation controls in unrestricted Codex mode.
- Routes actions to executor(s) and streams progress to client.

3. Policy and Validation Layer
- JSON schema validation for action plans.
- Rule engine for command/file/network constraints.
- Approval gates for risky operations.

4. Execution Layer
- Local sandbox runner (Docker/VM/jail) for safe code execution.
- SSH executor for remote machine operations.
- Unified event format for stdout/stderr/exit status/artifacts.

5. State and Storage
- Session store (Redis/Postgres).
- Durable run logs/audit logs (Postgres/object storage).
- Optional artifact storage for generated files and outputs.

6. LLM Provider Integration
- Primary model for intent parsing, planning, summarization.
- Optional fallback model for resilience.
- Preferred MVP placement: backend-side LLM calls for centralized keys, policy, and logging.
- Optional future mode: phone-side LLM calls for latency/privacy tradeoffs.

## Data Flow

1. User speaks in app.
2. App transcribes to text.
3. App sends `UserUtterance` payload to backend.
4. Backend asks LLM for `ActionPlan`.
5. Backend either validates actions (structured mode) or dispatches to unrestricted Codex executor mode.
6. Executor runs actions, streaming `ExecutionEvent`.
7. Backend summarizes outcome using LLM (optional).
8. App receives final text + events, speaks summary.

## 4) Canonical Contracts (MVP)

## API: `POST /v1/utterances`

Request:
- `session_id`
- `utterance_text`
- `device_time`
- `mode` (`assistant`, `execute`)

Response:
- `run_id`
- `status` (`accepted`, `needs_approval`, `rejected`)
- `message`

## API: `GET /v1/runs/{run_id}/events` (SSE/WebSocket)

Event types:
- `plan.generated`
- `plan.rejected`
- `action.started`
- `action.stdout`
- `action.stderr`
- `action.completed`
- `run.completed`
- `run.failed`

## ActionPlan schema (example)

```json
{
  "version": "1.0",
  "goal": "Create hello.py and run it",
  "actions": [
    {
      "type": "write_file",
      "path": "workspace/hello.py",
      "content": "print('hello')"
    },
    {
      "type": "run_command",
      "command": "python workspace/hello.py",
      "timeout_sec": 30
    }
  ]
}
```

Allowed initial action types:
- `write_file`
- `read_file`
- `list_dir`
- `run_command`
- `ssh_exec`
- `summarize_output`

## 5) Safety and Governance

For the current Codex-driven MVP mode, execution is intentionally unrestricted on the target machine.
Primary safeguard is deployment isolation (dedicated machine/VM), plus strong auth, network controls, and audit logs.

## Hard Constraints (must enforce in code)

- For structured-executor mode: no direct shell from model text; only typed actions.
- For structured-executor mode: command allowlist (start small).
- For unrestricted Codex mode: rely on environment isolation and host-level controls instead of per-command policy gates.
- Time/memory/process limits per action where technically feasible.
- Mask secrets in logs.

## Human-in-the-Loop Controls

- Optional for structured mode:
- `needs_approval` for risky categories (for example SSH on production hosts or writes outside workspace).

## Audit Requirements

- Store utterance, planned actions (if used), command output, and final response.
- Include timestamps and actor identity.

## 6) Implementation Roadmap

## Phase 0: Foundations (now)

- Create repo docs and decision records.
- Define API contracts and action schema.
- Scaffold backend service with health endpoints.

Exit criteria:
- `ARCHITECTURE.md`, `STATUS.md`, `MEMORY.md` present.
- Backend project skeleton committed.

## Phase 1: End-to-End Vertical Slice (MVP)

- iOS app captures voice and sends transcribed text.
- Backend creates simple plan for safe local execution.
- Local executor runs command in sandbox and streams output.
- App receives result and reads final summary aloud.

Exit criteria:
- Voice prompt "create hello script and run it" works end-to-end.

## Phase 2: SSH Execution + Stronger Safety

- Add SSH executor with key-based auth.
- Policy engine for host-level and command-level controls.
- Approval workflow for risky actions.

Exit criteria:
- Controlled remote command flow with approval and audit trace.

## Phase 3: Reliability + DX

- Retry strategies, idempotency keys, better error handling.
- Session memory and conversation history tools.
- Integration tests and basic load tests.

Exit criteria:
- Stable repeated runs and reproducible CI tests.

## Phase 4: Product Hardening

- User accounts/auth, encrypted secrets management.
- Monitoring dashboards + alerting.
- Beta release pipeline (TestFlight).

Exit criteria:
- Operational readiness for external testers.

## 6.1) Distribution and Setup Protocol (Product Requirement)

Target user experience for setup:
- Phone install: user downloads iOS app.
- Server install: user runs one setup command from the backend repo on the target machine.
- Pairing: setup outputs server URL and a pairing token (or QR payload) that user enters/scans in app.
- Verification: app has a "Test connection" step before first voice run.

Required backend packaging for this:
- `scripts/install_backend.sh` for one-command install/setup.
- `scripts/doctor.sh` for connectivity and dependency checks.
- Service management so backend auto-starts (systemd/launchd, depending on OS).
- Auto-generated config/token with minimal manual editing.

Default connectivity approach for MVP:
- Prefer private networking (for example Tailscale) to avoid public exposure during early versions.
- If public HTTPS is used, token auth is mandatory on non-health endpoints.

Design constraint:
- Non-technical users should be able to complete backend setup in under 10 minutes using copy/paste commands.

## 7) Suggested Repository Layout

```text
.
├── ARCHITECTURE.md
├── STATUS.md
├── MEMORY.md
├── README.md
├── backend/
│   ├── app/
│   │   ├── api/
│   │   ├── core/
│   │   ├── llm/
│   │   ├── policy/
│   │   ├── executors/
│   │   └── models/
│   ├── tests/
│   └── pyproject.toml
└── ios/
    ├── VoiceAgentApp/
    └── VoiceAgentAppTests/
```

## 8) Testing Strategy

Minimum required test layers:

- Unit: schema validation and execution/orchestration behavior.
- Integration: orchestrator + local executor + streaming events.
- End-to-end: iOS simulator to backend dev environment.

Smoke test scenario:
1. User asks to create/run a Python file.
2. Plan is generated and validated.
3. File is written in sandbox.
4. Command executes and output streams.
5. Final text response is returned and speakable.

## 9) Observability and Operations

- Structured logging with `run_id`, `session_id`, `action_id`.
- Metrics:
- Request latency, LLM latency, executor runtime.
- Success/failure rates by action type.
- Alert on repeated run failures and timeout spikes (and policy rejects if structured mode is enabled).

## 10) Decision Log (Living)

Current decisions:
- Backend stack: Python + FastAPI.
- Streaming: SSE first, WebSocket optional later.
- Execution target priority: local sandbox first, then SSH.
- Model output contract: JSON action plan with strict schema validation.
- MVP control plane: backend owns planning/execution; iPhone is voice UI + transport client.
- Codex CLI mode: unrestricted/full-access execution on a dedicated trusted target machine.

When a major choice changes, update this section and `MEMORY.md`.
