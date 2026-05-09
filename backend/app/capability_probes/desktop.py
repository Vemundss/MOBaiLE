from __future__ import annotations

import json
import platform
import shutil
import subprocess
import time
from typing import Callable

from app.models.schemas import AgendaItem, CapabilityProbe


def probe_peekaboo_permissions(*, deep: bool) -> CapabilityProbe:
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


def probe_calendar_adapter(
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

    was_running = is_process_running("Calendar")
    if launch_app:
        open_app_background("Calendar")
        time.sleep(0.5)
    running = is_process_running("Calendar")
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
        status, code, message = classify_apple_event_failure(str(exc), "Calendar")
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


def is_process_running(process_name: str) -> bool:
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


def open_app_background(app_name: str) -> None:
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


def classify_apple_event_failure(raw_error: str, app_name: str) -> tuple[str, str, str]:
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
