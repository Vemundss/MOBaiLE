from __future__ import annotations

import json
import platform
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal
from urllib.parse import urlparse

from pydantic import BaseModel, Field

from app.models.schemas import RunSummary
from app.pairing_service import PairingService
from app.pairing_url_policy import (
    is_loopback_host,
    is_public_server_url,
    server_url_matches_mode,
)
from app.phone_access_mode import PhoneAccessMode
from app.run_state import RunState
from app.runtime_environment import RuntimeEnvironment

SetupCheckStatus = Literal["ok", "todo", "info"]


class SetupReadinessCheck(BaseModel):
    id: str
    title: str
    status: SetupCheckStatus
    message: str


class SetupPhoneAccess(BaseModel):
    mode: PhoneAccessMode
    label: str
    server_url: str | None = None
    server_urls: list[str] = Field(default_factory=list)


class SetupPairingState(BaseModel):
    status: Literal["ready", "expired", "missing", "invalid"]
    message: str
    expires_at: str | None = None
    qr_available: bool = False
    qr_url: str | None = None


class SetupAgentState(BaseModel):
    status: SetupCheckStatus
    available: list[str] = Field(default_factory=list)
    message: str


class SetupFirstRunState(BaseModel):
    status: SetupCheckStatus
    message: str
    run_id: str | None = None
    run_status: str | None = None
    updated_at: str | None = None


class SetupAutonomyState(BaseModel):
    status: SetupCheckStatus
    enabled: bool
    message: str
    setup_command: str = "mobaile autonomy"
    deep_check_command: str = "mobaile autonomy --deep --open-permissions"
    checks: list[SetupReadinessCheck] = Field(default_factory=list)
    next_actions: list[str] = Field(default_factory=list)


class SetupReadinessResponse(BaseModel):
    status: Literal["ready", "needs_action"]
    updated_at: str
    backend_root: str
    security_mode: Literal["safe", "full-access"]
    phone_access: SetupPhoneAccess
    pairing: SetupPairingState
    agent_cli: SetupAgentState
    first_run: SetupFirstRunState
    autonomy: SetupAutonomyState
    checks: list[SetupReadinessCheck]
    next_actions: list[str] = Field(default_factory=list)
    recommended_actions: list[str] = Field(default_factory=list)


def build_setup_readiness(
    env: RuntimeEnvironment,
    pairing_service: PairingService,
    run_state: RunState,
    *,
    include_local_setup_urls: bool = False,
) -> SetupReadinessResponse:
    pairing_payload = _read_pairing_payload(env.pairing_file)
    server_urls = pairing_service.pairing_server_urls()
    server_url = server_urls[0] if server_urls else _string_value(pairing_payload.get("server_url")) or None
    phone_access = SetupPhoneAccess(
        mode=env.phone_access_mode,
        label=_phone_access_label(env.phone_access_mode, env.public_server_url, server_url),
        server_url=server_url,
        server_urls=server_urls,
    )
    pairing = _pairing_state(
        pairing_payload,
        qr_path=_pairing_qr_path(env),
        include_local_setup_urls=include_local_setup_urls,
    )
    agent_cli = _agent_cli_state(env)
    first_run = _first_run_state(run_state)
    autonomy = _autonomy_state(env)
    checks = [
        SetupReadinessCheck(
            id="backend",
            title="Backend",
            status="ok",
            message="Backend is running.",
        ),
        SetupReadinessCheck(
            id="phone_path",
            title="Phone Path",
            status=_phone_path_status(env.phone_access_mode, env.public_server_url, server_urls),
            message=_phone_path_message(env.phone_access_mode, env.public_server_url, server_urls),
        ),
        SetupReadinessCheck(
            id="pairing",
            title="Pairing",
            status="ok" if pairing.status == "ready" else "todo",
            message=pairing.message,
        ),
        SetupReadinessCheck(
            id="agent_cli",
            title="Agent CLI",
            status=agent_cli.status,
            message=agent_cli.message,
        ),
        SetupReadinessCheck(
            id="first_run",
            title="First Run",
            status=first_run.status,
            message=first_run.message,
        ),
    ]
    next_actions = [check.message for check in checks if check.status == "todo"]
    recommended_actions: list[str] = []
    if first_run.status != "ok":
        recommended_actions.append("Run `mobaile first-run` to test a safe starter task.")
    if autonomy.status != "ok":
        recommended_actions.append("Run `mobaile autonomy` on the Mac to provision browser and desktop control.")
    if not next_actions and pairing.qr_available:
        recommended_actions.append("Scan the QR from the phone, then send a small prompt.")
    return SetupReadinessResponse(
        status="needs_action" if next_actions else "ready",
        updated_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        backend_root=str(env.backend_root),
        security_mode=env.security_mode,  # type: ignore[arg-type]
        phone_access=phone_access,
        pairing=pairing,
        agent_cli=agent_cli,
        first_run=first_run,
        autonomy=autonomy,
        checks=checks,
        next_actions=next_actions,
        recommended_actions=recommended_actions,
    )


def setup_page_html() -> str:
    return """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MOBaiLE Setup</title>
  <style>
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; background: Canvas; color: CanvasText; }
    main { width: min(980px, calc(100vw - 32px)); margin: 0 auto; padding: 32px 0 44px; }
    header { display: flex; justify-content: space-between; gap: 18px; align-items: flex-start; margin-bottom: 24px; }
    h1 { margin: 0; font-size: clamp(2rem, 7vw, 4.2rem); line-height: .9; letter-spacing: 0; }
    .lede { margin: 10px 0 0; color: color-mix(in srgb, CanvasText 72%, Canvas); font-size: 1.05rem; max-width: 620px; }
    .status { border: 1px solid color-mix(in srgb, CanvasText 18%, Canvas); border-radius: 8px; padding: 10px 12px; min-width: 128px; text-align: center; font-weight: 700; }
    .ready { background: color-mix(in srgb, #13a36f 18%, Canvas); color: color-mix(in srgb, #13a36f 70%, CanvasText); }
    .needs_action { background: color-mix(in srgb, #d08100 18%, Canvas); color: color-mix(in srgb, #d08100 72%, CanvasText); }
    .grid { display: grid; grid-template-columns: minmax(260px, .78fr) minmax(280px, 1.22fr); gap: 18px; align-items: start; }
    section { border-top: 1px solid color-mix(in srgb, CanvasText 16%, Canvas); padding-top: 18px; }
    .qr { aspect-ratio: 1; width: 100%; max-width: 360px; border: 1px solid color-mix(in srgb, CanvasText 14%, Canvas); border-radius: 8px; display: grid; place-items: center; background: white; overflow: hidden; }
    .qr img { width: 100%; height: 100%; object-fit: contain; image-rendering: pixelated; }
    .qr span { color: #53565a; padding: 18px; text-align: center; }
    .list { display: grid; gap: 10px; }
    .row { display: grid; grid-template-columns: 28px 1fr; gap: 10px; align-items: start; padding: 12px; border: 1px solid color-mix(in srgb, CanvasText 13%, Canvas); border-radius: 8px; }
    .dot { width: 24px; height: 24px; border-radius: 999px; display: grid; place-items: center; font-size: .82rem; font-weight: 800; }
    .ok .dot { background: #13a36f; color: white; }
    .todo .dot { background: #d08100; color: white; }
    .info .dot { background: #3867d6; color: white; }
    .title { font-weight: 700; }
    .message, .meta { color: color-mix(in srgb, CanvasText 68%, Canvas); }
    .actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 16px; }
    code, button { font: inherit; }
    button { border: 1px solid color-mix(in srgb, CanvasText 18%, Canvas); border-radius: 8px; padding: 9px 12px; background: color-mix(in srgb, CanvasText 6%, Canvas); color: CanvasText; cursor: pointer; }
    pre { white-space: pre-wrap; overflow-wrap: anywhere; border-radius: 8px; padding: 12px; background: color-mix(in srgb, CanvasText 7%, Canvas); }
    @media (max-width: 760px) { header, .grid { display: block; } .status { margin-top: 16px; text-align: left; } .qr { max-width: none; margin-bottom: 18px; } }
  </style>
</head>
<body>
<main>
  <header>
    <div>
      <h1>MOBaiLE Setup</h1>
      <p class="lede">Pair the phone, confirm the backend, and run one safe starter task. This page opens on the backend computer; scan the QR with the iPhone.</p>
    </div>
    <div id="status" class="status">Checking</div>
  </header>
  <div class="grid">
    <section>
      <div id="qr" class="qr"><span>Loading pairing QR...</span></div>
      <div class="actions">
        <button type="button" data-copy="mobaile pair">Copy pair command</button>
        <button type="button" data-copy="mobaile first-run">Copy first-run</button>
        <button type="button" id="refresh">Refresh</button>
      </div>
    </section>
    <section>
      <div id="checks" class="list"></div>
      <h2>Next</h2>
      <pre id="next">Checking...</pre>
      <h2>Autonomy</h2>
      <div id="autonomy" class="list"></div>
    </section>
  </div>
</main>
<script>
const $ = (id) => document.getElementById(id);
function symbol(status) { return status === "ok" ? "OK" : status === "todo" ? "!" : "i"; }
function render(data) {
  $("status").textContent = data.status === "ready" ? "Ready" : "Needs action";
  $("status").className = "status " + data.status;
  $("checks").innerHTML = data.checks.map((item) => `
    <div class="row ${item.status}">
      <div class="dot">${symbol(item.status)}</div>
      <div><div class="title">${escapeHTML(item.title)}</div><div class="message">${escapeHTML(item.message)}</div></div>
    </div>`).join("");
  $("autonomy").innerHTML = [
    `<div class="row ${data.autonomy.status}">
      <div class="dot">${symbol(data.autonomy.status)}</div>
      <div><div class="title">Autonomy Setup</div><div class="message">${escapeHTML(data.autonomy.message)}</div></div>
    </div>`,
    ...data.autonomy.checks.map((item) => `
      <div class="row ${item.status}">
        <div class="dot">${symbol(item.status)}</div>
        <div><div class="title">${escapeHTML(item.title)}</div><div class="message">${escapeHTML(item.message)}</div></div>
      </div>`)
  ].join("");
  if (data.pairing.qr_available && data.pairing.qr_url) {
    $("qr").innerHTML = `<img src="${data.pairing.qr_url}?t=${Date.now()}" alt="MOBaiLE pairing QR">`;
  } else {
    $("qr").innerHTML = `<span>${escapeHTML(data.pairing.message || "Run mobaile pair to generate a QR.")}</span>`;
  }
  const lines = [];
  if (data.next_actions.length) lines.push(...data.next_actions);
  if (data.recommended_actions.length) lines.push(...data.recommended_actions);
  lines.push(`Phone access: ${data.phone_access.label}`);
  lines.push(`Backend: ${data.backend_root}`);
  $("next").textContent = lines.join("\\n");
}
function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
async function load() {
  const response = await fetch("/setup/readiness", { cache: "no-store" });
  if (!response.ok) throw new Error(`Readiness failed: ${response.status}`);
  render(await response.json());
}
document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    await navigator.clipboard.writeText(button.dataset.copy);
    button.textContent = "Copied";
    setTimeout(() => { button.textContent = button.dataset.copy.includes("pair") ? "Copy pair command" : "Copy first-run"; }, 1200);
  });
});
$("refresh").addEventListener("click", load);
load().catch((error) => {
  $("status").textContent = "Unavailable";
  $("next").textContent = error.message;
});
</script>
</body>
</html>
"""


def _read_pairing_payload(pairing_file: Path) -> dict[str, object]:
    try:
        payload = json.loads(pairing_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def _pairing_state(
    payload: dict[str, object],
    *,
    qr_path: Path,
    include_local_setup_urls: bool,
) -> SetupPairingState:
    server_url = _string_value(payload.get("server_url"))
    pair_code = _string_value(payload.get("pair_code"))
    expires_at = _string_value(payload.get("pair_code_expires_at"))
    qr_available = qr_path.exists()
    qr_url = "/setup/pairing-qr.png" if include_local_setup_urls and qr_available else None
    if not server_url or not pair_code:
        return SetupPairingState(
            status="missing",
            message="Pairing is not ready; run `mobaile pair`.",
            expires_at=expires_at or None,
            qr_available=qr_available,
            qr_url=qr_url,
        )
    if expires_at:
        try:
            parsed = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
        except ValueError:
            return SetupPairingState(
                status="invalid",
                message="Pairing expiry is invalid; run `mobaile pair`.",
                expires_at=expires_at,
                qr_available=qr_available,
                qr_url=qr_url,
            )
        if parsed <= datetime.now(timezone.utc):
            return SetupPairingState(
                status="expired",
                message="Pair code is expired; run `mobaile pair`.",
                expires_at=expires_at,
                qr_available=qr_available,
                qr_url=qr_url,
            )
    return SetupPairingState(
        status="ready",
        message="Pairing QR is ready.",
        expires_at=expires_at or None,
        qr_available=qr_available,
        qr_url=qr_url,
    )


def _agent_cli_state(env: RuntimeEnvironment) -> SetupAgentState:
    available = env.available_agent_executors()
    if not available:
        return SetupAgentState(
            status="todo",
            available=[],
            message="Install and sign in to Codex CLI or Claude CLI for real agent runs.",
        )
    names = [name.capitalize() for name in available]
    return SetupAgentState(
        status="ok",
        available=available,
        message=f"Agent CLI ready: {', '.join(names)}.",
    )


def _autonomy_state(env: RuntimeEnvironment) -> SetupAutonomyState:
    checks: list[SetupReadinessCheck] = []
    available_agents = env.available_agent_executors()
    codex_available = "codex" in available_agents

    checks.append(
        SetupReadinessCheck(
            id="autonomy_security_mode",
            title="Full Access Runtime",
            status="ok" if env.full_access_mode else "info",
            message=(
                "Full Access is enabled for host-side work."
                if env.full_access_mode
                else "Safe mode is enabled. Use Full Access when this Mac is intentionally remote-controlled."
            ),
        )
    )
    checks.append(
        SetupReadinessCheck(
            id="autonomy_file_access",
            title="Host File Access",
            status="ok" if env.full_access_mode and env.allow_absolute_file_reads else "info",
            message=(
                "Absolute host file reads are allowed for agent runs."
                if env.full_access_mode and env.allow_absolute_file_reads
                else "File access is constrained by the configured safe-mode roots."
            ),
        )
    )
    checks.append(
        SetupReadinessCheck(
            id="autonomy_codex_cli",
            title="Codex MCP Host",
            status="ok" if codex_available else "todo",
            message=(
                "Codex CLI is available for browser and desktop MCP tools."
                if codex_available
                else "Install and sign in to Codex CLI to use the packaged browser and desktop automation stack."
            ),
        )
    )
    checks.append(
        SetupReadinessCheck(
            id="autonomy_web_search",
            title="Web Search",
            status="ok" if env.codex_enable_web_search else "info",
            message=(
                "Codex web search is enabled for up-to-date tasks."
                if env.codex_enable_web_search
                else "Codex web search is disabled; enable it for current web research tasks."
            ),
        )
    )
    checks.append(
        SetupReadinessCheck(
            id="autonomy_browser_profile",
            title="Persistent Browser Profile",
            status="ok",
            message=f"Playwright sessions persist under {env.playwright_user_data_dir}.",
        )
    )
    checks.append(
        SetupReadinessCheck(
            id="autonomy_desktop_permissions",
            title="Desktop Permissions",
            status="info",
            message=_desktop_permission_message(),
        )
    )
    checks.append(
        SetupReadinessCheck(
            id="autonomy_human_unblock",
            title="Human Unblock",
            status="info",
            message="CAPTCHA, 2FA, Apple ID, and admin approvals still pause with an exact unblock request.",
        )
    )

    next_actions = [check.message for check in checks if check.status == "todo"]
    enabled = env.full_access_mode and env.allow_absolute_file_reads and codex_available
    if next_actions:
        status: SetupCheckStatus = "todo"
        message = next_actions[0]
    elif enabled:
        status = "ok"
        message = "Autonomy stack is configured; run the deep check to verify macOS privacy permissions."
    else:
        status = "info"
        message = "Autonomy is partially configured. Full Access plus Codex gives the best phone-driven control."

    return SetupAutonomyState(
        status=status,
        enabled=enabled,
        message=message,
        checks=checks,
        next_actions=next_actions,
    )


def _desktop_permission_message() -> str:
    if platform.system() != "Darwin":
        return "Native desktop permission checks are macOS-specific; browser and CLI automation can still work."
    return "Run `mobaile autonomy --deep --open-permissions` to verify Accessibility and Screen Recording."


def _first_run_state(run_state: RunState) -> SetupFirstRunState:
    runs = run_state.list_session_runs("mobaile-first-run", limit=10)
    if not runs:
        return SetupFirstRunState(
            status="info",
            message="Run `mobaile first-run` to test a safe starter task.",
        )
    latest = runs[0]
    if _has_completed_first_run(runs):
        completed = next(run for run in runs if run.status == "completed")
        return SetupFirstRunState(
            status="ok",
            message="Starter task completed successfully.",
            run_id=completed.run_id,
            run_status=completed.status,
            updated_at=completed.updated_at,
        )
    if latest.status == "running":
        return SetupFirstRunState(
            status="info",
            message="Starter task is running.",
            run_id=latest.run_id,
            run_status=latest.status,
            updated_at=latest.updated_at,
        )
    return SetupFirstRunState(
        status="todo",
        message="Starter task did not complete; run `mobaile first-run` again.",
        run_id=latest.run_id,
        run_status=latest.status,
        updated_at=latest.updated_at,
    )


def _has_completed_first_run(runs: list[RunSummary]) -> bool:
    return any(run.status == "completed" for run in runs)


def _phone_path_status(
    mode: PhoneAccessMode,
    public_server_url: str,
    server_urls: list[str],
) -> SetupCheckStatus:
    if public_server_url and is_public_server_url(public_server_url):
        return "ok"
    if mode == "local":
        return "ok" if any(_server_url_is_loopback(url) for url in server_urls) else "info"
    return "ok" if any(server_url_matches_mode(url, phone_access_mode=mode) for url in server_urls) else "todo"


def _phone_path_message(
    mode: PhoneAccessMode,
    public_server_url: str,
    server_urls: list[str],
) -> str:
    if public_server_url and is_public_server_url(public_server_url):
        return "Public HTTPS URL is configured for phone access."
    if mode == "tailscale":
        if any(server_url_matches_mode(url, phone_access_mode=mode) for url in server_urls):
            return "Tailscale phone path is advertised."
        return "Tailscale mode needs a Tailscale URL; run `mobaile pair` after Tailscale is connected."
    if mode == "wifi":
        if any(server_url_matches_mode(url, phone_access_mode=mode) for url in server_urls):
            return "Same-Wi-Fi phone path is advertised."
        return "Wi-Fi mode needs a LAN or .local URL; run `mobaile pair` on the same network."
    if any(_server_url_is_loopback(url) for url in server_urls):
        return "Local simulator path is advertised."
    return "Local mode is for this computer or simulator only."


def _phone_access_label(
    mode: PhoneAccessMode,
    public_server_url: str,
    server_url: str | None,
) -> str:
    if mode == "wifi":
        return "On this Wi-Fi"
    if mode == "local":
        return "This computer only"
    if _is_https(public_server_url) or _is_https(server_url or ""):
        return "Public URL"
    return "Anywhere with Tailscale"


def _pairing_qr_path(env: RuntimeEnvironment) -> Path:
    return env.pairing_file.with_name("pairing-qr.png")


def _server_url_is_loopback(server_url: str) -> bool:
    try:
        parsed = urlparse(server_url)
    except ValueError:
        return False
    return is_loopback_host((parsed.hostname or "").strip().lower())


def _is_https(value: str) -> bool:
    return value.strip().lower().startswith("https://")


def _string_value(value: object) -> str:
    return str(value).strip() if value is not None else ""
