from __future__ import annotations

import json

from app.models.schemas import SessionContextResponse
from app.models.schemas import SessionRuntimeSettingValue
from app.runtime_environment import RuntimeEnvironment
from app.runtime_settings_catalog import RuntimeSettingKey
from app.runtime_settings_catalog import RuntimeSettingsCatalog


class SessionRuntimeState:
    def __init__(self, env: RuntimeEnvironment, catalog: RuntimeSettingsCatalog) -> None:
        self._env = env
        self._catalog = catalog

    def load_row_values(self, row) -> dict[RuntimeSettingKey, str]:
        values: dict[RuntimeSettingKey, str] = {}
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
                    normalized_setting_id = self._catalog.normalized_runtime_setting_id(decoded.id)
                    normalized_value = self._normalized_optional_text(decoded.value)
                    if normalized_setting_id is None or normalized_value is None:
                        continue
                    values[(decoded.executor, normalized_setting_id)] = normalized_value

        legacy_values = {
            ("codex", "model"): self._normalized_optional_text(
                str(row["codex_model"]).strip() if row is not None and row["codex_model"] else None
            ),
            ("codex", "reasoning_effort"): self._catalog.validated_optional_codex_reasoning_effort(
                str(row["codex_reasoning_effort"]).strip().lower()
                if row is not None and row["codex_reasoning_effort"]
                else None
            ),
            ("claude", "model"): self._normalized_optional_text(
                str(row["claude_model"]).strip() if row is not None and row["claude_model"] else None
            ),
        }
        for key, normalized_value in legacy_values.items():
            if normalized_value is None:
                values.pop(key, None)
            else:
                values[key] = normalized_value
        return values

    def response_items(self, values: dict[RuntimeSettingKey, str]) -> list[SessionRuntimeSettingValue]:
        items: list[SessionRuntimeSettingValue] = []
        seen: set[RuntimeSettingKey] = set()
        for executor in self._env.runtime_executor_descriptors():
            for setting in executor.settings or []:
                setting_id = self._catalog.normalized_runtime_setting_id(setting.id)
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

    def serialize_values(self, values: dict[RuntimeSettingKey, str]) -> str | None:
        if not values:
            return None
        payload = [
            {"executor": executor, "id": setting_id, "value": values[(executor, setting_id)]}
            for executor, setting_id in sorted(values)
        ]
        return json.dumps(payload, separators=(",", ":"))

    def values_from_context(self, context: SessionContextResponse) -> dict[RuntimeSettingKey, str]:
        values: dict[RuntimeSettingKey, str] = {}
        for item in context.runtime_settings:
            setting_id = self._catalog.normalized_runtime_setting_id(item.id)
            setting_value = self._normalized_optional_text(item.value)
            if setting_id is None or setting_value is None:
                continue
            values[(item.executor, setting_id)] = setting_value
        return values

    @staticmethod
    def _normalized_optional_text(value: str | None) -> str | None:
        normalized = (value or "").strip()
        return normalized or None
