from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import textwrap
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def create_fake_codex_bin(tmp_path: Path) -> Path:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir(parents=True, exist_ok=True)
    write_executable(
        fake_bin / "codex",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            if [[ "${1:-}" == "--version" ]]; then
              echo "codex 9.9.9"
              exit 0
            fi
            echo "fake codex"
            """
        ),
    )
    return fake_bin


def create_fake_first_run_curl(tmp_path: Path) -> Path:
    fake_bin = tmp_path / "curl-bin"
    fake_bin.mkdir(parents=True, exist_ok=True)
    write_executable(
        fake_bin / "curl",
        textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import sys
            from pathlib import Path

            args = sys.argv[1:]
            out_path = None
            write_code = False
            url = ""
            i = 0
            while i < len(args):
                arg = args[i]
                if arg == "-o":
                    out_path = args[i + 1]
                    i += 2
                    continue
                if arg == "-w":
                    write_code = True
                    i += 2
                    continue
                if arg.startswith("http"):
                    url = arg
                i += 1

            code = "200"
            if url.endswith("/v1/utterances"):
                body = '{"run_id":"first-run-1","status":"accepted","message":"Run started"}'
            elif url.endswith("/v1/runs/first-run-1"):
                body = '{"run_id":"first-run-1","status":"completed","summary":"Run completed successfully"}'
            elif url.endswith("/health"):
                body = '{"status":"ok"}'
            else:
                code = "404"
                body = '{"detail":"unexpected url"}'

            if out_path:
                Path(out_path).write_text(body, encoding="utf-8")
            else:
                print(body, end="")
            if write_code:
                print(code, end="")
            """
        ),
    )
    return fake_bin


def create_fake_demo_curl(tmp_path: Path) -> Path:
    fake_bin = tmp_path / "demo-curl-bin"
    fake_bin.mkdir(parents=True, exist_ok=True)
    write_executable(
        fake_bin / "curl",
        textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import json
            import sys
            from pathlib import Path

            args = sys.argv[1:]
            out_path = None
            write_code = False
            url = ""
            i = 0
            while i < len(args):
                arg = args[i]
                if arg == "-o":
                    out_path = args[i + 1]
                    i += 2
                    continue
                if arg == "-w":
                    write_code = True
                    i += 2
                    continue
                if arg.startswith("http"):
                    url = arg
                i += 1

            code = "200"
            if "/v1/runs/demo-run" in url:
                body = json.dumps({
                    "run_id": "demo-run",
                    "status": "completed",
                    "executor": "codex",
                    "utterance_text": "SECRET prompt should not be exported",
                    "working_directory": "/Users/me/private-project",
                    "summary": "Updated the README and generated a public demo artifact.",
                    "events": [
                        {
                            "seq": 0,
                            "type": "activity.started",
                            "stage": "planning",
                            "display_message": "Planning the public proof artifact.",
                            "message": "Planning the public proof artifact.",
                        },
                        {
                            "seq": 1,
                            "type": "log.message",
                            "message": "SECRET raw log should be omitted",
                        },
                        {
                            "seq": 2,
                            "type": "action.stdout",
                            "message": "SECRET stdout should be omitted",
                        },
                        {
                            "seq": 3,
                            "type": "chat.message",
                            "message": json.dumps({
                                "type": "assistant_response",
                                "version": "1.0",
                                "summary": "Public demo artifact is ready.",
                                "sections": [],
                                "agenda_items": [],
                            }),
                        },
                        {
                            "seq": 4,
                            "type": "run.completed",
                            "stage": "summarizing",
                            "message": "Run completed successfully.",
                        },
                    ],
                })
            else:
                code = "404"
                body = '{"detail":"unexpected url"}'

            if out_path:
                Path(out_path).write_text(body, encoding="utf-8")
            else:
                print(body, end="")
            if write_code:
                print(code, end="")
            """
        ),
    )
    return fake_bin


def run_git(args: list[str], cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )


def create_update_checkout(tmp_path: Path) -> tuple[Path, Path, dict[str, str]]:
    home = tmp_path / "home"
    home.mkdir()
    shared_env = {
        **os.environ,
        "HOME": str(home),
    }

    remote = tmp_path / "remote.git"
    run_git(["init", "--bare", "--initial-branch=main", str(remote)], cwd=tmp_path, env=shared_env)

    author = tmp_path / "author"
    run_git(["clone", str(remote), str(author)], cwd=tmp_path, env=shared_env)
    run_git(["config", "user.name", "MOBaiLE Tests"], cwd=author, env=shared_env)
    run_git(["config", "user.email", "tests@example.com"], cwd=author, env=shared_env)

    (author / "scripts").mkdir(parents=True)
    (author / "backend").mkdir(parents=True)
    (author / ".gitignore").write_text("backend/.env\n", encoding="utf-8")
    (author / "README.md").write_text("# temp\n", encoding="utf-8")
    (author / "scripts" / "install.sh").write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
            printf "%s\n" "$@" > "${REPO_ROOT}/update_args.txt"
            """
        ),
        encoding="utf-8",
    )
    (author / "scripts" / "install_backend.sh").write_text("#!/usr/bin/env bash\nset -euo pipefail\n", encoding="utf-8")
    (author / "scripts" / "pairing_qr.sh").write_text("#!/usr/bin/env bash\nset -euo pipefail\n", encoding="utf-8")
    for path in [
        author / "scripts" / "install.sh",
        author / "scripts" / "install_backend.sh",
        author / "scripts" / "pairing_qr.sh",
    ]:
        path.chmod(0o755)

    run_git(["add", "."], cwd=author, env=shared_env)
    run_git(["commit", "-m", "Initial"], cwd=author, env=shared_env)
    run_git(["push", "-u", "origin", "main"], cwd=author, env=shared_env)

    repo = tmp_path / "repo"
    run_git(["clone", str(remote), str(repo)], cwd=tmp_path, env=shared_env)
    run_git(["config", "user.name", "MOBaiLE Tests"], cwd=repo, env=shared_env)
    run_git(["config", "user.email", "tests@example.com"], cwd=repo, env=shared_env)

    (repo / "backend").mkdir(exist_ok=True)
    (repo / "backend" / ".env").write_text(
        "VOICE_AGENT_SECURITY_MODE=full-access\nVOICE_AGENT_PHONE_ACCESS_MODE=tailscale\n",
        encoding="utf-8",
    )

    (author / "README.md").write_text("# updated\n", encoding="utf-8")
    run_git(["add", "README.md"], cwd=author, env=shared_env)
    run_git(["commit", "-m", "Update"], cwd=author, env=shared_env)
    run_git(["push"], cwd=author, env=shared_env)

    return repo, author, shared_env


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
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
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


def test_mobaile_setup_prints_local_setup_url(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text("VOICE_AGENT_PORT=8123\n", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "setup", "--url"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_SKIP_OPEN": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "http://127.0.0.1:8123/setup"


def test_mobaile_autonomy_dry_run_uses_active_backend_paths(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend-runtime"
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "\n".join(
            [
                "VOICE_AGENT_SECURITY_MODE=full-access",
                "VOICE_AGENT_CODEX_HOME=codex-home",
                "VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR=data/pw-out",
                f"VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR={tmp_path / 'browser-profile'}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            "bash",
            str(PROJECT_ROOT / "scripts" / "mobaile"),
            "autonomy",
            "--dry-run",
            "--skip-browser-warmup",
            "--force-mcp",
        ],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "MOBaiLE autonomy setup" in result.stdout
    assert "provision_codex_autonomy.py" in result.stdout
    assert "--mode full-access" in result.stdout
    assert f"--codex-home {backend_dir / 'codex-home'}" in result.stdout
    assert f"--playwright-output-dir {backend_dir / 'data' / 'pw-out'}" in result.stdout
    assert f"--playwright-user-data-dir {tmp_path / 'browser-profile'}" in result.stdout
    assert "--skip-browser-warmup" in result.stdout
    assert "--force-mcp" in result.stdout
    assert "Deep readiness: skipped" in result.stdout


def test_mobaile_check_reports_ready_for_wifi_setup(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    fake_bin = create_fake_codex_bin(tmp_path)
    npx_path = shutil.which("npx")
    filtered_path_entries = [
        entry
        for entry in os.environ["PATH"].split(os.pathsep)
        if not npx_path or Path(entry).resolve() != Path(npx_path).parent.resolve()
    ]
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "\n".join(
            [
                "VOICE_AGENT_SECURITY_MODE=full-access",
                "VOICE_AGENT_PHONE_ACCESS_MODE=wifi",
                "VOICE_AGENT_DEFAULT_EXECUTOR=codex",
                "VOICE_AGENT_API_TOKEN=test-token",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://192.168.1.20:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "check"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_DOCTOR_SKIP_NETWORK": "1",
            "PATH": os.pathsep.join([str(fake_bin), *filtered_path_entries]),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "MOBaiLE setup check" in result.stdout
    assert "[ok] Codex CLI is available: codex 9.9.9" in result.stdout
    assert "browser/desktop automation needs npx" in result.stdout
    assert "[info] Wi-Fi mode does not require Tailscale" in result.stdout
    assert "Check result: ready" in result.stdout


def test_mobaile_check_json_reports_structured_status(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    fake_bin = create_fake_codex_bin(tmp_path)
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "\n".join(
            [
                "VOICE_AGENT_PHONE_ACCESS_MODE=wifi",
                "VOICE_AGENT_DEFAULT_EXECUTOR=codex",
                "VOICE_AGENT_API_TOKEN=test-token",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://192.168.1.20:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )
    (backend_dir / "pairing-qr.png").write_text("qr", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "check", "--json"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    payload = json.loads(result.stdout)
    assert payload["status"] == "ready"
    assert payload["active_backend"] == str(backend_dir)
    assert payload["phone_access"]["mode"] == "wifi"
    assert any(item["id"] == "agent_cli" and item["status"] == "ok" for item in payload["checks"])


def test_mobaile_check_points_to_missing_agent_and_tailscale(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale\nVOICE_AGENT_DEFAULT_EXECUTOR=codex\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://mobaile.tail6a5903.ts.net:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "check"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "Install and sign in to Codex CLI or Claude CLI" in result.stdout
    assert "Install Tailscale on this computer and the iPhone" in result.stdout
    assert "Check result: needs action" in result.stdout


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
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
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
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
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
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_SKIP_OPEN": "1",
            "MOBAILE_TEST_PAIRING_QR": str(backend_dir / "pairing-qr.png"),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "pairing-qr.png" in result.stdout


def test_mobaile_first_run_starts_playground_run(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    playground = tmp_path / "playground"
    fake_curl_bin = create_fake_first_run_curl(tmp_path)
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "VOICE_AGENT_API_TOKEN=test-token\nVOICE_AGENT_DEFAULT_EXECUTOR=shell\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            "bash",
            str(PROJECT_ROOT / "scripts" / "mobaile"),
            "first-run",
            "--workdir",
            str(playground),
            "--timeout",
            "5",
        ],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "PATH": f"{fake_curl_bin}:{os.environ['PATH']}",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert playground.exists()
    assert "MOBaiLE first run" in result.stdout
    assert "Executor: shell" in result.stdout
    assert "Run: first-run-1" in result.stdout
    assert "Status: completed" in result.stdout
    assert "First run complete" in result.stdout


def test_mobaile_demo_exports_sample_markdown(tmp_path: Path):
    repo = tmp_path / "repo"
    repo.mkdir()
    out_path = tmp_path / "mobaile-demo.md"

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "demo", "--out", str(out_path)],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert f"MOBaiLE demo exported: {out_path}" in result.stdout
    body = out_path.read_text(encoding="utf-8")
    assert "# MOBaiLE Demo Replay" in body
    assert "Planning a safe starter task." in body
    assert "bash -s -- --yes" in body
    assert "without exposing raw logs" in body


def test_mobaile_demo_exports_sanitized_real_run(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    fake_curl_bin = create_fake_demo_curl(tmp_path)
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text("VOICE_AGENT_API_TOKEN=test-token\n", encoding="utf-8")
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            "bash",
            str(PROJECT_ROOT / "scripts" / "mobaile"),
            "demo",
            "--run-id",
            "demo-run",
            "--events-limit",
            "25",
            "--out",
            "-",
        ],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "PATH": f"{fake_curl_bin}:{os.environ['PATH']}",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "Public demo artifact is ready." in result.stdout
    assert "Planning the public proof artifact." in result.stdout
    assert "SECRET" not in result.stdout
    assert "/Users/me/private-project" not in result.stdout
    assert "SECRET raw log should be omitted" not in result.stdout


def test_mobaile_pair_requests_fresh_pair_code(tmp_path: Path):
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
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            printf "%s" "${MOBAILE_PAIR_FORCE_REFRESH:-}" > "${MOBAILE_BACKEND_DIR}/pair-force-refresh.txt"
            : > "${MOBAILE_PAIRING_QR_OUT}"
            """
        ),
        encoding="utf-8",
    )
    (scripts_dir / "pairing_qr.sh").chmod(0o755)

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "pair"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_SKIP_OPEN": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert (backend_dir / "pair-force-refresh.txt").read_text(encoding="utf-8") == "1"


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
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_SKIP_OPEN": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "Phone pairing: Expired; run mobaile pair" in result.stdout
    assert "Pairing QR: Expired; run mobaile pair" in result.stdout


def test_mobaile_status_does_not_report_existing_qr_as_ready_when_pairing_expired(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2000-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )
    (backend_dir / "pairing-qr.png").write_text("stale-qr", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "status"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_SKIP_OPEN": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "Pairing QR: Expired; run mobaile pair" in result.stdout


def test_mobaile_doctor_passes_for_tailscale_pairing(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    fake_bin = create_fake_codex_bin(tmp_path)
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale\nVOICE_AGENT_DEFAULT_EXECUTOR=codex\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        json.dumps(
            {
                "server_url": "http://mobaile.tail6a5903.ts.net:8000",
                "server_urls": [
                    "http://mobaile.tail6a5903.ts.net:8000",
                    "http://100.111.99.51:8000",
                ],
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )
    (backend_dir / "pairing-qr.png").write_text("qr", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "doctor"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_TEST_KEEP_AWAKE_STATE": "running",
            "MOBAILE_DOCTOR_SKIP_NETWORK": "1",
            "PATH": f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "[ok] Tailscale mode advertises a Tailscale phone path" in result.stdout
    assert "[ok] Codex binary is available: codex 9.9.9" in result.stdout
    if platform.system() == "Darwin":
        assert "[ok] Keep-awake service is running" in result.stdout
    else:
        assert "[warn] Keep-awake service is macOS-only" in result.stdout
    assert "Doctor result: ready" in result.stdout


def test_mobaile_doctor_network_config_check_does_not_leak_return_trap(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    fake_bin = create_fake_codex_bin(tmp_path)
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "\n".join(
            [
                "VOICE_AGENT_PHONE_ACCESS_MODE=local",
                "VOICE_AGENT_DEFAULT_EXECUTOR=codex",
                "VOICE_AGENT_API_TOKEN=test-token",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        json.dumps(
            {
                "server_url": "http://127.0.0.1:8000",
                "server_urls": ["http://127.0.0.1:8000"],
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )
    (backend_dir / "pairing-qr.png").write_text("qr", encoding="utf-8")
    write_executable(
        fake_bin / "curl",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            out_path="/dev/null"
            write_code="false"
            url=""
            while [[ $# -gt 0 ]]; do
              case "$1" in
                -o)
                  out_path="$2"
                  shift 2
                  ;;
                -w)
                  write_code="true"
                  shift 2
                  ;;
                http*)
                  url="$1"
                  shift
                  ;;
                *)
                  shift
                  ;;
              esac
            done
            if [[ "${url}" == */v1/config ]]; then
              printf '{"default_executor":"codex","available_executors":["codex"],"executors":[]}' > "${out_path}"
            else
              printf '{"status":"ok"}' > "${out_path}"
            fi
            if [[ "${write_code}" == "true" ]]; then
              printf "200"
            fi
            """
        ),
    )

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "doctor"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_TEST_KEEP_AWAKE_STATE": "running",
            "PATH": f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "Backend reports Codex executor ready" in result.stdout
    assert "unbound variable" not in result.stderr
    assert "Doctor result: ready" in result.stdout


def test_mobaile_doctor_fails_when_default_codex_binary_is_missing(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "\n".join(
            [
                "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale",
                "VOICE_AGENT_DEFAULT_EXECUTOR=codex",
                "VOICE_AGENT_CODEX_BINARY=/missing/codex",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        json.dumps(
            {
                "server_url": "http://mobaile.tail6a5903.ts.net:8000",
                "server_urls": ["http://mobaile.tail6a5903.ts.net:8000"],
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )
    (backend_dir / "pairing-qr.png").write_text("qr", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "doctor"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_TEST_KEEP_AWAKE_STATE": "running",
            "MOBAILE_DOCTOR_SKIP_NETWORK": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "Default executor is Codex, but the Codex binary is unavailable: /missing/codex" in result.stdout
    assert "Doctor result: attention needed" in result.stdout


def test_mobaile_doctor_warns_when_keep_awake_is_stopped(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    fake_bin = create_fake_codex_bin(tmp_path)
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale\nVOICE_AGENT_DEFAULT_EXECUTOR=codex\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        json.dumps(
            {
                "server_url": "http://mobaile.tail6a5903.ts.net:8000",
                "server_urls": ["http://mobaile.tail6a5903.ts.net:8000"],
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )
    (backend_dir / "pairing-qr.png").write_text("qr", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "doctor"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_TEST_KEEP_AWAKE_STATE": "stopped",
            "MOBAILE_DOCTOR_SKIP_NETWORK": "1",
            "PATH": f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    if platform.system() == "Darwin":
        assert "[warn] Keep-awake service is not running; run mobaile awake" in result.stdout
    else:
        assert "[warn] Keep-awake service is macOS-only" in result.stdout
    assert "Doctor result: ready" in result.stdout


def test_mobaile_doctor_fails_when_tailscale_pairing_has_lan_fallback(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        json.dumps(
            {
                "server_url": "http://mobaile.tail6a5903.ts.net:8000",
                "server_urls": [
                    "http://mobaile.tail6a5903.ts.net:8000",
                    "http://192.168.1.20:8000",
                ],
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )
    (backend_dir / "pairing-qr.png").write_text("qr", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "doctor"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_DOCTOR_SKIP_NETWORK": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "Tailscale mode advertises Wi-Fi/local-only URL(s): http://192.168.1.20:8000" in result.stdout
    assert "Doctor result: attention needed" in result.stdout


def test_mobaile_doctor_fails_when_tailscale_pairing_has_raw_ip_only(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        json.dumps(
            {
                "server_url": "http://100.111.99.51:8000",
                "server_urls": [
                    "http://100.111.99.51:8000",
                ],
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )
    (backend_dir / "pairing-qr.png").write_text("qr", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "doctor"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_DOCTOR_SKIP_NETWORK": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "Tailscale mode has no iOS-permitted pairing URL" in result.stdout
    assert "Doctor result: attention needed" in result.stdout


def test_mobaile_doctor_fails_when_tailscale_pairing_raw_ip_is_primary(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        json.dumps(
            {
                "server_url": "http://100.111.99.51:8000",
                "server_urls": [
                    "http://100.111.99.51:8000",
                    "http://mobaile.tail6a5903.ts.net:8000",
                ],
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )
    (backend_dir / "pairing-qr.png").write_text("qr", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "doctor"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_DOCTOR_SKIP_NETWORK": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "Primary Tailscale pairing URL may be blocked by iOS ATS" in result.stdout
    assert "Doctor result: attention needed" in result.stdout


def test_mobaile_status_reports_pairing_qr_can_be_regenerated(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "status"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_SKIP_OPEN": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "Phone pairing: Ready" in result.stdout
    assert "Pairing QR: Available via mobaile pair" in result.stdout


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
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
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
    args_log = repo / "pairing_qr_args.txt"
    backend_dir.mkdir(parents=True)
    scripts_dir.mkdir(parents=True)
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )
    (scripts_dir / "pairing_qr.sh").write_text(
        f"""#!/usr/bin/env bash
set -euo pipefail

out_path=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      out_path="$2"
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

printf "%s\n" "${{args[*]}}" > "{args_log}"
mkdir -p "$(dirname "${{out_path}}")"
printf "stub-qr" > "${{out_path}}"
""",
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "pair"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_SKIP_OPEN": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "Pairing QR:" in result.stdout
    assert (backend_dir / "pairing-qr.png").read_text(encoding="utf-8") == "stub-qr"
    assert args_log.read_text(encoding="utf-8").strip() == "--quiet --no-preview"


def test_mobaile_pair_refreshes_expired_pair_code(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    scripts_dir = repo / "scripts"
    fake_bin = tmp_path / "bin"
    backend_dir.mkdir(parents=True)
    scripts_dir.mkdir(parents=True)
    fake_bin.mkdir(parents=True)

    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","server_urls":["http://127.0.0.1:8000"],"session_id":"iphone-app","pair_code":"expired-1234","pair_code_expires_at":"2000-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )
    (scripts_dir / "pairing_qr.sh").write_text(
        (PROJECT_ROOT / "scripts" / "pairing_qr.sh").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    (scripts_dir / "pairing_qr.sh").chmod(0o755)

    (fake_bin / "uv").write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import subprocess
            import sys

            args = sys.argv[1:]
            if args[:2] == ["run", "python"]:
                raise SystemExit(subprocess.call([sys.executable] + args[2:]))
            raise SystemExit(f"unsupported uv invocation: {args}")
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "uv").chmod(0o755)
    (fake_bin / "qrencode").write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail

            out_path=""
            while [[ $# -gt 0 ]]; do
              case "$1" in
                -o)
                  out_path="$2"
                  shift 2
                  ;;
                *)
                  shift
                  ;;
              esac
            done

            printf "stub-qr" > "${out_path}"
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "qrencode").chmod(0o755)

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "pair"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_SKIP_OPEN": "1",
            "PATH": f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "Phone pairing: Ready" in result.stdout
    updated = (backend_dir / "pairing.json").read_text(encoding="utf-8")
    assert '"pair_code": "expired-1234"' not in updated


def test_mobaile_pair_prefers_runtime_backend_when_service_is_installed(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    runtime_backend_dir = tmp_path / "home-runtime"
    home = tmp_path / "home"
    backend_dir.mkdir(parents=True)
    runtime_backend_dir.mkdir(parents=True)

    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://repo.example:8000","session_id":"iphone-app","pair_code":"repo-code","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )
    (runtime_backend_dir / "pairing.json").write_text(
        '{"server_url":"http://runtime.example:8000","session_id":"iphone-app","pair_code":"runtime-code","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    if platform.system() == "Darwin":
        marker = home / "Library" / "LaunchAgents" / "com.mobile.voiceagent.backend.plist"
    else:
        marker = home / ".config" / "systemd" / "user" / "mobaile-backend.service"
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("", encoding="utf-8")

    qr_path = runtime_backend_dir / "pairing-qr.png"
    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "pair"],
        env={
            **os.environ,
            "HOME": str(home),
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_SKIP_OPEN": "1",
            "MOBAILE_TEST_RUNTIME_BACKEND_DIR": str(runtime_backend_dir),
            "MOBAILE_TEST_PAIRING_QR": str(qr_path),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert f"Pairing QR: {qr_path}" in result.stdout
    assert "URL: http://runtime.example:8000" in result.stdout


def test_mobaile_repair_restarts_service_refreshes_pairing_and_runs_doctor(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    scripts_dir = repo / "scripts"
    home = tmp_path / "home"
    log_path = repo / "repair.log"
    backend_dir.mkdir(parents=True)
    scripts_dir.mkdir(parents=True)
    home.mkdir()

    (backend_dir / ".env").write_text(
        "\n".join(
            [
                "VOICE_AGENT_PHONE_ACCESS_MODE=local",
                "VOICE_AGENT_DEFAULT_EXECUTOR=shell",
                "VOICE_AGENT_API_TOKEN=test-token",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )
    (scripts_dir / "pairing_qr.sh").write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail
            printf "pair %s\\n" "$*" >> "{log_path}"
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
            printf "qr" > "${{out_path}}"
            """
        ),
        encoding="utf-8",
    )
    (scripts_dir / "pairing_qr.sh").chmod(0o755)

    helper_name = "service_macos.sh" if platform.system() == "Darwin" else "service_linux.sh"
    (scripts_dir / helper_name).write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail
            printf "service %s\\n" "$*" >> "{log_path}"
            if [[ "${{1:-}}" == "status" ]]; then
              echo "running"
            fi
            """
        ),
        encoding="utf-8",
    )
    (scripts_dir / helper_name).chmod(0o755)

    if platform.system() == "Darwin":
        marker = home / "Library" / "LaunchAgents" / "com.mobile.voiceagent.backend.plist"
    else:
        marker = home / ".config" / "systemd" / "user" / "mobaile-backend.service"
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "repair"],
        env={
            **os.environ,
            "HOME": str(home),
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ACTIVE_BACKEND_DIR": str(backend_dir),
            "MOBAILE_SKIP_OPEN": "1",
            "MOBAILE_DOCTOR_SKIP_NETWORK": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "MOBaiLE repair" in result.stdout
    assert "Repair result: ready" in result.stdout
    assert "service restart" in log_path.read_text(encoding="utf-8")
    assert "--quiet --no-preview" in log_path.read_text(encoding="utf-8")


def test_mobaile_uninstall_stops_services_and_keeps_data_by_default(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    scripts_dir = repo / "scripts"
    home = tmp_path / "home"
    runtime_root = tmp_path / "runtime-root"
    log_path = repo / "uninstall.log"
    backend_dir.mkdir(parents=True)
    scripts_dir.mkdir(parents=True)
    home.mkdir()
    runtime_root.mkdir()
    (runtime_root / "backend-runtime").mkdir()
    (backend_dir / ".env").write_text("VOICE_AGENT_API_TOKEN=test-token\n", encoding="utf-8")
    (backend_dir / "pairing.json").write_text('{"server_url":"http://127.0.0.1:8000"}\n', encoding="utf-8")

    helper_name = "service_macos.sh" if platform.system() == "Darwin" else "service_linux.sh"
    write_executable(
        scripts_dir / helper_name,
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail
            printf "service %s\\n" "$*" >> "{log_path}"
            """
        ),
    )
    if platform.system() == "Darwin":
        service_marker = home / "Library" / "LaunchAgents" / "com.mobile.voiceagent.backend.plist"
        keep_awake_marker = home / "Library" / "LaunchAgents" / "com.mobile.voiceagent.keepawake.plist"
        keep_awake_marker.parent.mkdir(parents=True, exist_ok=True)
        keep_awake_marker.write_text("", encoding="utf-8")
    else:
        service_marker = home / ".config" / "systemd" / "user" / "mobaile-backend.service"
    service_marker.parent.mkdir(parents=True, exist_ok=True)
    service_marker.write_text("", encoding="utf-8")

    command_path = home / ".local" / "bin" / "mobaile"
    command_path.parent.mkdir(parents=True)
    command_path.symlink_to(repo / "scripts" / "mobaile")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "uninstall"],
        env={
            **os.environ,
            "HOME": str(home),
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_RUNTIME_DATA_ROOT": str(runtime_root),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "MOBaiLE uninstall" in result.stdout
    assert "Data kept" in result.stdout
    assert "Uninstall complete" in result.stdout
    assert "service uninstall" in log_path.read_text(encoding="utf-8")
    if platform.system() == "Darwin":
        assert "service keep-awake-uninstall" in log_path.read_text(encoding="utf-8")
    assert not command_path.exists()
    assert runtime_root.exists()
    assert (backend_dir / ".env").exists()
    assert repo.exists()


def test_mobaile_uninstall_delete_data_removes_runtime_and_checkout_state(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    scripts_dir = repo / "scripts"
    home = tmp_path / "home"
    runtime_root = tmp_path / "runtime-root"
    backend_dir.mkdir(parents=True)
    scripts_dir.mkdir(parents=True)
    home.mkdir()
    (runtime_root / "backend-runtime" / "logs").mkdir(parents=True)
    (backend_dir / "data" / "profiles").mkdir(parents=True)
    (backend_dir / "logs").mkdir()
    (backend_dir / ".env").write_text("VOICE_AGENT_API_TOKEN=test-token\n", encoding="utf-8")
    (backend_dir / "pairing.json").write_text('{"server_url":"http://127.0.0.1:8000"}\n', encoding="utf-8")
    (backend_dir / "pairing-qr.png").write_text("qr", encoding="utf-8")
    (backend_dir / "data" / "runs.db").write_text("db", encoding="utf-8")
    (backend_dir / "logs" / "backend.log").write_text("log", encoding="utf-8")

    helper_name = "service_macos.sh" if platform.system() == "Darwin" else "service_linux.sh"
    write_executable(
        scripts_dir / helper_name,
        "#!/usr/bin/env bash\nset -euo pipefail\n",
    )

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "uninstall", "--delete-data", "--yes"],
        env={
            **os.environ,
            "HOME": str(home),
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_RUNTIME_DATA_ROOT": str(runtime_root),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "Deleted runtime data" in result.stdout
    assert not runtime_root.exists()
    assert not (backend_dir / ".env").exists()
    assert not (backend_dir / "pairing.json").exists()
    assert not (backend_dir / "pairing-qr.png").exists()
    assert not (backend_dir / "data").exists()
    assert not (backend_dir / "logs").exists()
    assert repo.exists()


def test_mobaile_uninstall_delete_data_requires_yes_noninteractive(tmp_path: Path):
    repo = tmp_path / "repo"
    home = tmp_path / "home"
    (repo / "backend").mkdir(parents=True)
    home.mkdir()

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "uninstall", "--delete-data"],
        env={
            **os.environ,
            "HOME": str(home),
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_RUNTIME_DATA_ROOT": str(tmp_path / "runtime-root"),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "require --yes" in result.stderr


def test_mobaile_uninstall_dry_run_allows_delete_data_without_yes(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    home = tmp_path / "home"
    runtime_root = tmp_path / "runtime-root"
    backend_dir.mkdir(parents=True)
    home.mkdir()
    runtime_root.mkdir()
    (backend_dir / ".env").write_text("VOICE_AGENT_API_TOKEN=test-token\n", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "uninstall", "--delete-data", "--dry-run"],
        env={
            **os.environ,
            "HOME": str(home),
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_RUNTIME_DATA_ROOT": str(runtime_root),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "Would delete runtime data" in result.stdout
    assert "Dry run complete" in result.stdout
    assert runtime_root.exists()
    assert (backend_dir / ".env").exists()


def test_mobaile_update_check_reports_available_update(tmp_path: Path):
    repo, author, shared_env = create_update_checkout(tmp_path)

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "update", "--check"],
        env={
            **shared_env,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ALLOW_ANY_UPDATE_REMOTE": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "Current branch: main" in result.stdout
    assert "Update available." in result.stdout
    assert run_git(["rev-parse", "--short", "HEAD"], cwd=author, env=shared_env).stdout.strip() in result.stdout


def test_mobaile_update_pulls_and_reapplies_setup(tmp_path: Path):
    repo, author, shared_env = create_update_checkout(tmp_path)

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "update"],
        env={
            **shared_env,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ALLOW_ANY_UPDATE_REMOTE": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "Updated MOBaiLE to" in result.stdout
    assert run_git(["rev-parse", "HEAD"], cwd=repo, env=shared_env).stdout.strip() == run_git(
        ["rev-parse", "HEAD"], cwd=author, env=shared_env
    ).stdout.strip()

    install_args = (repo / "update_args.txt").read_text(encoding="utf-8").splitlines()
    assert install_args == [
        "--checkout",
        str(repo),
        "--non-interactive",
        "--mode",
        "full-access",
        "--phone-access",
        "tailscale",
        "--background-service",
        "no",
    ]


def test_mobaile_update_refuses_dirty_checkout(tmp_path: Path):
    repo, _author, shared_env = create_update_checkout(tmp_path)
    (repo / "local-notes.txt").write_text("dirty\n", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "update"],
        env={
            **shared_env,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_ALLOW_ANY_UPDATE_REMOTE": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "requires a clean checkout" in result.stderr
