# Scripts

Utility scripts for local dev tasks (smoke tests, local setup, helpers).

Bootstrap backend on a host/server (clone/update + install + service + pairing QR):

```bash
bash ./scripts/bootstrap_server.sh --mode safe
# or:
bash ./scripts/bootstrap_server.sh --mode full-access
```

Install backend (one-command setup):

```bash
bash ./scripts/install_backend.sh --mode safe
# or:
bash ./scripts/install_backend.sh --mode full-access
```

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

Smoke test:

```bash
cd backend
uv run python ../scripts/backend_smoke.py
```
