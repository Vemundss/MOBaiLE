from __future__ import annotations

import json
import os
import shutil
import subprocess
import textwrap
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def run_warmup_with_capabilities(tmp_path: Path, capabilities: list[dict[str, object]]) -> subprocess.CompletedProcess[str]:
    repo = tmp_path / "repo"
    scripts_dir = repo / "scripts"
    backend_dir = repo / "backend"
    fake_bin = tmp_path / "bin"
    payload_path = tmp_path / "capabilities.json"

    scripts_dir.mkdir(parents=True)
    backend_dir.mkdir(parents=True)
    fake_bin.mkdir(parents=True)
    shutil.copy2(PROJECT_ROOT / "scripts" / "warmup_capabilities.sh", scripts_dir / "warmup_capabilities.sh")
    (backend_dir / ".env").write_text("VOICE_AGENT_API_TOKEN=test-token\n", encoding="utf-8")
    payload_path.write_text(
        json.dumps(
            {
                "checked_at": "2026-05-10T10:00:00Z",
                "host_platform": "Darwin",
                "security_mode": "full-access",
                "capabilities": capabilities,
                "report_path": str(tmp_path / "report.json"),
            }
        ),
        encoding="utf-8",
    )
    write_executable(
        fake_bin / "curl",
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail
            url="${{@:$#}}"
            if [[ "${{url}}" == */health ]]; then
              printf '{{"status":"ok"}}'
              exit 0
            fi
            cat "{payload_path}"
            """
        ),
    )

    return subprocess.run(
        ["bash", str(scripts_dir / "warmup_capabilities.sh"), "--deep", "true"],
        cwd=repo,
        env={**os.environ, "PATH": f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin"},
        capture_output=True,
        text=True,
        check=False,
    )


def test_warmup_treats_optional_blocked_capabilities_as_warnings(tmp_path: Path) -> None:
    result = run_warmup_with_capabilities(
        tmp_path,
        [
            {"id": "codex_cli", "status": "ready", "code": "ok", "message": "Codex is available."},
            {"id": "npx_cli", "status": "ready", "code": "ok", "message": "npx is available."},
            {"id": "claude_cli", "status": "blocked", "code": "missing_dependency", "message": "Claude is missing."},
            {"id": "transcribe_provider", "status": "blocked", "code": "auth_missing", "message": "No key."},
            {"id": "calendar_adapter", "status": "blocked", "code": "probe_failed", "message": "Calendar timed out."},
        ],
    )

    assert result.returncode == 0, result.stderr
    assert "- claude_cli: optional (missing_dependency)" in result.stdout
    assert "Readiness warning: 3 optional capability issue(s)." in result.stderr
    assert "Readiness failed" not in result.stderr


def test_warmup_fails_when_required_capability_is_blocked(tmp_path: Path) -> None:
    result = run_warmup_with_capabilities(
        tmp_path,
        [
            {"id": "codex_cli", "status": "ready", "code": "ok", "message": "Codex is available."},
            {"id": "peekaboo_permissions", "status": "blocked", "code": "permission_required", "message": "Permissions missing."},
            {"id": "claude_cli", "status": "blocked", "code": "missing_dependency", "message": "Claude is missing."},
        ],
    )

    assert result.returncode == 2
    assert "Readiness failed: 1 required capability(ies) need action." in result.stderr
