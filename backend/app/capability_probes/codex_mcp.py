from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from app.host_tools import binary_available
from app.models.schemas import CapabilityProbe


def probe_codex_mcp_server(codex_binary: str, codex_home: Path, server_name: str) -> CapabilityProbe:
    title = f"Codex MCP: {server_name}"
    if not binary_available(codex_binary):
        return CapabilityProbe(
            id=f"codex_mcp_{server_name}",
            title=title,
            status="blocked",
            code="missing_dependency",
            message="Codex CLI is not available, so MCP server configuration cannot be checked.",
            details={"codex_binary": codex_binary, "codex_home": str(codex_home)},
        )

    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    try:
        proc = subprocess.run(
            [codex_binary, "mcp", "get", server_name, "--json"],
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
    except Exception as exc:
        return CapabilityProbe(
            id=f"codex_mcp_{server_name}",
            title=title,
            status="blocked",
            code="probe_failed",
            message=f"Failed to inspect Codex MCP server '{server_name}': {exc}",
            details={"codex_binary": codex_binary, "codex_home": str(codex_home)},
        )

    if proc.returncode != 0 or not proc.stdout.strip():
        return CapabilityProbe(
            id=f"codex_mcp_{server_name}",
            title=title,
            status="blocked",
            code="missing_configuration",
            message=f"Codex MCP server '{server_name}' is not configured.",
            details={"codex_binary": codex_binary, "codex_home": str(codex_home)},
        )

    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return CapabilityProbe(
            id=f"codex_mcp_{server_name}",
            title=title,
            status="degraded",
            code="invalid_configuration",
            message=f"Codex MCP server '{server_name}' returned invalid JSON.",
            details={"codex_binary": codex_binary, "codex_home": str(codex_home)},
        )

    enabled = bool(payload.get("enabled", False))
    transport = payload.get("transport") or {}
    command = str(transport.get("command", ""))
    args = [str(item) for item in transport.get("args") or []]
    details: dict[str, object] = {
        "codex_home": str(codex_home),
        "command": command,
        "args": args,
    }
    if not enabled:
        return CapabilityProbe(
            id=f"codex_mcp_{server_name}",
            title=title,
            status="blocked",
            code="disabled",
            message=f"Codex MCP server '{server_name}' is configured but disabled.",
            details=details,
        )

    if server_name == "playwright":
        has_persistence = (
            "--user-data-dir" in args
            and "--output-dir" in args
            and "--save-session" in args
        )
        details["persistent_browser_state"] = has_persistence
        if has_persistence:
            return CapabilityProbe(
                id="codex_mcp_playwright",
                title=title,
                status="ready",
                code="ok",
                message="Codex Playwright MCP is configured with persistent browser state.",
                details=details,
            )
        return CapabilityProbe(
            id="codex_mcp_playwright",
            title=title,
            status="degraded",
            code="session_persistence_missing",
            message="Codex Playwright MCP is configured, but browser session persistence is missing.",
            details=details,
        )

    return CapabilityProbe(
        id=f"codex_mcp_{server_name}",
        title=title,
        status="ready",
        code="ok",
        message=f"Codex MCP server '{server_name}' is configured.",
        details=details,
    )
