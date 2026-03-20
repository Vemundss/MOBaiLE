from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import time
from datetime import datetime
from datetime import timezone
from pathlib import Path
from typing import Callable

from app.models.schemas import AgendaItem, CapabilitiesResponse, CapabilityProbe


def _binary_available(binary: str) -> bool:
    trimmed = binary.strip()
    if not trimmed:
        return False
    if "/" in trimmed or trimmed.startswith("."):
        return Path(trimmed).expanduser().exists()
    return shutil.which(trimmed) is not None


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
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    capabilities: list[CapabilityProbe] = []

    capabilities.append(_probe_binary("codex_cli", "Codex CLI", codex_binary))
    capabilities.append(_probe_binary("claude_cli", "Claude Code CLI", claude_binary))
    capabilities.append(_probe_binary("uv_cli", "uv package manager", "uv"))
    capabilities.append(_probe_binary("npx_cli", "npx runtime", "npx"))
    capabilities.append(_probe_transcriber(transcribe_provider))
    capabilities.append(_probe_codex_search(codex_enable_web_search))
    capabilities.append(_probe_codex_mcp_server(codex_binary, codex_home, "playwright"))
    capabilities.append(_probe_codex_mcp_server(codex_binary, codex_home, "peekaboo"))
    capabilities.append(_probe_codex_skill(codex_home, "playwright"))
    capabilities.append(_probe_codex_skill(codex_home, "peekaboo"))
    capabilities.append(_probe_codex_skill(codex_home, "remote-operator"))
    capabilities.append(
        _probe_playwright_persistence(
            output_dir=playwright_output_dir,
            user_data_dir=playwright_user_data_dir,
        )
    )
    capabilities.append(_probe_peekaboo_permissions(deep=deep))
    capabilities.append(
        _probe_calendar_adapter(
            deep=deep,
            launch_app=launch_apps,
            fetch_calendar_events=fetch_calendar_events,
        )
    )
    capabilities.append(_probe_mail_adapter(deep=deep, launch_app=launch_apps))

    report_target = str(report_path) if report_path else None
    response = CapabilitiesResponse(
        checked_at=now,
        host_platform=platform.system(),
        security_mode=security_mode if security_mode in {"safe", "full-access"} else "safe",
        capabilities=capabilities,
        report_path=report_target,
    )
    if report_path is not None:
        _persist_capabilities_report(response, report_path)
    return response


def _probe_binary(capability_id: str, title: str, binary: str) -> CapabilityProbe:
    trimmed = binary.strip()
    resolved = ""
    if "/" in trimmed or trimmed.startswith("."):
        candidate = Path(trimmed).expanduser()
        if candidate.exists():
            resolved = str(candidate.resolve())
    elif trimmed:
        resolved = shutil.which(trimmed) or ""
    details: dict[str, object] = {"binary": trimmed}
    if resolved:
        details["resolved_path"] = resolved
        return CapabilityProbe(
            id=capability_id,
            title=title,
            status="ready",
            code="ok",
            message=f"{title} is available.",
            details=details,
        )
    return CapabilityProbe(
        id=capability_id,
        title=title,
        status="blocked",
        code="missing_dependency",
        message=f"{title} is not available in PATH.",
        details=details,
    )


def _probe_transcriber(provider: str) -> CapabilityProbe:
    normalized = provider.strip().lower() or "openai"
    details: dict[str, object] = {"provider": normalized}
    if normalized == "mock":
        return CapabilityProbe(
            id="transcribe_provider",
            title="Transcription provider",
            status="ready",
            code="ok",
            message="Mock transcription is active.",
            details=details,
        )
    if normalized == "openai":
        if os.getenv("OPENAI_API_KEY", "").strip():
            return CapabilityProbe(
                id="transcribe_provider",
                title="Transcription provider",
                status="ready",
                code="ok",
                message="OpenAI transcription is configured.",
                details=details,
            )
        return CapabilityProbe(
            id="transcribe_provider",
            title="Transcription provider",
            status="blocked",
            code="auth_missing",
            message="OpenAI transcription selected but OPENAI_API_KEY is not set.",
            details=details,
        )
    return CapabilityProbe(
        id="transcribe_provider",
        title="Transcription provider",
        status="degraded",
        code="unknown_provider",
        message=f"Provider '{normalized}' is not recognized by capability probe.",
        details=details,
    )


def _probe_codex_search(enabled: bool) -> CapabilityProbe:
    return CapabilityProbe(
        id="codex_web_search",
        title="Codex live web search",
        status="ready" if enabled else "degraded",
        code="ok" if enabled else "disabled",
        message="Codex runs include live web search." if enabled else "Codex live web search is disabled.",
        details={"enabled": enabled},
    )


def _probe_codex_mcp_server(codex_binary: str, codex_home: Path, server_name: str) -> CapabilityProbe:
    title = f"Codex MCP: {server_name}"
    if not _binary_available(codex_binary):
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


def _probe_codex_skill(codex_home: Path, skill_name: str) -> CapabilityProbe:
    skill_path = codex_home / "skills" / skill_name / "SKILL.md"
    if skill_path.exists():
        return CapabilityProbe(
            id=f"codex_skill_{skill_name.replace('-', '_')}",
            title=f"Codex skill: {skill_name}",
            status="ready",
            code="ok",
            message=f"Codex skill '{skill_name}' is installed.",
            details={"path": str(skill_path)},
        )
    return CapabilityProbe(
        id=f"codex_skill_{skill_name.replace('-', '_')}",
        title=f"Codex skill: {skill_name}",
        status="blocked",
        code="missing_skill",
        message=f"Codex skill '{skill_name}' is not installed.",
        details={"path": str(skill_path)},
    )


def _probe_playwright_persistence(*, output_dir: Path, user_data_dir: Path) -> CapabilityProbe:
    details = {
        "output_dir": str(output_dir),
        "user_data_dir": str(user_data_dir),
    }
    output_ready = output_dir.exists() and os.access(output_dir, os.W_OK)
    user_data_ready = user_data_dir.exists() and os.access(user_data_dir, os.W_OK)
    if output_ready and user_data_ready:
        return CapabilityProbe(
            id="playwright_persistence",
            title="Playwright persistent state",
            status="ready",
            code="ok",
            message="Persistent Playwright output and browser profile directories are writable.",
            details=details,
        )
    return CapabilityProbe(
        id="playwright_persistence",
        title="Playwright persistent state",
        status="blocked",
        code="path_unavailable",
        message="Persistent Playwright output or browser profile directory is not writable.",
        details=details,
    )


def _probe_peekaboo_permissions(*, deep: bool) -> CapabilityProbe:
    title = "Peekaboo permissions (macOS)"
    if platform.system() != "Darwin":
        return CapabilityProbe(
            id="peekaboo_permissions",
            title=title,
            status="unsupported",
            code="unsupported_platform",
            message="Peekaboo desktop permission probe supports macOS only.",
            unattended_safe=False,
        )
    if shutil.which("npx") is None:
        return CapabilityProbe(
            id="peekaboo_permissions",
            title=title,
            status="blocked",
            code="missing_dependency",
            message="npx is not available, so Peekaboo permission status cannot be checked.",
            unattended_safe=False,
        )

    try:
        proc = subprocess.run(
            ["npx", "-y", "@steipete/peekaboo", "permissions", "--json"],
            capture_output=True,
            text=True,
            timeout=20 if deep else 12,
        )
    except Exception as exc:
        return CapabilityProbe(
            id="peekaboo_permissions",
            title=title,
            status="blocked",
            code="probe_failed",
            message=f"Peekaboo permission probe failed: {exc}",
            unattended_safe=False,
        )

    if proc.returncode != 0 or not proc.stdout.strip():
        return CapabilityProbe(
            id="peekaboo_permissions",
            title=title,
            status="blocked",
            code="probe_failed",
            message=proc.stderr.strip() or "Peekaboo permission probe failed.",
            unattended_safe=False,
        )

    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return CapabilityProbe(
            id="peekaboo_permissions",
            title=title,
            status="blocked",
            code="invalid_probe_output",
            message="Peekaboo permission probe returned invalid JSON.",
            unattended_safe=False,
        )

    details = payload.get("data", {}) if isinstance(payload.get("data"), dict) else {}
    permissions = details.get("permissions", []) if isinstance(details.get("permissions"), list) else []
    missing = [
        str(item.get("name", "unknown"))
        for item in permissions
        if item.get("isRequired") and not item.get("isGranted")
    ]
    if missing:
        return CapabilityProbe(
            id="peekaboo_permissions",
            title=title,
            status="blocked",
            code="permission_required",
            message=f"Missing required macOS permissions for unattended desktop control: {', '.join(missing)}.",
            unattended_safe=False,
            details=details,
        )
    return CapabilityProbe(
        id="peekaboo_permissions",
        title=title,
        status="ready",
        code="ok",
        message="Peekaboo reports required macOS permissions are granted.",
        unattended_safe=False,
        details=details,
    )


def _probe_calendar_adapter(
    *,
    deep: bool,
    launch_app: bool,
    fetch_calendar_events: Callable[[], list[AgendaItem]] | None,
) -> CapabilityProbe:
    title = "Calendar adapter (macOS)"
    if platform.system() != "Darwin":
        return CapabilityProbe(
            id="calendar_adapter",
            title=title,
            status="unsupported",
            code="unsupported_platform",
            message="Calendar adapter probe supports macOS only.",
            unattended_safe=False,
        )
    if shutil.which("osascript") is None:
        return CapabilityProbe(
            id="calendar_adapter",
            title=title,
            status="blocked",
            code="missing_dependency",
            message="osascript is not available on this host.",
            unattended_safe=False,
        )

    was_running = _is_process_running("Calendar")
    if launch_app:
        _open_app_background("Calendar")
        time.sleep(0.5)
    running = _is_process_running("Calendar")
    details: dict[str, object] = {
        "deep_probe": deep,
        "app_running": running,
        "app_was_running": was_running,
    }
    if not deep:
        if running:
            return CapabilityProbe(
                id="calendar_adapter",
                title=title,
                status="ready",
                code="light_probe_ok",
                message="Calendar app is running. Deep permission probe was skipped.",
                unattended_safe=False,
                details=details,
            )
        return CapabilityProbe(
            id="calendar_adapter",
            title=title,
            status="degraded",
            code="app_not_running",
            message="Calendar app is not running. Run warmup before unattended use.",
            unattended_safe=False,
            details=details,
        )

    if fetch_calendar_events is None:
        return CapabilityProbe(
            id="calendar_adapter",
            title=title,
            status="blocked",
            code="probe_unavailable",
            message="Calendar deep probe is not available in this runtime.",
            unattended_safe=False,
            details=details,
        )

    try:
        events = fetch_calendar_events()
    except Exception as exc:  # pragma: no cover - defensive fallback
        status, code, message = _classify_apple_event_failure(str(exc), "Calendar")
        details["error"] = str(exc)
        return CapabilityProbe(
            id="calendar_adapter",
            title=title,
            status=status,
            code=code,
            message=message,
            unattended_safe=False,
            details=details,
        )
    details["event_count_today"] = len(events)
    return CapabilityProbe(
        id="calendar_adapter",
        title=title,
        status="ready",
        code="ok",
        message="Calendar deep probe succeeded.",
        unattended_safe=False,
        details=details,
    )


def _probe_mail_adapter(*, deep: bool, launch_app: bool) -> CapabilityProbe:
    title = "Mail adapter (macOS)"
    if platform.system() != "Darwin":
        return CapabilityProbe(
            id="mail_adapter",
            title=title,
            status="unsupported",
            code="unsupported_platform",
            message="Mail adapter probe supports macOS only.",
            unattended_safe=False,
        )
    if shutil.which("osascript") is None:
        return CapabilityProbe(
            id="mail_adapter",
            title=title,
            status="blocked",
            code="missing_dependency",
            message="osascript is not available on this host.",
            unattended_safe=False,
        )

    was_running = _is_process_running("Mail")
    if launch_app:
        _open_app_background("Mail")
        time.sleep(0.5)
    running = _is_process_running("Mail")
    details: dict[str, object] = {
        "deep_probe": deep,
        "app_running": running,
        "app_was_running": was_running,
    }
    if not deep:
        if running:
            return CapabilityProbe(
                id="mail_adapter",
                title=title,
                status="ready",
                code="light_probe_ok",
                message="Mail app is running. Deep permission probe was skipped.",
                unattended_safe=False,
                details=details,
            )
        return CapabilityProbe(
            id="mail_adapter",
            title=title,
            status="degraded",
            code="app_not_running",
            message="Mail app is not running. Run warmup before unattended use.",
            unattended_safe=False,
            details=details,
        )

    script = r'''
tell application "Mail"
    set inboxUnread to 0
    try
        set inboxUnread to unread count of inbox
    end try
    return inboxUnread as text
end tell
'''
    proc = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=20,
    )
    if proc.returncode != 0:
        err = proc.stderr.strip() or "unknown osascript error"
        status, code, message = _classify_apple_event_failure(err, "Mail")
        details["error"] = err
        return CapabilityProbe(
            id="mail_adapter",
            title=title,
            status=status,
            code=code,
            message=message,
            unattended_safe=False,
            details=details,
        )

    unread = (proc.stdout.strip() or "0").strip()
    details["inbox_unread_count"] = unread
    return CapabilityProbe(
        id="mail_adapter",
        title=title,
        status="ready",
        code="ok",
        message="Mail deep probe succeeded.",
        unattended_safe=False,
        details=details,
    )


def _is_process_running(process_name: str) -> bool:
    try:
        proc = subprocess.run(
            ["pgrep", "-x", process_name],
            capture_output=True,
            text=True,
            timeout=2,
        )
    except Exception:
        return False
    return proc.returncode == 0


def _open_app_background(app_name: str) -> None:
    try:
        subprocess.run(
            ["open", "-ga", app_name],
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )
    except Exception:
        return


def _classify_apple_event_failure(raw_error: str, app_name: str) -> tuple[str, str, str]:
    lowered = raw_error.lower()
    if (
        "-1743" in lowered
        or "not authorized" in lowered
        or "not permitted" in lowered
        or ("automation" in lowered and "allow" in lowered)
    ):
        return (
            "blocked",
            "permission_required",
            f"{app_name} permission is missing for Apple Events automation.",
        )
    if "isn't running" in lowered or "isn’t running" in lowered:
        return ("degraded", "app_not_running", f"{app_name} is not running.")
    if "-1728" in lowered:
        return ("degraded", "data_unavailable", f"{app_name} is reachable but requested data is unavailable.")
    return ("blocked", "probe_failed", f"{app_name} probe failed: {raw_error.strip()}")


def _persist_capabilities_report(response: CapabilitiesResponse, report_path: Path) -> None:
    try:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(response.model_dump_json(indent=2) + "\n", encoding="utf-8")
    except OSError:
        return
