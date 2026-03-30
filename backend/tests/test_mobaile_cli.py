from __future__ import annotations

import os
from pathlib import Path
import subprocess


PROJECT_ROOT = Path(__file__).resolve().parents[2]


def test_mobaile_status_reports_running_summary(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "\n".join(
            [
                "VOICE_AGENT_SECURITY_MODE=full-access",
                "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale",
                "VOICE_AGENT_API_TOKEN=test-token",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://mobaile.tail6a5903.ts.net:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "status"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_SKIP_OPEN": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "MOBaiLE: Running" in result.stdout
    assert "Security: Full Access" in result.stdout
    assert "Phone access: Anywhere with Tailscale" in result.stdout
    assert "mobaile pair" in result.stdout


def test_mobaile_pair_prints_qr_path_when_open_is_skipped(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "pair"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_SKIP_OPEN": "1",
            "MOBAILE_TEST_PAIRING_QR": str(backend_dir / "pairing-qr.png"),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "pairing-qr.png" in result.stdout
