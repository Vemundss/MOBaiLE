#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PAIRING_FILE="${REPO_ROOT}/backend/pairing.json"
ENV_FILE="${REPO_ROOT}/backend/.env"

SERVER_URL="${VOICE_AGENT_SERVER_URL:-}"
TOKEN="${VOICE_AGENT_API_TOKEN:-}"
EXECUTOR="${VOICE_AGENT_SMOKE_EXECUTOR:-local}"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" > /dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
}

load_pairing() {
  if [[ -n "${SERVER_URL}" && -n "${TOKEN}" ]]; then
    return
  fi
  if [[ -z "${SERVER_URL}" && ! -f "${PAIRING_FILE}" ]]; then
    echo "Missing pairing file: ${PAIRING_FILE}" >&2
    echo "Run: bash ./scripts/install_backend.sh" >&2
    exit 1
  fi
  if [[ -z "${SERVER_URL}" ]]; then
    SERVER_URL="$(
      PAIRING_FILE_PATH="${PAIRING_FILE}" python3 - << 'PY'
import json
import os
from pathlib import Path
p = Path(os.environ["PAIRING_FILE_PATH"])
d = json.loads(p.read_text(encoding='utf-8'))
print(d.get('server_url', ''))
PY
    )"
  fi
  if [[ -z "${TOKEN}" && -f "${ENV_FILE}" ]]; then
    TOKEN="$(awk -F= '/^VOICE_AGENT_API_TOKEN=/{print $2; exit}' "${ENV_FILE}")"
  fi
}

wait_for_terminal_status() {
  local run_id="$1"
  local status="running"
  for _ in {1..80}; do
    status="$(curl -sS -H "Authorization: Bearer ${TOKEN}" "${SERVER_URL}/v1/runs/${run_id}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
    if [[ "${status}" != "running" ]]; then
      echo "${status}"
      return
    fi
    sleep 0.25
  done
  echo "${status}"
}

main() {
  require_cmd curl
  require_cmd python3
  load_pairing

  if [[ -z "${SERVER_URL}" || -z "${TOKEN}" ]]; then
    echo "Connection values are missing (server_url from pairing.json, api_token from backend/.env or env vars)." >&2
    exit 1
  fi

  echo "Using server: ${SERVER_URL}"
  echo "Executor: ${EXECUTOR}"
  if [[ "${EXECUTOR}" == "local" ]]; then
    echo "Using internal local smoke/dev fallback."
  fi

  local health_code
  health_code="$(curl -s -o /dev/null -w "%{http_code}" "${SERVER_URL}/health" || true)"
  echo "health status code: ${health_code}"
  if [[ "${health_code}" != "200" ]]; then
    echo "Health check failed." >&2
    exit 1
  fi

  local noauth_code
  noauth_code="$(curl -s -o /dev/null -w "%{http_code}" -X POST "${SERVER_URL}/v1/utterances" || true)"
  echo "auth check without token (expect 401): ${noauth_code}"

  printf 'fakewav' > /tmp/voice_agent_smoke.wav
  local audio_resp
  audio_resp="$(curl -sS -X POST "${SERVER_URL}/v1/audio" \
    -H "Authorization: Bearer ${TOKEN}" \
    -F 'session_id=phone-smoke' \
    -F "executor=${EXECUTOR}" \
    -F 'transcript_hint=create a hello python script and run it' \
    -F 'audio=@/tmp/voice_agent_smoke.wav;type=audio/wav')"

  local run_id
  run_id="$(printf '%s' "${audio_resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')"
  local transcript
  transcript="$(printf '%s' "${audio_resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["transcript_text"])')"

  echo "audio run_id: ${run_id}"
  echo "transcript: ${transcript}"

  local final_status
  final_status="$(wait_for_terminal_status "${run_id}")"
  echo "final status: ${final_status}"

  curl -sS -H "Authorization: Bearer ${TOKEN}" "${SERVER_URL}/v1/runs/${run_id}" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print("summary:", d.get("summary","")); print("events:", len(d.get("events", [])))'
}

main "$@"
