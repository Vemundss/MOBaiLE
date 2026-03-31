from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import textwrap


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
    assert "Readiness failed:" not in result.stdout
    assert "- codex_cli:" not in result.stdout
