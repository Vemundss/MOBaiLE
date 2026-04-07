from __future__ import annotations

import os
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def test_pairing_qr_script_uses_python_fallback_when_qrencode_is_missing(tmp_path: Path):
    repo = tmp_path / "repo"
    scripts_dir = repo / "scripts"
    backend_dir = repo / "backend"
    fake_bin = tmp_path / "bin"
    out_path = tmp_path / "pairing-qr.png"

    scripts_dir.mkdir(parents=True, exist_ok=True)
    backend_dir.mkdir(parents=True, exist_ok=True)
    fake_bin.mkdir(parents=True, exist_ok=True)

    shutil.copy2(PROJECT_ROOT / "scripts" / "pairing_qr.sh", scripts_dir / "pairing_qr.sh")
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","server_urls":["http://127.0.0.1:8000"],"session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    write_executable(
        fake_bin / "uv",
        textwrap.dedent(
            f"""\
            #!/usr/bin/env python3
            import subprocess
            import sys

            args = sys.argv[1:]
            if args[:2] == ["run", "python"]:
                raise SystemExit(subprocess.call([{sys.executable!r}] + args[2:]))
            raise SystemExit(f"unsupported uv invocation: {{args}}")
            """
        ),
    )

    result = subprocess.run(
        [
            "bash",
            str(scripts_dir / "pairing_qr.sh"),
            "--out",
            str(out_path),
            "--quiet",
            "--no-preview",
        ],
        cwd=repo,
        env={
            **os.environ,
            "PATH": f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == ""
    assert out_path.exists()
    assert out_path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")


def test_pairing_qr_script_refreshes_expired_pair_code_before_generating_qr(tmp_path: Path):
    repo = tmp_path / "repo"
    scripts_dir = repo / "scripts"
    backend_dir = repo / "backend"
    fake_bin = tmp_path / "bin"
    out_path = tmp_path / "pairing-qr.png"

    scripts_dir.mkdir(parents=True, exist_ok=True)
    backend_dir.mkdir(parents=True, exist_ok=True)
    fake_bin.mkdir(parents=True, exist_ok=True)

    shutil.copy2(PROJECT_ROOT / "scripts" / "pairing_qr.sh", scripts_dir / "pairing_qr.sh")
    pairing_path = backend_dir / "pairing.json"
    pairing_path.write_text(
        '{"server_url":"http://127.0.0.1:8000","server_urls":["http://127.0.0.1:8000"],"session_id":"iphone-app","pair_code":"expired-1234","pair_code_expires_at":"2000-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    write_executable(
        fake_bin / "uv",
        textwrap.dedent(
            f"""\
            #!/usr/bin/env python3
            import subprocess
            import sys

            args = sys.argv[1:]
            if args[:2] == ["run", "python"]:
                raise SystemExit(subprocess.call([{sys.executable!r}] + args[2:]))
            raise SystemExit(f"unsupported uv invocation: {{args}}")
            """
        ),
    )

    result = subprocess.run(
        [
            "bash",
            str(scripts_dir / "pairing_qr.sh"),
            "--out",
            str(out_path),
            "--quiet",
            "--no-preview",
        ],
        cwd=repo,
        env={
            **os.environ,
            "PATH": f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    updated = pairing_path.read_text(encoding="utf-8")
    assert '"pair_code": "expired-1234"' not in updated
    assert '"pair_code_expires_at": "2000-01-01T00:00:00Z"' not in updated
    assert out_path.exists()
    assert out_path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
