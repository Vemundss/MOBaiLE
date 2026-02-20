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

check_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
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

  if command -v codex >/dev/null 2>&1; then
    ok "found command: codex"
  else
    warn "codex not found (executor=codex will fail until installed/logged in)"
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
  else
    warn "backend .env missing. Run scripts/install_backend.sh"
  fi

  if curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then
    ok "backend health endpoint reachable at http://127.0.0.1:8000/health"
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
