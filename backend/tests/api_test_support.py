from __future__ import annotations

import importlib
import time
from pathlib import Path

from fastapi.testclient import TestClient


def auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def reload_module(name: str):
    module = importlib.import_module(name)
    return importlib.reload(module)


def wait_for_run_to_settle(
    client: TestClient,
    token: str,
    run_id: str,
    *,
    attempts: int = 80,
    delay: float = 0.05,
) -> dict[str, object]:
    payload: dict[str, object] | None = None
    for _ in range(attempts):
        run_resp = client.get(f"/v1/runs/{run_id}", headers=auth_headers(token))
        assert run_resp.status_code == 200
        payload = run_resp.json()
        if payload["status"] != "running":
            return payload
        time.sleep(delay)

    assert payload is not None
    assert payload["status"] != "running"
    return payload


def write_executable(path: Path, script: str) -> Path:
    path.write_text(script, encoding="utf-8")
    path.chmod(0o755)
    return path
