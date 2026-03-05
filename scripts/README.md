# Scripts

Quick ways to install and operate the backend.

## Fastest Backend Install (No Clone Needed)

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/bootstrap_server.sh | bash -s -- --mode safe
```

## If You Already Cloned the Repo

```bash
bash ./scripts/bootstrap_server.sh --mode safe
# or:
bash ./scripts/bootstrap_server.sh --mode full-access
```

## npm Command Wrappers (Optional)

From repo root:

```bash
npm run setup:server
npm run backend:start
npm run doctor
npm run pair:qr
```

## Direct Script Commands

Install backend only:

```bash
bash ./scripts/install_backend.sh --mode safe
# or:
bash ./scripts/install_backend.sh --mode full-access
```

Notes:
- `install_backend.sh` defaults to local-only bind (`127.0.0.1`).
- Add `--expose-network` when you want phone pairing over LAN/Tailscale.
- `bootstrap_server.sh` already enables network exposure for you.

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

Switch backend security mode after install:

```bash
bash ./scripts/set_security_mode.sh safe
bash ./scripts/set_security_mode.sh full-access
```
