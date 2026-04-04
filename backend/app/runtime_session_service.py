from __future__ import annotations

from fastapi import HTTPException

from app.models.schemas import (
    HumanUnblockRequest,
    RunExecutorName,
    RuntimeSettingDescriptor,
    SessionContextResponse,
    SessionContextUpdateRequest,
    SessionRuntimeSettingValue,
    SlashCommandDescriptor,
    SlashCommandExecutionResponse,
)
from app.runtime_environment import RuntimeEnvironment
from app.session_runtime_state import SessionRuntimeState
from app.runtime_settings_catalog import RuntimeSettingKey
from app.runtime_settings_catalog import RuntimeSettingsCatalog
from app.storage import RunStore


_UNSET = object()


class RuntimeSessionService:
    def __init__(self, env: RuntimeEnvironment, run_store: RunStore) -> None:
        self._env = env
        self._run_store = run_store
        self._runtime_settings = RuntimeSettingsCatalog(env)
        self._session_runtime_state = SessionRuntimeState(env, self._runtime_settings)

    def slash_command_catalog(self) -> list[SlashCommandDescriptor]:
        executor_options = self._slash_command_executor_options()
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
        return [*commands, *self._runtime_setting_slash_commands()]

    def session_context_response(self, session_id: str) -> SessionContextResponse:
        row = self._run_store.get_session_context(session_id)
        raw_executor = str(row["executor"]).strip() if row is not None and row["executor"] else ""
        raw_working_directory = str(row["working_directory"]).strip() if row is not None and row["working_directory"] else ""
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

        effective_executor = raw_executor if raw_executor in {"local", "codex", "claude"} else self._env.default_executor
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
            runtime_settings=self._session_runtime_settings_response(runtime_settings),
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
            executor = None if payload.executor is None else self._validated_session_context_executor(payload.executor)

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
                        id=self._normalized_runtime_setting_id(item.id) or item.id,
                        value=self._validated_runtime_setting_value(item.executor, item.id, item.value),
                    )
                )
            runtime_settings = entries

        if "codex_model" in payload.model_fields_set:
            codex_model = self._normalized_optional_text(payload.codex_model)

        if "codex_reasoning_effort" in payload.model_fields_set:
            codex_reasoning_effort = self._validated_optional_codex_reasoning_effort(payload.codex_reasoning_effort)

        if "claude_model" in payload.model_fields_set:
            claude_model = self._normalized_optional_text(payload.claude_model)

        return self._update_session_context(
            session_id,
            executor=executor,
            working_directory=working_directory,
            runtime_settings=runtime_settings,
            codex_model=codex_model,
            codex_reasoning_effort=codex_reasoning_effort,
            claude_model=claude_model,
        )

    def execute_slash_command(
        self,
        session_id: str,
        *,
        command_id: str,
        arguments: str | None,
    ) -> SlashCommandExecutionResponse:
        normalized_command = command_id.strip().lower()
        normalized_arguments = (arguments or "").strip()

        if normalized_command == "cwd":
            if not normalized_arguments:
                context = self.session_context_response(session_id)
                return SlashCommandExecutionResponse(
                    command_id="cwd",
                    message=self._working_directory_status_message(context),
                    session_context=context,
                )

            try:
                resolved_working_directory = str(self._env.resolve_workdir(normalized_arguments))
            except ValueError as exc:
                raise HTTPException(status_code=400, detail=str(exc)) from exc

            context = self._update_session_context(
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
                context = self.session_context_response(session_id)
                return SlashCommandExecutionResponse(
                    command_id="executor",
                    message=self._executor_status_message(context),
                    session_context=context,
                )

            requested_executor = normalized_arguments.lower()
            if requested_executor not in {"local", "codex", "claude"}:
                raise HTTPException(status_code=400, detail=f"executor {requested_executor} is not available on this backend")
            context = self._update_session_context(
                session_id,
                executor=self._validated_session_context_executor(requested_executor),  # type: ignore[arg-type]
            )
            return SlashCommandExecutionResponse(
                command_id="executor",
                message=self._executor_status_message(context),
                session_context=context,
            )

        runtime_setting_id = self._slash_command_runtime_setting_id(normalized_command)
        if runtime_setting_id is not None:
            context = self.session_context_response(session_id)
            if not normalized_arguments:
                return SlashCommandExecutionResponse(
                    command_id=normalized_command,
                    message=self._runtime_setting_status_message(context, runtime_setting_id),
                    session_context=context,
                )

            if (context.executor, runtime_setting_id) not in self._runtime_setting_descriptor_map():
                supported_titles = [
                    self._runtime_executor_titles().get(executor, executor)
                    for executor in self._runtime_setting_supported_executors(runtime_setting_id)
                ]
                raise HTTPException(
                    status_code=400,
                    detail=(
                        f"{self._runtime_setting_title_text(runtime_setting_id)} overrides apply only when "
                        f"the session executor is {self._human_join(supported_titles)}"
                    ),
                )

            requested_value = normalized_arguments
            if requested_value.lower() in {"backend-default", "default", "auto"}:
                requested_value = ""

            next_runtime_settings = self._session_runtime_state.values_from_context(context)
            validated_value = self._validated_runtime_setting_value(
                context.executor,
                runtime_setting_id,
                requested_value,
            )
            key = (context.executor, runtime_setting_id)
            if validated_value is None:
                next_runtime_settings.pop(key, None)
            else:
                next_runtime_settings[key] = validated_value
            context = self._update_session_context(
                session_id,
                runtime_settings=[
                    SessionRuntimeSettingValue(executor=executor, id=setting_id, value=value)
                    for (executor, setting_id), value in sorted(next_runtime_settings.items())
                ],
            )
            return SlashCommandExecutionResponse(
                command_id=normalized_command,
                message=self._runtime_setting_status_message(context, runtime_setting_id),
                session_context=context,
            )

        raise HTTPException(status_code=404, detail=f"unknown slash command {normalized_command}")

    def _normalized_runtime_setting_id(self, value: str | None) -> str | None:
        return self._runtime_settings.normalized_runtime_setting_id(value)

    def _runtime_setting_descriptor_map(self) -> dict[RuntimeSettingKey, RuntimeSettingDescriptor]:
        return self._runtime_settings.runtime_setting_descriptor_map

    def _runtime_executor_titles(self) -> dict[str, str]:
        return self._runtime_settings.runtime_executor_titles

    def _available_runtime_setting_entries(self) -> list[tuple[str, list[tuple[str, RuntimeSettingDescriptor]]]]:
        return self._runtime_settings.available_runtime_setting_entries

    def _runtime_setting_supported_executors(self, setting_id: str) -> list[str]:
        return self._runtime_settings.runtime_setting_supported_executors(setting_id)

    def _runtime_setting_slash_command_id(self, setting_id: str) -> str:
        return self._runtime_settings.runtime_setting_slash_command_id(setting_id)

    def _slash_command_runtime_setting_id(self, command_id: str) -> str | None:
        return self._runtime_settings.slash_command_runtime_setting_id(command_id)

    def _runtime_setting_option_list(
        self,
        descriptors: list[tuple[str, RuntimeSettingDescriptor]],
    ) -> list[str]:
        return self._runtime_settings.runtime_setting_option_list(descriptors)

    def _runtime_setting_allows_custom(
        self,
        descriptors: list[tuple[str, RuntimeSettingDescriptor]],
    ) -> bool:
        return self._runtime_settings.runtime_setting_allows_custom(descriptors)

    def _human_join(self, values: list[str]) -> str:
        cleaned = [value for value in values if value]
        if not cleaned:
            return ""
        if len(cleaned) == 1:
            return cleaned[0]
        if len(cleaned) == 2:
            return f"{cleaned[0]} or {cleaned[1]}"
        return f"{', '.join(cleaned[:-1])}, or {cleaned[-1]}"

    def _runtime_setting_usage(
        self,
        command_id: str,
        options: list[str],
        *,
        allow_custom: bool,
        placeholder: str,
    ) -> str:
        return self._runtime_settings.runtime_setting_usage(
            command_id,
            options,
            allow_custom=allow_custom,
            placeholder=placeholder,
        )

    def _runtime_setting_command_metadata(
        self,
        setting_id: str,
        descriptors: list[tuple[str, RuntimeSettingDescriptor]],
    ) -> tuple[str, str, list[str], str, str]:
        return self._runtime_settings.runtime_setting_command_metadata(setting_id, descriptors)

    def _runtime_setting_title_text(
        self,
        setting_id: str,
        descriptor: RuntimeSettingDescriptor | None = None,
    ) -> str:
        return self._runtime_settings.runtime_setting_title_text(setting_id, descriptor)

    def _runtime_setting_slash_commands(self) -> list[SlashCommandDescriptor]:
        return self._runtime_settings.runtime_setting_slash_commands()

    def _canonical_runtime_setting_option(self, value: str, options: list[str]) -> str | None:
        return self._runtime_settings.canonical_runtime_setting_option(value, options)

    def _validated_runtime_setting_value(
        self,
        executor: str,
        setting_id: str,
        value: str | None,
    ) -> str | None:
        return self._runtime_settings.validated_runtime_setting_value(executor, setting_id, value)

    def _session_runtime_settings_response(
        self,
        values: dict[RuntimeSettingKey, str],
    ) -> list[SessionRuntimeSettingValue]:
        return self._session_runtime_state.response_items(values)

    def _serialized_runtime_settings(self, values: dict[RuntimeSettingKey, str]) -> str | None:
        return self._session_runtime_state.serialize_values(values)

    def _session_context_runtime_settings_map(
        self,
        context: SessionContextResponse,
    ) -> dict[RuntimeSettingKey, str]:
        return self._session_runtime_state.values_from_context(context)

    def _update_session_context(
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
        next_codex_model = str(current["codex_model"]).strip() if current is not None and current["codex_model"] else None
        next_codex_reasoning_effort = (
            str(current["codex_reasoning_effort"]).strip().lower()
            if current is not None and current["codex_reasoning_effort"]
            else None
        )
        next_claude_model = str(current["claude_model"]).strip() if current is not None and current["claude_model"] else None
        next_runtime_settings = self._session_runtime_state.load_row_values(current)

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
                key = (item.executor, self._normalized_runtime_setting_id(item.id) or item.id)
                if item.value is None:
                    next_runtime_settings.pop(key, None)
                else:
                    next_runtime_settings[key] = item.value

        next_codex_model = next_runtime_settings.get(("codex", "model"))
        next_codex_reasoning_effort = next_runtime_settings.get(("codex", "reasoning_effort"))
        next_claude_model = next_runtime_settings.get(("claude", "model"))

        self._run_store.upsert_session_context(
            session_id,
            executor=next_executor,
            working_directory=next_working_directory,
            runtime_settings_json=self._serialized_runtime_settings(next_runtime_settings),
            codex_model=next_codex_model,
            codex_reasoning_effort=next_codex_reasoning_effort,
            claude_model=next_claude_model,
        )
        return self.session_context_response(session_id)

    def _validated_session_context_executor(self, executor: RunExecutorName) -> RunExecutorName:
        if executor == "local":
            return "local"
        if executor in self._env.available_agent_executors():
            return executor
        raise HTTPException(status_code=400, detail=f"executor {executor} is not available on this backend")

    def _normalized_optional_text(self, value: str | None) -> str | None:
        normalized = (value or "").strip()
        return normalized or None

    def _validated_optional_codex_reasoning_effort(self, value: str | None) -> str | None:
        return self._runtime_settings.validated_optional_codex_reasoning_effort(value)

    def _slash_command_executor_options(self) -> list[str]:
        values = list(self._env.available_agent_executors())
        if "local" not in values:
            values.append("local")
        return values

    def _working_directory_status_message(self, context: SessionContextResponse) -> str:
        current = context.resolved_working_directory.strip()
        if current:
            return f"Working directory: {current}"
        return "Working directory follows the backend default."

    def _executor_status_message(self, context: SessionContextResponse) -> str:
        options = ", ".join(self._slash_command_executor_options())
        return f"Executor: {context.executor}. Available: {options}."

    def _runtime_setting_status_message(self, context: SessionContextResponse, setting_id: str) -> str:
        normalized_setting_id = self._normalized_runtime_setting_id(setting_id)
        if normalized_setting_id is None:
            return "Runtime setting is not available."

        executor_titles = self._runtime_executor_titles()
        descriptor = self._runtime_setting_descriptor_map().get((context.executor, normalized_setting_id))
        if descriptor is None:
            supported_titles = [
                executor_titles.get(executor, executor)
                for executor in self._runtime_setting_supported_executors(normalized_setting_id)
            ]
            if not supported_titles:
                return "Runtime setting is not available."
            return (
                f"{self._runtime_setting_title_text(normalized_setting_id)} overrides apply when "
                f"the session executor is {self._human_join(supported_titles)}."
            )

        value = self._session_context_runtime_settings_map(context).get((context.executor, normalized_setting_id))
        if value is None:
            if context.executor == "codex" and normalized_setting_id == "reasoning_effort":
                value = self._validated_optional_codex_reasoning_effort(descriptor.value)
            else:
                value = self._normalized_optional_text(descriptor.value)
        executor_title = executor_titles.get(context.executor, context.executor.title())
        return f"{executor_title} {self._runtime_setting_title_text(normalized_setting_id, descriptor)}: {value or 'backend default'}."
