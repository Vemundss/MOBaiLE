from __future__ import annotations

from app.models.schemas import (
    RuntimeExecutorDescriptor,
    RuntimeSettingDescriptor,
    SessionContextResponse,
    SessionRuntimeSettingValue,
)
from app.runtime_settings_catalog import RuntimeSettingsCatalog
from app.session_runtime_state import SessionRuntimeState


class _FakeEnv:
    default_executor = "codex"

    def runtime_executor_descriptors(self) -> list[RuntimeExecutorDescriptor]:
        return [
            RuntimeExecutorDescriptor(
                id="codex",
                title="Codex",
                kind="agent",
                available=True,
                settings=[
                    RuntimeSettingDescriptor(
                        id="model",
                        title="Model",
                        kind="enum",
                        allow_custom=True,
                        options=["gpt-5.4-mini"],
                    ),
                    RuntimeSettingDescriptor(
                        id="reasoning_effort",
                        title="Reasoning Effort",
                        kind="enum",
                        options=["medium", "high", "xhigh"],
                    ),
                ],
            ),
            RuntimeExecutorDescriptor(
                id="claude",
                title="Claude",
                kind="agent",
                available=True,
                settings=[
                    RuntimeSettingDescriptor(
                        id="model",
                        title="Model",
                        kind="enum",
                        allow_custom=True,
                        options=["claude-sonnet-4-5"],
                    )
                ],
            ),
        ]


def test_session_runtime_state_loads_json_and_overlays_legacy_columns() -> None:
    env = _FakeEnv()
    state = SessionRuntimeState(env, RuntimeSettingsCatalog(env))
    row = {
        "runtime_settings_json": '[{"executor":"codex","id":"model","value":"gpt-5.4-mini"}]',
        "codex_model": "gpt-5.4-mini",
        "codex_reasoning_effort": "high",
        "claude_model": "claude-sonnet-4-5",
    }

    values = state.load_row_values(row)

    assert values[("codex", "model")] == "gpt-5.4-mini"
    assert values[("codex", "reasoning_effort")] == "high"
    assert values[("claude", "model")] == "claude-sonnet-4-5"


def test_session_runtime_state_response_items_keep_known_and_unknown_values() -> None:
    env = _FakeEnv()
    state = SessionRuntimeState(env, RuntimeSettingsCatalog(env))

    items = state.response_items(
        {
            ("codex", "model"): "gpt-5.4-mini",
            ("codex", "verbosity"): "detailed",
        }
    )

    pairs = {(item.executor, item.id): item.value for item in items}
    assert pairs[("codex", "model")] == "gpt-5.4-mini"
    assert pairs[("codex", "reasoning_effort")] is None
    assert pairs[("codex", "verbosity")] == "detailed"


def test_session_runtime_state_extracts_values_from_context() -> None:
    env = _FakeEnv()
    state = SessionRuntimeState(env, RuntimeSettingsCatalog(env))
    context = SessionContextResponse(
        session_id="sess-1",
        executor="codex",
        runtime_settings=[
            SessionRuntimeSettingValue(executor="codex", id="model", value="gpt-5.4-mini"),
            SessionRuntimeSettingValue(executor="codex", id="reasoning_effort", value=None),
        ],
        codex_model="gpt-5.4-mini",
        codex_reasoning_effort=None,
        claude_model=None,
        resolved_working_directory="/tmp",
    )

    values = state.values_from_context(context)

    assert values == {("codex", "model"): "gpt-5.4-mini"}
