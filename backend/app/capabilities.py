from __future__ import annotations

import platform
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from app.capability_probes import (
    probe_binary,
    probe_calendar_adapter,
    probe_codex_mcp_server,
    probe_codex_search,
    probe_peekaboo_permissions,
    probe_playwright_persistence,
    probe_transcriber,
)
from app.models.schemas import AgendaItem, CapabilitiesResponse, CapabilityProbe


def _deferred_probe(capability_id: str, title: str, message: str, *, unattended_safe: bool = True) -> CapabilityProbe:
    return CapabilityProbe(
        id=capability_id,
        title=title,
        status="degraded",
        code="deep_probe_required",
        message=message,
        unattended_safe=unattended_safe,
        details={"deep_probe_required": True},
    )


def collect_capabilities(
    *,
    security_mode: str,
    codex_binary: str,
    claude_binary: str,
    codex_home: Path,
    codex_enable_web_search: bool,
    playwright_output_dir: Path,
    playwright_user_data_dir: Path,
    transcribe_provider: str,
    report_path: Path | None = None,
    deep: bool = False,
    launch_apps: bool = False,
    fetch_calendar_events: Callable[[], list[AgendaItem]] | None = None,
) -> CapabilitiesResponse:
    capabilities: list[CapabilityProbe] = []

    capabilities.append(probe_binary("codex_cli", "Codex CLI", codex_binary))
    capabilities.append(probe_binary("claude_cli", "Claude Code CLI", claude_binary))
    capabilities.append(probe_binary("uv_cli", "uv package manager", "uv"))
    capabilities.append(probe_binary("npx_cli", "npx runtime", "npx"))
    capabilities.append(probe_transcriber(transcribe_provider))
    capabilities.append(probe_codex_search(codex_enable_web_search))
    if deep:
        capabilities.append(probe_codex_mcp_server(codex_binary, codex_home, "playwright"))
        capabilities.append(probe_codex_mcp_server(codex_binary, codex_home, "peekaboo"))
    else:
        capabilities.append(
            _deferred_probe(
                "codex_mcp_playwright",
                "Codex MCP: playwright",
                "Skipped subprocess MCP inspection during the light capability check. Run with deep=true to verify.",
            )
        )
        capabilities.append(
            _deferred_probe(
                "codex_mcp_peekaboo",
                "Codex MCP: peekaboo",
                "Skipped subprocess MCP inspection during the light capability check. Run with deep=true to verify.",
            )
        )
    capabilities.append(
        probe_playwright_persistence(
            output_dir=playwright_output_dir,
            user_data_dir=playwright_user_data_dir,
        )
    )
    if deep:
        capabilities.append(probe_peekaboo_permissions(deep=deep))
    else:
        capabilities.append(
            _deferred_probe(
                "peekaboo_permissions",
                "Peekaboo permissions (macOS)",
                "Skipped desktop permission probing during the light capability check. Run with deep=true to verify.",
                unattended_safe=False,
            )
        )
    capabilities.append(
        probe_calendar_adapter(
            deep=deep,
            launch_app=launch_apps,
            fetch_calendar_events=fetch_calendar_events,
        )
    )

    report_target = str(report_path) if report_path else None
    response = CapabilitiesResponse(
        checked_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        host_platform=platform.system(),
        security_mode=security_mode if security_mode in {"safe", "full-access"} else "safe",
        capabilities=capabilities,
        report_path=report_target,
    )
    if report_path is not None:
        _persist_capabilities_report(response, report_path)
    return response


def _persist_capabilities_report(response: CapabilitiesResponse, report_path: Path) -> None:
    try:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(response.model_dump_json(indent=2) + "\n", encoding="utf-8")
    except OSError:
        return
