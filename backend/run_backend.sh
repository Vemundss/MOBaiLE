#!/usr/bin/env bash
set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${BACKEND_DIR}"

# Service managers often provide a minimal PATH; include common user/local locations.
export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/snap/bin:${PATH}"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source ".env"
  set +a
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is not available in PATH: ${PATH}" >&2
  exit 127
fi

HOST="${VOICE_AGENT_HOST:-0.0.0.0}"
PORT="${VOICE_AGENT_PORT:-8000}"

exec uv run uvicorn app.main:app --host "${HOST}" --port "${PORT}"
