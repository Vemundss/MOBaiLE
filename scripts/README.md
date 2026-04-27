# Scripts

This file is an index, not the canonical setup guide. For installation, service management,
pairing, and end-to-end usage, prefer [`docs/USAGE.md`](../docs/USAGE.md).

## Start Here

Most people should start with the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/install.sh | bash
```

If you are already in a checkout, run:

```bash
bash ./scripts/install.sh --checkout "$PWD"
```

The installer asks three simple questions. The normal answers are `Full Access`,
`Anywhere with Tailscale`, and `Yes` for the background service. After setup, use
`mobaile status` to check the connection. If your shell does not find it yet, run
`~/.local/bin/mobaile status`. When you want the latest installed version later,
run `mobaile update`.

## Install and Bootstrap

- `install.sh`: main installer and onboarding flow
- `install_backend.sh`: lower-level backend-only install/configure path for the current checkout
- `set_security_mode.sh`: switch an existing `backend/.env` between `safe` and `full-access`
- `rotate_api_token.sh`: rotate `VOICE_AGENT_API_TOKEN` and refresh pairing code exports

## Operations

- `doctor.sh`: host/runtime health checks
- `service_macos.sh`: launchd install/start/stop/status/logs/sync
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
bash ./scripts/service_linux.sh status
bash ./scripts/pairing_qr.sh
cd backend && uv run python ../scripts/sync_contracts.py --check
```
