from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import textwrap


def test_install_backend_script_persists_phone_access_and_pairing_urls(tmp_path: Path):
    repo_root = Path(__file__).resolve().parents[2]
    source_script = repo_root / "scripts" / "install_backend.sh"
    source_app_init = repo_root / "backend" / "app" / "__init__.py"
    source_pairing_url = repo_root / "backend" / "app" / "pairing_url.py"

    temp_repo = tmp_path / "repo"
    backend_dir = temp_repo / "backend"
    app_dir = backend_dir / "app"
    scripts_dir = temp_repo / "scripts"
    fake_bin = tmp_path / "bin"

    app_dir.mkdir(parents=True, exist_ok=True)
    scripts_dir.mkdir(parents=True, exist_ok=True)
    fake_bin.mkdir(parents=True, exist_ok=True)

    shutil.copy2(source_script, scripts_dir / "install_backend.sh")
    shutil.copy2(source_app_init, app_dir / "__init__.py")
    shutil.copy2(source_pairing_url, app_dir / "pairing_url.py")

    (backend_dir / "sitecustomize.py").write_text(
        textwrap.dedent(
            """
            import app.pairing_url

            app.pairing_url.detect_lan_ip = lambda: None
            """
        ),
        encoding="utf-8",
    )

    (fake_bin / "uv").write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env python3
            import subprocess
            import sys

            args = sys.argv[1:]
            if args == ["sync"]:
                raise SystemExit(0)
            if args[:2] == ["run", "python"]:
                raise SystemExit(subprocess.call([{sys.executable!r}] + args[2:]))
            raise SystemExit(f"unsupported uv invocation: {{args}}")
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "tailscale").write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import json
            import sys

            if sys.argv[1:] == ["status", "--json"]:
                print(json.dumps({"Self": {"DNSName": "mobaile.tail6a5903.ts.net.", "TailscaleIPs": ["100.111.99.51"]}}))
                raise SystemExit(0)
            if sys.argv[1:] == ["ip", "-4"]:
                print("100.111.99.51")
                raise SystemExit(0)
            raise SystemExit(1)
            """
        ),
        encoding="utf-8",
    )
    os.chmod(fake_bin / "uv", 0o755)
    os.chmod(fake_bin / "tailscale", 0o755)

    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["HOME"] = str(tmp_path / "home")
    env["PYTHONPATH"] = str(backend_dir)

    subprocess.run(
        ["bash", str(scripts_dir / "install_backend.sh"), "--phone-access", "tailscale"],
        cwd=temp_repo,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )

    env_contents = (backend_dir / ".env").read_text(encoding="utf-8")
    assert "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale" in env_contents

    pairing_payload = json.loads((backend_dir / "pairing.json").read_text(encoding="utf-8"))
    assert pairing_payload["server_url"] == "http://mobaile.tail6a5903.ts.net:8000"
    assert pairing_payload["server_urls"] == [
        "http://mobaile.tail6a5903.ts.net:8000",
        "http://100.111.99.51:8000",
    ]
