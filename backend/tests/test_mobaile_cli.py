from __future__ import annotations

import os
from pathlib import Path
import platform
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


def test_mobaile_labels_public_url_in_status_and_config(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "\n".join(
            [
                "VOICE_AGENT_SECURITY_MODE=full-access",
                "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale",
                "VOICE_AGENT_PUBLIC_SERVER_URL=https://demo.mobaile.app",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"https://demo.mobaile.app","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    status_result = subprocess.run(
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
    config_result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "config"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_SKIP_OPEN": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert status_result.returncode == 0
    assert "Phone access: Public URL" in status_result.stdout
    assert config_result.returncode == 0
    assert "Phone access mode: Public URL (tailscale)" in config_result.stdout


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


def test_mobaile_status_does_not_report_ready_for_expired_pairing(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2000-01-01T00:00:00Z"}\n',
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
    assert "Phone pairing: Not ready" in result.stdout


def test_mobaile_status_prefers_running_state_over_unrelated_inactive_text(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    scripts_dir = repo / "scripts"
    backend_dir.mkdir(parents=True)
    scripts_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "\n".join(
            [
                "VOICE_AGENT_SECURITY_MODE=full-access",
                "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://mobaile.tail6a5903.ts.net:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    helper_name = "service_macos.sh" if platform.system() == "Darwin" else "service_linux.sh"
    (scripts_dir / helper_name).write_text(
        """#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
gui/501/com.mobile.voiceagent.backend = {
    state = running
    jetsam memory limit (inactive) = (unlimited)
}
EOF
""",
        encoding="utf-8",
    )
    (scripts_dir / helper_name).chmod(0o755)

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "status"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_SKIP_OPEN": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "MOBaiLE: Running" in result.stdout


def test_mobaile_pair_uses_real_pairing_helper_script(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    scripts_dir = repo / "scripts"
    backend_dir.mkdir(parents=True)
    scripts_dir.mkdir(parents=True)
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )
    (scripts_dir / "pairing_qr.sh").write_text(
        """#!/usr/bin/env bash
set -euo pipefail

out_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      out_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$(dirname "${out_path}")"
printf "stub-qr" > "${out_path}"
""",
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "pair"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_SKIP_OPEN": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "Pairing QR:" in result.stdout
    assert (backend_dir / "pairing-qr.png").read_text(encoding="utf-8") == "stub-qr"
