from __future__ import annotations

from fastapi import HTTPException

from app.models.schemas import (
    HumanUnblockRequest,
    RunExecutorName,
    SessionContextResponse,
    SessionContextUpdateRequest,
    SessionRuntimeSettingValue,
)
from app.runtime_environment import RuntimeEnvironment
from app.runtime_settings_catalog import RuntimeSettingKey, RuntimeSettingsCatalog
from app.session_runtime_state import SessionRuntimeState
from app.storage import RunStore

_UNSET = object()


class SessionContextService:
    def __init__(
        self,
        env: RuntimeEnvironment,
        run_store: RunStore,
        runtime_settings: RuntimeSettingsCatalog,
    ) -> None:
        self._env = env
        self._run_store = run_store
        self._runtime_settings = runtime_settings
        self._session_runtime_state = SessionRuntimeState(env, runtime_settings)

    def session_context_response(self, session_id: str) -> SessionContextResponse:
        row = self._run_store.get_session_context(session_id)
        raw_executor = str(row["executor"]).strip() if row is not None and row["executor"] else ""
        raw_working_directory = (
            str(row["working_directory"]).strip()
            if row is not None and row["working_directory"]
            else ""
        )
        runtime_settings = self._session_runtime_state.load_row_values(row)
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

        effective_executor = (
            raw_executor if raw_executor in {"local", "codex", "claude"} else self._env.default_executor
        )
        effective_working_directory = raw_working_directory or None
        try:
            resolved_working_directory = str(self._env.resolve_workdir(effective_working_directory))
        except ValueError:
            effective_working_directory = None
            resolved_working_directory = str(self._env.default_workdir)

        return SessionContextResponse(
            session_id=session_id,
            executor=effective_executor,  # type: ignore[arg-type]
            working_directory=effective_working_directory,
            runtime_settings=self.response_items(runtime_settings),
            codex_model=codex_model or None,
            codex_reasoning_effort=codex_reasoning_effort or None,  # type: ignore[arg-type]
            claude_model=claude_model or None,
            resolved_working_directory=resolved_working_directory,
            latest_run_id=str(row["latest_run_id"]).strip() if row is not None and row["latest_run_id"] else None,
            latest_run_status=(
                str(row["latest_run_status"]).strip() if row is not None and row["latest_run_status"] else None
            ),
            latest_run_summary=(
                str(row["latest_run_summary"]).strip() if row is not None and row["latest_run_summary"] else None
            ),
            latest_run_updated_at=(
                str(row["latest_run_updated_at"]).strip()
                if row is not None and row["latest_run_updated_at"]
                else None
            ),
            latest_run_pending_human_unblock=latest_run_pending_human_unblock,
            updated_at=str(row["updated_at"]).strip() if row is not None and row["updated_at"] else None,
        )

    def apply_session_context_patch(
        self,
        session_id: str,
        payload: SessionContextUpdateRequest,
    ) -> SessionContextResponse:
        executor = _UNSET
        working_directory = _UNSET
        runtime_settings = _UNSET
        codex_model = _UNSET
        codex_reasoning_effort = _UNSET
        claude_model = _UNSET

        if "executor" in payload.model_fields_set:
            executor = None if payload.executor is None else self.validated_session_context_executor(payload.executor)

        if "working_directory" in payload.model_fields_set:
            raw_path = (payload.working_directory or "").strip()
            if raw_path:
                try:
                    working_directory = str(self._env.resolve_workdir(raw_path))
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
                        id=self.normalized_runtime_setting_id(item.id) or item.id,
                        value=self.validated_runtime_setting_value(item.executor, item.id, item.value),
                    )
                )
            runtime_settings = entries

        if "codex_model" in payload.model_fields_set:
            codex_model = self.normalized_optional_text(payload.codex_model)

        if "codex_reasoning_effort" in payload.model_fields_set:
            codex_reasoning_effort = self.validated_optional_codex_reasoning_effort(
                payload.codex_reasoning_effort
            )

        if "claude_model" in payload.model_fields_set:
            claude_model = self.normalized_optional_text(payload.claude_model)

        return self.update_session_context(
            session_id,
            executor=executor,
            working_directory=working_directory,
            runtime_settings=runtime_settings,
            codex_model=codex_model,
            codex_reasoning_effort=codex_reasoning_effort,
            claude_model=claude_model,
        )

    def update_session_context(
        self,
        session_id: str,
        *,
        executor=_UNSET,
        working_directory=_UNSET,
        runtime_settings=_UNSET,
        codex_model=_UNSET,
        codex_reasoning_effort=_UNSET,
        claude_model=_UNSET,
    ) -> SessionContextResponse:
        current = self._run_store.get_session_context(session_id)
        next_executor = str(current["executor"]).strip() if current is not None and current["executor"] else None
        next_working_directory = (
            str(current["working_directory"]).strip()
            if current is not None and current["working_directory"]
            else None
        )
        next_runtime_settings = self._session_runtime_state.load_row_values(current)

        if executor is not _UNSET:
            next_executor = executor
        if working_directory is not _UNSET:
            next_working_directory = working_directory
        if codex_model is not _UNSET:
            if codex_model is None:
                next_runtime_settings.pop(("codex", "model"), None)
            else:
                next_runtime_settings[("codex", "model")] = codex_model
        if codex_reasoning_effort is not _UNSET:
            if codex_reasoning_effort is None:
                next_runtime_settings.pop(("codex", "reasoning_effort"), None)
            else:
                next_runtime_settings[("codex", "reasoning_effort")] = codex_reasoning_effort
        if claude_model is not _UNSET:
            if claude_model is None:
                next_runtime_settings.pop(("claude", "model"), None)
            else:
                next_runtime_settings[("claude", "model")] = claude_model
        if runtime_settings is not _UNSET:
            next_runtime_settings = {}
            for item in runtime_settings:
                key = (item.executor, self.normalized_runtime_setting_id(item.id) or item.id)
                if item.value is None:
                    next_runtime_settings.pop(key, None)
                else:
                    next_runtime_settings[key] = item.value

        self._run_store.upsert_session_context(
            session_id,
            executor=next_executor,
            working_directory=next_working_directory,
            runtime_settings_json=self.serialize_runtime_settings(next_runtime_settings),
            codex_model=next_runtime_settings.get(("codex", "model")),
            codex_reasoning_effort=next_runtime_settings.get(("codex", "reasoning_effort")),
            claude_model=next_runtime_settings.get(("claude", "model")),
        )
        return self.session_context_response(session_id)

    def values_from_context(
        self,
        context: SessionContextResponse,
    ) -> dict[RuntimeSettingKey, str]:
        return self._session_runtime_state.values_from_context(context)

    def response_items(
        self,
        values: dict[RuntimeSettingKey, str],
    ) -> list[SessionRuntimeSettingValue]:
        return self._session_runtime_state.response_items(values)

    def serialize_runtime_settings(self, values: dict[RuntimeSettingKey, str]) -> str | None:
        return self._session_runtime_state.serialize_values(values)

    def normalized_runtime_setting_id(self, value: str | None) -> str | None:
        return self._runtime_settings.normalized_runtime_setting_id(value)

    def validated_runtime_setting_value(
        self,
        executor: str,
        setting_id: str,
        value: str | None,
    ) -> str | None:
        return self._runtime_settings.validated_runtime_setting_value(executor, setting_id, value)

    def validated_session_context_executor(self, executor: RunExecutorName) -> RunExecutorName:
        if executor == "local":
            return "local"
        if executor in self._env.available_agent_executors():
            return executor
        raise HTTPException(status_code=400, detail=f"executor {executor} is not available on this backend")

    def normalized_optional_text(self, value: str | None) -> str | None:
        normalized = (value or "").strip()
        return normalized or None

    def validated_optional_codex_reasoning_effort(self, value: str | None) -> str | None:
        return self._runtime_settings.validated_optional_codex_reasoning_effort(value)
