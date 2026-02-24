from __future__ import annotations

import json
import mimetypes
import os
import secrets
import subprocess
import threading
import time
import uuid
from queue import Empty, Queue
from pathlib import Path
from typing import Iterator, Literal

from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

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
ACTIVE_PROCS_LOCK = threading.Lock()
ACTIVE_PROCS: dict[str, subprocess.Popen[str]] = {}
RUN_CANCELLED: set[str] = set()
DEFAULT_WORKDIR = Path(
    os.getenv("VOICE_AGENT_DEFAULT_WORKDIR", str(Path.home()))
).expanduser().resolve()
DEFAULT_WORKDIR.mkdir(parents=True, exist_ok=True)
CODEX_TIMEOUT_SEC = int(os.getenv("VOICE_AGENT_CODEX_TIMEOUT_SEC", "900"))
CODEX_USE_CONTEXT = os.getenv("VOICE_AGENT_CODEX_USE_CONTEXT", "true").strip().lower() not in {
    "0",
    "false",
    "no",
    "off",
}
CODEX_CONTEXT_FILE = os.getenv("VOICE_AGENT_CODEX_CONTEXT_FILE", "AGENT_CONTEXT.md").strip()
MAX_AUDIO_MB = float(os.getenv("VOICE_AGENT_MAX_AUDIO_MB", "20"))
MAX_AUDIO_BYTES = int(MAX_AUDIO_MB * 1024 * 1024)
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
    workdir = _resolve_workdir(request.working_directory)
    if request.executor == "codex":
        _store_run(
            RunRecord(
                run_id=run_id,
                session_id=request.session_id,
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
            args=(run_id, request.utterance_text, workdir),
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
    audio: UploadFile = File(...),
    executor: Literal["local", "codex"] = Form("codex"),
    mode: Literal["assistant", "execute"] = Form("execute"),
    transcript_hint: str | None = Form(None),
    working_directory: str | None = Form(None),
) -> AudioRunResponse:
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
    result = create_utterance(
        UtteranceRequest(
            session_id=session_id,
            utterance_text=transcript_text,
            executor=executor,
            mode=mode,
            working_directory=working_directory,
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


@app.get("/v1/files")
def get_file(path: str = Query(..., min_length=1)) -> FileResponse:
    target = Path(path.strip()).expanduser()
    if not target.is_absolute():
        target = (DEFAULT_WORKDIR / target).resolve()
    else:
        target = target.resolve()
    if not target.exists() or not target.is_file():
        raise HTTPException(status_code=404, detail="file not found")
    media_type, _ = mimetypes.guess_type(str(target))
    return FileResponse(str(target), media_type=media_type or "application/octet-stream")


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


def _run_codex(run_id: str, prompt: str, workdir: Path) -> None:
    codex_executor = CodexExecutor(workdir)
    codex_prompt = _build_codex_prompt(prompt)
    _append_event(
        run_id,
        ExecutionEvent(
            type="action.started",
            action_index=0,
            message=f"starting codex exec (cwd={workdir})",
        ),
    )
    try:
        proc = codex_executor.start(codex_prompt)
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

    with ACTIVE_PROCS_LOCK:
        ACTIVE_PROCS[run_id] = proc

    assert proc.stdout is not None
    line_queue: Queue[str | None] = Queue()

    def _drain_stdout() -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            line_queue.put(line.rstrip())
        line_queue.put(None)

    reader = threading.Thread(target=_drain_stdout, daemon=True)
    reader.start()

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
                _append_event(
                    run_id,
                    ExecutionEvent(type="action.stdout", action_index=0, message=message),
                )
                structured = _codex_structured_message(message, prompt)
                if structured:
                    _append_event(
                        run_id,
                        ExecutionEvent(type="assistant.message", action_index=0, message=structured),
                    )
        else:
            if proc.poll() is not None:
                break

        if _is_cancelled(run_id):
            cancelled = True
            break
        if time.monotonic() > deadline:
            timed_out = True
            break

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
        return
    if timed_out:
        summary = f"Run timed out after {CODEX_TIMEOUT_SEC}s"
        _append_event(run_id, ExecutionEvent(type="run.failed", message=summary))
        _set_run_status(run_id, "failed", summary)
        return

    success = exit_code == 0
    summary = "Run completed successfully" if success else "Run failed"
    _append_event(
        run_id,
        ExecutionEvent(type="run.completed" if success else "run.failed", message=summary),
    )
    _set_run_status(run_id, "completed" if success else "failed", summary)


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
        requested.mkdir(parents=True, exist_ok=True)
        return requested
    return DEFAULT_WORKDIR


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
    if text.startswith("**") and text.endswith("**"):
        return None
    if text.isdigit():
        return None
    return text


def _is_cancelled(run_id: str) -> bool:
    with RUNS_LOCK:
        return run_id in RUN_CANCELLED


def _build_codex_prompt(user_prompt: str) -> str:
    if not CODEX_USE_CONTEXT:
        return user_prompt
    context = _load_codex_context()
    if not context:
        return user_prompt
    return (
        "You are running through MOBaiLE.\n\n"
        "MOBaiLE runtime context:\n"
        f"{context}\n\n"
        "User request:\n"
        f"{user_prompt}"
    )


def _load_codex_context() -> str:
    path = Path(CODEX_CONTEXT_FILE)
    if not path.is_absolute():
        path = (Path(__file__).resolve().parent.parent / path).resolve()
    if not path.exists() or not path.is_file():
        return ""
    return path.read_text(encoding="utf-8").strip()
