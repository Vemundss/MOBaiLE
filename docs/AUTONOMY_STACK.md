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

### 4. Runtime prompt guidance

Needed:

- explicit control-surface selection rules
- anti-stall behavior for auth gates and hidden UI

Implemented:

- repo-owned runtime context injected by the backend from `.mobaile/runtime/RUNTIME_CONTEXT.md`

### 5. Readiness checks

Needed:

- a way to verify the host is actually ready before the user leaves

Implemented:

- `/v1/capabilities` now reports:
  - Codex MCP config for Playwright and Peekaboo
  - Playwright persistence paths
  - Peekaboo permission status
  - Codex web-search status
- `/v1/setup/readiness` includes an `autonomy` summary for setup clients
- `mobaile autonomy` provisions Codex MCP against the active installed backend runtime paths

### 6. Credential handoff foundation

Needed:

- phone-side prompts for usernames, passwords, and tokens
- no raw secrets in normal chat, activity logs, or persisted metadata
- opaque handles that backend tools can resolve later

Implemented:

- `/v1/credential-requests` creates and lists credential prompts
- `/v1/credential-requests/{id}/fulfill` accepts submitted values and returns an opaque handle
- `/v1/credential-requests/{id}/resolve` lets localhost-only host tooling consume fulfilled values
- persisted request metadata records only submitted field names and handles, never submitted values
- repo-owned runtime guidance tells agents to use the handoff and avoid printing secrets

## Real Limits

These still require explicit preparation or human involvement:

- macOS privacy permissions cannot be silently granted by a normal user-space script
- CAPTCHA and most 2FA challenges are intentionally human-bound
- passwords or secrets that are not already available on the host still need user action
- persistent Keychain-backed credential storage is not implemented yet; current credential fulfillment is volatile and consume-on-read by default
- browser/native automation still needs first-class helpers that consume credential handles without exposing values to logs or chat

For a truly unattended macOS deployment, prepare the machine once in person:

- grant Accessibility
- grant Screen Recording
- approve first-run Apple Events / automation prompts
- sign into the web apps the user expects to control

For fleet-grade deployment, the next step is MDM/PPPC-based permission pre-granting for the persistent host identity.

## Setup Commands

From repo root:

```bash
bash ./scripts/install.sh --checkout "$PWD"
```

After backend-only/manual setup:

```bash
mobaile autonomy
```

Verify macOS permissions and open the relevant System Settings panes:

```bash
mobaile autonomy --deep --open-permissions
```

## Inspiration

This direction borrows the same core ideas used by OpenClaw:

- explicit MCP/browser automation surfaces
- persistent browser state for authenticated sessions
- readiness checks for permission-sensitive desktop control
