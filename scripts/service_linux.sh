#!/usr/bin/env bash
set -euo pipefail

UNIT_NAME="mobaile-backend.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${REPO_ROOT}/backend"
RUNTIME_DIR="${HOME}/.local/share/MOBaiLE/backend-runtime"
RUN_SCRIPT="${RUNTIME_DIR}/run_backend.sh"
WARMUP_SCRIPT="${REPO_ROOT}/scripts/warmup_capabilities.sh"
WARMUP_ON_START="${VOICE_AGENT_WARMUP_ON_START:-true}"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
UNIT_PATH="${SYSTEMD_USER_DIR}/${UNIT_NAME}"

usage() {
  cat << EOF
Usage: bash ./scripts/service_linux.sh <command>

Commands:
  install    Sync runtime, write user unit, enable service, and start backend
  uninstall  Stop and remove the user service
  sync       Sync backend runtime into ~/.local/share/MOBaiLE/backend-runtime
  start      Start/refresh the systemd user service
  stop       Stop the systemd user service
  restart    Restart the systemd user service
  status     Show systemd user service state
  logs       Tail backend service logs from journald
  warmup     Run capability warmup against current backend
EOF
}

require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This script supports Linux systemd only." >&2
    exit 1
  fi
}

require_systemd_user() {
  if ! command -v systemctl > /dev/null 2>&1; then
    echo "systemctl is not available. Start backend manually from backend/run_backend.sh." >&2
    exit 1
  fi
  if ! systemctl --user show-environment > /dev/null 2>&1; then
    cat >&2 << EOF
systemd user instance is not reachable.
Try logging into a graphical/session shell first, or enable linger:
  sudo loginctl enable-linger $(id -un)
Then rerun this command.
EOF
    exit 1
  fi
}

ensure_uv_available() {
  if command -v uv > /dev/null 2>&1; then
    return 0
  fi

  export PATH="${HOME}/.local/bin:${PATH}"
  if command -v uv > /dev/null 2>&1; then
    return 0
  fi

  echo "uv is required to sync the MOBaiLE runtime." >&2
  echo "Install it first with the one-line installer or add ~/.local/bin to PATH." >&2
  exit 1
}

merge_runtime_pairing_state() {
  local source_pairing="${BACKEND_DIR}/pairing.json"
  local runtime_pairing="${RUNTIME_DIR}/pairing.json"

  if [[ ! -f "${source_pairing}" ]]; then
    return
  fi

  python3 - "${source_pairing}" "${runtime_pairing}" << 'PY'
from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path

source_path = Path(sys.argv[1])
runtime_path = Path(sys.argv[2])


def load(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return payload if isinstance(payload, dict) else {}


source_payload = load(source_path)
runtime_payload = load(runtime_path)
if not source_payload and not runtime_payload:
    raise SystemExit(0)


def has_pair_code(payload: dict[str, object]) -> bool:
    return bool(str(payload.get("pair_code", "")).strip())


def pair_code_expiry(payload: dict[str, object]):
    raw = str(payload.get("pair_code_expires_at", "")).strip()
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def source_pair_code_is_newer():
    source_expiry = pair_code_expiry(source_payload)
    runtime_expiry = pair_code_expiry(runtime_payload)
    return source_expiry is not None and (
        runtime_expiry is None or source_expiry > runtime_expiry
    )


merged = dict(runtime_payload)
for key in ("session_id", "server_url", "server_urls"):
    if key in source_payload:
        merged[key] = source_payload[key]

if has_pair_code(source_payload) and (
    not has_pair_code(runtime_payload) or source_pair_code_is_newer()
):
    for key in ("pair_code", "pair_code_expires_at"):
        if key in source_payload:
            merged[key] = source_payload[key]

if "paired_clients" in runtime_payload:
    merged["paired_clients"] = runtime_payload["paired_clients"]
elif "paired_clients" in source_payload:
    merged["paired_clients"] = source_payload["paired_clients"]

runtime_path.parent.mkdir(parents=True, exist_ok=True)
runtime_path.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
PY

  rm -f "${RUNTIME_DIR}/pairing-qr.png"
}

sync_runtime() {
  ensure_uv_available
  mkdir -p "${RUNTIME_DIR}"
  if command -v rsync > /dev/null 2>&1; then
    rsync -a --delete \
      --exclude ".venv" \
      --exclude "__pycache__" \
      --exclude "sandbox" \
      --exclude "data" \
      --exclude "logs" \
      --exclude "pairing.json" \
      --exclude "pairing-qr.png" \
      "${BACKEND_DIR}/" "${RUNTIME_DIR}/"
  else
    echo "rsync not found; using cp fallback" >&2
    local saved_pairing=""
    if [[ -f "${RUNTIME_DIR}/pairing.json" ]]; then
      saved_pairing="$(mktemp)"
      cp "${RUNTIME_DIR}/pairing.json" "${saved_pairing}"
    fi
    cp -R "${BACKEND_DIR}/." "${RUNTIME_DIR}/"
    if [[ -n "${saved_pairing}" ]]; then
      cp "${saved_pairing}" "${RUNTIME_DIR}/pairing.json"
      rm -f "${saved_pairing}"
    fi
  fi

  if [[ -f "${BACKEND_DIR}/.env" ]]; then
    cp "${BACKEND_DIR}/.env" "${RUNTIME_DIR}/.env"
  fi

  merge_runtime_pairing_state

  local sync_output=""
  if sync_output="$(
    cd "${RUNTIME_DIR}"
    uv sync 2>&1
  )"; then
    return
  fi

  printf "%s\n" "${sync_output}" >&2
  exit 1
}

write_unit() {
  mkdir -p "${SYSTEMD_USER_DIR}"
  cat > "${UNIT_PATH}" << EOF
[Unit]
Description=MOBaiLE backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${RUNTIME_DIR}
ExecStart=/bin/bash ${RUN_SCRIPT}
Restart=always
RestartSec=2
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
EOF
}

run_warmup_if_enabled() {
  if [[ "${WARMUP_ON_START}" != "true" ]]; then
    return
  fi
  if [[ ! -x "${WARMUP_SCRIPT}" ]]; then
    echo "Warmup script missing or not executable: ${WARMUP_SCRIPT}" >&2
    return
  fi
  local warmup_output=""
  local warmup_status=0
  local report_path=""

  echo "Checking optional host integrations..."
  if warmup_output="$("${WARMUP_SCRIPT}" --deep false --launch-apps false 2>&1)"; then
    warmup_status=0
  else
    warmup_status=$?
  fi

  report_path="$(printf "%s\n" "${warmup_output}" | awk -F': ' '/^Report path: / {print $2; exit}')"

  if [[ ${warmup_status} -ne 0 ]] || [[ "${warmup_output}" == *"Readiness warning:"* ]]; then
    echo "Some optional host integrations are not ready yet. MOBaiLE will still run."
    if [[ -n "${report_path}" ]]; then
      echo "Capability report: ${report_path}"
    fi
  fi
}

reload_systemd() {
  systemctl --user daemon-reload
}

install_service() {
  sync_runtime
  write_unit
  reload_systemd
  systemctl --user enable "${UNIT_NAME}" > /dev/null
  systemctl --user restart "${UNIT_NAME}" > /dev/null
  run_warmup_if_enabled
  echo "Background service installed and running."
}

uninstall_service() {
  systemctl --user disable --now "${UNIT_NAME}" > /dev/null 2>&1 || true
  rm -f "${UNIT_PATH}"
  reload_systemd
  echo "Background service removed."
}

start_service() {
  if [[ ! -f "${UNIT_PATH}" ]]; then
    echo "Systemd unit missing. Run: bash ./scripts/service_linux.sh install" >&2
    exit 1
  fi
  sync_runtime
  write_unit
  reload_systemd
  systemctl --user restart "${UNIT_NAME}" > /dev/null
  run_warmup_if_enabled
  echo "Background service started."
}

stop_service() {
  systemctl --user stop "${UNIT_NAME}"
  echo "Background service stopped."
}

status_service() {
  systemctl --user status "${UNIT_NAME}" --no-pager --full || true
}

logs_service() {
  journalctl --user -u "${UNIT_NAME}" -n 80 -f
}

main() {
  require_linux
  local cmd="${1:-}"
  case "${cmd}" in
    install)
      require_systemd_user
      install_service
      ;;
    uninstall)
      require_systemd_user
      uninstall_service
      ;;
    sync)
      sync_runtime
      echo "Synced runtime to ${RUNTIME_DIR}"
      ;;
    start)
      require_systemd_user
      start_service
      ;;
    stop)
      require_systemd_user
      stop_service
      ;;
    restart)
      require_systemd_user
      stop_service
      start_service
      ;;
    status)
      require_systemd_user
      status_service
      ;;
    logs)
      require_systemd_user
      logs_service
      ;;
    warmup)
      "${WARMUP_SCRIPT}"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
