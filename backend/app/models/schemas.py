from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field, model_validator


class UtteranceRequest(BaseModel):
    session_id: str = Field(min_length=1)
    utterance_text: str = Field(min_length=1)
    mode: Literal["assistant", "execute"] = "execute"
    executor: Literal["local", "codex"] = "local"
    working_directory: str | None = None


class Action(BaseModel):
    type: Literal["write_file", "run_command"]
    path: str | None = None
    content: str | None = None
    command: str | None = None
    timeout_sec: int = 30

    @model_validator(mode="after")
    def validate_fields(self) -> "Action":
        if self.type == "write_file":
            if not self.path:
                raise ValueError("write_file requires path")
            if self.content is None:
                raise ValueError("write_file requires content")
        if self.type == "run_command" and not self.command:
            raise ValueError("run_command requires command")
        return self


class ActionPlan(BaseModel):
    version: Literal["1.0"] = "1.0"
    goal: str
    actions: list[Action]


class ExecutionEvent(BaseModel):
    type: Literal[
        "chat.message",
        "log.message",
        "action.started",
        "action.stdout",
        "action.stderr",
        "action.completed",
        "assistant.message",
        "run.completed",
        "run.failed",
        "run.cancelled",
    ]
    action_index: int | None = None
    message: str
    event_id: str | None = None
    created_at: str | None = None


class ChatSection(BaseModel):
    title: str
    body: str


class AgendaItem(BaseModel):
    start: str
    end: str
    title: str
    calendar: str
    location: str | None = None


class ChatEnvelope(BaseModel):
    type: Literal["assistant_response"] = "assistant_response"
    version: Literal["1.0"] = "1.0"
    message_id: str | None = None
    created_at: str | None = None
    summary: str
    sections: list[ChatSection] = Field(default_factory=list)
    agenda_items: list[AgendaItem] = Field(default_factory=list)
    artifacts: list["ChatArtifact"] = Field(default_factory=list)


class ChatArtifact(BaseModel):
    type: Literal["image", "file", "code"]
    title: str
    path: str | None = None
    mime: str | None = None
    url: str | None = None


class ActionResult(BaseModel):
    success: bool
    exit_code: int | None = None
    stdout: str = ""
    stderr: str = ""
    details: str = ""


class RunRecord(BaseModel):
    run_id: str
    session_id: str
    executor: Literal["local", "codex"] = "local"
    utterance_text: str
    working_directory: str | None = None
    status: Literal["running", "completed", "failed", "rejected", "cancelled"]
    plan: ActionPlan | None = None
    events: list[ExecutionEvent] = Field(default_factory=list)
    summary: str
    created_at: str | None = None
    updated_at: str | None = None


class RunSummary(BaseModel):
    run_id: str
    session_id: str
    executor: Literal["local", "codex"] = "local"
    utterance_text: str
    status: Literal["running", "completed", "failed", "rejected", "cancelled"]
    summary: str
    updated_at: str | None = None
    working_directory: str | None = None


class RunDiagnostics(BaseModel):
    run_id: str
    status: str
    summary: str
    event_count: int
    event_type_counts: dict[str, int]
    has_stderr: bool
    last_error: str | None = None
    created_at: str | None = None
    updated_at: str | None = None


class UtteranceResponse(BaseModel):
    run_id: str
    status: Literal["accepted", "rejected"]
    message: str


class AudioRunResponse(UtteranceResponse):
    transcript_text: str


class PairExchangeRequest(BaseModel):
    pair_code: str = Field(min_length=4)
    session_id: str | None = None


class PairExchangeResponse(BaseModel):
    api_token: str
    session_id: str
    security_mode: Literal["safe", "full-access"]
