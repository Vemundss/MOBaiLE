from __future__ import annotations

import hashlib
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
    HumanUnblockRequest,
    PairExchangeRequest,
    PairExchangeResponse,
    PairRefreshRequest,
    RunDiagnostics,
    RunExecutorName,
    RunRecord,
    RunSummary,
    RuntimeConfigResponse,
    RuntimeSettingDescriptor,
    SessionRuntimeSettingValue,
    SessionContextResponse,
    SessionContextUpdateRequest,
    SlashCommandDescriptor,
    SlashCommandExecutionRequest,
    SlashCommandExecutionResponse,
    UploadResponse,
    UtteranceRequest,
    UtteranceResponse,
)
from app.orchestrator.planner import plan_from_utterance
from app.pairing_url import refresh_pairing_server_url
from app.policy.validator import validate_plan
from app.profile_store import ProfileStore
from app.run_state import RunState
from app.runtime_environment import load_env_defaults
from app.runtime_environment import RuntimeEnvironment
from app.runtime_environment import CODEX_REASONING_EFFORT_OPTIONS
from app.storage import RunStore
from app.transcription import Transcriber, TranscriptionError


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
MAX_PAIRED_CLIENT_TOKENS = 12
_UNSET = object()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.middleware("http")
async def require_api_token(request: Request, call_next):
    if not request.url.path.startswith("/v1/"):
        return await call_next(request)
    if request.url.path in {"/v1/pair/exchange", "/v1/pair/refresh"}:
        return await call_next(request)

    pairing = _read_pairing_file()
    if not ENV.api_token and not _paired_client_records(pairing):
        return JSONResponse(
            status_code=503,
            content={"detail": "server auth token is not configured"},
        )

    auth_header = request.headers.get("Authorization", "")
    if not _is_authorized_api_token(auth_header, pairing):
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
        session_id = payload.session_id or str(pairing.get("session_id", "iphone-app")).strip() or "iphone-app"
        api_token, refresh_token = _issue_paired_client_credentials(pairing, session_id=session_id)
        return _pair_credentials_response(
            pairing,
            api_token=api_token,
            refresh_token=refresh_token,
            session_id=session_id,
        )


@app.post("/v1/pair/refresh", response_model=PairExchangeResponse)
def pair_refresh(payload: PairRefreshRequest, request: Request) -> PairExchangeResponse:
    _enforce_pair_rate_limit(request.client.host if request.client else "unknown")
    with PAIR_EXCHANGE_LOCK:
        pairing = _read_pairing_file()
        api_token, refresh_token, session_id = _refresh_paired_client_credentials(
            pairing,
            auth_header=request.headers.get("Authorization", ""),
            refresh_token=payload.refresh_token,
            session_id=payload.session_id,
        )
        return _pair_credentials_response(
            pairing,
            api_token=api_token,
            refresh_token=refresh_token,
            session_id=session_id,
        )


@app.post("/v1/utterances", response_model=UtteranceResponse)
def create_utterance(request: UtteranceRequest) -> UtteranceResponse:
    run_id = str(uuid.uuid4())
    session_context = _session_context_response(request.session_id)
    executor = ENV.resolve_request_executor(request.executor if request.executor is not None else session_context.executor)
    requested_working_directory = request.working_directory
    if requested_working_directory is None:
        requested_working_directory = session_context.working_directory
    try:
        workdir = ENV.resolve_workdir(requested_working_directory)
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
                session_context.codex_model,
                session_context.codex_reasoning_effort,
                session_context.claude_model,
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
    draft_text: str | None = Form(None),
    attachments_json: str | None = Form(None),
    working_directory: str | None = Form(None),
    response_mode: Literal["concise", "verbose"] = Form("concise"),
    response_profile: Literal["guided", "minimal"] = Form("guided"),
) -> AudioRunResponse:
    normalized_thread_id = (thread_id or "").strip() or None
    attachments = _parse_audio_attachments(attachments_json)
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
        utterance_text = _merge_voice_utterance(draft_text, transcript_text)
        result = create_utterance(
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
    pairing = _read_pairing_file()
    server_urls = _pairing_server_urls(pairing)
    return ENV.runtime_config_response(
        transcribe_provider=TRANSCRIBER.provider,
        transcribe_ready=ENV.transcriber_ready(TRANSCRIBER.provider),
        server_url=server_urls[0] if server_urls else None,
        server_urls=server_urls,
    )


@app.get("/v1/slash-commands", response_model=list[SlashCommandDescriptor])
def list_slash_commands() -> list[SlashCommandDescriptor]:
    return _slash_command_catalog()


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


@app.get("/v1/sessions/{session_id}/context", response_model=SessionContextResponse)
def get_session_context(session_id: str) -> SessionContextResponse:
    return _session_context_response(session_id)


@app.patch("/v1/sessions/{session_id}/context", response_model=SessionContextResponse)
def update_session_context(session_id: str, payload: SessionContextUpdateRequest) -> SessionContextResponse:
    executor = _UNSET
    working_directory = _UNSET
    runtime_settings = _UNSET
    codex_model = _UNSET
    codex_reasoning_effort = _UNSET
    claude_model = _UNSET

    if "executor" in payload.model_fields_set:
        executor = None if payload.executor is None else _validated_session_context_executor(payload.executor)

    if "working_directory" in payload.model_fields_set:
        raw_path = (payload.working_directory or "").strip()
        if raw_path:
            try:
                working_directory = str(ENV.resolve_workdir(raw_path))
            except ValueError as exc:
                raise HTTPException(status_code=400, detail=str(exc)) from exc
        else:
            working_directory = None

    if "runtime_settings" in payload.model_fields_set:
        entries: list[SessionRuntimeSettingValue] = []
        for item in payload.runtime_settings or []:
            entries.append(
                SessionRuntimeSettingValue(
                    executor=item.executor,
                    id=_normalized_runtime_setting_id(item.id) or item.id,
                    value=_validated_runtime_setting_value(item.executor, item.id, item.value),
                )
            )
        runtime_settings = entries

    if "codex_model" in payload.model_fields_set:
        codex_model = _normalized_optional_text(payload.codex_model)

    if "codex_reasoning_effort" in payload.model_fields_set:
        codex_reasoning_effort = _validated_optional_codex_reasoning_effort(payload.codex_reasoning_effort)

    if "claude_model" in payload.model_fields_set:
        claude_model = _normalized_optional_text(payload.claude_model)

    return _update_session_context(
        session_id,
        executor=executor,
        working_directory=working_directory,
        runtime_settings=runtime_settings,
        codex_model=codex_model,
        codex_reasoning_effort=codex_reasoning_effort,
        claude_model=claude_model,
    )


@app.post(
    "/v1/sessions/{session_id}/slash-commands/{command_id}",
    response_model=SlashCommandExecutionResponse,
)
def execute_slash_command(
    session_id: str,
    command_id: str,
    payload: SlashCommandExecutionRequest,
) -> SlashCommandExecutionResponse:
    return _execute_slash_command(
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
def stream_run_events(run_id: str, after_seq: int = Query(-1, ge=-1)) -> StreamingResponse:
    if RUN_STATE.get_run(run_id) is None:
        raise HTTPException(status_code=404, detail="run not found")
    return StreamingResponse(
        RUN_STATE.event_stream(run_id, after_seq=after_seq),
        media_type="text/event-stream",
    )


def _normalized_runtime_setting_id(value: str | None) -> str | None:
    normalized = _normalized_optional_text(value)
    if normalized is None:
        return None
    return normalized.lower().replace(" ", "_")


def _runtime_setting_descriptor_map() -> dict[tuple[str, str], RuntimeSettingDescriptor]:
    descriptors: dict[tuple[str, str], RuntimeSettingDescriptor] = {}
    for executor in ENV.runtime_executor_descriptors():
        for setting in executor.settings or []:
            setting_id = _normalized_runtime_setting_id(setting.id)
            if setting_id is None:
                continue
            descriptors[(executor.id, setting_id)] = setting
    return descriptors


def _runtime_executor_titles() -> dict[str, str]:
    return {executor.id: executor.title for executor in ENV.runtime_executor_descriptors()}


def _available_runtime_setting_entries() -> list[tuple[str, list[tuple[str, RuntimeSettingDescriptor]]]]:
    entries: dict[str, list[tuple[str, RuntimeSettingDescriptor]]] = {}
    order: list[str] = []
    for executor in ENV.runtime_executor_descriptors():
        if executor.internal_only or not executor.available:
            continue
        for setting in executor.settings or []:
            setting_id = _normalized_runtime_setting_id(setting.id)
            if setting_id is None:
                continue
            if setting_id not in entries:
                entries[setting_id] = []
                order.append(setting_id)
            entries[setting_id].append((executor.id, setting))
    return [(setting_id, entries[setting_id]) for setting_id in order]


def _runtime_setting_supported_executors(setting_id: str) -> list[str]:
    normalized_setting_id = _normalized_runtime_setting_id(setting_id)
    if normalized_setting_id is None:
        return []
    for candidate_setting_id, descriptors in _available_runtime_setting_entries():
        if candidate_setting_id == normalized_setting_id:
            return [executor for executor, _ in descriptors]
    return []


def _runtime_setting_slash_command_id(setting_id: str) -> str:
    normalized_setting_id = _normalized_runtime_setting_id(setting_id) or setting_id
    if normalized_setting_id == "reasoning_effort":
        return "effort"
    command_id = normalized_setting_id.replace("_", "-")
    if command_id in {"cwd", "executor"}:
        return f"runtime-{command_id}"
    return command_id


def _slash_command_runtime_setting_id(command_id: str) -> str | None:
    normalized_command = _normalized_optional_text(command_id)
    if normalized_command is None:
        return None
    lowered_command = normalized_command.lower()
    for setting_id, _ in _available_runtime_setting_entries():
        if _runtime_setting_slash_command_id(setting_id) == lowered_command:
            return setting_id
    return None


def _runtime_setting_option_list(descriptors: list[tuple[str, RuntimeSettingDescriptor]]) -> list[str]:
    options: list[str] = []
    seen: set[str] = set()
    for _, descriptor in descriptors:
        for option in descriptor.options:
            lowered = option.lower()
            if lowered in seen:
                continue
            seen.add(lowered)
            options.append(option)
    return options


def _runtime_setting_allows_custom(descriptors: list[tuple[str, RuntimeSettingDescriptor]]) -> bool:
    return any(descriptor.allow_custom for _, descriptor in descriptors)


def _human_join(values: list[str]) -> str:
    cleaned = [value for value in values if value]
    if not cleaned:
        return ""
    if len(cleaned) == 1:
        return cleaned[0]
    if len(cleaned) == 2:
        return f"{cleaned[0]} or {cleaned[1]}"
    return f"{', '.join(cleaned[:-1])}, or {cleaned[-1]}"


def _runtime_setting_usage(command_id: str, options: list[str], *, allow_custom: bool, placeholder: str) -> str:
    if allow_custom:
        return f"/{command_id} [backend-default|{placeholder}]"
    usage_options = ["backend-default", *options] if options else ["backend-default"]
    return f"/{command_id} [{'|'.join(usage_options)}]"


def _runtime_setting_command_metadata(
    setting_id: str,
    descriptors: list[tuple[str, RuntimeSettingDescriptor]],
) -> tuple[str, str, list[str], str, str]:
    normalized_setting_id = _normalized_runtime_setting_id(setting_id) or setting_id
    if normalized_setting_id == "model":
        return (
            "Model Override",
            "Show or override the active agent model for this session.",
            ["runtime-model"],
            "sparkles",
            "model-id",
        )
    if normalized_setting_id == "reasoning_effort":
        return (
            "Reasoning Effort",
            "Show or override the active executor reasoning effort for this session.",
            ["thinking", "reasoning", "reasoning-effort"],
            "brain.head.profile",
            "effort",
        )

    primary_descriptor = descriptors[0][1]
    title = primary_descriptor.title.strip() or normalized_setting_id.replace("_", " ").title()
    description = f"Show or override the active {title.lower()} for this session."
    return (title, description, [], "slider.horizontal.3", normalized_setting_id.replace("_", "-"))


def _runtime_setting_title_text(setting_id: str, descriptor: RuntimeSettingDescriptor | None = None) -> str:
    if descriptor is not None and descriptor.title.strip():
        return descriptor.title.strip().lower()
    normalized_setting_id = _normalized_runtime_setting_id(setting_id) or setting_id
    for candidate_setting_id, descriptors in _available_runtime_setting_entries():
        if candidate_setting_id == normalized_setting_id and descriptors:
            candidate_title = descriptors[0][1].title.strip()
            if candidate_title:
                return candidate_title.lower()
            break
    return normalized_setting_id.replace("_", " ")


def _runtime_setting_slash_commands() -> list[SlashCommandDescriptor]:
    commands: list[SlashCommandDescriptor] = []
    for setting_id, descriptors in _available_runtime_setting_entries():
        command_id = _runtime_setting_slash_command_id(setting_id)
        title, description, aliases, symbol, placeholder = _runtime_setting_command_metadata(setting_id, descriptors)
        options = _runtime_setting_option_list(descriptors)
        allow_custom = _runtime_setting_allows_custom(descriptors)
        commands.append(
            SlashCommandDescriptor(
                id=command_id,
                title=title,
                description=description,
                usage=_runtime_setting_usage(command_id, options, allow_custom=allow_custom, placeholder=placeholder),
                group="Runtime",
                aliases=aliases,
                symbol=symbol,
                argument_kind="text" if allow_custom or not options else "enum",
                argument_options=[] if allow_custom else ["backend-default", *options],
                argument_placeholder=placeholder,
            )
        )
    return commands


def _canonical_runtime_setting_option(value: str, options: list[str]) -> str | None:
    normalized = value.strip()
    if not normalized:
        return None
    lowered = normalized.lower()
    for option in options:
        if option.lower() == lowered:
            return option
    return None


def _validated_runtime_setting_value(executor: str, setting_id: str, value: str | None) -> str | None:
    normalized_setting_id = _normalized_runtime_setting_id(setting_id)
    if normalized_setting_id is None:
        raise HTTPException(status_code=400, detail="runtime setting id is required")

    descriptor = _runtime_setting_descriptor_map().get((executor, normalized_setting_id))
    if descriptor is None:
        raise HTTPException(
            status_code=400,
            detail=f"runtime setting {executor}.{normalized_setting_id} is not supported by this backend",
        )

    normalized_value = _normalized_optional_text(value)
    if normalized_value is None:
        return None

    if executor == "codex" and normalized_setting_id == "reasoning_effort":
        return _validated_optional_codex_reasoning_effort(normalized_value)

    canonical_option = _canonical_runtime_setting_option(normalized_value, descriptor.options)
    if canonical_option is not None:
        return canonical_option
    if descriptor.allow_custom:
        return normalized_value

    allowed = ", ".join(descriptor.options)
    raise HTTPException(
        status_code=400,
        detail=f"runtime setting {executor}.{normalized_setting_id} must be one of: {allowed}",
    )


def _session_runtime_settings_map(row) -> dict[tuple[str, str], str]:
    values: dict[tuple[str, str], str] = {}
    raw_runtime_settings = str(row["runtime_settings_json"]).strip() if row is not None and row["runtime_settings_json"] else ""
    if raw_runtime_settings:
        try:
            payload = json.loads(raw_runtime_settings)
        except Exception:
            payload = []
        if isinstance(payload, list):
            for item in payload:
                try:
                    decoded = SessionRuntimeSettingValue.model_validate(item)
                except Exception:
                    continue
                normalized_setting_id = _normalized_runtime_setting_id(decoded.id)
                normalized_value = _normalized_optional_text(decoded.value)
                if normalized_setting_id is None or normalized_value is None:
                    continue
                values[(decoded.executor, normalized_setting_id)] = normalized_value

    legacy_values = {
        ("codex", "model"): _normalized_optional_text(
            str(row["codex_model"]).strip() if row is not None and row["codex_model"] else None
        ),
        ("codex", "reasoning_effort"): _validated_optional_codex_reasoning_effort(
            str(row["codex_reasoning_effort"]).strip().lower()
            if row is not None and row["codex_reasoning_effort"]
            else None
        ),
        ("claude", "model"): _normalized_optional_text(
            str(row["claude_model"]).strip() if row is not None and row["claude_model"] else None
        ),
    }
    for key, normalized_value in legacy_values.items():
        if normalized_value is None:
            values.pop(key, None)
        else:
            values[key] = normalized_value
    return values


def _session_runtime_settings_response(values: dict[tuple[str, str], str]) -> list[SessionRuntimeSettingValue]:
    items: list[SessionRuntimeSettingValue] = []
    seen: set[tuple[str, str]] = set()
    for executor in ENV.runtime_executor_descriptors():
        for setting in executor.settings or []:
            setting_id = _normalized_runtime_setting_id(setting.id)
            if setting_id is None:
                continue
            key = (executor.id, setting_id)
            seen.add(key)
            items.append(SessionRuntimeSettingValue(executor=executor.id, id=setting_id, value=values.get(key)))
    for executor, setting_id in sorted(values):
        key = (executor, setting_id)
        if key in seen:
            continue
        items.append(SessionRuntimeSettingValue(executor=executor, id=setting_id, value=values[key]))
    return items


def _serialized_runtime_settings(values: dict[tuple[str, str], str]) -> str | None:
    if not values:
        return None
    payload = [
        {"executor": executor, "id": setting_id, "value": values[(executor, setting_id)]}
        for executor, setting_id in sorted(values)
    ]
    return json.dumps(payload, separators=(",", ":"))


def _session_context_runtime_settings_map(context: SessionContextResponse) -> dict[tuple[str, str], str]:
    values: dict[tuple[str, str], str] = {}
    for item in context.runtime_settings:
        setting_id = _normalized_runtime_setting_id(item.id)
        setting_value = _normalized_optional_text(item.value)
        if setting_id is None or setting_value is None:
            continue
        values[(item.executor, setting_id)] = setting_value
    return values


def _session_context_response(session_id: str) -> SessionContextResponse:
    row = RUN_STORE.get_session_context(session_id)
    raw_executor = str(row["executor"]).strip() if row is not None and row["executor"] else ""
    raw_working_directory = str(row["working_directory"]).strip() if row is not None and row["working_directory"] else ""
    runtime_settings = _session_runtime_settings_map(row)
    codex_model = runtime_settings.get(("codex", "model"), "")
    codex_reasoning_effort = runtime_settings.get(("codex", "reasoning_effort"), "")
    claude_model = runtime_settings.get(("claude", "model"), "")
    latest_run_pending_human_unblock: HumanUnblockRequest | None = None
    if row is not None and row["latest_run_pending_human_unblock_json"]:
        try:
            latest_run_pending_human_unblock = HumanUnblockRequest.model_validate_json(
                row["latest_run_pending_human_unblock_json"]
            )
        except Exception:
            latest_run_pending_human_unblock = None

    effective_executor = raw_executor if raw_executor in {"local", "codex", "claude"} else ENV.default_executor
    effective_working_directory = raw_working_directory or None
    try:
        resolved_working_directory = str(ENV.resolve_workdir(effective_working_directory))
    except ValueError:
        effective_working_directory = None
        resolved_working_directory = str(ENV.default_workdir)

    return SessionContextResponse(
        session_id=session_id,
        executor=effective_executor,  # type: ignore[arg-type]
        working_directory=effective_working_directory,
        runtime_settings=_session_runtime_settings_response(runtime_settings),
        codex_model=codex_model or None,
        codex_reasoning_effort=codex_reasoning_effort or None,  # type: ignore[arg-type]
        claude_model=claude_model or None,
        resolved_working_directory=resolved_working_directory,
        latest_run_id=str(row["latest_run_id"]).strip() if row is not None and row["latest_run_id"] else None,
        latest_run_status=str(row["latest_run_status"]).strip() if row is not None and row["latest_run_status"] else None,
        latest_run_summary=str(row["latest_run_summary"]).strip() if row is not None and row["latest_run_summary"] else None,
        latest_run_updated_at=str(row["latest_run_updated_at"]).strip() if row is not None and row["latest_run_updated_at"] else None,
        latest_run_pending_human_unblock=latest_run_pending_human_unblock,
        updated_at=str(row["updated_at"]).strip() if row is not None and row["updated_at"] else None,
    )


def _update_session_context(
    session_id: str,
    *,
    executor=_UNSET,
    working_directory=_UNSET,
    runtime_settings=_UNSET,
    codex_model=_UNSET,
    codex_reasoning_effort=_UNSET,
    claude_model=_UNSET,
) -> SessionContextResponse:
    current = RUN_STORE.get_session_context(session_id)
    next_executor = str(current["executor"]).strip() if current is not None and current["executor"] else None
    next_working_directory = (
        str(current["working_directory"]).strip()
        if current is not None and current["working_directory"]
        else None
    )
    next_codex_model = str(current["codex_model"]).strip() if current is not None and current["codex_model"] else None
    next_codex_reasoning_effort = (
        str(current["codex_reasoning_effort"]).strip().lower()
        if current is not None and current["codex_reasoning_effort"]
        else None
    )
    next_claude_model = str(current["claude_model"]).strip() if current is not None and current["claude_model"] else None
    next_runtime_settings = _session_runtime_settings_map(current)

    if executor is not _UNSET:
        next_executor = executor
    if working_directory is not _UNSET:
        next_working_directory = working_directory
    if codex_model is not _UNSET:
        next_codex_model = codex_model
        if next_codex_model is None:
            next_runtime_settings.pop(("codex", "model"), None)
        else:
            next_runtime_settings[("codex", "model")] = next_codex_model
    if codex_reasoning_effort is not _UNSET:
        next_codex_reasoning_effort = codex_reasoning_effort
        if next_codex_reasoning_effort is None:
            next_runtime_settings.pop(("codex", "reasoning_effort"), None)
        else:
            next_runtime_settings[("codex", "reasoning_effort")] = next_codex_reasoning_effort
    if claude_model is not _UNSET:
        next_claude_model = claude_model
        if next_claude_model is None:
            next_runtime_settings.pop(("claude", "model"), None)
        else:
            next_runtime_settings[("claude", "model")] = next_claude_model
    if runtime_settings is not _UNSET:
        next_runtime_settings = {}
        for item in runtime_settings:
            key = (item.executor, _normalized_runtime_setting_id(item.id) or item.id)
            if item.value is None:
                next_runtime_settings.pop(key, None)
            else:
                next_runtime_settings[key] = item.value

    next_codex_model = next_runtime_settings.get(("codex", "model"))
    next_codex_reasoning_effort = next_runtime_settings.get(("codex", "reasoning_effort"))
    next_claude_model = next_runtime_settings.get(("claude", "model"))

    RUN_STORE.upsert_session_context(
        session_id,
        executor=next_executor,
        working_directory=next_working_directory,
        runtime_settings_json=_serialized_runtime_settings(next_runtime_settings),
        codex_model=next_codex_model,
        codex_reasoning_effort=next_codex_reasoning_effort,
        claude_model=next_claude_model,
    )
    return _session_context_response(session_id)


def _validated_session_context_executor(executor: RunExecutorName) -> RunExecutorName:
    if executor == "local":
        return "local"
    if executor in ENV.available_agent_executors():
        return executor
    raise HTTPException(status_code=400, detail=f"executor {executor} is not available on this backend")


def _normalized_optional_text(value: str | None) -> str | None:
    normalized = (value or "").strip()
    return normalized or None


def _validated_optional_codex_reasoning_effort(value: str | None) -> str | None:
    normalized = (value or "").strip().lower()
    if not normalized:
        return None
    if normalized not in CODEX_REASONING_EFFORT_OPTIONS:
        allowed = ", ".join(CODEX_REASONING_EFFORT_OPTIONS)
        raise HTTPException(status_code=400, detail=f"codex reasoning effort must be one of: {allowed}")
    return normalized


def _slash_command_catalog() -> list[SlashCommandDescriptor]:
    executor_options = _slash_command_executor_options()
    executor_usage = "/executor"
    if executor_options:
        executor_usage = f"/executor [{'|'.join(executor_options)}]"

    commands = [
        SlashCommandDescriptor(
            id="cwd",
            title="Working Directory",
            description="Show or change the working directory used for new runs.",
            usage="/cwd [path]",
            group="Runtime",
            aliases=["pwd", "workdir"],
            symbol="arrow.triangle.branch",
            argument_kind="path",
            argument_placeholder="path",
        ),
        SlashCommandDescriptor(
            id="executor",
            title="Executor",
            description="Show or switch the active executor.",
            usage=executor_usage,
            group="Runtime",
            aliases=["exec", "agent"],
            symbol="bolt.horizontal.circle",
            argument_kind="enum" if executor_options else "text",
            argument_options=executor_options,
            argument_placeholder="executor",
        ),
    ]
    return [*commands, *_runtime_setting_slash_commands()]


def _slash_command_executor_options() -> list[str]:
    values = list(ENV.available_agent_executors())
    if "local" not in values:
        values.append("local")
    return values


def _execute_slash_command(
    session_id: str,
    *,
    command_id: str,
    arguments: str | None,
) -> SlashCommandExecutionResponse:
    normalized_command = command_id.strip().lower()
    normalized_arguments = (arguments or "").strip()

    if normalized_command == "cwd":
        if not normalized_arguments:
            context = _session_context_response(session_id)
            return SlashCommandExecutionResponse(
                command_id="cwd",
                message=_working_directory_status_message(context),
                session_context=context,
            )

        try:
            resolved_working_directory = str(ENV.resolve_workdir(normalized_arguments))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

        context = _update_session_context(
            session_id,
            working_directory=resolved_working_directory,
        )
        return SlashCommandExecutionResponse(
            command_id="cwd",
            message=f"Working directory set to {context.resolved_working_directory}.",
            session_context=context,
        )

    if normalized_command == "executor":
        if not normalized_arguments:
            context = _session_context_response(session_id)
            return SlashCommandExecutionResponse(
                command_id="executor",
                message=_executor_status_message(context),
                session_context=context,
            )

        requested_executor = normalized_arguments.lower()
        if requested_executor not in {"local", "codex", "claude"}:
            raise HTTPException(status_code=400, detail=f"executor {requested_executor} is not available on this backend")
        context = _update_session_context(
            session_id,
            executor=_validated_session_context_executor(requested_executor),  # type: ignore[arg-type]
        )
        return SlashCommandExecutionResponse(
            command_id="executor",
            message=_executor_status_message(context),
            session_context=context,
        )

    runtime_setting_id = _slash_command_runtime_setting_id(normalized_command)
    if runtime_setting_id is not None:
        context = _session_context_response(session_id)
        if not normalized_arguments:
            return SlashCommandExecutionResponse(
                command_id=normalized_command,
                message=_runtime_setting_status_message(context, runtime_setting_id),
                session_context=context,
            )

        if (context.executor, runtime_setting_id) not in _runtime_setting_descriptor_map():
            supported_titles = [
                _runtime_executor_titles().get(executor, executor)
                for executor in _runtime_setting_supported_executors(runtime_setting_id)
            ]
            raise HTTPException(
                status_code=400,
                detail=(
                    f"{_runtime_setting_title_text(runtime_setting_id)} overrides apply only when "
                    f"the session executor is {_human_join(supported_titles)}"
                ),
            )

        requested_value = normalized_arguments
        if requested_value.lower() in {"backend-default", "default", "auto"}:
            requested_value = ""

        next_runtime_settings = _session_context_runtime_settings_map(context)
        validated_value = _validated_runtime_setting_value(
            context.executor,
            runtime_setting_id,
            requested_value,
        )
        key = (context.executor, runtime_setting_id)
        if validated_value is None:
            next_runtime_settings.pop(key, None)
        else:
            next_runtime_settings[key] = validated_value
        context = _update_session_context(
            session_id,
            runtime_settings=[
                SessionRuntimeSettingValue(executor=executor, id=setting_id, value=value)
                for (executor, setting_id), value in sorted(next_runtime_settings.items())
            ],
        )
        return SlashCommandExecutionResponse(
            command_id=normalized_command,
            message=_runtime_setting_status_message(context, runtime_setting_id),
            session_context=context,
        )

    raise HTTPException(status_code=404, detail=f"unknown slash command {normalized_command}")


def _working_directory_status_message(context: SessionContextResponse) -> str:
    current = context.resolved_working_directory.strip()
    if current:
        return f"Working directory: {current}"
    return "Working directory follows the backend default."


def _executor_status_message(context: SessionContextResponse) -> str:
    options = ", ".join(_slash_command_executor_options())
    return f"Executor: {context.executor}. Available: {options}."


def _runtime_setting_status_message(context: SessionContextResponse, setting_id: str) -> str:
    normalized_setting_id = _normalized_runtime_setting_id(setting_id)
    if normalized_setting_id is None:
        return "Runtime setting is not available."

    executor_titles = _runtime_executor_titles()
    descriptor = _runtime_setting_descriptor_map().get((context.executor, normalized_setting_id))
    if descriptor is None:
        supported_titles = [
            executor_titles.get(executor, executor) for executor in _runtime_setting_supported_executors(normalized_setting_id)
        ]
        if not supported_titles:
            return "Runtime setting is not available."
        return (
            f"{_runtime_setting_title_text(normalized_setting_id)} overrides apply when "
            f"the session executor is {_human_join(supported_titles)}."
        )

    value = _session_context_runtime_settings_map(context).get((context.executor, normalized_setting_id))
    if value is None:
        if context.executor == "codex" and normalized_setting_id == "reasoning_effort":
            value = _validated_optional_codex_reasoning_effort(descriptor.value)
        else:
            value = _normalized_optional_text(descriptor.value)
    executor_title = executor_titles.get(context.executor, context.executor.title())
    return f"{executor_title} {_runtime_setting_title_text(normalized_setting_id, descriptor)}: {value or 'backend default'}."


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


def _merge_voice_utterance(draft_text: str | None, transcript_text: str) -> str:
    parts = [
        (draft_text or "").strip(),
        transcript_text.strip(),
    ]
    return "\n\n".join(part for part in parts if part)


def _parse_audio_attachments(raw_attachments: str | None) -> list[ChatArtifact]:
    payload = (raw_attachments or "").strip()
    if not payload:
        return []
    try:
        decoded = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail="attachments_json must be valid JSON") from exc
    if not isinstance(decoded, list):
        raise HTTPException(status_code=400, detail="attachments_json must be a JSON array")
    try:
        return [ChatArtifact.model_validate(item) for item in decoded]
    except Exception as exc:
        raise HTTPException(status_code=400, detail="attachments_json contains an invalid attachment") from exc


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


def _pairing_server_urls(payload: dict[str, object]) -> list[str]:
    seen: set[str] = set()
    urls: list[str] = []

    for raw in payload.get("server_urls", []) if isinstance(payload.get("server_urls"), list) else []:
        if not isinstance(raw, str):
            continue
        candidate = raw.strip().rstrip("/")
        if not candidate or candidate in seen:
            continue
        seen.add(candidate)
        urls.append(candidate)

    primary = str(payload.get("server_url", "")).strip().rstrip("/")
    if primary and primary not in seen:
        urls.insert(0, primary)

    return urls


def _write_pairing_file(payload: dict[str, object]) -> None:
    ENV.pairing_file.parent.mkdir(parents=True, exist_ok=True)
    ENV.pairing_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _rotate_pair_code(payload: dict[str, object]) -> None:
    payload["pair_code"] = secrets.token_urlsafe(10)
    payload["pair_code_expires_at"] = (
        datetime.now(timezone.utc) + timedelta(minutes=ENV.pair_code_ttl_min)
    ).isoformat().replace("+00:00", "Z")
    _write_pairing_file(payload)


def _pair_credentials_response(
    pairing: dict[str, object],
    *,
    api_token: str,
    refresh_token: str,
    session_id: str,
) -> PairExchangeResponse:
    server_urls = _pairing_server_urls(pairing)
    return PairExchangeResponse(
        api_token=api_token,
        refresh_token=refresh_token,
        session_id=session_id,
        security_mode=ENV.security_mode,  # type: ignore[arg-type]
        server_url=server_urls[0] if server_urls else str(pairing.get("server_url", "")).strip() or None,
        server_urls=server_urls,
    )


def _extract_bearer_token(auth_header: str) -> str:
    prefix = "Bearer "
    if not auth_header.startswith(prefix):
        return ""
    return auth_header[len(prefix):].strip()


def _hash_api_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _paired_client_records(payload: dict[str, object]) -> list[dict[str, str]]:
    raw = payload.get("paired_clients")
    if not isinstance(raw, list):
        return []

    records: list[dict[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        token_hash = str(item.get("token_sha256", "")).strip()
        if not token_hash:
            continue
        records.append(
            {
                "token_sha256": token_hash,
                "refresh_token_sha256": str(item.get("refresh_token_sha256", "")).strip(),
                "session_id": str(item.get("session_id", "")).strip(),
                "issued_at": str(item.get("issued_at", "")).strip(),
                "refreshed_at": str(item.get("refreshed_at", "")).strip(),
            }
        )
    return records


def _paired_client_record_index_for_hashed_token(
    records: list[dict[str, str]],
    *,
    field: str,
    token: str,
) -> int | None:
    token_hash = _hash_api_token(token)
    for index, record in enumerate(records):
        candidate = record.get(field, "")
        if candidate and secrets.compare_digest(candidate, token_hash):
            return index
    return None


def _pairing_token_matches(payload: dict[str, object], token: str) -> bool:
    return _paired_client_record_index_for_hashed_token(
        _paired_client_records(payload),
        field="token_sha256",
        token=token,
    ) is not None


def _is_authorized_api_token(auth_header: str, pairing: dict[str, object]) -> bool:
    token = _extract_bearer_token(auth_header)
    if not token:
        return False
    if ENV.api_token and secrets.compare_digest(token, ENV.api_token):
        return True
    return _pairing_token_matches(pairing, token)


def _issue_paired_client_credentials(payload: dict[str, object], *, session_id: str) -> tuple[str, str]:
    token = secrets.token_urlsafe(32)
    refresh_token = secrets.token_urlsafe(32)
    records = _paired_client_records(payload)
    records.append(
        {
            "token_sha256": _hash_api_token(token),
            "refresh_token_sha256": _hash_api_token(refresh_token),
            "session_id": session_id,
            "issued_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "refreshed_at": "",
        }
    )
    payload["paired_clients"] = records[-MAX_PAIRED_CLIENT_TOKENS:]
    _write_pairing_file(payload)
    return token, refresh_token


def _refresh_paired_client_credentials(
    payload: dict[str, object],
    *,
    auth_header: str,
    refresh_token: str | None,
    session_id: str | None,
) -> tuple[str, str, str]:
    records = _paired_client_records(payload)
    normalized_refresh_token = (refresh_token or "").strip()
    normalized_auth_token = _extract_bearer_token(auth_header)

    if normalized_refresh_token:
        record_index = _paired_client_record_index_for_hashed_token(
            records,
            field="refresh_token_sha256",
            token=normalized_refresh_token,
        )
        if record_index is None:
            raise HTTPException(status_code=401, detail="missing or invalid refresh token")

        record = records[record_index]
        next_api_token = secrets.token_urlsafe(32)
        record["token_sha256"] = _hash_api_token(next_api_token)
        record["refreshed_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        effective_session_id = record.get("session_id", "").strip() or session_id or "iphone-app"
        records[record_index] = record
        payload["paired_clients"] = records[-MAX_PAIRED_CLIENT_TOKENS:]
        _write_pairing_file(payload)
        return next_api_token, normalized_refresh_token, effective_session_id

    if not normalized_auth_token:
        raise HTTPException(status_code=401, detail="missing refresh token")
    if ENV.api_token and secrets.compare_digest(normalized_auth_token, ENV.api_token):
        raise HTTPException(status_code=403, detail="refresh bootstrap is only available for paired phones")

    record_index = _paired_client_record_index_for_hashed_token(
        records,
        field="token_sha256",
        token=normalized_auth_token,
    )
    if record_index is None:
        raise HTTPException(status_code=401, detail="missing or invalid bearer token")

    record = records[record_index]
    next_refresh_token = secrets.token_urlsafe(32)
    record["refresh_token_sha256"] = _hash_api_token(next_refresh_token)
    record["refreshed_at"] = record.get("refreshed_at", "").strip()
    if session_id and not record.get("session_id", "").strip():
        record["session_id"] = session_id
    effective_session_id = record.get("session_id", "").strip() or session_id or "iphone-app"
    records[record_index] = record
    payload["paired_clients"] = records[-MAX_PAIRED_CLIENT_TOKENS:]
    _write_pairing_file(payload)
    return normalized_auth_token, next_refresh_token, effective_session_id


def _enforce_pair_rate_limit(client_id: str) -> None:
    now = time.monotonic()
    with PAIR_ATTEMPTS_LOCK:
        attempts = PAIR_ATTEMPTS.get(client_id, [])
        attempts = [t for t in attempts if now - t <= 60.0]
        if len(attempts) >= ENV.pair_attempt_limit_per_min:
            raise HTTPException(status_code=429, detail="too many pairing attempts, try again soon")
        attempts.append(now)
        PAIR_ATTEMPTS[client_id] = attempts
