from __future__ import annotations

import os
import platform
import subprocess
import textwrap
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


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
