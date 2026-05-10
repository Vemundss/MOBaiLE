# Scripts

This file is an index, not the canonical setup guide. For installation, service management,
pairing, and end-to-end usage, prefer [`docs/USAGE.md`](../docs/USAGE.md).

## Start Here

Most people should start with the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/mobaile/main/scripts/install.sh | bash -s -- --yes
```

If you are already in a checkout, run:

```bash
bash ./scripts/install.sh --checkout "$PWD"
```

The pasted one-liner uses the recommended answers: `Full Access`,
`Anywhere with Tailscale`, and `Yes` for the background service. After setup, use
`mobaile setup` on the backend computer for the computer-local checklist, or `mobaile status` to check the connection. If your shell does not find it yet, run
`~/.local/bin/mobaile status`. On macOS, run `mobaile awake` when this host should
stay reachable while you are logged in, and `mobaile awake-status` to check it.
Run `mobaile first-run` for a safe starter task in `~/MOBaiLE-playground`.
Run `mobaile demo --out mobaile-demo.md` when you want a sanitized proof artifact
for README updates, launch posts, or a quick product walkthrough.
Run `mobaile ready --open-permissions` on the Mac when you want to finish
high-autonomy readiness, including browser and desktop automation checks.
Use `mobaile check` for preflight and `mobaile repair` to refresh pairing, restart the
service when installed, and run diagnostics. When you want the latest installed version
later, run `mobaile update`.

Other useful one-liners:

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/mobaile/main/scripts/install.sh | bash -s -- --yes --phone-access wifi
curl -fsSL https://raw.githubusercontent.com/vemundss/mobaile/main/scripts/install.sh | bash -s -- --yes --mode safe --phone-access local --background-service no
curl -fsSL https://raw.githubusercontent.com/vemundss/mobaile/main/scripts/install.sh | bash -s -- --yes --dry-run
```

## Install and Bootstrap

- `install.sh`: main installer and onboarding flow
- `install_backend.sh`: lower-level backend-only install/configure path for the current checkout
- `set_security_mode.sh`: switch an existing `backend/.env` between `safe` and `full-access`
- `rotate_api_token.sh`: rotate `VOICE_AGENT_API_TOKEN` and refresh pairing code exports

## Operations

- `doctor.sh`: host/runtime health checks; use `mobaile doctor` for pairing, URL, Codex, and keep-awake readiness
- `mobaile setup`: open the computer-local setup page with QR, readiness, and first-run status
- `mobaile check`: concise setup preflight for dependencies, phone access, service, and pairing
  - use `mobaile check --json` when another tool or UI needs structured readiness state
- `mobaile ready`: guided high-autonomy readiness flow for service, keep-awake, automation, and final checks
- `mobaile autonomy`: provision Codex MCP browser/desktop automation against the active backend runtime
- `mobaile first-run`: starter playground run through the paired backend
- `mobaile demo`: export a sanitized Markdown or JSON demo replay from a sample or existing run
- `mobaile repair`: restart service when installed, refresh pairing QR, and run diagnostics
- `mobaile uninstall`: stop background services and optionally delete local MOBaiLE data
- `service_macos.sh`: launchd install/start/stop/status/logs/sync plus keep-awake helpers
- `service_linux.sh`: systemd user-service install/start/stop/status/logs/sync
- `warmup_capabilities.sh`: preflight capabilities and runtime readiness
- `pairing_qr.sh`: generate pairing QR from `backend/pairing.json`
- `phone_connectivity_smoke.sh`: end-to-end connectivity smoke test
- `ios_pairing_e2e.sh`: simulator-driven iOS pairing test against the live backend; defaults to the simulator-safe `127.0.0.1` backend route

## Contracts and Autonomy

- `sync_contracts.py`: refresh checked-in contracts from backend schemas
- `provision_codex_autonomy.py`: provision Codex MCP configuration for trusted hosts

## Release and App Store

- `capture_app_store_screenshots.sh`: capture screenshot set into `build/`
- `render_app_store_screenshots.py`: process screenshot assets
- `ios_release_version.rb`: inspect or compute iOS release versions

## Optional npm Wrappers

```bash
npm run shell:lint
npm run shell:format
npm run setup:server
npm run setup:server:auto
npm run backend:install
npm run backend:install:auto
npm run backend:start
npm run doctor
npm run pair:qr
npm run ios:open
npm run ios:version
```

## Shell Tooling

Shell scripts in `scripts/` use a small shared wrapper:

```bash
bash ./scripts/shell_checks.sh lint
bash ./scripts/shell_checks.sh format
```

The lint command runs `shellcheck` and `shfmt -d`. The format command rewrites the shell
scripts in place with `shfmt`.

Install those tools with your preferred package manager before running the checks locally.

## Common Direct Commands

```bash
bash ./scripts/doctor.sh
bash ./scripts/service_macos.sh status
bash ./scripts/service_macos.sh keep-awake-status
bash ./scripts/service_linux.sh status
bash ./scripts/pairing_qr.sh
cd backend && uv run python ../scripts/sync_contracts.py --check
```

When a backend-launched MOBaiLE agent runs a service `restart`, the service scripts defer the actual restart until the active run leaves `running` state. Human shell restarts still run immediately.
