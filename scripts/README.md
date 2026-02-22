# Scripts

Utility scripts for local dev tasks (smoke tests, local setup, helpers).

Install backend (one-command setup):

```bash
bash ./scripts/install_backend.sh
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
```

Smoke test:

```bash
cd backend
uv run python ../scripts/backend_smoke.py
```
