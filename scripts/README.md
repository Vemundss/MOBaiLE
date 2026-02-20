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

Smoke test:

```bash
cd backend
uv run python ../scripts/backend_smoke.py
```
