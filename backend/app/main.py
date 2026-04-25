from __future__ import annotations

import asyncio
import uuid
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

from app.calendar_service import CalendarService
from app.capabilities import collect_capabilities
from app.chat_attachments import merge_voice_utterance, parse_audio_attachments
from app.codex_text import (
    CodexAssistantExtractor as _CodexAssistantExtractor,
)
from app.codex_text import (
    filter_codex_assistant_message as _filter_codex_assistant_message,
)
from app.execution_service import ExecutionService
from app.models.schemas import (
    ApiErrorDetail,
    AudioRunResponse,
    CapabilitiesResponse,
    DirectoryCreateRequest,
    DirectoryCreateResponse,
    DirectoryListingResponse,
    ExecutionEvent,
    PairExchangeRequest,
    PairExchangeResponse,
    PairRefreshRequest,
    RunDiagnostics,
    RunEventsPage,
    RunExecutorName,
    RunRecord,
    RunSummary,
    RuntimeConfigResponse,
    SessionContextResponse,
    SessionContextUpdateRequest,
    SlashCommandDescriptor,
    SlashCommandExecutionRequest,
    SlashCommandExecutionResponse,
    UploadResponse,
    UtteranceRequest,
    UtteranceResponse,
)
from app.pairing_service import PairingService
from app.pairing_url import refresh_pairing_server_url
from app.profile_store import ProfileStore
from app.run_state import RunState
from app.runtime_environment import RuntimeEnvironment, load_env_defaults
from app.runtime_session_service import RuntimeSessionService
from app.storage import RunStore
from app.transcription import Transcriber, TranscriptionError
from app.upload_limits import read_upload_bytes_limited, validate_upload_content_length
from app.utterance_service import UtteranceService
from app.workspace_service import WorkspaceService

# Keep these names available from app.main for existing tests and module consumers.
CodexAssistantExtractor = _CodexAssistantExtractor
filter_codex_assistant_message = _filter_codex_assistant_message

BACKEND_ROOT = Path(__file__).resolve().parent.parent
load_env_defaults(BACKEND_ROOT / ".env")


app = FastAPI(title="Voice Agent Backend", version="0.1.0")
ENV = RuntimeEnvironment.from_env(BACKEND_ROOT)
refresh_pairing_server_url(
    ENV.pairing_file,
    bind_host=ENV.host,
    bind_port=ENV.port,
    public_server_url=ENV.public_server_url,
    phone_access_mode=ENV.phone_access_mode,
)
TRANSCRIBER = Transcriber()
RUN_STORE = RunStore(ENV.db_path)
RUN_STATE = RunState(RUN_STORE, max_event_message_chars=ENV.max_event_message_chars)
RUN_STATE.reconcile_interrupted_runs()
CALENDAR_SERVICE = CalendarService()
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
    fetch_calendar_events=lambda: CALENDAR_SERVICE.fetch_today_events(),
)
PAIRING_SERVICE = PairingService(ENV)
RUNTIME_SESSION_SERVICE = RuntimeSessionService(ENV, RUN_STORE)
UTTERANCE_SERVICE = UtteranceService(
    environment=ENV,
    run_state=RUN_STATE,
    execution_service=EXECUTION_SERVICE,
    session_context_loader=RUNTIME_SESSION_SERVICE.session_context_response,
)
WORKSPACE_SERVICE = WorkspaceService(ENV)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.middleware("http")
async def require_api_token(request: Request, call_next):
    if not request.url.path.startswith("/v1/"):
        return await call_next(request)
    if request.url.path in {"/v1/pair/exchange", "/v1/pair/refresh"}:
        return await call_next(request)

    if not PAIRING_SERVICE.has_configured_api_token():
        return JSONResponse(
            status_code=503,
            content={"detail": "server auth token is not configured"},
        )

    auth_header = request.headers.get("Authorization", "")
    if not PAIRING_SERVICE.is_authorized_api_token(auth_header):
        return JSONResponse(
            status_code=401,
            content={"detail": "missing or invalid bearer token"},
        )
    return await call_next(request)


@app.post("/v1/pair/exchange", response_model=PairExchangeResponse)
def pair_exchange(payload: PairExchangeRequest, request: Request) -> PairExchangeResponse:
    return PAIRING_SERVICE.exchange_pair_code(
        payload,
        client_id=request.client.host if request.client else "unknown",
    )


@app.post("/v1/pair/refresh", response_model=PairExchangeResponse)
def pair_refresh(payload: PairRefreshRequest, request: Request) -> PairExchangeResponse:
    return PAIRING_SERVICE.refresh_pairing_credentials(
        payload,
        auth_header=request.headers.get("Authorization", ""),
        client_id=request.client.host if request.client else "unknown",
    )


@app.post("/v1/utterances", response_model=UtteranceResponse)
def create_utterance(request: UtteranceRequest) -> UtteranceResponse:
    return UTTERANCE_SERVICE.submit(request)


@app.post("/v1/audio", response_model=AudioRunResponse)
async def create_audio_run(
    session_id: str = Form(...),
    thread_id: str | None = Form(None),
    run_id: str | None = Form(None),
    audio: UploadFile = File(...),
    executor: RunExecutorName | None = Form(None),
    mode: Literal["assistant", "execute"] = Form("execute"),
    transcript_hint: str | None = Form(None),
    draft_text: str | None = Form(None),
    attachments_json: str | None = Form(None),
    working_directory: str | None = Form(None),
    response_mode: Literal["concise", "verbose"] = Form("concise"),
    response_profile: Literal["guided", "minimal"] = Form("guided"),
) -> AudioRunResponse:
    normalized_thread_id = (thread_id or "").strip() or None
    audio_run_id = (run_id or "").strip() or str(uuid.uuid4())
    attachments = parse_audio_attachments(attachments_json)
    lifecycle_request = UtteranceRequest(
        session_id=session_id,
        thread_id=normalized_thread_id,
        utterance_text=(draft_text or "").strip() or "Voice message",
        attachments=attachments,
        executor=executor,
        mode=mode,
        working_directory=working_directory,
        response_mode=response_mode,
        response_profile=response_profile,
    )
    UTTERANCE_SERVICE.create_transcribing_run(lifecycle_request, run_id=audio_run_id)
    try:
        validate_upload_content_length(
            audio,
            field="audio",
            max_bytes=ENV.max_audio_bytes,
            max_mb=ENV.max_audio_mb,
        )
        audio_bytes = await read_upload_bytes_limited(
            audio,
            field="audio",
            max_bytes=ENV.max_audio_bytes,
            max_mb=ENV.max_audio_mb,
        )
    except HTTPException as exc:
        if exc.status_code == 413:
            RUN_STATE.append_activity_event(
                audio_run_id,
                stage="transcribing",
                title="Rejected",
                display_message="Audio payload is too large.",
                level="error",
                event_type="activity.completed",
            )
            RUN_STATE.append_event(audio_run_id, ExecutionEvent(type="run.failed", message="Audio payload too large"))
            RUN_STATE.set_run_status(audio_run_id, "failed", "Audio payload too large")
        raise
    if _is_run_cancelled(audio_run_id):
        _mark_cancelled_before_execution(audio_run_id)
        raise HTTPException(
            status_code=409,
            detail=ApiErrorDetail(
                code="run_cancelled",
                message="Audio run was cancelled before transcription started.",
            ).model_dump(),
        )
    try:
        transcript_text = await asyncio.to_thread(
            TRANSCRIBER.transcribe,
            audio_bytes=audio_bytes,
            filename=audio.filename or "audio",
            text_hint=transcript_hint,
        )
    except TranscriptionError as exc:
        if _is_run_cancelled(audio_run_id):
            _mark_cancelled_before_execution(audio_run_id)
            raise HTTPException(
                status_code=409,
                detail=ApiErrorDetail(
                    code="run_cancelled",
                    message="Audio run was cancelled before transcription completed.",
                ).model_dump(),
            ) from exc
        _mark_audio_transcription_failed(audio_run_id, str(exc))
        raise HTTPException(
            status_code=502,
            detail=ApiErrorDetail(code="transcription_failed", message=str(exc), field="audio").model_dump(),
        ) from exc
    except Exception as exc:
        if _is_run_cancelled(audio_run_id):
            _mark_cancelled_before_execution(audio_run_id)
            raise HTTPException(
                status_code=409,
                detail=ApiErrorDetail(
                    code="run_cancelled",
                    message="Audio run was cancelled before transcription completed.",
                ).model_dump(),
            ) from exc
        _mark_audio_transcription_failed(audio_run_id, "Audio transcription failed")
        raise HTTPException(
            status_code=500,
            detail=ApiErrorDetail(
                code="transcription_failed",
                message="Audio transcription failed.",
                field="audio",
            ).model_dump(),
        ) from exc
    if _is_run_cancelled(audio_run_id):
        _mark_cancelled_before_execution(audio_run_id)
        raise HTTPException(
            status_code=409,
            detail=ApiErrorDetail(
                code="run_cancelled",
                message="Audio run was cancelled before execution started.",
            ).model_dump(),
        )
    utterance_text = merge_voice_utterance(draft_text, transcript_text)
    result = UTTERANCE_SERVICE.submit_precreated(
        UtteranceRequest(
            session_id=session_id,
            thread_id=normalized_thread_id,
            utterance_text=utterance_text,
            attachments=attachments,
            executor=executor,
            mode=mode,
            working_directory=working_directory,
            response_mode=response_mode,
            response_profile=response_profile,
        ),
        run_id=audio_run_id,
    )
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
    validate_upload_content_length(
        file,
        field="file",
        max_bytes=ENV.max_upload_bytes,
        max_mb=ENV.max_upload_mb,
    )
    file_bytes = await read_upload_bytes_limited(
        file,
        field="file",
        max_bytes=ENV.max_upload_bytes,
        max_mb=ENV.max_upload_mb,
    )
    return WORKSPACE_SERVICE.store_upload(
        session_id=session_id,
        filename=file.filename,
        content_type=file.content_type,
        file_bytes=file_bytes,
    )


@app.get("/v1/runs/{run_id}", response_model=RunRecord)
def get_run(run_id: str, events_limit: int | None = Query(None, ge=0, le=500)) -> RunRecord:
    run = RUN_STATE.get_run(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="run not found")
    if events_limit is not None:
        run = run.model_copy(deep=True)
        run.events = run.events[-events_limit:] if events_limit > 0 else []
    return run


@app.get("/v1/config", response_model=RuntimeConfigResponse)
def get_runtime_config() -> RuntimeConfigResponse:
    server_urls = PAIRING_SERVICE.pairing_server_urls()
    return ENV.runtime_config_response(
        transcribe_provider=TRANSCRIBER.provider,
        transcribe_ready=ENV.transcriber_ready(TRANSCRIBER.provider),
        server_url=server_urls[0] if server_urls else None,
        server_urls=server_urls,
    )


@app.get("/v1/slash-commands", response_model=list[SlashCommandDescriptor])
def list_slash_commands() -> list[SlashCommandDescriptor]:
    return RUNTIME_SESSION_SERVICE.slash_command_catalog()


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
        fetch_calendar_events=CALENDAR_SERVICE.fetch_today_events,
    )


@app.get("/v1/tools/calendar/today")
def get_calendar_today() -> dict[str, object]:
    today = CALENDAR_SERVICE.today_label()
    try:
        events = CALENDAR_SERVICE.fetch_today_events()
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


@app.get("/v1/sessions/{session_id}/context", response_model=SessionContextResponse)
def get_session_context(session_id: str) -> SessionContextResponse:
    return RUNTIME_SESSION_SERVICE.session_context_response(session_id)


@app.patch("/v1/sessions/{session_id}/context", response_model=SessionContextResponse)
def update_session_context(session_id: str, payload: SessionContextUpdateRequest) -> SessionContextResponse:
    return RUNTIME_SESSION_SERVICE.apply_session_context_patch(session_id, payload)


@app.post(
    "/v1/sessions/{session_id}/slash-commands/{command_id}",
    response_model=SlashCommandExecutionResponse,
)
def execute_slash_command(
    session_id: str,
    command_id: str,
    payload: SlashCommandExecutionRequest,
) -> SlashCommandExecutionResponse:
    return RUNTIME_SESSION_SERVICE.execute_slash_command(
        session_id,
        command_id=command_id,
        arguments=payload.arguments,
    )


@app.get("/v1/runs/{run_id}/diagnostics", response_model=RunDiagnostics)
def get_run_diagnostics(run_id: str) -> RunDiagnostics:
    diagnostics = RUN_STATE.diagnostics_for(run_id)
    if diagnostics is None:
        raise HTTPException(status_code=404, detail="run not found")
    return diagnostics


@app.get("/v1/runs/{run_id}/events-page", response_model=RunEventsPage)
def get_run_events_page(
    run_id: str,
    limit: int = Query(100, ge=1, le=500),
    before_seq: int | None = Query(None, ge=0),
    after_seq: int | None = Query(None, ge=0),
) -> RunEventsPage:
    try:
        page = RUN_STATE.event_page(run_id, limit=limit, before_seq=before_seq, after_seq=after_seq)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if page is None:
        raise HTTPException(status_code=404, detail="run not found")
    return page


@app.get("/v1/files")
def get_file(path: str = Query(..., min_length=1)) -> FileResponse:
    return WORKSPACE_SERVICE.file_response(path)


@app.get("/v1/directories", response_model=DirectoryListingResponse)
def list_directory(path: str | None = Query(None)) -> DirectoryListingResponse:
    return WORKSPACE_SERVICE.list_directory(path)


@app.post("/v1/directories", response_model=DirectoryCreateResponse)
def create_directory(request: DirectoryCreateRequest) -> DirectoryCreateResponse:
    return WORKSPACE_SERVICE.create_directory(request.path)


@app.post("/v1/runs/{run_id}/cancel")
def cancel_run(run_id: str) -> dict[str, str]:
    try:
        run = RUN_STATE.request_cancel(run_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="run not found") from exc
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=f"run already terminal ({exc})") from exc

    if _is_audio_transcribing_run(run):
        _mark_cancelled_before_execution(run_id)
    else:
        EXECUTION_SERVICE.terminate_active_process(run_id)

    return {"run_id": run_id, "status": "cancel_requested"}


def _is_audio_transcribing_run(run: RunRecord) -> bool:
    return run.status == "running" and run.summary == "Transcribing audio"


def _is_run_cancelled(run_id: str) -> bool:
    if RUN_STATE.is_cancelled(run_id):
        return True
    run = RUN_STATE.get_run(run_id)
    return run is not None and run.status == "cancelled"


def _mark_cancelled_before_execution(run_id: str) -> None:
    run = RUN_STATE.get_run(run_id)
    if run is not None and run.status == "cancelled":
        return
    RUN_STATE.append_activity_event(
        run_id,
        stage="transcribing",
        title="Cancelled",
        display_message="Audio run cancelled before execution.",
        level="warning",
        event_type="activity.completed",
    )
    RUN_STATE.append_event(run_id, ExecutionEvent(type="run.cancelled", message="Run cancelled by user"))
    RUN_STATE.set_run_status(run_id, "cancelled", "Run cancelled by user")


def _mark_audio_transcription_failed(run_id: str, message: str) -> None:
    RUN_STATE.append_activity_event(
        run_id,
        stage="transcribing",
        title="Failed",
        display_message="Audio transcription failed.",
        level="error",
        event_type="activity.completed",
    )
    RUN_STATE.append_event(run_id, ExecutionEvent(type="run.failed", message=message))
    RUN_STATE.set_run_status(run_id, "failed", "Audio transcription failed")


@app.get("/v1/runs/{run_id}/events")
def stream_run_events(run_id: str, after_seq: int = Query(-1, ge=-1)) -> StreamingResponse:
    if RUN_STATE.get_run(run_id) is None:
        raise HTTPException(status_code=404, detail="run not found")
    return StreamingResponse(
        RUN_STATE.event_stream(run_id, after_seq=after_seq),
        media_type="text/event-stream",
    )
