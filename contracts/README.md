# Contracts

Checked-in API contracts live here.

Source of truth files:
- `openapi.json`: FastAPI OpenAPI spec snapshot.
- `action_plan.schema.json`: JSON schema for `ActionPlan`.
- `chat_envelope.schema.json`: JSON schema for `assistant_response` payloads.

Sync from backend models:

```bash
cd backend
uv run python ../scripts/sync_contracts.py
```

Validate drift:

```bash
cd backend
uv run python ../scripts/sync_contracts.py --check
```
