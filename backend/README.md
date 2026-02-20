# Backend

FastAPI service for:
- intake of user utterances
- action-plan generation/validation
- safe execution routing
- streaming run events

Run locally (after installing deps):

```bash
uv run uvicorn app.main:app --reload
```

Current implemented endpoints:
- `GET /health`
- `POST /v1/utterances` (asynchronous run start; supports `executor=local|codex`)
- `GET /v1/runs/{run_id}` (retrieve run record and events)
- `GET /v1/runs/{run_id}/events` (SSE event stream)
