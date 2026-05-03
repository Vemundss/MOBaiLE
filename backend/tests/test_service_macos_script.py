from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import textwrap
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def test_service_macos_install_summarizes_warmup_failures(tmp_path: Path):
    repo = tmp_path / "repo"
    scripts_dir = repo / "scripts"
    backend_dir = repo / "backend"
    fake_bin = tmp_path / "bin"
    home = tmp_path / "home"
    report_path = home / "Library" / "Application Support" / "MOBaiLE" / "backend-runtime" / "data" / "capabilities.json"

    scripts_dir.mkdir(parents=True)
    backend_dir.mkdir(parents=True)
    fake_bin.mkdir(parents=True)
    home.mkdir(parents=True)

    shutil.copy2(PROJECT_ROOT / "scripts" / "service_macos.sh", scripts_dir / "service_macos.sh")
    (backend_dir / ".env").write_text("VOICE_AGENT_API_TOKEN=test-token\n", encoding="utf-8")
    (backend_dir / "run_backend.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")

    write_executable(
        scripts_dir / "warmup_capabilities.sh",
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail
            cat <<'EOF'
            Checked at: 2026-03-31T18:02:33Z
            Host platform: Darwin
            Security mode: full-access

            - codex_cli: ready (ok)
              Codex CLI is available.

            Report path: {report_path}

            Readiness failed: 4 blocked capability(ies).
            EOF
            exit 2
            """
        ),
    )
    write_executable(
        fake_bin / "uname",
        "#!/usr/bin/env bash\nprintf 'Darwin\\n'\n",
    )
    write_executable(
        fake_bin / "uv",
        "#!/usr/bin/env bash\nif [[ \"$1\" == \"sync\" ]]; then exit 0; fi\nexit 0\n",
    )
    write_executable(
        fake_bin / "launchctl",
        "#!/usr/bin/env bash\nexit 0\n",
    )

    result = subprocess.run(
        ["bash", str(scripts_dir / "service_macos.sh"), "install"],
        cwd=repo,
        env={
            **os.environ,
            "HOME": str(home),
            "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "Checking optional host integrations..." in result.stdout
    assert "Some optional host integrations are not ready yet. MOBaiLE will still run." in result.stdout
    assert f"Capability report: {report_path}" in result.stdout
    assert "Background service installed and running." in result.stdout
    assert "Readiness failed:" not in result.stdout
    assert "- codex_cli:" not in result.stdout


def test_service_macos_sync_preserves_paired_clients_in_runtime_state(tmp_path: Path):
    repo = tmp_path / "repo"
    scripts_dir = repo / "scripts"
    backend_dir = repo / "backend"
    fake_bin = tmp_path / "bin"
    home = tmp_path / "home"
    runtime_dir = home / "Library" / "Application Support" / "MOBaiLE" / "backend-runtime"

    scripts_dir.mkdir(parents=True)
    backend_dir.mkdir(parents=True)
    fake_bin.mkdir(parents=True)
    runtime_dir.mkdir(parents=True)
    home.mkdir(parents=True, exist_ok=True)

    shutil.copy2(PROJECT_ROOT / "scripts" / "service_macos.sh", scripts_dir / "service_macos.sh")
    (backend_dir / ".env").write_text("VOICE_AGENT_API_TOKEN=test-token\n", encoding="utf-8")
    (backend_dir / "pairing.json").write_text(
        json.dumps(
            {
                "server_url": "http://repo.example:8000",
                "server_urls": ["http://repo.example:8000", "http://wifi.example:8000"],
                "session_id": "iphone-app",
                "pair_code": "fresh-code",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    (runtime_dir / "pairing.json").write_text(
        json.dumps(
            {
                "server_url": "http://old-runtime.example:8000",
                "server_urls": ["http://old-runtime.example:8000"],
                "session_id": "iphone-app",
                "pair_code": "old-code",
                "pair_code_expires_at": "2000-01-01T00:00:00Z",
                "paired_clients": [
                    {
                        "token_sha256": "token-hash",
                        "refresh_token_sha256": "refresh-hash",
                        "session_id": "phone-session",
                        "issued_at": "2026-04-02T10:00:00Z",
                        "refreshed_at": "",
                    }
                ],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    (runtime_dir / "pairing-qr.png").write_text("stale", encoding="utf-8")

    write_executable(
        fake_bin / "uname",
        "#!/usr/bin/env bash\nprintf 'Darwin\\n'\n",
    )
    write_executable(
        fake_bin / "uv",
        "#!/usr/bin/env bash\nif [[ \"$1\" == \"sync\" ]]; then exit 0; fi\nexit 0\n",
    )

    result = subprocess.run(
        ["bash", str(scripts_dir / "service_macos.sh"), "sync"],
        cwd=repo,
        env={
            **os.environ,
            "HOME": str(home),
            "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    merged = json.loads((runtime_dir / "pairing.json").read_text(encoding="utf-8"))
    assert merged["server_url"] == "http://repo.example:8000"
    assert merged["server_urls"] == ["http://repo.example:8000", "http://wifi.example:8000"]
    assert merged["pair_code"] == "fresh-code"
    assert merged["paired_clients"] == [
        {
            "token_sha256": "token-hash",
            "refresh_token_sha256": "refresh-hash",
            "session_id": "phone-session",
            "issued_at": "2026-04-02T10:00:00Z",
            "refreshed_at": "",
        }
    ]
    assert not (runtime_dir / "pairing-qr.png").exists()


def test_service_macos_keep_awake_install_writes_caffeinate_agent(tmp_path: Path):
    repo = tmp_path / "repo"
    scripts_dir = repo / "scripts"
    fake_bin = tmp_path / "bin"
    home = tmp_path / "home"
    launchctl_log = tmp_path / "launchctl.log"
    plist_path = home / "Library" / "LaunchAgents" / "com.mobile.voiceagent.keepawake.plist"

    scripts_dir.mkdir(parents=True)
    fake_bin.mkdir(parents=True)
    home.mkdir(parents=True)
    shutil.copy2(PROJECT_ROOT / "scripts" / "service_macos.sh", scripts_dir / "service_macos.sh")

    write_executable(
        fake_bin / "uname",
        "#!/usr/bin/env bash\nprintf 'Darwin\\n'\n",
    )
    write_executable(
        fake_bin / "launchctl",
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            printf "%s\\n" "$*" >> "{launchctl_log}"
            exit 0
            """
        ),
    )

    result = subprocess.run(
        ["bash", str(scripts_dir / "service_macos.sh"), "keep-awake-install"],
        cwd=repo,
        env={
            **os.environ,
            "HOME": str(home),
            "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "Keep-awake service installed and running." in result.stdout
    plist = plist_path.read_text(encoding="utf-8")
    assert "<string>/usr/bin/caffeinate</string>" in plist
    assert "<string>-ims</string>" in plist
    assert "com.mobile.voiceagent.keepawake" in plist
    assert "bootstrap" in launchctl_log.read_text(encoding="utf-8")


def assert_service_sync_preserves_newer_runtime_pair_code(
    tmp_path: Path,
    script_name: str,
    platform_name: str,
    runtime_dir: Path,
) -> None:
    repo = tmp_path / "repo"
    scripts_dir = repo / "scripts"
    backend_dir = repo / "backend"
    fake_bin = tmp_path / "bin"
    home = tmp_path / "home"

    scripts_dir.mkdir(parents=True)
    backend_dir.mkdir(parents=True)
    fake_bin.mkdir(parents=True)
    runtime_dir.mkdir(parents=True)
    home.mkdir(parents=True, exist_ok=True)

    shutil.copy2(PROJECT_ROOT / "scripts" / script_name, scripts_dir / script_name)
    (backend_dir / ".env").write_text("VOICE_AGENT_API_TOKEN=test-token\n", encoding="utf-8")
    (backend_dir / "pairing.json").write_text(
        json.dumps(
            {
                "server_url": "http://repo.example:8000",
                "server_urls": ["http://repo.example:8000", "http://wifi.example:8000"],
                "session_id": "iphone-app",
                "pair_code": "checkout-code",
                "pair_code_expires_at": "2026-01-01T00:00:00Z",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    (runtime_dir / "pairing.json").write_text(
        json.dumps(
            {
                "server_url": "http://old-runtime.example:8000",
                "server_urls": ["http://old-runtime.example:8000"],
                "session_id": "iphone-app",
                "pair_code": "runtime-code",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
                "paired_clients": [{"token_sha256": "token-hash"}],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    (runtime_dir / "pairing-qr.png").write_text("stale", encoding="utf-8")

    write_executable(
        fake_bin / "uname",
        f"#!/usr/bin/env bash\nprintf '{platform_name}\\n'\n",
    )
    write_executable(
        fake_bin / "uv",
        "#!/usr/bin/env bash\nif [[ \"$1\" == \"sync\" ]]; then exit 0; fi\nexit 0\n",
    )

    result = subprocess.run(
        ["bash", str(scripts_dir / script_name), "sync"],
        cwd=repo,
        env={
            **os.environ,
            "HOME": str(home),
            "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    merged = json.loads((runtime_dir / "pairing.json").read_text(encoding="utf-8"))
    assert merged["server_url"] == "http://repo.example:8000"
    assert merged["server_urls"] == ["http://repo.example:8000", "http://wifi.example:8000"]
    assert merged["pair_code"] == "runtime-code"
    assert merged["pair_code_expires_at"] == "2999-01-01T00:00:00Z"
    assert merged["paired_clients"] == [{"token_sha256": "token-hash"}]
    assert not (runtime_dir / "pairing-qr.png").exists()


def test_service_macos_sync_preserves_newer_runtime_pair_code(tmp_path: Path):
    home = tmp_path / "home"
    runtime_dir = home / "Library" / "Application Support" / "MOBaiLE" / "backend-runtime"

    assert_service_sync_preserves_newer_runtime_pair_code(
        tmp_path,
        "service_macos.sh",
        "Darwin",
        runtime_dir,
    )


def test_service_linux_sync_preserves_newer_runtime_pair_code(tmp_path: Path):
    home = tmp_path / "home"
    runtime_dir = home / ".local" / "share" / "MOBaiLE" / "backend-runtime"

    assert_service_sync_preserves_newer_runtime_pair_code(
        tmp_path,
        "service_linux.sh",
        "Linux",
        runtime_dir,
    )


def assert_service_restart_defers_during_active_run(
    tmp_path: Path,
    script_name: str,
    platform_name: str,
    service_binary_name: str,
) -> None:
    repo = tmp_path / f"repo-{script_name}"
    scripts_dir = repo / "scripts"
    fake_bin = tmp_path / f"bin-{script_name}"
    home = tmp_path / f"home-{script_name}"
    db_path = tmp_path / f"{script_name}.db"
    service_log = tmp_path / f"{script_name}.service.log"

    scripts_dir.mkdir(parents=True)
    fake_bin.mkdir(parents=True)
    home.mkdir(parents=True)
    shutil.copy2(PROJECT_ROOT / "scripts" / script_name, scripts_dir / script_name)

    with sqlite3.connect(db_path) as conn:
        conn.execute("CREATE TABLE runs (run_id TEXT PRIMARY KEY, status TEXT NOT NULL)")
        conn.execute("INSERT INTO runs (run_id, status) VALUES ('run-active', 'running')")

    write_executable(
        fake_bin / "uname",
        f"#!/usr/bin/env bash\nprintf '{platform_name}\\n'\n",
    )
    write_executable(
        fake_bin / "sqlite3",
        "#!/usr/bin/env bash\nprintf 'running\\n'\n",
    )
    write_executable(
        fake_bin / service_binary_name,
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail
            printf "%s\\n" "$*" >> "{service_log}"
            """
        ),
    )

    result = subprocess.run(
        ["bash", str(scripts_dir / script_name), "restart"],
        cwd=repo,
        env={
            **os.environ,
            "HOME": str(home),
            "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
            "MOBAILE_ACTIVE_RUN_ID": "run-active",
            "MOBAILE_DEFER_SERVICE_RESTART": "true",
            "MOBAILE_RUNS_DB_PATH": str(db_path),
            "MOBAILE_DEFERRED_RESTART_TIMEOUT_SEC": "0",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "backend restart deferred until this run finishes" in result.stdout
    assert not service_log.exists()


def test_service_macos_restart_defers_during_active_mobaile_run(tmp_path: Path) -> None:
    assert_service_restart_defers_during_active_run(
        tmp_path,
        "service_macos.sh",
        "Darwin",
        "launchctl",
    )


def test_service_macos_deferred_restart_kickstarts_loaded_launchd_job(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    scripts_dir = repo / "scripts"
    fake_bin = tmp_path / "bin"
    home = tmp_path / "home"
    db_path = tmp_path / "runs.db"
    launchctl_log = tmp_path / "launchctl.log"

    scripts_dir.mkdir(parents=True)
    fake_bin.mkdir(parents=True)
    home.mkdir(parents=True)
    shutil.copy2(PROJECT_ROOT / "scripts" / "service_macos.sh", scripts_dir / "service_macos.sh")

    with sqlite3.connect(db_path) as conn:
        conn.execute("CREATE TABLE runs (run_id TEXT PRIMARY KEY, status TEXT NOT NULL)")
        conn.execute("INSERT INTO runs (run_id, status) VALUES ('run-done', 'completed')")

    write_executable(
        fake_bin / "uname",
        "#!/usr/bin/env bash\nprintf 'Darwin\\n'\n",
    )
    write_executable(
        fake_bin / "launchctl",
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail
            printf "%s\\n" "$*" >> "{launchctl_log}"
            exit 0
            """
        ),
    )

    result = subprocess.run(
        ["bash", str(scripts_dir / "service_macos.sh"), "restart"],
        cwd=repo,
        env={
            **os.environ,
            "HOME": str(home),
            "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
            "MOBAILE_ACTIVE_RUN_ID": "run-done",
            "MOBAILE_DEFER_SERVICE_RESTART": "true",
            "MOBAILE_RUNS_DB_PATH": str(db_path),
            "MOBAILE_DEFERRED_RESTART_TIMEOUT_SEC": "5",
            "MOBAILE_DEFERRED_RESTART_POLL_INTERVAL_SEC": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "backend restart deferred until this run finishes" in result.stdout

    for _ in range(50):
        if launchctl_log.exists() and "kickstart -k" in launchctl_log.read_text(encoding="utf-8"):
            break
        time.sleep(0.1)

    service_target = f"gui/{os.getuid()}/com.mobile.voiceagent.backend"
    log_text = launchctl_log.read_text(encoding="utf-8")
    assert f"print {service_target}" in log_text
    assert f"kickstart -k {service_target}" in log_text
    assert "bootout" not in log_text
    assert "bootstrap" not in log_text


def test_service_linux_restart_defers_during_active_mobaile_run(tmp_path: Path) -> None:
    assert_service_restart_defers_during_active_run(
        tmp_path,
        "service_linux.sh",
        "Linux",
        "systemctl",
    )
