#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys


REPO_ROOT = Path(__file__).resolve().parents[1]
BACKEND_DIR = REPO_ROOT / "backend"
DEFAULT_CODEX_HOME = Path.home() / ".codex"
DEFAULT_PLAYWRIGHT_OUTPUT_DIR = BACKEND_DIR / "data" / "playwright"
DEFAULT_PLAYWRIGHT_USER_DATA_DIR = BACKEND_DIR / "data" / "playwright-profile"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Provision Codex MCP servers for autonomous MOBaiLE runs."
    )
    parser.add_argument(
        "--mode",
        choices=("safe", "full-access"),
        default="full-access",
        help="Backend security mode. full-access enables unrestricted Playwright file access.",
    )
    parser.add_argument(
        "--codex-home",
        default=os.environ.get("VOICE_AGENT_CODEX_HOME") or os.environ.get("CODEX_HOME") or str(DEFAULT_CODEX_HOME),
        help="Codex home directory to configure. Defaults to VOICE_AGENT_CODEX_HOME, CODEX_HOME, or ~/.codex.",
    )
    parser.add_argument(
        "--playwright-output-dir",
        default=str(DEFAULT_PLAYWRIGHT_OUTPUT_DIR),
        help="Directory for Playwright artifacts and session output.",
    )
    parser.add_argument(
        "--playwright-user-data-dir",
        default=str(DEFAULT_PLAYWRIGHT_USER_DATA_DIR),
        help="Directory for the persistent Playwright browser profile.",
    )
    parser.add_argument(
        "--force-skills",
        action="store_true",
        help="Deprecated no-op. MOBaiLE no longer provisions repo-managed Codex skills.",
    )
    parser.add_argument(
        "--force-mcp",
        action="store_true",
        help="Replace existing MCP server configs even when they were customized.",
    )
    parser.add_argument(
        "--skip-browser-warmup",
        action="store_true",
        help="Skip Playwright browser install warmup.",
    )
    return parser.parse_args()


def info(message: str) -> None:
    print(f"[INFO] {message}")


def ok(message: str) -> None:
    print(f"[OK] {message}")


def warn(message: str) -> None:
    print(f"[WARN] {message}")


def _resolve_path(raw: str) -> Path:
    path = Path(raw).expanduser()
    if path.is_absolute():
        return path.resolve()
    return (REPO_ROOT / path).resolve()


def _run(
    cmd: list[str],
    *,
    env: dict[str, str] | None = None,
    check: bool = False,
    timeout: int = 30,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        env=env,
        check=check,
        timeout=timeout,
    )


def _codex_env(codex_home: Path) -> dict[str, str]:
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    return env


def _codex_exists() -> bool:
    return shutil.which("codex") is not None


def _npx_exists() -> bool:
    return shutil.which("npx") is not None


def get_mcp_config(*, codex_home: Path, name: str) -> dict[str, object] | None:
    proc = _run(
        ["codex", "mcp", "get", name, "--json"],
        env=_codex_env(codex_home),
        timeout=10,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def add_mcp_server(*, codex_home: Path, name: str, command: str, args: list[str]) -> bool:
    proc = _run(
        ["codex", "mcp", "add", name, "--", command, *args],
        env=_codex_env(codex_home),
        timeout=20,
    )
    if proc.returncode == 0:
        ok(f"configured Codex MCP server '{name}'")
        return True
    warn(f"failed to configure Codex MCP server '{name}': {proc.stderr.strip() or proc.stdout.strip()}")
    return False


def remove_mcp_server(*, codex_home: Path, name: str) -> None:
    _run(
        ["codex", "mcp", "remove", name],
        env=_codex_env(codex_home),
        timeout=10,
    )


def ensure_mcp_server(
    *,
    codex_home: Path,
    name: str,
    command: str,
    args: list[str],
    force: bool,
    replace_baseline_playwright: bool = False,
) -> None:
    existing = get_mcp_config(codex_home=codex_home, name=name)
    desired_transport = {"command": command, "args": args}
    if existing is None:
        add_mcp_server(codex_home=codex_home, name=name, command=command, args=args)
        return

    transport = existing.get("transport") if isinstance(existing, dict) else None
    current_command = ""
    current_args: list[str] = []
    if isinstance(transport, dict):
        current_command = str(transport.get("command") or "")
        raw_args = transport.get("args") or []
        if isinstance(raw_args, list):
            current_args = [str(item) for item in raw_args]

    if current_command == desired_transport["command"] and current_args == desired_transport["args"]:
        ok(f"Codex MCP server '{name}' already matches the MOBaiLE profile")
        return

    baseline_playwright = (
        name == "playwright"
        and current_command == "npx"
        and current_args == ["@playwright/mcp@latest"]
    )
    if force or (replace_baseline_playwright and baseline_playwright):
        remove_mcp_server(codex_home=codex_home, name=name)
        add_mcp_server(codex_home=codex_home, name=name, command=command, args=args)
        return

    warn(f"leaving existing custom Codex MCP server '{name}' unchanged")


def detect_browser_channel() -> str | None:
    system = platform.system()
    if system == "Darwin":
        if Path("/Applications/Google Chrome.app").exists():
            return "chrome"
        if Path("/Applications/Microsoft Edge.app").exists():
            return "msedge"
        return None

    chrome_binaries = ("google-chrome", "google-chrome-stable", "chrome", "chromium-browser", "chromium")
    if any(shutil.which(candidate) for candidate in chrome_binaries):
        return "chrome"
    if shutil.which("microsoft-edge"):
        return "msedge"
    return None


def desired_playwright_args(
    *,
    mode: str,
    output_dir: Path,
    user_data_dir: Path,
) -> list[str]:
    args = [
        "@playwright/mcp@latest",
        "--caps",
        "vision,pdf,devtools",
        "--save-session",
        "--save-trace",
        "--output-dir",
        str(output_dir),
        "--user-data-dir",
        str(user_data_dir),
        "--grant-permissions",
        "clipboard-read",
        "clipboard-write",
    ]
    browser_channel = detect_browser_channel()
    if browser_channel:
        args.extend(["--browser", browser_channel])
    if platform.system() != "Darwin":
        args.append("--headless")
    if mode == "full-access":
        args.append("--allow-unrestricted-file-access")
    return args


def warm_playwright() -> None:
    proc = _run(
        ["npx", "-y", "playwright@latest", "install", "chromium"],
        timeout=600,
    )
    if proc.returncode == 0:
        ok("warmed Playwright Chromium browser runtime")
        return
    warn(f"Playwright warmup failed: {proc.stderr.strip() or proc.stdout.strip()}")


def show_peekaboo_permissions() -> None:
    if platform.system() != "Darwin":
        return
    proc = _run(
        ["npx", "-y", "@steipete/peekaboo", "permissions", "--json"],
        timeout=20,
    )
    if proc.returncode != 0:
        warn(f"Peekaboo permission probe failed: {proc.stderr.strip() or proc.stdout.strip()}")
        return
    try:
        payload = json.loads(proc.stdout)
        permissions = payload.get("data", {}).get("permissions", [])
    except json.JSONDecodeError:
        warn("Peekaboo permission probe returned invalid JSON")
        return

    missing = [item["name"] for item in permissions if item.get("isRequired") and not item.get("isGranted")]
    if missing:
        warn(f"missing macOS permissions for unattended desktop control: {', '.join(missing)}")
    else:
        ok("Peekaboo reports required macOS permissions are granted")


def main() -> int:
    args = parse_args()

    codex_home = _resolve_path(args.codex_home)
    playwright_output_dir = _resolve_path(args.playwright_output_dir)
    playwright_user_data_dir = _resolve_path(args.playwright_user_data_dir)
    codex_home.mkdir(parents=True, exist_ok=True)
    playwright_output_dir.mkdir(parents=True, exist_ok=True)
    playwright_user_data_dir.mkdir(parents=True, exist_ok=True)

    info(f"Codex home: {codex_home}")
    info(f"Playwright output dir: {playwright_output_dir}")
    info(f"Playwright user-data dir: {playwright_user_data_dir}")

    if not _codex_exists():
        warn("codex is not installed; skipping MCP provisioning")
        return 0

    if args.force_skills:
        warn("--force-skills is deprecated; repo-managed Codex skills were removed")

    ensure_mcp_server(
        codex_home=codex_home,
        name="peekaboo",
        command="npx",
        args=["-y", "@steipete/peekaboo", "mcp"],
        force=args.force_mcp,
    )
    ensure_mcp_server(
        codex_home=codex_home,
        name="playwright",
        command="npx",
        args=desired_playwright_args(
            mode=args.mode,
            output_dir=playwright_output_dir,
            user_data_dir=playwright_user_data_dir,
        ),
        force=args.force_mcp,
        replace_baseline_playwright=True,
    )

    if not _npx_exists():
        warn("npx is not installed; Playwright and Peekaboo MCP servers will not launch until Node.js/npm is available")
        return 0

    show_peekaboo_permissions()
    if not args.skip_browser_warmup:
        warm_playwright()
    return 0


if __name__ == "__main__":
    sys.exit(main())
