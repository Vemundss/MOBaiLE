from __future__ import annotations

import os
from pathlib import Path
import platform
import stat
import subprocess
import textwrap


PROJECT_ROOT = Path(__file__).resolve().parents[2]


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def make_checkout(tmp_path: Path) -> Path:
    checkout = tmp_path / "repo"
    scripts_dir = checkout / "scripts"
    backend_dir = checkout / "backend"
    scripts_dir.mkdir(parents=True, exist_ok=True)
    backend_dir.mkdir(parents=True, exist_ok=True)

    write_executable(scripts_dir / "install.sh", "#!/usr/bin/env bash\n")
    write_executable(
        scripts_dir / "install_backend.sh",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            printf "install_backend %s\\n" "$*" >> "${MOBAILE_TEST_LOG}"
            mkdir -p "${MOBAILE_TEST_CHECKOUT}/backend"
            printf '{"server_url":"http://127.0.0.1:8000"}\\n' > "${MOBAILE_TEST_CHECKOUT}/backend/pairing.json"
            """
        ),
    )
    write_executable(
        scripts_dir / "service_macos.sh",
        '#!/usr/bin/env bash\nset -euo pipefail\nprintf "service_macos %s\\n" "$*" >> "${MOBAILE_TEST_LOG}"\n',
    )
    write_executable(
        scripts_dir / "service_linux.sh",
        '#!/usr/bin/env bash\nset -euo pipefail\nprintf "service_linux %s\\n" "$*" >> "${MOBAILE_TEST_LOG}"\n',
    )
    write_executable(
        scripts_dir / "pairing_qr.sh",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            printf "pairing_qr %s\\n" "$*" >> "${MOBAILE_TEST_LOG}"
            mkdir -p "${MOBAILE_TEST_CHECKOUT}/backend"
            printf "qr" > "${MOBAILE_TEST_CHECKOUT}/backend/pairing-qr.png"
            """
        ),
    )
    write_executable(scripts_dir / "mobaile", "#!/usr/bin/env bash\n")
    return checkout


def run_install_script(
    checkout: Path,
    home: Path,
    *args: str,
    dry_run: bool = True,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    home.mkdir(parents=True, exist_ok=True)
    command = [
        "bash",
        str(PROJECT_ROOT / "scripts" / "install.sh"),
        "--checkout",
        str(checkout),
        "--non-interactive",
    ]
    if dry_run:
        command.append("--dry-run")
    command.extend(args)
    env = {
        **os.environ,
        "HOME": str(home),
        "MOBAILE_TEST_CHECKOUT": str(checkout),
        "MOBAILE_TEST_LOG": str(tmp_log_path(home)),
    }
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


def tmp_log_path(home: Path) -> Path:
    return home / "calls.log"


def expected_service_phrase() -> str | None:
    system = platform.system()
    if system == "Darwin":
        return "service_macos.sh install"
    if system == "Linux":
        return "service_linux.sh install"
    return None


def make_fake_openers(fake_bin: Path, log_path: Path) -> None:
    fake_bin.mkdir(parents=True, exist_ok=True)
    write_executable(
        fake_bin / "open",
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail
            printf "open %s\\n" "$*" >> "{log_path}"
            """
        ),
    )
    write_executable(
        fake_bin / "xdg-open",
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail
            printf "xdg-open %s\\n" "$*" >> "{log_path}"
            """
        ),
    )


def test_install_script_defaults_to_full_access_and_tailscale(tmp_path: Path):
    checkout = make_checkout(tmp_path)
    home = tmp_path / "home"

    result = run_install_script(checkout, home)

    assert result.returncode == 0
    assert "MOBaiLE runs on this computer. Your iPhone connects to it." in result.stdout
    assert "Dry run." in result.stdout
    assert "Security: Full Access" in result.stdout
    assert "Phone access: Anywhere with Tailscale" in result.stdout
    assert "Background service: Yes" in result.stdout
    assert "Next:" in result.stdout
    assert "Scan the QR on this computer with your iPhone." in result.stdout
    assert "Run `mobaile status` any time to check the connection." in result.stdout
    assert "--mode full-access --phone-access tailscale" in result.stdout
    assert "ln -sfn" in result.stdout
    assert "pairing_qr.sh" in result.stdout
    service_phrase = expected_service_phrase()
    if service_phrase is not None:
        assert service_phrase in result.stdout
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
    assert "Dry run." in result.stdout
    assert "Security: Full Access" in result.stdout
    assert "Phone access: On this Wi-Fi" in result.stdout
    assert "Background service: No" in result.stdout
    assert "--mode full-access --phone-access wifi" in result.stdout
    assert "pairing_qr.sh" in result.stdout
    assert "service_macos.sh install" not in result.stdout
    assert "service_linux.sh install" not in result.stdout
    assert not (home / ".local" / "bin" / "mobaile").exists()


def test_install_script_real_run_opens_qr_and_prints_final_summary(tmp_path: Path):
    checkout = make_checkout(tmp_path)
    home = tmp_path / "home"
    log_path = tmp_log_path(home)
    fake_bin = tmp_path / "bin"
    make_fake_openers(fake_bin, log_path)

    result = run_install_script(
        checkout,
        home,
        "--background-service",
        "no",
        dry_run=False,
        extra_env={
            "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        },
    )

    assert result.returncode == 0
    assert "Done." in result.stdout
    assert "Security: Full Access" in result.stdout
    assert "Phone access: Anywhere with Tailscale" in result.stdout
    assert "Background service: No" in result.stdout
    assert "Scan the QR on this computer with your iPhone." in result.stdout
    assert "Run `mobaile status` any time to check the connection." in result.stdout
    assert (home / ".local" / "bin" / "mobaile").is_symlink()
    assert (checkout / "backend" / "pairing-qr.png").exists()

    log_contents = log_path.read_text(encoding="utf-8")
    assert "install_backend --mode full-access --phone-access tailscale" in log_contents
    assert "pairing_qr " in log_contents
    system = platform.system()
    if system == "Darwin":
        assert f"open {checkout}/backend/pairing-qr.png" in log_contents
    elif system == "Linux":
        assert f"xdg-open {checkout}/backend/pairing-qr.png" in log_contents
