from __future__ import annotations

import json
import os
import secrets
import threading
import time
import uuid
from pathlib import Path
from typing import Iterator, Literal

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, StreamingResponse

from app.executors.codex_executor import CodexExecutor
from app.executors.local_executor import LocalExecutor
from app.models.schemas import (
    ActionPlan,
    AudioRunResponse,
    ExecutionEvent,
    RunRecord,
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
EXECUTOR = LocalExecutor(Path(__file__).resolve().parent.parent / "sandbox")
CODEX_EXECUTOR = CodexExecutor(Path(__file__).resolve().parents[2])
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


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.middleware("http")
async def require_api_token(request: Request, call_next):
    if not request.url.path.startswith("/v1/"):
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


@app.post("/v1/utterances", response_model=UtteranceResponse)
def create_utterance(request: UtteranceRequest) -> UtteranceResponse:
    run_id = str(uuid.uuid4())
    if request.executor == "codex":
        _store_run(
            RunRecord(
                run_id=run_id,
                session_id=request.session_id,
                utterance_text=request.utterance_text,
                status="running",
                plan=None,
                events=[],
                summary="Run started",
            )
        )
        threading.Thread(
            target=_run_codex,
            args=(run_id, request.utterance_text),
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
            utterance_text=request.utterance_text,
            status="running",
            plan=plan,
            events=[],
            summary="Run started",
        )
    )
    threading.Thread(target=_run_local_plan, args=(run_id, plan), daemon=True).start()
    return UtteranceResponse(run_id=run_id, status="accepted", message="Run started")


@app.post("/v1/audio", response_model=AudioRunResponse)
async def create_audio_run(
    session_id: str = Form(...),
    audio: UploadFile = File(...),
    executor: Literal["local", "codex"] = Form("codex"),
    mode: Literal["assistant", "execute"] = Form("execute"),
    transcript_hint: str | None = Form(None),
) -> AudioRunResponse:
    audio_bytes = await audio.read()
    try:
        transcript_text = TRANSCRIBER.transcribe(
            audio_bytes=audio_bytes,
            filename=audio.filename or "audio",
            text_hint=transcript_hint,
        )
    except TranscriptionError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    result = create_utterance(
        UtteranceRequest(
            session_id=session_id,
            utterance_text=transcript_text,
            executor=executor,
            mode=mode,
        )
    )
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

            done = status in {"completed", "failed", "rejected"}
            if done and not pending_events:
                break

            now = time.monotonic()
            if now - heartbeat_at > 10:
                heartbeat_at = now
                yield ": keep-alive\n\n"
            time.sleep(0.25)

    return StreamingResponse(event_stream(), media_type="text/event-stream")


def _run_local_plan(run_id: str, plan: ActionPlan) -> None:
    success = _execute_plan(run_id, plan)
    summary = "Run completed successfully" if success else "Run failed"
    _append_event(
        run_id,
        ExecutionEvent(
            type="run.completed" if success else "run.failed",
            message=summary,
        ),
    )
    _set_run_status(run_id, "completed" if success else "failed", summary)


def _run_codex(run_id: str, prompt: str) -> None:
    _append_event(
        run_id,
        ExecutionEvent(type="action.started", action_index=0, message="starting codex exec"),
    )
    try:
        proc = CODEX_EXECUTOR.start(prompt)
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
        return

    assert proc.stdout is not None
    for line in proc.stdout:
        message = line.rstrip()
        if message:
            _append_event(
                run_id,
                ExecutionEvent(type="action.stdout", action_index=0, message=message),
            )

    exit_code = proc.wait()
    _append_event(
        run_id,
        ExecutionEvent(
            type="action.completed",
            action_index=0,
            message=f"codex exec finished (exit={exit_code})",
        ),
    )
    success = exit_code == 0
    summary = "Run completed successfully" if success else "Run failed"
    _append_event(
        run_id,
        ExecutionEvent(type="run.completed" if success else "run.failed", message=summary),
    )
    _set_run_status(run_id, "completed" if success else "failed", summary)


def _execute_plan(run_id: str, plan: ActionPlan) -> bool:
    for idx, action in enumerate(plan.actions):
        _append_event(
            run_id,
            ExecutionEvent(
                type="action.started",
                action_index=idx,
                message=f"starting {action.type}",
            )
        )
        result = EXECUTOR.execute(action)
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
        RUN_STORE.upsert(run)


def _append_event(run_id: str, event: ExecutionEvent) -> None:
    with RUNS_LOCK:
        run = RUNS.get(run_id)
        if run is None:
            return
        run.events.append(event)
        RUN_STORE.upsert(run)


def _set_run_status(run_id: str, status: str, summary: str) -> None:
    with RUNS_LOCK:
        run = RUNS.get(run_id)
        if run is None:
            return
        run.status = status
        run.summary = summary
        RUN_STORE.upsert(run)
