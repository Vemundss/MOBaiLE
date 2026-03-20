from __future__ import annotations

import json
import mimetypes
import os
import re
import secrets
import subprocess
import threading
import time
import uuid
from datetime import datetime
from datetime import timedelta
from datetime import timezone
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

from app.agent_runtime import is_calendar_request
from app.capabilities import collect_capabilities
from app.codex_text import CodexAssistantExtractor
from app.codex_text import filter_codex_assistant_message
from app.execution_service import ExecutionService
from app.models.schemas import (
    AgendaItem,
    AudioRunResponse,
    CapabilitiesResponse,
    ChatArtifact,
    DirectoryCreateRequest,
    DirectoryCreateResponse,
    DirectoryEntry,
    DirectoryListingResponse,
    ExecutionEvent,
    PairExchangeRequest,
    PairExchangeResponse,
    RunDiagnostics,
    RunExecutorName,
    RunRecord,
    RunSummary,
    RuntimeConfigResponse,
    UploadResponse,
    UtteranceRequest,
    UtteranceResponse,
)
from app.orchestrator.planner import plan_from_utterance
from app.policy.validator import validate_plan
from app.profile_store import ProfileStore
from app.run_state import RunState
from app.runtime_environment import load_env_defaults
from app.runtime_environment import RuntimeEnvironment
from app.storage import RunStore
from app.transcription import Transcriber, TranscriptionError


BACKEND_ROOT = Path(__file__).resolve().parent.parent
load_env_defaults(BACKEND_ROOT / ".env")


app = FastAPI(title="Voice Agent Backend", version="0.1.0")
ENV = RuntimeEnvironment.from_env(BACKEND_ROOT)
TRANSCRIBER = Transcriber()
RUN_STORE = RunStore(ENV.db_path)
RUN_STATE = RunState(RUN_STORE, max_event_message_chars=ENV.max_event_message_chars)
PROFILE_STORE = ProfileStore(
    profile_state_root=ENV.profile_state_root,
    legacy_session_state_root=ENV.legacy_session_state_root,
    profile_id=ENV.profile_id,
    profile_agents_max_chars=ENV.profile_agents_max_chars,
    profile_memory_max_chars=ENV.profile_memory_max_chars,
)
EXECUTION_SERVICE = ExecutionService(
    environment=ENV,
    run_state=RUN_STATE,
    profile_store=PROFILE_STORE,
    fetch_calendar_events=lambda: _fetch_today_calendar_events(),
)
PAIR_ATTEMPTS_LOCK = threading.Lock()
PAIR_ATTEMPTS: dict[str, list[float]] = {}
PAIR_EXCHANGE_LOCK = threading.Lock()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.middleware("http")
async def require_api_token(request: Request, call_next):
    if not request.url.path.startswith("/v1/"):
        return await call_next(request)
    if request.url.path == "/v1/pair/exchange":
        return await call_next(request)

    if not ENV.api_token:
        return JSONResponse(
            status_code=503,
            content={"detail": "server auth token is not configured"},
        )

    auth_header = request.headers.get("Authorization", "")
    expected = f"Bearer {ENV.api_token}"
    if not secrets.compare_digest(auth_header, expected):
        return JSONResponse(
            status_code=401,
            content={"detail": "missing or invalid bearer token"},
        )
    return await call_next(request)


@app.post("/v1/pair/exchange", response_model=PairExchangeResponse)
def pair_exchange(payload: PairExchangeRequest, request: Request) -> PairExchangeResponse:
    _enforce_pair_rate_limit(request.client.host if request.client else "unknown")
    with PAIR_EXCHANGE_LOCK:
        pairing = _read_pairing_file()
        expected = str(pairing.get("pair_code", "")).strip()
        expires_at = str(pairing.get("pair_code_expires_at", "")).strip()
        if not expected or not expires_at:
            raise HTTPException(status_code=503, detail="pairing code is not configured")
        if not secrets.compare_digest(payload.pair_code.strip(), expected):
            raise HTTPException(status_code=401, detail="invalid pairing code")
        try:
            expires = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
        except ValueError as exc:
            raise HTTPException(status_code=503, detail="pairing code configuration is invalid") from exc
        if datetime.now(tz=expires.tzinfo) > expires:
            raise HTTPException(status_code=401, detail="pairing code expired")

        _rotate_pair_code(pairing)
        api_token = str(pairing.get("api_token", "")).strip() or ENV.api_token
        if not api_token:
            raise HTTPException(status_code=503, detail="server auth token is not configured")
        session_id = payload.session_id or str(pairing.get("session_id", "iphone-app")).strip() or "iphone-app"
        return PairExchangeResponse(
            api_token=api_token,
            session_id=session_id,
            security_mode=ENV.security_mode,  # type: ignore[arg-type]
        )


@app.post("/v1/utterances", response_model=UtteranceResponse)
def create_utterance(request: UtteranceRequest) -> UtteranceResponse:
    run_id = str(uuid.uuid4())
    executor = ENV.resolve_request_executor(request.executor)
    try:
        workdir = ENV.resolve_workdir(request.working_directory)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    display_utterance_text = _display_utterance_text(request.utterance_text, request.attachments)
    effective_utterance_text = _render_utterance_for_executor(request.utterance_text, request.attachments)

    if ENV.is_agent_executor(executor) and is_calendar_request(effective_utterance_text):
        RUN_STATE.store_run(
            RunRecord(
                run_id=run_id,
                session_id=request.session_id,
                executor=executor,
                utterance_text=display_utterance_text,
                working_directory=str(workdir),
                status="running",
                plan=None,
                events=[],
                summary="Run started",
            )
        )
        threading.Thread(
            target=EXECUTION_SERVICE.run_calendar_adapter,
            args=(run_id, effective_utterance_text),
            daemon=True,
        ).start()
        return UtteranceResponse(run_id=run_id, status="accepted", message="Run started")

    if ENV.is_agent_executor(executor):
        guardrail_status, guardrail_message = ENV.evaluate_runtime_guardrails(effective_utterance_text)
        if guardrail_status == "reject":
            RUN_STATE.store_run(
                RunRecord(
                    run_id=run_id,
                    session_id=request.session_id,
                    executor=executor,
                    utterance_text=display_utterance_text,
                    working_directory=str(workdir),
                    status="rejected",
                    plan=None,
                    events=[ExecutionEvent(type="run.failed", message=guardrail_message)],
                    summary=guardrail_message,
                )
            )
            return UtteranceResponse(run_id=run_id, status="rejected", message=guardrail_message)
        RUN_STATE.store_run(
            RunRecord(
                run_id=run_id,
                session_id=request.session_id,
                executor=executor,
                utterance_text=display_utterance_text,
                working_directory=str(workdir),
                status="running",
                plan=None,
                events=[],
                summary="Run started",
            )
        )
        threading.Thread(
            target=EXECUTION_SERVICE.run_agent,
            args=(
                run_id,
                effective_utterance_text,
                workdir,
                request.session_id,
                executor,
                request.thread_id,
                request.response_profile,
                guardrail_message if guardrail_status == "warn" else None,
            ),
            daemon=True,
        ).start()
        return UtteranceResponse(run_id=run_id, status="accepted", message="Run started")

    plan = plan_from_utterance(effective_utterance_text)
    allowed, message = validate_plan(plan)
    if not allowed:
        RUN_STATE.store_run(
            RunRecord(
                run_id=run_id,
                session_id=request.session_id,
                utterance_text=display_utterance_text,
                working_directory=str(workdir),
                status="rejected",
                plan=plan,
                events=[ExecutionEvent(type="run.failed", message=message)],
                summary=f"Rejected by policy: {message}",
            )
        )
        return UtteranceResponse(run_id=run_id, status="rejected", message=message)

    RUN_STATE.store_run(
        RunRecord(
            run_id=run_id,
            session_id=request.session_id,
            executor="local",
            utterance_text=display_utterance_text,
            working_directory=str(workdir),
            status="running",
            plan=plan,
            events=[],
            summary="Run started",
        )
    )
    threading.Thread(target=EXECUTION_SERVICE.run_local_plan, args=(run_id, plan, workdir), daemon=True).start()
    return UtteranceResponse(run_id=run_id, status="accepted", message="Run started")


@app.post("/v1/audio", response_model=AudioRunResponse)
async def create_audio_run(
    session_id: str = Form(...),
    thread_id: str | None = Form(None),
    audio: UploadFile = File(...),
    executor: RunExecutorName | None = Form(None),
    mode: Literal["assistant", "execute"] = Form("execute"),
    transcript_hint: str | None = Form(None),
    working_directory: str | None = Form(None),
    response_mode: Literal["concise", "verbose"] = Form("concise"),
    response_profile: Literal["guided", "minimal"] = Form("guided"),
) -> AudioRunResponse:
    normalized_thread_id = (thread_id or "").strip() or None
    content_length_header = audio.headers.get("content-length")
    if content_length_header:
        try:
            if int(content_length_header) > ENV.max_audio_bytes:
                raise HTTPException(
                    status_code=413,
                    detail=f"audio payload too large (max {ENV.max_audio_mb:g} MB)",
                )
        except ValueError:
            pass
    audio_bytes = await audio.read()
    if len(audio_bytes) > ENV.max_audio_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"audio payload too large (max {ENV.max_audio_mb:g} MB)",
        )
    try:
        transcript_text = TRANSCRIBER.transcribe(
            audio_bytes=audio_bytes,
            filename=audio.filename or "audio",
            text_hint=transcript_hint,
        )
    except TranscriptionError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    try:
        result = create_utterance(
            UtteranceRequest(
                session_id=session_id,
                thread_id=normalized_thread_id,
                utterance_text=transcript_text,
                executor=executor,
                mode=mode,
                working_directory=working_directory,
                response_mode=response_mode,
                response_profile=response_profile,
            )
        )
    except HTTPException:
        raise
    return AudioRunResponse(
        run_id=result.run_id,
        status=result.status,
        message=result.message,
        transcript_text=transcript_text,
    )


@app.post("/v1/uploads", response_model=UploadResponse)
async def upload_file(
    session_id: str = Form(...),
    file: UploadFile = File(...),
) -> UploadResponse:
    content_length_header = file.headers.get("content-length")
    if content_length_header:
        try:
            if int(content_length_header) > ENV.max_upload_bytes:
                raise HTTPException(
                    status_code=413,
                    detail=f"file payload too large (max {ENV.max_upload_mb:g} MB)",
                )
        except ValueError:
            pass

    file_bytes = await file.read()
    if len(file_bytes) > ENV.max_upload_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"file payload too large (max {ENV.max_upload_mb:g} MB)",
        )

    target_dir = ENV.upload_session_dir(session_id)
    target_dir.mkdir(parents=True, exist_ok=True)

    file_name = _sanitize_upload_name(file.filename or "attachment")
    target = (target_dir / f"{uuid.uuid4()}-{file_name}").resolve()
    if not ENV.is_path_allowed(target):
        raise HTTPException(status_code=403, detail="upload path is outside allowed roots")
    target.write_bytes(file_bytes)

    mime = (file.content_type or "").strip() or mimetypes.guess_type(file_name)[0]
    artifact = ChatArtifact(
        type=_artifact_type_for_upload(file_name, mime),
        title=file_name,
        path=str(target),
        mime=mime,
    )
    return UploadResponse(artifact=artifact, size_bytes=len(file_bytes))


@app.get("/v1/runs/{run_id}", response_model=RunRecord)
def get_run(run_id: str) -> RunRecord:
    run = RUN_STATE.get_run(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="run not found")
    return run


@app.get("/v1/config", response_model=RuntimeConfigResponse)
def get_runtime_config() -> RuntimeConfigResponse:
    return ENV.runtime_config_response(
        transcribe_provider=TRANSCRIBER.provider,
        transcribe_ready=ENV.transcriber_ready(TRANSCRIBER.provider),
    )


@app.get("/v1/capabilities", response_model=CapabilitiesResponse)
def get_capabilities(
    deep: bool = Query(False),
    launch_apps: bool = Query(False),
) -> CapabilitiesResponse:
    return collect_capabilities(
        security_mode=ENV.security_mode,
        codex_binary=ENV.codex_binary,
        claude_binary=ENV.claude_binary,
        codex_home=ENV.codex_home,
        codex_enable_web_search=ENV.codex_enable_web_search,
        playwright_output_dir=ENV.playwright_output_dir,
        playwright_user_data_dir=ENV.playwright_user_data_dir,
        transcribe_provider=TRANSCRIBER.provider,
        report_path=ENV.capabilities_report_path,
        deep=deep,
        launch_apps=launch_apps,
        fetch_calendar_events=_fetch_today_calendar_events,
    )


@app.get("/v1/tools/calendar/today")
def get_calendar_today() -> dict[str, object]:
    today = datetime.now().strftime("%A, %B %d, %Y")
    try:
        events = _fetch_today_calendar_events()
    except RuntimeError as exc:
        return JSONResponse(
            status_code=503,
            content={
                "supported": False,
                "date": today,
                "count": 0,
                "events": [],
                "detail": str(exc),
            },
        )
    return {
        "supported": True,
        "date": today,
        "count": len(events),
        "events": [event.model_dump() for event in events],
    }


@app.get("/v1/sessions/{session_id}/runs", response_model=list[RunSummary])
def list_session_runs(session_id: str, limit: int = Query(20, ge=1, le=100)) -> list[RunSummary]:
    return RUN_STATE.list_session_runs(session_id, limit=limit)


@app.get("/v1/runs/{run_id}/diagnostics", response_model=RunDiagnostics)
def get_run_diagnostics(run_id: str) -> RunDiagnostics:
    diagnostics = RUN_STATE.diagnostics_for(run_id)
    if diagnostics is None:
        raise HTTPException(status_code=404, detail="run not found")
    return diagnostics


@app.get("/v1/files")
def get_file(path: str = Query(..., min_length=1)) -> FileResponse:
    target = Path(path.strip()).expanduser()
    if target.is_absolute():
        target = target.resolve()
        # Uploaded artifacts are returned as absolute paths by design, so keep those readable
        # even in safe mode without reopening arbitrary absolute file access.
        upload_artifact = ENV._is_relative_to(target, ENV.uploads_root)
        if not ENV.allow_absolute_file_reads and not upload_artifact:
            raise HTTPException(status_code=403, detail="absolute file paths are disabled in safe mode")
    else:
        target = (ENV.default_workdir / target).resolve()
    if not ENV.is_path_allowed(target):
        raise HTTPException(status_code=403, detail="file path is outside allowed roots")
    if not target.exists() or not target.is_file():
        raise HTTPException(status_code=404, detail="file not found")
    media_type, _ = mimetypes.guess_type(str(target))
    return FileResponse(str(target), media_type=media_type or "application/octet-stream")


@app.get("/v1/directories", response_model=DirectoryListingResponse)
def list_directory(path: str | None = Query(None)) -> DirectoryListingResponse:
    raw = (path or "").strip()
    if raw:
        target = Path(raw).expanduser()
        if target.is_absolute():
            target = target.resolve()
        else:
            target = (ENV.default_workdir / target).resolve()
    else:
        target = ENV.default_workdir

    if not ENV.is_path_allowed(target):
        raise HTTPException(status_code=403, detail="directory path is outside allowed roots")
    if not target.exists():
        raise HTTPException(status_code=404, detail="directory not found")
    if not target.is_dir():
        raise HTTPException(status_code=404, detail="directory not found")

    try:
        children = sorted(target.iterdir(), key=lambda item: (not item.is_dir(), item.name.lower()))
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail="permission denied for directory path") from exc

    entries: list[DirectoryEntry] = []
    truncated = False
    for idx, child in enumerate(children):
        if idx >= ENV.max_directory_entries:
            truncated = True
            break
        entries.append(
            DirectoryEntry(
                name=child.name,
                path=str(child),
                is_directory=child.is_dir(),
            )
        )
    return DirectoryListingResponse(path=str(target), entries=entries, truncated=truncated)


@app.post("/v1/directories", response_model=DirectoryCreateResponse)
def create_directory(request: DirectoryCreateRequest) -> DirectoryCreateResponse:
    raw = request.path.strip()
    target = Path(raw).expanduser()
    if target.is_absolute():
        target = target.resolve()
    else:
        target = (ENV.default_workdir / target).resolve()

    if not ENV.is_path_allowed(target):
        raise HTTPException(status_code=403, detail="directory path is outside allowed roots")
    if target.exists() and not target.is_dir():
        raise HTTPException(status_code=409, detail="path exists and is not a directory")

    created = False
    if not target.exists():
        try:
            target.mkdir(parents=True, exist_ok=True)
            created = True
        except OSError as exc:
            raise HTTPException(status_code=403, detail="permission denied for directory path") from exc

    return DirectoryCreateResponse(path=str(target), created=created)


@app.post("/v1/runs/{run_id}/cancel")
def cancel_run(run_id: str) -> dict[str, str]:
    try:
        RUN_STATE.request_cancel(run_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="run not found") from exc
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=f"run already terminal ({exc})") from exc

    EXECUTION_SERVICE.terminate_active_process(run_id)

    return {"run_id": run_id, "status": "cancel_requested"}


@app.get("/v1/runs/{run_id}/events")
def stream_run_events(run_id: str) -> StreamingResponse:
    if RUN_STATE.get_run(run_id) is None:
        raise HTTPException(status_code=404, detail="run not found")
    return StreamingResponse(RUN_STATE.event_stream(run_id), media_type="text/event-stream")


def _fetch_today_calendar_events() -> list[AgendaItem]:
    if os.uname().sysname.lower() != "darwin":
        raise RuntimeError("calendar adapter currently supports macOS only")

    script = r'''
set nowDate to current date
set y to year of nowDate
set m to month of nowDate
set d to day of nowDate
set startDate to date ("00:00:00 " & (m as string) & " " & d & ", " & y)
set endDate to startDate + (24 * hours)
set rows to {}
tell application "Calendar"
    repeat with cal in calendars
        set calName to name of cal
        set evs to (every event of cal whose start date < endDate and end date > startDate)
        repeat with ev in evs
            set s to start date of ev
            set e to end date of ev
            set titleText to summary of ev
            set locText to ""
            try
                set locText to location of ev
            end try
            set sh to text -2 thru -1 of ("0" & (hours of s as string))
            set sm to text -2 thru -1 of ("0" & (minutes of s as string))
            set eh to text -2 thru -1 of ("0" & (hours of e as string))
            set em to text -2 thru -1 of ("0" & (minutes of e as string))
            set lineText to (sh & ":" & sm & tab & eh & ":" & em & tab & titleText & tab & calName & tab & locText)
            copy lineText to end of rows
        end repeat
    end repeat
end tell
set AppleScript's text item delimiters to linefeed
return rows as text
'''
    proc = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=20,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip() or "unknown osascript error"
        raise RuntimeError(stderr)

    items: list[AgendaItem] = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        start, end, title, calendar = parts[0], parts[1], parts[2], parts[3]
        location = parts[4] if len(parts) > 4 and parts[4].strip() else None
        if location and location.strip().lower() == "missing value":
            location = None
        items.append(
            AgendaItem(
                start=start.strip(),
                end=end.strip(),
                title=title.strip() or "(Untitled)",
                calendar=calendar.strip() or "Calendar",
                location=location.strip() if location else None,
            )
        )
    items.sort(key=lambda item: (item.start, item.end, item.title))
    return items

def _display_utterance_text(raw_text: str, attachments: list[ChatArtifact]) -> str:
    trimmed = raw_text.strip()
    if trimmed:
        return trimmed
    if len(attachments) == 1:
        title = attachments[0].title.strip() or "attachment"
        return f"Inspect {title}"
    return f"Inspect {len(attachments)} attachments"


def _render_utterance_for_executor(raw_text: str, attachments: list[ChatArtifact]) -> str:
    trimmed = raw_text.strip()
    if not attachments:
        return trimmed

    images = [artifact for artifact in attachments if artifact.type == "image"]
    files = [artifact for artifact in attachments if artifact.type != "image"]
    sections: list[str] = [
        trimmed or _default_attachment_prompt(len(attachments))
    ]

    if images:
        sections.append(
            "Attached images:\n" + "\n".join(
                line for line in (_attachment_reference_line(item) for item in images) if line
            )
        )
    if files:
        sections.append(
            "Attached files:\n" + "\n".join(
                line for line in (_attachment_reference_line(item) for item in files) if line
            )
        )
    return "\n\n".join(section for section in sections if section.strip())


def _default_attachment_prompt(count: int) -> str:
    if count == 1:
        return "Please inspect the attached file and summarize the important details."
    return "Please inspect the attached files and summarize the important details."


def _attachment_reference_line(artifact: ChatArtifact) -> str | None:
    reference = (artifact.path or artifact.url or "").strip()
    if not reference:
        title = artifact.title.strip()
        return f"- {title}" if title else None
    title = artifact.title.strip() or "attachment"
    if artifact.type == "image":
        return f"![{title}]({reference})"
    return f"[{title}]({reference})"

def _sanitize_upload_name(raw_name: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "-", raw_name.strip()).strip(".-")
    return cleaned or "attachment"


def _artifact_type_for_upload(file_name: str, mime: str | None) -> Literal["image", "file", "code"]:
    lower_mime = (mime or "").lower()
    if lower_mime.startswith("image/"):
        return "image"
    if lower_mime.startswith("text/"):
        return "code"

    suffix = Path(file_name).suffix.lower()
    if suffix in {
        ".c",
        ".cc",
        ".cpp",
        ".css",
        ".go",
        ".h",
        ".hpp",
        ".html",
        ".java",
        ".js",
        ".json",
        ".kt",
        ".md",
        ".mjs",
        ".php",
        ".py",
        ".rb",
        ".rs",
        ".sh",
        ".sql",
        ".swift",
        ".toml",
        ".ts",
        ".tsx",
        ".txt",
        ".xml",
        ".yaml",
        ".yml",
    }:
        return "code"
    return "file"

def _read_pairing_file() -> dict[str, object]:
    if not ENV.pairing_file.exists():
        return {}
    try:
        return json.loads(ENV.pairing_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def _write_pairing_file(payload: dict[str, object]) -> None:
    ENV.pairing_file.parent.mkdir(parents=True, exist_ok=True)
    ENV.pairing_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _rotate_pair_code(payload: dict[str, object]) -> None:
    payload["pair_code"] = secrets.token_urlsafe(10)
    payload["pair_code_expires_at"] = (
        datetime.now(timezone.utc) + timedelta(minutes=ENV.pair_code_ttl_min)
    ).isoformat().replace("+00:00", "Z")
    _write_pairing_file(payload)


def _enforce_pair_rate_limit(client_id: str) -> None:
    now = time.monotonic()
    with PAIR_ATTEMPTS_LOCK:
        attempts = PAIR_ATTEMPTS.get(client_id, [])
        attempts = [t for t in attempts if now - t <= 60.0]
        if len(attempts) >= ENV.pair_attempt_limit_per_min:
            raise HTTPException(status_code=429, detail="too many pairing attempts, try again soon")
        attempts.append(now)
        PAIR_ATTEMPTS[client_id] = attempts
