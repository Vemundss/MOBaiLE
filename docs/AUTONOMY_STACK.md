# Autonomous Agent Stack

This document maps the pieces required for a genuinely unattended server-side MOBaiLE agent and what the repo now provisions.

## Capability Layers

### 1. Executor privileges

Needed:

- full-access execution on trusted private hosts
- unrestricted file access when the machine is intentionally remote-controlled
- live web search for up-to-date tasks

Implemented:

- `VOICE_AGENT_SECURITY_MODE=full-access`
- `VOICE_AGENT_CODEX_UNRESTRICTED=true`
- `VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=true`
- `VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH=true`

### 2. Browser automation

Needed:

- a real browser control surface for modern web apps
- persistent browser state to keep logins and cookies
- traces and artifacts for debugging

Implemented:

- Codex MCP registration for `playwright`
- persistent browser profile via `VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR`
- saved browser artifacts via `VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR`

### 3. Native desktop automation

Needed:

- the ability to inspect and control the actual host desktop
- handling for permission prompts, password sheets, save dialogs, and native apps

Implemented:

- Codex MCP registration for `peekaboo`
- readiness probe for required macOS permissions

### 4. Skills / operating heuristics

Needed:

- explicit control-surface selection rules
- anti-stall behavior for auth gates and hidden UI

Implemented:

- repo-managed Codex skills:
  - `playwright`
  - `peekaboo`
  - `remote-operator`

### 5. Readiness checks

Needed:

- a way to verify the host is actually ready before the user leaves

Implemented:

- `/v1/capabilities` now reports:
  - Codex MCP config for Playwright and Peekaboo
  - installed Codex skills
  - Playwright persistence paths
  - Peekaboo permission status
  - Codex web-search status

## Real Limits

These still require explicit preparation or human involvement:

- macOS privacy permissions cannot be silently granted by a normal user-space script
- CAPTCHA and most 2FA challenges are intentionally human-bound
- passwords or secrets that are not already available on the host still need user action

For a truly unattended macOS deployment, prepare the machine once in person:

- grant Accessibility
- grant Screen Recording
- approve first-run Apple Events / automation prompts
- sign into the web apps the user expects to control

For fleet-grade deployment, the next step is MDM/PPPC-based permission pre-granting for the persistent host identity.

## Setup Commands

From repo root:

```bash
bash ./scripts/install_backend.sh --mode full-access --with-autonomy-stack
```

Managed install:

```bash
bash ./scripts/bootstrap_server.sh --mode full-access --with-autonomy-stack
```

Refresh Codex MCP + skills:

```bash
python3 ./scripts/provision_codex_autonomy.py --mode full-access
```

## Inspiration

This direction borrows the same core ideas used by OpenClaw:

- bundled skills instead of prompt-only hints
- explicit MCP/browser automation surfaces
- persistent browser state for authenticated sessions
- readiness checks for permission-sensitive desktop control
