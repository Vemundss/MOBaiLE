# Voice-to-Agent iPhone App

This project builds an iPhone app that:

1. Listens to spoken user input.
2. Transcribes speech to text.
3. Sends text to a backend API orchestrator.
4. Uses an LLM to plan safe, structured actions.
5. Executes those actions on a target machine (local sandbox first, remote host later).
6. Returns execution updates/results to the phone and reads final output aloud.

Current MVP focus:
- Use the phone as the voice UI (speech in, speech out).
- Use the backend as the control plane for planning and execution.
- Run Codex CLI in unrestricted mode with full machine access on the target host.
- Treat the target host as a dedicated trusted environment for this purpose.

Distribution vision:
- iOS app is installed by end users from TestFlight/App Store.
- Backend is installed on the target machine from this repo with a one-command setup script.
- Setup should output a server URL + pairing token/QR that the phone app can use to connect.

The implementation strategy, architecture, and rollout plan are documented in `ARCHITECTURE.md`.
Current execution status is tracked in `STATUS.md`.
Basic local setup and run instructions are in `docs/USAGE.md`.
Immediate iPhone testing path (Shortcuts-based) is in `docs/PHONE_SHORTCUT_MVP.md`.
