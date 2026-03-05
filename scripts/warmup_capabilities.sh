#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/backend/.env"

SERVER_URL=""
DEEP="true"
LAUNCH_APPS="true"
WAIT_SECONDS="10"

usage() {
  cat <<EOF
Usage: bash ./scripts/warmup_capabilities.sh [options]

Options:
  --server-url <url>      Backend base URL (default: http://127.0.0.1:<PORT from .env>)
  --deep <true|false>     Run deep probes (default: true)
  --launch-apps <true|false>
                          Open Calendar and Mail in background before probing (default: true)
  --wait-seconds <int>    Seconds to wait for /health before probing (default: 10)
EOF
}

read_env_value() {
  local key="$1"
  local fallback="${2:-}"
  if [[ ! -f "${ENV_FILE}" ]]; then
    printf "%s" "${fallback}"
    return
  fi
  local raw
  raw="$(awk -v k="${key}" -F= '$1==k {print substr($0, index($0, "=")+1)}' "${ENV_FILE}" | tail -n1)"
  raw="${raw%\"}"
  raw="${raw#\"}"
  raw="${raw%\'}"
  raw="${raw#\'}"
  if [[ -z "${raw}" ]]; then
    printf "%s" "${fallback}"
    return
  fi
  printf "%s" "${raw}"
}

wait_for_backend() {
  local url="$1"
  local max_wait="$2"
  local i
  for ((i = 0; i < max_wait; i++)); do
    if curl -fsS "${url}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-url)
        SERVER_URL="$2"
        shift 2
        ;;
      --deep)
        DEEP="$2"
        shift 2
        ;;
      --launch-apps)
        LAUNCH_APPS="$2"
        shift 2
        ;;
      --wait-seconds)
        WAIT_SECONDS="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  local host port token
  host="$(read_env_value "VOICE_AGENT_HOST" "127.0.0.1")"
  port="$(read_env_value "VOICE_AGENT_PORT" "8000")"
  token="$(read_env_value "VOICE_AGENT_API_TOKEN" "")"
  if [[ "${host}" == "0.0.0.0" ]]; then
    host="127.0.0.1"
  fi
  if [[ -z "${SERVER_URL}" ]]; then
    SERVER_URL="http://${host}:${port}"
  fi
  if [[ -z "${token}" ]]; then
    echo "Missing VOICE_AGENT_API_TOKEN in ${ENV_FILE}" >&2
    exit 1
  fi

  if [[ "${LAUNCH_APPS}" == "true" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
    open -ga Calendar >/dev/null 2>&1 || true
    open -ga Mail >/dev/null 2>&1 || true
  fi

  if ! wait_for_backend "${SERVER_URL}" "${WAIT_SECONDS}"; then
    echo "Backend is not reachable at ${SERVER_URL} after ${WAIT_SECONDS}s" >&2
    exit 1
  fi

  local query url response
  query="deep=${DEEP}&launch_apps=${LAUNCH_APPS}"
  url="${SERVER_URL}/v1/capabilities?${query}"
  response="$(curl -fsS -H "Authorization: Bearer ${token}" "${url}")"

  CAPABILITIES_JSON="${response}" python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["CAPABILITIES_JSON"])
capabilities = payload.get("capabilities", [])
blocked = [item for item in capabilities if item.get("status") == "blocked"]
degraded = [item for item in capabilities if item.get("status") == "degraded"]

print(f"Checked at: {payload.get('checked_at', '')}")
print(f"Host platform: {payload.get('host_platform', '')}")
print(f"Security mode: {payload.get('security_mode', '')}")
print("")
for item in capabilities:
    print(f"- {item.get('id')}: {item.get('status')} ({item.get('code')})")
    print(f"  {item.get('message')}")
if payload.get("report_path"):
    print("")
    print(f"Report path: {payload['report_path']}")

if blocked:
    print("")
    print(f"Readiness failed: {len(blocked)} blocked capability(ies).", file=sys.stderr)
    sys.exit(2)
if degraded:
    print("")
    print(f"Readiness warning: {len(degraded)} degraded capability(ies).", file=sys.stderr)
    sys.exit(0)
PY
}

main "$@"
