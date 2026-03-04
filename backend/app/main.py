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
from queue import Empty, Queue
from pathlib import Path
from typing import Iterator, Literal

from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

from app.executors.codex_executor import CodexExecutor
from app.executors.local_executor import LocalExecutor
from app.models.schemas import (
    ActionPlan,
    AgendaItem,
    AudioRunResponse,
    ChatArtifact,
    ChatEnvelope,
    ChatSection,
    DirectoryCreateRequest,
    DirectoryCreateResponse,
    DirectoryEntry,
    DirectoryListingResponse,
    ExecutionEvent,
    PairExchangeRequest,
    PairExchangeResponse,
    RunDiagnostics,
    RunRecord,
    RunSummary,
    UtteranceRequest,
    UtteranceResponse,
)
from app.orchestrator.planner import plan_from_utterance
from app.policy.validator import validate_plan
from app.storage import RunStore
from app.transcription import Transcriber, TranscriptionError


def _load_env_defaults() -> None:
    env_path = Path(__file__).resolve().parent.parent / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        if not key:
            continue
        os.environ.setdefault(key, value.strip().strip("'\""))


_load_env_defaults()


app = FastAPI(title="Voice Agent Backend", version="0.1.0")
RUNS_LOCK = threading.Lock()
ACTIVE_PROCS_LOCK = threading.Lock()
ACTIVE_PROCS: dict[str, subprocess.Popen[str]] = {}
RUN_CANCELLED: set[str] = set()
DEFAULT_WORKDIR = Path(
    os.getenv("VOICE_AGENT_DEFAULT_WORKDIR", str(Path.home()))
).expanduser().resolve()
DEFAULT_WORKDIR.mkdir(parents=True, exist_ok=True)
SECURITY_MODE = os.getenv("VOICE_AGENT_SECURITY_MODE", "safe").strip().lower()
if SECURITY_MODE not in {"safe", "full-access"}:
    SECURITY_MODE = "safe"
FULL_ACCESS_MODE = SECURITY_MODE == "full-access"
WORKDIR_ROOT_RAW = os.getenv("VOICE_AGENT_WORKDIR_ROOT", "").strip()
if WORKDIR_ROOT_RAW:
    WORKDIR_ROOT = Path(WORKDIR_ROOT_RAW).expanduser().resolve()
else:
    WORKDIR_ROOT = None if FULL_ACCESS_MODE else DEFAULT_WORKDIR
if WORKDIR_ROOT is not None:
    WORKDIR_ROOT.mkdir(parents=True, exist_ok=True)
ALLOW_ABSOLUTE_FILE_READS = os.getenv(
    "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS",
    "true" if FULL_ACCESS_MODE else "false",
).strip().lower() in {"1", "true", "yes", "on"}
FILE_ROOTS_RAW = os.getenv("VOICE_AGENT_FILE_ROOTS", "").strip()
if FILE_ROOTS_RAW:
    FILE_ROOTS = [Path(item.strip()).expanduser().resolve() for item in FILE_ROOTS_RAW.split(",") if item.strip()]
else:
    FILE_ROOTS = [] if FULL_ACCESS_MODE else [DEFAULT_WORKDIR]
    if WORKDIR_ROOT is not None and WORKDIR_ROOT not in FILE_ROOTS:
        FILE_ROOTS.append(WORKDIR_ROOT)
for _root in FILE_ROOTS:
    _root.mkdir(parents=True, exist_ok=True)
CODEX_TIMEOUT_SEC = int(os.getenv("VOICE_AGENT_CODEX_TIMEOUT_SEC", "900"))
CODEX_USE_CONTEXT = os.getenv("VOICE_AGENT_CODEX_USE_CONTEXT", "true").strip().lower() not in {
    "0",
    "false",
    "no",
    "off",
}
CODEX_CONTEXT_FILE = os.getenv("VOICE_AGENT_CODEX_CONTEXT_FILE", "AGENT_CONTEXT.md").strip()
CODEX_GUARDRAILS = os.getenv("VOICE_AGENT_CODEX_GUARDRAILS", "warn").strip().lower()
CODEX_MODEL_OVERRIDE = os.getenv("VOICE_AGENT_CODEX_MODEL", "").strip()
CODEX_DANGEROUS_CONFIRM_TOKEN = os.getenv(
    "VOICE_AGENT_CODEX_DANGEROUS_CONFIRM_TOKEN", "[allow-dangerous]"
).strip()
PROFILE_STATE_ROOT = Path(
    os.getenv(
        "VOICE_AGENT_PROFILE_STATE_ROOT",
        os.getenv(
            "VOICE_AGENT_SESSION_STATE_ROOT",
            str(Path(__file__).resolve().parent.parent / "data" / "profiles"),
        ),
    )
).resolve()
PROFILE_STATE_ROOT.mkdir(parents=True, exist_ok=True)
LEGACY_SESSION_STATE_ROOT = Path(
    os.getenv(
        "VOICE_AGENT_SESSION_STATE_ROOT",
        str(Path(__file__).resolve().parent.parent / "data" / "sessions"),
    )
).resolve()
PROFILE_ID = os.getenv("VOICE_AGENT_PROFILE_ID", "default-user").strip() or "default-user"
PROFILE_AGENTS_MAX_CHARS = int(
    os.getenv("VOICE_AGENT_PROFILE_AGENTS_MAX_CHARS", os.getenv("VOICE_AGENT_SESSION_AGENTS_MAX_CHARS", "3000"))
)
PROFILE_MEMORY_MAX_CHARS = int(
    os.getenv("VOICE_AGENT_PROFILE_MEMORY_MAX_CHARS", os.getenv("VOICE_AGENT_SESSION_MEMORY_MAX_CHARS", "6000"))
)
MAX_AUDIO_MB = float(os.getenv("VOICE_AGENT_MAX_AUDIO_MB", "20"))
MAX_AUDIO_BYTES = int(MAX_AUDIO_MB * 1024 * 1024)
MAX_DIRECTORY_ENTRIES = int(os.getenv("VOICE_AGENT_MAX_DIRECTORY_ENTRIES", "200"))
MAX_EVENT_MESSAGE_CHARS = int(os.getenv("VOICE_AGENT_MAX_EVENT_MESSAGE_CHARS", "16000"))
TRANSCRIBER = Transcriber()
API_TOKEN = os.getenv("VOICE_AGENT_API_TOKEN", "")
RUN_STORE = RunStore(
    Path(
        os.getenv(
            "VOICE_AGENT_DB_PATH",
            str(Path(__file__).resolve().parent.parent / "data" / "runs.db"),
        )
    )
)
RUNS: dict[str, RunRecord] = RUN_STORE.load_all()
PAIRING_FILE = Path(
    os.getenv(
        "VOICE_AGENT_PAIRING_FILE",
        str(Path(__file__).resolve().parent.parent / "pairing.json"),
    )
)
PAIR_CODE_TTL_MIN = int(os.getenv("VOICE_AGENT_PAIR_CODE_TTL_MIN", "30"))
PAIR_ATTEMPTS_LOCK = threading.Lock()
PAIR_ATTEMPTS: dict[str, list[float]] = {}
PAIR_ATTEMPT_LIMIT_PER_MIN = int(os.getenv("VOICE_AGENT_PAIR_ATTEMPT_LIMIT_PER_MIN", "20"))
PROFILE_FILE_LOCK = threading.Lock()

DEFAULT_PROFILE_AGENTS = """# MOBaiLE AGENTS
You are an assistant running through MOBaiLE.
- You run on the user's server/computer.
- Your output is displayed in a phone UI.
- Prefer concise updates and clear final results.
- Do not repeat runtime context unless asked.
"""

DEFAULT_PROFILE_MEMORY = """# MOBaiLE MEMORY
Purpose: persistent notes across runs.

Rules:
- Keep this file concise and useful.
- Store durable learnings only (preferences, environment facts, reliable workflows).
- Avoid secrets/tokens.
- Remove stale or duplicate notes.

## User Preferences
- (none yet)

## Environment Notes
- (none yet)

## Reliable Workflows
- (none yet)
"""


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.middleware("http")
async def require_api_token(request: Request, call_next):
    if not request.url.path.startswith("/v1/"):
        return await call_next(request)
    if request.url.path == "/v1/pair/exchange":
        return await call_next(request)

    if not API_TOKEN:
        return JSONResponse(
            status_code=503,
            content={"detail": "server auth token is not configured"},
        )

    auth_header = request.headers.get("Authorization", "")
    expected = f"Bearer {API_TOKEN}"
    if not secrets.compare_digest(auth_header, expected):
        return JSONResponse(
            status_code=401,
            content={"detail": "missing or invalid bearer token"},
        )
    return await call_next(request)


@app.post("/v1/pair/exchange", response_model=PairExchangeResponse)
def pair_exchange(payload: PairExchangeRequest, request: Request) -> PairExchangeResponse:
    _enforce_pair_rate_limit(request.client.host if request.client else "unknown")
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
    api_token = str(pairing.get("api_token", "")).strip() or API_TOKEN
    if not api_token:
        raise HTTPException(status_code=503, detail="server auth token is not configured")
    session_id = payload.session_id or str(pairing.get("session_id", "iphone-app")).strip() or "iphone-app"
    return PairExchangeResponse(
        api_token=api_token,
        session_id=session_id,
        security_mode=SECURITY_MODE,
    )


@app.post("/v1/utterances", response_model=UtteranceResponse)
def create_utterance(request: UtteranceRequest) -> UtteranceResponse:
    run_id = str(uuid.uuid4())
    try:
        workdir = _resolve_workdir(request.working_directory)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if request.executor == "codex" and _is_calendar_request(request.utterance_text):
        _store_run(
            RunRecord(
                run_id=run_id,
                session_id=request.session_id,
                executor="codex",
                utterance_text=request.utterance_text,
                working_directory=str(workdir),
                status="running",
                plan=None,
                events=[],
                summary="Run started",
            )
        )
        threading.Thread(
            target=_run_calendar_adapter,
            args=(run_id, request.utterance_text),
            daemon=True,
        ).start()
        return UtteranceResponse(run_id=run_id, status="accepted", message="Run started")

    if request.executor == "codex":
        guardrail_status, guardrail_message = _evaluate_codex_guardrails(request.utterance_text)
        if guardrail_status == "reject":
            _store_run(
                RunRecord(
                    run_id=run_id,
                    session_id=request.session_id,
                    executor="codex",
                    utterance_text=request.utterance_text,
                    working_directory=str(workdir),
                    status="rejected",
                    plan=None,
                    events=[ExecutionEvent(type="run.failed", message=guardrail_message)],
                    summary=guardrail_message,
                )
            )
            return UtteranceResponse(run_id=run_id, status="rejected", message=guardrail_message)
        _store_run(
            RunRecord(
                run_id=run_id,
                session_id=request.session_id,
                executor="codex",
                utterance_text=request.utterance_text,
                working_directory=str(workdir),
                status="running",
                plan=None,
                events=[],
                summary="Run started",
            )
        )
        threading.Thread(
            target=_run_codex,
            args=(
                run_id,
                request.utterance_text,
                workdir,
                request.session_id,
                request.thread_id,
                request.response_profile,
                guardrail_message if guardrail_status == "warn" else None,
            ),
            daemon=True,
        ).start()
        return UtteranceResponse(run_id=run_id, status="accepted", message="Run started")

    plan = plan_from_utterance(request.utterance_text)
    allowed, message = validate_plan(plan)
    if not allowed:
        _store_run(
            RunRecord(
                run_id=run_id,
                session_id=request.session_id,
                utterance_text=request.utterance_text,
                working_directory=str(workdir),
                status="rejected",
                plan=plan,
                events=[ExecutionEvent(type="run.failed", message=message)],
                summary=f"Rejected by policy: {message}",
            )
        )
        return UtteranceResponse(run_id=run_id, status="rejected", message=message)

    _store_run(
        RunRecord(
            run_id=run_id,
            session_id=request.session_id,
            executor="local",
            utterance_text=request.utterance_text,
            working_directory=str(workdir),
            status="running",
            plan=plan,
            events=[],
            summary="Run started",
        )
    )
    threading.Thread(target=_run_local_plan, args=(run_id, plan, workdir), daemon=True).start()
    return UtteranceResponse(run_id=run_id, status="accepted", message="Run started")


@app.post("/v1/audio", response_model=AudioRunResponse)
async def create_audio_run(
    session_id: str = Form(...),
    thread_id: str | None = Form(None),
    audio: UploadFile = File(...),
    executor: Literal["local", "codex"] = Form("codex"),
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
            if int(content_length_header) > MAX_AUDIO_BYTES:
                raise HTTPException(
                    status_code=413,
                    detail=f"audio payload too large (max {MAX_AUDIO_MB:g} MB)",
                )
        except ValueError:
            pass
    audio_bytes = await audio.read()
    if len(audio_bytes) > MAX_AUDIO_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"audio payload too large (max {MAX_AUDIO_MB:g} MB)",
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


@app.get("/v1/runs/{run_id}", response_model=RunRecord)
def get_run(run_id: str) -> RunRecord:
    with RUNS_LOCK:
        run = RUNS.get(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="run not found")
    return run


@app.get("/v1/config")
def get_runtime_config() -> dict[str, object]:
    return {
        "security_mode": SECURITY_MODE,
        "codex_model": CODEX_MODEL_OVERRIDE or None,
        "workdir_root": str(WORKDIR_ROOT) if WORKDIR_ROOT is not None else None,
        "allow_absolute_file_reads": ALLOW_ABSOLUTE_FILE_READS,
        "file_roots": [str(root) for root in FILE_ROOTS],
    }


@app.get("/v1/tools/calendar/today")
def get_calendar_today() -> dict[str, object]:
    events = _fetch_today_calendar_events()
    today = datetime.now().strftime("%A, %B %d, %Y")
    return {
        "date": today,
        "count": len(events),
        "events": [event.model_dump() for event in events],
    }


@app.get("/v1/sessions/{session_id}/runs", response_model=list[RunSummary])
def list_session_runs(session_id: str, limit: int = Query(20, ge=1, le=100)) -> list[RunSummary]:
    runs = RUN_STORE.list_runs_for_session(session_id, limit=limit)
    return [
        RunSummary(
            run_id=run.run_id,
            session_id=run.session_id,
            executor=run.executor,
            utterance_text=run.utterance_text,
            status=run.status,
            summary=run.summary,
            updated_at=run.updated_at,
            working_directory=run.working_directory,
        )
        for run in runs
    ]


@app.get("/v1/runs/{run_id}/diagnostics", response_model=RunDiagnostics)
def get_run_diagnostics(run_id: str) -> RunDiagnostics:
    with RUNS_LOCK:
        run = RUNS.get(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="run not found")
    counts: dict[str, int] = {}
    last_error: str | None = None
    has_stderr = False
    for event in run.events:
        counts[event.type] = counts.get(event.type, 0) + 1
        if event.type == "action.stderr":
            has_stderr = True
            last_error = event.message
        if event.type == "run.failed":
            last_error = event.message
    return RunDiagnostics(
        run_id=run.run_id,
        status=run.status,
        summary=run.summary,
        event_count=len(run.events),
        event_type_counts=counts,
        has_stderr=has_stderr,
        last_error=last_error,
        created_at=run.created_at,
        updated_at=run.updated_at,
    )


@app.get("/v1/files")
def get_file(path: str = Query(..., min_length=1)) -> FileResponse:
    target = Path(path.strip()).expanduser()
    if target.is_absolute():
        target = target.resolve()
        if not ALLOW_ABSOLUTE_FILE_READS:
            raise HTTPException(status_code=403, detail="absolute file paths are disabled in safe mode")
    else:
        target = (DEFAULT_WORKDIR / target).resolve()
    if not _is_path_allowed(target):
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
            target = (DEFAULT_WORKDIR / target).resolve()
    else:
        target = DEFAULT_WORKDIR

    if not _is_path_allowed(target):
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
        if idx >= MAX_DIRECTORY_ENTRIES:
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
        target = (DEFAULT_WORKDIR / target).resolve()

    if not _is_path_allowed(target):
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
    with RUNS_LOCK:
        run = RUNS.get(run_id)
        if not run:
            raise HTTPException(status_code=404, detail="run not found")
        if run.status in {"completed", "failed", "rejected", "cancelled"}:
            raise HTTPException(status_code=409, detail=f"run already terminal ({run.status})")
        RUN_CANCELLED.add(run_id)

    with ACTIVE_PROCS_LOCK:
        proc = ACTIVE_PROCS.get(run_id)
        if proc is not None and proc.poll() is None:
            proc.terminate()

    return {"run_id": run_id, "status": "cancel_requested"}


@app.get("/v1/runs/{run_id}/events")
def stream_run_events(run_id: str) -> StreamingResponse:
    with RUNS_LOCK:
        if run_id not in RUNS:
            raise HTTPException(status_code=404, detail="run not found")

    def event_stream() -> Iterator[str]:
        sent_count = 0
        heartbeat_at = time.monotonic()
        while True:
            with RUNS_LOCK:
                run = RUNS.get(run_id)
                if run is None:
                    break
                pending_events = run.events[sent_count:]
                status = run.status

            for event in pending_events:
                sent_count += 1
                payload = json.dumps(event.model_dump())
                yield f"event: {event.type}\ndata: {payload}\n\n"

            done = status in {"completed", "failed", "rejected", "cancelled"}
            if done and not pending_events:
                break

            now = time.monotonic()
            if now - heartbeat_at > 10:
                heartbeat_at = now
                yield ": keep-alive\n\n"
            time.sleep(0.25)

    return StreamingResponse(event_stream(), media_type="text/event-stream")


def _append_chat_message(
    run_id: str,
    *,
    summary: str,
    sections: list[ChatSection] | None = None,
    agenda_items: list[AgendaItem] | None = None,
    artifacts: list[ChatArtifact] | None = None,
) -> None:
    envelope = ChatEnvelope(
        message_id=str(uuid.uuid4()),
        created_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        summary=summary,
        sections=sections or [],
        agenda_items=agenda_items or [],
        artifacts=artifacts or [],
    )
    _append_event(
        run_id,
        ExecutionEvent(type="chat.message", message=envelope.model_dump_json()),
    )


def _append_assistant_payload(run_id: str, raw_text: str) -> None:
    payload = _parse_chat_envelope_payload(raw_text)
    if payload is not None:
        _append_event(run_id, ExecutionEvent(type="chat.message", message=json.dumps(payload)))
        return
    envelope = _coerce_assistant_text_to_envelope(raw_text)
    _append_event(run_id, ExecutionEvent(type="chat.message", message=envelope.model_dump_json()))


def _append_log_message(run_id: str, message: str, *, action_index: int | None = 0) -> None:
    text = message.strip()
    if not text:
        return
    _append_event(
        run_id,
        ExecutionEvent(type="log.message", action_index=action_index, message=text),
    )


def _run_calendar_adapter(run_id: str, prompt: str) -> None:
    _append_event(
        run_id,
        ExecutionEvent(type="action.started", action_index=0, message="starting calendar adapter"),
    )
    _append_chat_message(
        run_id,
        summary="Checking your calendar for today.",
        sections=[ChatSection(title="What I Did", body="Queried your local macOS Calendar for today's events.")],
    )
    try:
        events = _fetch_today_calendar_events()
    except Exception as exc:
        message = f"Calendar adapter failed: {exc}"
        _append_log_message(run_id, message)
        _append_event(
            run_id,
            ExecutionEvent(type="action.completed", action_index=0, message="calendar adapter failed"),
        )
        _append_event(run_id, ExecutionEvent(type="run.failed", message="Run failed"))
        _set_run_status(run_id, "failed", "Calendar query failed")
        return

    today = datetime.now().strftime("%A, %B %d, %Y")
    if events:
        _append_chat_message(
            run_id,
            summary=f"{len(events)} event(s) found for {today}.",
            sections=[ChatSection(title="Result", body=f"Showing your agenda for {today}.")],
            agenda_items=events,
        )
    else:
        _append_chat_message(
            run_id,
            summary=f"No events found for {today}.",
            sections=[ChatSection(title="Result", body="Your calendar appears free today.")],
        )

    _append_event(
        run_id,
        ExecutionEvent(type="action.completed", action_index=0, message="calendar adapter completed"),
    )
    _append_event(run_id, ExecutionEvent(type="run.completed", message="Run completed successfully"))
    _set_run_status(run_id, "completed", "Run completed successfully")


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


def _run_local_plan(run_id: str, plan: ActionPlan, workdir: Path) -> None:
    executor = LocalExecutor(workdir)
    success = _execute_plan(run_id, plan, executor)
    with RUNS_LOCK:
        current_status = RUNS.get(run_id).status if run_id in RUNS else None
    if current_status == "cancelled":
        return
    summary = "Run completed successfully" if success else "Run failed"
    _append_event(
        run_id,
        ExecutionEvent(
            type="run.completed" if success else "run.failed",
            message=summary,
        ),
    )
    _set_run_status(run_id, "completed" if success else "failed", summary)


def _run_codex(
    run_id: str,
    prompt: str,
    workdir: Path,
    session_id: str,
    client_thread_id: str | None = None,
    response_profile: Literal["guided", "minimal"] = "guided",
    guardrail_message: str | None = None,
) -> None:
    codex_executor = CodexExecutor(workdir)
    profile_agents, profile_memory = _load_profile_context(session_id_hint=session_id)
    workdir_memory_path = _stage_profile_files_in_workdir(workdir, session_id_hint=session_id)
    codex_prompt = _build_codex_prompt(
        prompt,
        response_profile=response_profile,
        profile_agents=profile_agents,
        profile_memory=profile_memory,
        memory_file_hint=".mobaile/MEMORY.md",
    )
    normalized_client_thread_id = (client_thread_id or "").strip() or None
    resume_thread_id: str | None = None
    if normalized_client_thread_id:
        resume_thread_id = RUN_STORE.get_codex_thread_id(session_id, normalized_client_thread_id)
    _append_event(
        run_id,
        ExecutionEvent(
            type="action.started",
            action_index=0,
            message=f"starting codex exec (cwd={workdir})",
        ),
    )
    if guardrail_message:
        _append_chat_message(
            run_id,
            summary=guardrail_message,
            sections=[ChatSection(title="Safety", body=guardrail_message)],
        )
    try:
        proc = codex_executor.start(codex_prompt, resume_thread_id=resume_thread_id)
    except FileNotFoundError:
        _append_event(
            run_id,
            ExecutionEvent(type="action.stderr", action_index=0, message="codex binary not found"),
        )
        _append_event(
            run_id,
            ExecutionEvent(type="action.completed", action_index=0, message="codex exec failed"),
        )
        _append_event(run_id, ExecutionEvent(type="run.failed", message="Run failed"))
        _set_run_status(run_id, "failed", "Run failed")
        _sync_profile_memory_from_workdir(workdir_memory_path)
        return

    with ACTIVE_PROCS_LOCK:
        ACTIVE_PROCS[run_id] = proc

    assert proc.stdout is not None
    line_queue: Queue[str | None] = Queue()

    def _drain_stdout() -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            line_queue.put(line.rstrip("\r\n"))
        line_queue.put(None)

    reader = threading.Thread(target=_drain_stdout, daemon=True)
    reader.start()

    chat_extractor = _CodexAssistantExtractor(prompt)
    timed_out = False
    cancelled = False
    deadline = time.monotonic() + CODEX_TIMEOUT_SEC
    while True:
        try:
            line = line_queue.get(timeout=0.2)
        except Empty:
            line = None

        if line is not None:
            message = line.rstrip()
            if message:
                parsed = _parse_codex_json_event(message)
                if parsed is not None:
                    event_type = str(parsed.get("type", "")).strip()
                    if event_type == "thread.started":
                        codex_thread_id = str(parsed.get("thread_id", "")).strip()
                        if codex_thread_id and normalized_client_thread_id:
                            RUN_STORE.set_codex_thread_id(
                                session_id=session_id,
                                client_thread_id=normalized_client_thread_id,
                                codex_thread_id=codex_thread_id,
                            )
                            _append_log_message(
                                run_id,
                                f"codex thread linked ({codex_thread_id})",
                                action_index=0,
                            )
                    elif event_type == "item.completed":
                        item = parsed.get("item")
                        if isinstance(item, dict):
                            item_type = str(item.get("type", "")).strip()
                            item_text = str(item.get("text", "")).strip()
                            if item_type == "agent_message" and item_text:
                                _append_assistant_payload(run_id, item_text)
                    continue

                _append_log_message(run_id, message, action_index=0)
                for structured in chat_extractor.consume(message):
                    _append_assistant_payload(run_id, structured)
        else:
            if proc.poll() is not None:
                break

        if _is_cancelled(run_id):
            cancelled = True
            break
        if time.monotonic() > deadline:
            timed_out = True
            break

    for structured in chat_extractor.flush():
        _append_assistant_payload(run_id, structured)

    if cancelled or timed_out:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    exit_code = proc.wait()
    if not cancelled and _is_cancelled(run_id):
        cancelled = True
    with ACTIVE_PROCS_LOCK:
        ACTIVE_PROCS.pop(run_id, None)

    _append_event(
        run_id,
        ExecutionEvent(
            type="action.completed",
            action_index=0,
            message=f"codex exec finished (exit={exit_code})",
        ),
    )

    if cancelled:
        summary = "Run cancelled by user"
        _append_event(run_id, ExecutionEvent(type="run.cancelled", message=summary))
        _set_run_status(run_id, "cancelled", summary)
        _sync_profile_memory_from_workdir(workdir_memory_path)
        return
    if timed_out:
        summary = f"Run timed out after {CODEX_TIMEOUT_SEC}s"
        _append_event(run_id, ExecutionEvent(type="run.failed", message=summary))
        _set_run_status(run_id, "failed", summary)
        _sync_profile_memory_from_workdir(workdir_memory_path)
        return

    success = exit_code == 0
    summary = "Run completed successfully" if success else "Run failed"
    _append_event(
        run_id,
        ExecutionEvent(type="run.completed" if success else "run.failed", message=summary),
    )
    _set_run_status(run_id, "completed" if success else "failed", summary)
    _sync_profile_memory_from_workdir(workdir_memory_path)


def _execute_plan(run_id: str, plan: ActionPlan, executor: LocalExecutor) -> bool:
    for idx, action in enumerate(plan.actions):
        if _is_cancelled(run_id):
            _append_event(
                run_id,
                ExecutionEvent(type="run.cancelled", message="Run cancelled by user"),
            )
            _set_run_status(run_id, "cancelled", "Run cancelled by user")
            return False
        _append_event(
            run_id,
            ExecutionEvent(
                type="action.started",
                action_index=idx,
                message=f"starting {action.type}",
            )
        )
        result = executor.execute(action)
        if result.stdout:
            _append_event(
                run_id,
                ExecutionEvent(
                    type="action.stdout",
                    action_index=idx,
                    message=result.stdout.strip(),
                )
            )
        if result.stderr:
            _append_event(
                run_id,
                ExecutionEvent(
                    type="action.stderr",
                    action_index=idx,
                    message=result.stderr.strip(),
                )
            )
        done_message = result.details
        if result.exit_code is not None:
            done_message = f"{done_message} (exit={result.exit_code})"
        _append_event(
            run_id,
            ExecutionEvent(
                type="action.completed",
                action_index=idx,
                message=done_message,
            )
        )
        if not result.success:
            return False
    return True


def _store_run(run: RunRecord) -> None:
    with RUNS_LOCK:
        RUNS[run.run_id] = run
        RUN_STORE.upsert_run(run)


def _append_event(run_id: str, event: ExecutionEvent) -> None:
    if not event.event_id:
        event.event_id = str(uuid.uuid4())
    if not event.created_at:
        event.created_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    if len(event.message) > MAX_EVENT_MESSAGE_CHARS:
        event.message = event.message[:MAX_EVENT_MESSAGE_CHARS] + "\n...[truncated]"
    with RUNS_LOCK:
        run = RUNS.get(run_id)
        if run is None:
            return
        run.events.append(event)
        RUN_STORE.append_event(run_id, event)


def _set_run_status(run_id: str, status: str, summary: str) -> None:
    with RUNS_LOCK:
        run = RUNS.get(run_id)
        if run is None:
            return
        run.status = status
        run.summary = summary
        if status in {"completed", "failed", "rejected", "cancelled"}:
            RUN_CANCELLED.discard(run_id)
        RUN_STORE.update_run_status(run_id, status, summary)


def _resolve_workdir(raw_path: str | None) -> Path:
    if raw_path and raw_path.strip():
        requested = Path(raw_path.strip()).expanduser()
        if not requested.is_absolute():
            requested = (DEFAULT_WORKDIR / requested).resolve()
        else:
            requested = requested.resolve()
        if WORKDIR_ROOT is not None and not _is_relative_to(requested, WORKDIR_ROOT):
            raise ValueError(f"working_directory must stay inside {WORKDIR_ROOT}")
        requested.mkdir(parents=True, exist_ok=True)
        return requested
    return DEFAULT_WORKDIR


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _is_path_allowed(path: Path) -> bool:
    if FULL_ACCESS_MODE and ALLOW_ABSOLUTE_FILE_READS and not FILE_ROOTS:
        return True
    return any(_is_relative_to(path, root) for root in FILE_ROOTS)


def _read_pairing_file() -> dict[str, object]:
    if not PAIRING_FILE.exists():
        return {}
    try:
        return json.loads(PAIRING_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def _write_pairing_file(payload: dict[str, object]) -> None:
    PAIRING_FILE.parent.mkdir(parents=True, exist_ok=True)
    PAIRING_FILE.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _rotate_pair_code(payload: dict[str, object]) -> None:
    payload["pair_code"] = secrets.token_urlsafe(10)
    payload["pair_code_expires_at"] = (
        datetime.now(timezone.utc) + timedelta(minutes=PAIR_CODE_TTL_MIN)
    ).isoformat().replace("+00:00", "Z")
    _write_pairing_file(payload)


def _enforce_pair_rate_limit(client_id: str) -> None:
    now = time.monotonic()
    with PAIR_ATTEMPTS_LOCK:
        attempts = PAIR_ATTEMPTS.get(client_id, [])
        attempts = [t for t in attempts if now - t <= 60.0]
        if len(attempts) >= PAIR_ATTEMPT_LIMIT_PER_MIN:
            raise HTTPException(status_code=429, detail="too many pairing attempts, try again soon")
        attempts.append(now)
        PAIR_ATTEMPTS[client_id] = attempts


def _profile_key(raw_value: str) -> str:
    normalized = re.sub(r"[^a-zA-Z0-9._-]+", "_", raw_value.strip())[:120]
    if not normalized:
        return "default"
    return normalized


def _legacy_session_key(session_id: str) -> str:
    normalized = re.sub(r"[^a-zA-Z0-9._-]+", "_", session_id.strip())[:120]
    if not normalized:
        return "default"
    return normalized


def _legacy_session_dir(session_id: str) -> Path:
    return LEGACY_SESSION_STATE_ROOT / _legacy_session_key(session_id)


def _profile_dir() -> Path:
    return PROFILE_STATE_ROOT / _profile_key(PROFILE_ID)


def _profile_agents_path() -> Path:
    return _profile_dir() / "AGENTS.md"


def _profile_memory_path() -> Path:
    return _profile_dir() / "MEMORY.md"


def _clip_context(value: str, max_chars: int) -> str:
    text = value.strip()
    if max_chars <= 0 or len(text) <= max_chars:
        return text
    clipped = text[:max_chars].rstrip()
    return clipped + "\n...[truncated for context budget]"


def _ensure_profile_files(session_id_hint: str | None = None) -> tuple[Path, Path]:
    profile_path = _profile_dir()
    agents_path = _profile_agents_path()
    memory_path = _profile_memory_path()
    with PROFILE_FILE_LOCK:
        profile_path.mkdir(parents=True, exist_ok=True)
        if not agents_path.exists():
            seeded = ""
            if session_id_hint:
                legacy = _legacy_session_dir(session_id_hint) / "AGENTS.md"
                if legacy.exists() and legacy.is_file():
                    seeded = legacy.read_text(encoding="utf-8").strip()
            agents_path.write_text((seeded or DEFAULT_PROFILE_AGENTS).strip() + "\n", encoding="utf-8")
        if not memory_path.exists():
            seeded = ""
            if session_id_hint:
                legacy = _legacy_session_dir(session_id_hint) / "MEMORY.md"
                if legacy.exists() and legacy.is_file():
                    seeded = legacy.read_text(encoding="utf-8").strip()
            memory_path.write_text((seeded or DEFAULT_PROFILE_MEMORY).strip() + "\n", encoding="utf-8")
    return agents_path, memory_path


def _load_profile_context(session_id_hint: str | None = None) -> tuple[str, str]:
    agents_path, memory_path = _ensure_profile_files(session_id_hint=session_id_hint)
    agents = _clip_context(agents_path.read_text(encoding="utf-8"), PROFILE_AGENTS_MAX_CHARS)
    memory = _clip_context(memory_path.read_text(encoding="utf-8"), PROFILE_MEMORY_MAX_CHARS)
    return agents, memory


def _stage_profile_files_in_workdir(workdir: Path, session_id_hint: str | None = None) -> Path:
    agents_path, memory_path = _ensure_profile_files(session_id_hint=session_id_hint)
    mobaile_dir = (workdir / ".mobaile").resolve()
    mobaile_dir.mkdir(parents=True, exist_ok=True)
    workdir_agents = mobaile_dir / "AGENTS.md"
    workdir_memory = mobaile_dir / "MEMORY.md"
    workdir_agents.write_text(agents_path.read_text(encoding="utf-8"), encoding="utf-8")
    workdir_memory.write_text(memory_path.read_text(encoding="utf-8"), encoding="utf-8")
    return workdir_memory


def _sync_profile_memory_from_workdir(workdir_memory_path: Path) -> None:
    candidates = [workdir_memory_path]
    mobaile_dir = workdir_memory_path.parent
    workdir = mobaile_dir.parent
    candidates.extend(
        [
            mobaile_dir / "memory.md",
            workdir / "MEMORY.md",
            workdir / "memory.md",
        ]
    )

    latest_text: str | None = None
    latest_mtime = -1.0
    for candidate in candidates:
        if not candidate.exists() or not candidate.is_file():
            continue
        text = candidate.read_text(encoding="utf-8")
        normalized = text.replace("\r\n", "\n").replace("\r", "\n").strip()
        if not normalized:
            continue
        mtime = candidate.stat().st_mtime
        if mtime >= latest_mtime:
            latest_mtime = mtime
            latest_text = normalized
    if not latest_text:
        return

    bounded = _clip_context(latest_text, PROFILE_MEMORY_MAX_CHARS)
    _ensure_profile_files()
    _profile_memory_path().write_text(bounded + "\n", encoding="utf-8")


def _codex_structured_message(message: str, user_prompt: str) -> str | None:
    text = message.strip()
    if not text:
        return None
    if text == user_prompt.strip():
        return None

    lower = text.lower()
    noisy_exact = {
        "user",
        "codex",
        "exec",
        "thinking",
        "output:",
        "tokens used",
        "--------",
    }
    if lower in noisy_exact:
        return None
    noisy_prefixes = (
        "openai codex v",
        "you are running through mobaile",
        "mobaile runtime context:",
        "runtime:",
        "product intent:",
        "output style for phone ux:",
        "task-specific formatting:",
        "environment notes:",
        "user request:",
        "workdir:",
        "model:",
        "provider:",
        "approval:",
        "sandbox:",
        "reasoning effort:",
        "reasoning summaries:",
        "session id:",
        "mcp startup:",
    )
    if lower.startswith(noisy_prefixes):
        return None
    if "runtime context" in lower or "you are running through mobaile" in lower:
        return None
    context_leak_markers = (
        "keep responses concise and grouped",
        "avoid verbose step-by-step chatter",
        "you are the coding agent used by mobaile",
        "you run on the user's server/computer",
        "your stdout is streamed to a phone ui",
        "product intent:",
        "mobaile makes a user's computer available from their phone",
        "primary users are software engineers who run coding agents while away from the computer",
        "secondary use cases include normal remote productivity tasks",
        "output style for phone ux:",
        "prefer short status + result summaries",
        "environment notes:",
        "for created images, include markdown image syntax",
        "do not repeat or summarize this runtime context",
    )
    if any(marker in lower for marker in context_leak_markers):
        return None
    if any(marker in lower for marker in _context_leak_markers()):
        return None
    if lower.startswith("created ") and " and ran it successfully" in lower:
        return None
    if lower in {"run completed successfully", "run failed"}:
        return None
    if lower.startswith("error:"):
        return text
    if "succeeded in " in lower and " in /" in text:
        return None
    if text.startswith("/bin/") or text.startswith("$ "):
        return None
    if "/bin/zsh -lc" in text or " <<'PY'" in text:
        return None
    if re.match(r"^[A-Za-z0-9_./-]+\s+in\s+/.+\s+succeeded in \d+ms:?$", text):
        return None
    if re.match(r"^[A-Za-z0-9_./-]+:\s*$", text):
        return None
    if text in {"```text", "```bash", "```sh", "```python", "```"}:
        return None
    if text.startswith("**") and text.endswith("**"):
        return None
    if text.isdigit() or re.match(r"^\d[\d,]*$", text):
        return None
    return text


class _CodexAssistantExtractor:
    def __init__(self, user_prompt: str) -> None:
        self.user_prompt = user_prompt
        self.in_assistant_block = False
        self.buffer: list[str] = []
        self.last_emitted = ""

    def consume(self, raw_line: str) -> list[str]:
        text = raw_line.strip()
        if not text:
            return []
        lower = text.lower()
        if self._is_boundary(lower):
            out = self._flush()
            self.in_assistant_block = lower == "codex"
            return out

        # Only assistant blocks become chat messages. Raw lines remain available in logs.
        if not self.in_assistant_block:
            return []

        cleaned = _codex_structured_message(text, self.user_prompt)
        if not cleaned:
            return []
        self.buffer.append(cleaned)
        if sum(len(item) for item in self.buffer) > 2000:
            return self._flush()
        return []

    def flush(self) -> list[str]:
        return self._flush()

    def _flush(self) -> list[str]:
        if not self.buffer:
            return []
        merged = _merge_assistant_lines(self.buffer).strip()
        self.buffer.clear()
        if not merged:
            return []
        if merged == self.last_emitted:
            return []
        self.last_emitted = merged
        return [merged]

    def _is_boundary(self, lower: str) -> bool:
        if lower in {"user", "codex", "thinking", "exec", "tokens used", "--------"}:
            return True
        if lower.startswith(
            (
                "openai codex v",
                "workdir:",
                "model:",
                "provider:",
                "approval:",
                "sandbox:",
                "reasoning effort:",
                "reasoning summaries:",
                "session id:",
                "mcp startup:",
                "user request:",
                "mobaile runtime context:",
            )
        ):
            return True
        return False


def _parse_codex_json_event(raw_line: str) -> dict[str, object] | None:
    text = raw_line.strip()
    if not text.startswith("{"):
        return None
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    event_type = payload.get("type")
    if not isinstance(event_type, str) or not event_type.strip():
        return None
    return payload


def _is_cancelled(run_id: str) -> bool:
    with RUNS_LOCK:
        return run_id in RUN_CANCELLED


def _build_codex_prompt(
    user_prompt: str,
    response_profile: Literal["guided", "minimal"] = "guided",
    profile_agents: str = "",
    profile_memory: str = "",
    memory_file_hint: str = ".mobaile/MEMORY.md",
) -> str:
    if response_profile == "minimal":
        context = (
            "You are running through MOBaiLE.\n"
            "- You run on the user's server/computer.\n"
            "- Your stdout is streamed to a phone UI.\n"
            "- Do not repeat this runtime context unless the user asks."
        )
    else:
        if not CODEX_USE_CONTEXT:
            context = ""
        else:
            context = _load_codex_context()
    session_block = ""
    if profile_agents.strip() or profile_memory.strip():
        session_block = (
            "Persistent AGENTS profile:\n"
            f"{profile_agents.strip() or '(empty)'}\n\n"
            "Persistent MEMORY (shared across sessions):\n"
            f"{profile_memory.strip() or '(empty)'}\n\n"
            "Persistence guidance:\n"
            f"- If you learn durable facts, update `{memory_file_hint}`.\n"
            "- Do not store MOBaiLE persistence in `~/.codex/*`.\n"
            "- Keep notes concise, deduplicated, and non-sensitive.\n\n"
        )
    hygiene_block = (
        "Execution hygiene:\n"
        "- Keep generated files/images inside the current working directory.\n"
        "- Prefer project-local environments (for example `.mobaile/.venv`) for extra packages.\n"
        "- Ask before installing packages user-wide or system-wide.\n\n"
    )
    if not context and not session_block and not hygiene_block:
        return user_prompt
    if context:
        runtime_block = (
            "MOBaiLE runtime context:\n"
            f"{context}\n\n"
        )
    else:
        runtime_block = ""
    return (
        "You are running through MOBaiLE.\n\n"
        f"{runtime_block}"
        f"{session_block}"
        f"{hygiene_block}"
        "User request:\n"
        f"{user_prompt}"
    )


def _evaluate_codex_guardrails(user_prompt: str) -> tuple[str, str]:
    mode = CODEX_GUARDRAILS if CODEX_GUARDRAILS in {"off", "warn", "enforce"} else "warn"
    if mode == "off":
        return ("off", "")
    lowered = user_prompt.lower()
    dangerous_patterns = (
        r"\brm\s+-rf\b",
        r"\bmkfs\b",
        r"\bdd\s+if=",
        r"\bshutdown\b",
        r"\breboot\b",
        r"\bcurl\b.+\|\s*(sh|bash|zsh)\b",
        r"\bchmod\s+777\b",
        r"\bchown\s+-r\b",
        r"\bdrop\s+database\b",
    )
    is_dangerous = any(re.search(pattern, lowered) for pattern in dangerous_patterns)
    if not is_dangerous:
        return ("ok", "")
    if CODEX_DANGEROUS_CONFIRM_TOKEN and CODEX_DANGEROUS_CONFIRM_TOKEN.lower() in lowered:
        return ("ok", "")
    message = (
        "Potentially destructive request detected. "
        f"Add {CODEX_DANGEROUS_CONFIRM_TOKEN} to confirm intentionally."
    )
    if mode == "enforce":
        return ("reject", message)
    return ("warn", message)


def _is_calendar_request(user_prompt: str) -> bool:
    lowered = user_prompt.lower()
    calendar_terms = ("calendar", "agenda", "events")
    time_terms = ("today", "tomorrow", "this week", "next week")
    return any(term in lowered for term in calendar_terms) and any(
        term in lowered for term in time_terms
    )


def _load_codex_context() -> str:
    path = Path(CODEX_CONTEXT_FILE)
    if not path.is_absolute():
        path = (Path(__file__).resolve().parent.parent / path).resolve()
    if not path.exists() or not path.is_file():
        return ""
    return path.read_text(encoding="utf-8").strip()


def _parse_chat_envelope_payload(raw_text: str) -> dict[str, object] | None:
    candidate = raw_text.strip()
    if not candidate:
        return None
    if candidate.startswith("```") and candidate.endswith("```"):
        parts = candidate.split("\n")
        if len(parts) >= 3:
            candidate = "\n".join(parts[1:-1]).strip()

    parsed = None
    for _ in range(2):
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            parsed = None
            break
        if isinstance(parsed, str):
            candidate = parsed.strip()
            continue
        break
    if not isinstance(parsed, dict):
        return None
    if parsed.get("type") != "assistant_response":
        return None
    parsed.setdefault("version", "1.0")
    parsed.setdefault("message_id", str(uuid.uuid4()))
    parsed.setdefault("created_at", datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))
    parsed.setdefault("summary", "")
    parsed.setdefault("sections", [])
    parsed.setdefault("agenda_items", [])
    parsed.setdefault("artifacts", [])
    return parsed


def _merge_assistant_lines(lines: list[str]) -> str:
    merged_parts: list[str] = []
    section_labels = {"what i did", "result", "next step", "output"}
    for line in lines:
        text = line.strip()
        if not text:
            continue
        if not merged_parts:
            merged_parts.append(text)
            continue

        prev = merged_parts[-1]
        if prev.strip().lower().rstrip(":") in section_labels:
            merged_parts.append("\n" + text)
            continue
        if text.lower().rstrip(":") in section_labels:
            merged_parts.append("\n\n## " + text.rstrip(":"))
            continue
        if prev.endswith((":", ";")):
            merged_parts.append("\n" + text)
            continue
        if text.startswith(("-", "*", "##", "###", "```")):
            merged_parts.append("\n" + text)
            continue
        if text.startswith(("1.", "2.", "3.", "4.", "5.")):
            merged_parts.append("\n" + text)
            continue
        if prev.endswith((".", "!", "?", "`")):
            merged_parts.append("\n\n" + text)
            continue
        merged_parts.append("\n" + text)
    return "".join(merged_parts)


def _coerce_assistant_text_to_envelope(raw_text: str) -> ChatEnvelope:
    text = raw_text.strip()
    message_id = str(uuid.uuid4())
    created_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    if not text:
        return ChatEnvelope(
            message_id=message_id,
            created_at=created_at,
            summary="",
            sections=[],
            agenda_items=[],
            artifacts=[],
        )
    sections = _split_sections_from_text(text)
    artifacts = _extract_artifacts_from_text(text)
    summary = sections[0].body if sections else text.split("\n", 1)[0]
    summary = summary.strip()
    if not summary:
        summary = "Completed"
    return ChatEnvelope(
        message_id=message_id,
        created_at=created_at,
        summary=summary[:280],
        sections=sections,
        artifacts=artifacts,
    )


def _split_sections_from_text(text: str) -> list[ChatSection]:
    cleaned = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not cleaned:
        return []
    if "## " in cleaned:
        sections: list[ChatSection] = []
        for block in re.split(r"(?m)^##\s+", cleaned):
            chunk = block.strip()
            if not chunk:
                continue
            lines = chunk.splitlines()
            title = lines[0].strip().rstrip(":")
            body = "\n".join(lines[1:]).strip() if len(lines) > 1 else ""
            if not body:
                continue
            sections.append(ChatSection(title=title[:64], body=body))
        if sections:
            return sections
    paragraphs = [p.strip() for p in re.split(r"\n{2,}", cleaned) if p.strip()]
    if len(paragraphs) <= 1:
        return [ChatSection(title="Result", body=cleaned)]
    sections = [ChatSection(title="What I Did", body=paragraphs[0])]
    sections.append(ChatSection(title="Result", body="\n\n".join(paragraphs[1:])))
    return sections


def _extract_artifacts_from_text(text: str) -> list[ChatArtifact]:
    artifacts: list[ChatArtifact] = []
    seen: set[str] = set()
    image_pattern = r"!\[[^\]]*\]\(([^)]+)\)"
    for match in re.finditer(image_pattern, text):
        path = match.group(1).strip().strip("'\"")
        if not path or path in seen:
            continue
        seen.add(path)
        mime, _ = mimetypes.guess_type(path)
        artifacts.append(
            ChatArtifact(
                type="image",
                title=Path(path).name or "image",
                path=path,
                mime=mime or "image/png",
            )
        )
    path_pattern = r"(/[^ \n`'\"<>]+\.[A-Za-z0-9]{1,8})"
    for match in re.finditer(path_pattern, text):
        path = match.group(1).strip()
        if not path or path in seen:
            continue
        seen.add(path)
        mime, _ = mimetypes.guess_type(path)
        artifact_type = "image" if (mime or "").startswith("image/") else "file"
        artifacts.append(
            ChatArtifact(
                type=artifact_type,
                title=Path(path).name or path,
                path=path,
                mime=mime,
            )
        )
    return artifacts


def _context_leak_markers() -> list[str]:
    context = _load_codex_context().lower()
    if not context:
        return []
    markers: list[str] = []
    for chunk in re.split(r"[\n.:;]+", context):
        text = " ".join(chunk.strip().split())
        if len(text) >= 24:
            markers.append(text)
    return markers
