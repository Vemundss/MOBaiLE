# Scripts

Quick ways to install and operate the backend.

## Fastest Backend Install (No Clone Needed)

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/bootstrap_server.sh | bash -s -- --mode safe
```

This flow can install `uv` for you and manages a repo clone in `~/MOBaiLE` by default.

## Managed Install In `~/MOBaiLE`

```bash
bash ./scripts/bootstrap_server.sh --mode safe
# or:
bash ./scripts/bootstrap_server.sh --mode full-access
# or for the autonomous Codex stack:
bash ./scripts/bootstrap_server.sh --mode full-access --with-autonomy-stack
```

Note:
- `bootstrap_server.sh` clones or updates `~/MOBaiLE` unless you pass `--dir`
- use this when you want a managed install location, not when you specifically want to use your current checkout

## Use Your Current Checkout

```bash
bash ./scripts/install_backend.sh --mode safe
# or:
bash ./scripts/install_backend.sh --mode full-access
# or for the autonomous Codex stack:
bash ./scripts/install_backend.sh --mode full-access --with-autonomy-stack
```

Notes:
- `install_backend.sh` installs `uv` for you when it is missing
- `install_backend.sh` defaults to local-only bind (`127.0.0.1`)
- add `--expose-network` when you want phone pairing over LAN/Tailscale
- if no Codex/Claude CLI is installed, MOBaiLE keeps the internal `local` executor available for smoke/dev flows
- `--with-autonomy-stack` provisions Codex MCP servers and the managed skills pack for more autonomous remote control

## npm Command Wrappers (Optional)

From repo root:

```bash
npm run setup:server
npm run setup:server:auto
npm run backend:install:auto
npm run backend:start
npm run doctor
npm run pair:qr
npm run ios:open
npm run ios:version
```

For iOS release automation, see [`docs/IOS_RELEASE_AUTOMATION.md`](../docs/IOS_RELEASE_AUTOMATION.md).

## Direct Script Commands

After install, these are the most useful direct script commands.

`bootstrap_server.sh` already enables network exposure for you.

Run environment and connectivity checks:

```bash
bash ./scripts/doctor.sh
```

Install and manage backend as macOS launchd service:

```bash
bash ./scripts/service_macos.sh install
bash ./scripts/service_macos.sh sync
bash ./scripts/service_macos.sh status
bash ./scripts/service_macos.sh logs
bash ./scripts/service_macos.sh warmup
```

Install and manage backend as Linux systemd user service:

```bash
bash ./scripts/service_linux.sh install
bash ./scripts/service_linux.sh sync
bash ./scripts/service_linux.sh status
bash ./scripts/service_linux.sh logs
bash ./scripts/service_linux.sh warmup
```

Notes:
- Linux service management uses `systemd --user`.
- For always-on behavior after logout/reboot on headless hosts, you may need `sudo loginctl enable-linger $USER`.

Warmup runs automatically after `install/start/restart` unless disabled with:

```bash
export VOICE_AGENT_WARMUP_ON_START=false
```

Run capability warmup directly:

```bash
bash ./scripts/warmup_capabilities.sh
```

Run end-to-end connection smoke using `backend/pairing.json`:

```bash
bash ./scripts/phone_connectivity_smoke.sh
```

Generate a pairing QR from `backend/pairing.json`:

```bash
bash ./scripts/pairing_qr.sh
# Optional raw JSON payload QR:
bash ./scripts/pairing_qr.sh --format json
```

Rotate backend API token (updates `backend/.env` and `backend/pairing.json`):

```bash
bash ./scripts/rotate_api_token.sh
```

Provision or refresh the autonomous Codex stack:

```bash
python3 ./scripts/provision_codex_autonomy.py --mode full-access
```

Switch backend security mode after install:

```bash
bash ./scripts/set_security_mode.sh safe
bash ./scripts/set_security_mode.sh full-access
```

Sync checked-in contracts from backend models:

```bash
cd backend
uv run python ../scripts/sync_contracts.py
uv run python ../scripts/sync_contracts.py --check
```
