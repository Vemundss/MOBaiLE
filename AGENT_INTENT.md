# MOBaiLE Agent Intent

This file captures strategic intent and quality expectations for agents and contributors working in this repository.

## Product direction

MOBaiLE is building a stable, user-friendly, feature-rich remote computer companion:

- Keep phone UX clean and conversational, with logs/debug output separated from chat.
- Use the backend as a reliable control plane with typed contracts, observability, and recoverability.
- Support engineering workflows first, while expanding to normal productivity tasks (calendar/email/files).

## Core execution flow

1. Capture spoken user input on iPhone.
2. Transcribe speech to text.
3. Send text to backend API orchestrator.
4. Use an LLM to plan safe, structured actions.
5. Execute actions on a target machine (local sandbox first, remote host later).
6. Return execution updates/results to phone and read final output aloud.

## Quality bar

Applies to all meaningful changes:

- Prefer explicit typed contracts over heuristic text parsing.
- Avoid patch-only UI fixes where a schema/contract change is the right solution.
- Add tests and operational docs for behavior changes.
- Keep security and safety controls explicit, especially for unrestricted execution paths.

## Distribution vision

- iOS app is distributed to end users via TestFlight/App Store.
- Backend is installed on the target machine from this repo with one-command setup.
- Setup should output server URL + pairing token/QR for one-time pairing from phone.

## Bootstrap reference

```bash
git clone https://github.com/vemundss/MOBaiLE.git && cd MOBaiLE && bash ./scripts/bootstrap_server.sh --mode safe
```

Modes:

- `safe` (recommended): restricted workdir + restricted file reads + no unrestricted codex flag.
- `full-access`: unrestricted codex/filesystem behavior for trusted private hosts.
