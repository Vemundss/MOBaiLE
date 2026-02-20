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
- `POST /v1/audio` (multipart upload + transcript-to-run bridge)
- `GET /v1/runs/{run_id}` (retrieve run record and events)
- `GET /v1/runs/{run_id}/events` (SSE event stream)

Auth:
- `/v1/*` endpoints require `Authorization: Bearer <VOICE_AGENT_API_TOKEN>`.
- `GET /health` is intentionally unauthenticated.

Transcription:
- `VOICE_AGENT_TRANSCRIBE_PROVIDER=mock` (default) for local deterministic behavior.
- `VOICE_AGENT_TRANSCRIBE_PROVIDER=openai` for real STT via OpenAI `/v1/audio/transcriptions`.

Persistence:
- Run records are stored in SQLite (default path `data/runs.db`).
- Override with `VOICE_AGENT_DB_PATH`.

Tests:
- `uv run pytest -q`
