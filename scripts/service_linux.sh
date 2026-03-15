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
  cat <<EOF
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
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl is not available. Start backend manually from backend/run_backend.sh." >&2
    exit 1
  fi
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    cat >&2 <<EOF
systemd user instance is not reachable.
Try logging into a graphical/session shell first, or enable linger:
  sudo loginctl enable-linger $(id -un)
Then rerun this command.
EOF
    exit 1
  fi
}

sync_runtime() {
  mkdir -p "${RUNTIME_DIR}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude ".venv" \
      --exclude "__pycache__" \
      --exclude "sandbox" \
      --exclude "data" \
      --exclude "logs" \
      "${BACKEND_DIR}/" "${RUNTIME_DIR}/"
  else
    echo "rsync not found; using cp fallback" >&2
    cp -R "${BACKEND_DIR}/." "${RUNTIME_DIR}/"
  fi

  if [[ -f "${BACKEND_DIR}/.env" ]]; then
    cp "${BACKEND_DIR}/.env" "${RUNTIME_DIR}/.env"
  fi

  (
    cd "${RUNTIME_DIR}"
    uv sync
  )
}

write_unit() {
  mkdir -p "${SYSTEMD_USER_DIR}"
  cat > "${UNIT_PATH}" <<EOF
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
  echo "Running capability warmup..."
  "${WARMUP_SCRIPT}" || true
}

reload_systemd() {
  systemctl --user daemon-reload
}

install_service() {
  sync_runtime
  write_unit
  reload_systemd
  systemctl --user enable "${UNIT_NAME}" >/dev/null
  systemctl --user restart "${UNIT_NAME}" >/dev/null
  run_warmup_if_enabled
  echo "Installed and started ${UNIT_NAME}"
}

uninstall_service() {
  systemctl --user disable --now "${UNIT_NAME}" >/dev/null 2>&1 || true
  rm -f "${UNIT_PATH}"
  reload_systemd
  echo "Uninstalled ${UNIT_NAME}"
}

start_service() {
  if [[ ! -f "${UNIT_PATH}" ]]; then
    echo "Systemd unit missing. Run: bash ./scripts/service_linux.sh install" >&2
    exit 1
  fi
  sync_runtime
  write_unit
  reload_systemd
  systemctl --user restart "${UNIT_NAME}" >/dev/null
  run_warmup_if_enabled
  echo "Started ${UNIT_NAME}"
}

stop_service() {
  systemctl --user stop "${UNIT_NAME}"
  echo "Stopped ${UNIT_NAME}"
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
