from __future__ import annotations

import os
from pathlib import Path
import subprocess


PROJECT_ROOT = Path(__file__).resolve().parents[2]


def make_checkout(tmp_path: Path) -> Path:
    checkout = tmp_path / "repo"
    scripts_dir = checkout / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)
    for name in (
        "install.sh",
        "install_backend.sh",
        "service_macos.sh",
        "service_linux.sh",
        "pairing_qr.sh",
        "mobaile",
    ):
        (scripts_dir / name).write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    return checkout


def run_install_script(checkout: Path, home: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "bash",
            str(PROJECT_ROOT / "scripts" / "install.sh"),
            "--checkout",
            str(checkout),
            "--non-interactive",
            "--dry-run",
            *args,
        ],
        capture_output=True,
        text=True,
        check=False,
        env={
            **os.environ,
            "HOME": str(home),
        },
    )

def test_install_script_defaults_to_full_access_and_tailscale(tmp_path: Path):
    checkout = make_checkout(tmp_path)
    home = tmp_path / "home"

    result = run_install_script(checkout, home)

    assert result.returncode == 0
    assert "MOBaiLE runs on this computer. Your iPhone connects to it." in result.stdout
    assert "mode: full-access" in result.stdout
    assert "phone_access: tailscale" in result.stdout
    assert "background_service: yes" in result.stdout
    assert "--mode full-access --phone-access tailscale" in result.stdout
    assert "ln -sfn" in result.stdout
    assert "pairing_qr.sh" in result.stdout
    assert (
        "service_macos.sh install" in result.stdout
        or "service_linux.sh install" in result.stdout
        or "background service skipped on unsupported platform" in result.stdout
    )
    assert not (home / ".local" / "bin" / "mobaile").exists()


def test_install_script_can_switch_to_wifi_without_background_service(tmp_path: Path):
    checkout = make_checkout(tmp_path)
    home = tmp_path / "home"

    result = run_install_script(
        checkout,
        home,
        "--phone-access",
        "wifi",
        "--background-service",
        "no",
    )

    assert result.returncode == 0
    assert "mode: full-access" in result.stdout
    assert "phone_access: wifi" in result.stdout
    assert "background_service: no" in result.stdout
    assert "--mode full-access --phone-access wifi" in result.stdout
    assert "pairing_qr.sh" in result.stdout
    assert "service_macos.sh install" not in result.stdout
    assert "service_linux.sh install" not in result.stdout
    assert not (home / ".local" / "bin" / "mobaile").exists()
