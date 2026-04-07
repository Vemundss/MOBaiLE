from __future__ import annotations

from fastapi import HTTPException

from app.models.schemas import (
    RuntimeSettingDescriptor,
    SessionContextResponse,
    SessionRuntimeSettingValue,
    SlashCommandDescriptor,
    SlashCommandExecutionResponse,
)
from app.runtime_environment import RuntimeEnvironment
from app.runtime_settings_catalog import RuntimeSettingKey, RuntimeSettingsCatalog
from app.session_context_service import SessionContextService
from app.storage import RunStore


class RuntimeSessionService:
    def __init__(self, env: RuntimeEnvironment, run_store: RunStore) -> None:
        self._env = env
        self._runtime_settings = RuntimeSettingsCatalog(env)
        self._session_contexts = SessionContextService(env, run_store, self._runtime_settings)

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
        return self._session_contexts.session_context_response(session_id)

    def apply_session_context_patch(self, session_id: str, payload) -> SessionContextResponse:
        return self._session_contexts.apply_session_context_patch(session_id, payload)

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

            context = self._session_contexts.update_session_context(
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
            context = self._session_contexts.update_session_context(
                session_id,
                executor=self._session_contexts.validated_session_context_executor(
                    requested_executor  # type: ignore[arg-type]
                ),
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

            next_runtime_settings = self._session_contexts.values_from_context(context)
            validated_value = self._session_contexts.validated_runtime_setting_value(
                context.executor,
                runtime_setting_id,
                requested_value,
            )
            key = (context.executor, runtime_setting_id)
            if validated_value is None:
                next_runtime_settings.pop(key, None)
            else:
                next_runtime_settings[key] = validated_value
            context = self._session_contexts.update_session_context(
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

        value = self._session_contexts.values_from_context(context).get(
            (context.executor, normalized_setting_id)
        )
        if value is None:
            if context.executor == "codex" and normalized_setting_id == "reasoning_effort":
                value = self._session_contexts.validated_optional_codex_reasoning_effort(descriptor.value)
            else:
                value = self._session_contexts.normalized_optional_text(descriptor.value)
        executor_title = executor_titles.get(context.executor, context.executor.title())
        return f"{executor_title} {self._runtime_setting_title_text(normalized_setting_id, descriptor)}: {value or 'backend default'}."
