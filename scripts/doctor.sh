#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${REPO_ROOT}/backend"
ENV_FILE="${BACKEND_DIR}/.env"

ok() {
  echo "[OK] $1"
}

warn() {
  echo "[WARN] $1"
}

fail() {
  echo "[FAIL] $1"
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

check_cmd() {
  local cmd="$1"
  if command -v "${cmd}" > /dev/null 2>&1; then
    ok "found command: ${cmd}"
    return 0
  fi
  fail "missing command: ${cmd}"
  return 1
}

main() {
  local exit_code=0
  echo "Running backend doctor in: ${REPO_ROOT}"

  check_cmd python3 || exit_code=1
  check_cmd uv || exit_code=1

  local has_codex=0
  local has_claude=0
  if command -v codex > /dev/null 2>&1; then
    ok "found command: codex"
    has_codex=1
  fi
  if command -v claude > /dev/null 2>&1; then
    ok "found command: claude"
    has_claude=1
  fi
  if [[ "${has_codex}" -eq 0 && "${has_claude}" -eq 0 ]]; then
    warn "no Codex/Claude CLI found (only the internal local smoke/dev fallback will be available)"
  fi
  if command -v claude > /dev/null 2>&1; then
    ok "found command: claude"
  else
    warn "claude not found (executor=claude will fail until installed/logged in)"
  fi
  if command -v npx > /dev/null 2>&1; then
    ok "found command: npx"
  else
    warn "npx not found (Peekaboo/Playwright MCP servers will not launch until Node.js/npm is installed)"
  fi

  if [[ -f "${BACKEND_DIR}/pyproject.toml" ]]; then
    ok "backend project file exists"
  else
    fail "missing ${BACKEND_DIR}/pyproject.toml"
    exit_code=1
  fi

  if [[ -d "${BACKEND_DIR}/.venv" ]]; then
    ok "uv environment exists (${BACKEND_DIR}/.venv)"
  else
    warn "uv environment missing. Run scripts/install_backend.sh"
  fi

  if [[ -f "${ENV_FILE}" ]]; then
    ok "backend .env exists"
    if awk -F= '/^VOICE_AGENT_API_TOKEN=/{exit($2==""?1:0)}' "${ENV_FILE}"; then
      ok "VOICE_AGENT_API_TOKEN is set"
    else
      warn "VOICE_AGENT_API_TOKEN missing in ${ENV_FILE}"
    fi
    local mode
    mode="$(awk -F= '/^VOICE_AGENT_SECURITY_MODE=/{print $2}' "${ENV_FILE}" | tr -d '[:space:]')"
    if [[ -n "${mode}" ]]; then
      ok "VOICE_AGENT_SECURITY_MODE=${mode}"
    else
      warn "VOICE_AGENT_SECURITY_MODE not set (defaults to full-access)"
    fi
    local codex_home
    codex_home="$(read_env_value "VOICE_AGENT_CODEX_HOME" "${HOME}/.codex")"
    ok "VOICE_AGENT_CODEX_HOME=${codex_home}"
  else
    warn "backend .env missing. Run scripts/install_backend.sh"
  fi

  local codex_home
  codex_home="$(read_env_value "VOICE_AGENT_CODEX_HOME" "${HOME}/.codex")"
  if [[ "${has_codex}" -eq 1 ]]; then
    if CODEX_HOME="${codex_home}" codex mcp get playwright --json > /dev/null 2>&1; then
      ok "Codex MCP configured: playwright"
    else
      warn "Codex MCP missing: playwright (run python3 ./scripts/provision_codex_autonomy.py)"
    fi
    if CODEX_HOME="${codex_home}" codex mcp get peekaboo --json > /dev/null 2>&1; then
      ok "Codex MCP configured: peekaboo"
    else
      warn "Codex MCP missing: peekaboo (run python3 ./scripts/provision_codex_autonomy.py)"
    fi
  fi

  if [[ "$(uname -s)" == "Darwin" ]] && command -v npx > /dev/null 2>&1; then
    local permissions_json
    permissions_json="$(npx -y @steipete/peekaboo permissions --json 2> /dev/null || true)"
    if [[ -n "${permissions_json}" ]]; then
      if PERMISSIONS_JSON="${permissions_json}" python3 - << 'PY'; then
import json
import os
import sys

payload = json.loads(os.environ["PERMISSIONS_JSON"])
permissions = payload.get("data", {}).get("permissions", [])
missing = [item.get("name", "unknown") for item in permissions if item.get("isRequired") and not item.get("isGranted")]
if missing:
    print(", ".join(missing))
    sys.exit(1)
PY
        ok "Peekaboo reports required macOS permissions are granted"
      else
        warn "Peekaboo is missing required macOS permissions"
      fi
    else
      warn "could not read Peekaboo permission status"
    fi
  fi

  if curl -fsS http://127.0.0.1:8000/health > /dev/null 2>&1; then
    ok "backend health endpoint reachable at http://127.0.0.1:8000/health"
    local auth_code
    auth_code="$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8000/v1/utterances || true)"
    if [[ "${auth_code}" == "401" ]]; then
      ok "/v1 auth check without token returns 401"
    else
      warn "/v1 auth check without token expected 401, got ${auth_code} (possible old server build)"
    fi
    if [[ -f "${ENV_FILE}" ]]; then
      local token
      token="$(awk -F= '/^VOICE_AGENT_API_TOKEN=/{print $2}' "${ENV_FILE}")"
      if [[ -n "${token}" ]]; then
        local token_code
        token_code="$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer ${token}" http://127.0.0.1:8000/v1/utterances || true)"
        if [[ "${token_code}" == "422" ]]; then
          ok "/v1 auth check with token accepted (422 from empty request body is expected)"
        else
          warn "/v1 auth check with token expected 422, got ${token_code}"
        fi
      fi
    fi
  else
    warn "backend not reachable on 127.0.0.1:8000 (start server to verify runtime)"
  fi

  if [[ "${exit_code}" -ne 0 ]]; then
    echo
    fail "doctor checks found blocking issues"
    exit "${exit_code}"
  fi

  echo
  ok "doctor checks completed"
}

main "$@"
