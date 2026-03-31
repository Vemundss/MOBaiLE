#!/usr/bin/env bash
set -euo pipefail

LABEL="com.mobile.voiceagent.backend"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${REPO_ROOT}/backend"
RUNTIME_DIR="${HOME}/Library/Application Support/MOBaiLE/backend-runtime"
RUN_SCRIPT="${RUNTIME_DIR}/run_backend.sh"
LOG_DIR="${RUNTIME_DIR}/logs"
WARMUP_SCRIPT="${REPO_ROOT}/scripts/warmup_capabilities.sh"
WARMUP_ON_START="${VOICE_AGENT_WARMUP_ON_START:-true}"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

usage() {
  cat <<EOF
Usage: bash ./scripts/service_macos.sh <command>

Commands:
  install    Sync runtime, write plist, load service, and start backend
  uninstall  Stop and remove service plist
  sync       Sync backend runtime into Application Support directory
  start      Start/refresh the launchd service
  stop       Stop the launchd service
  restart    Restart the launchd service
  status     Show launchd service state
  logs       Tail backend service logs
  warmup     Run capability warmup against current backend
EOF
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This script supports macOS launchd only." >&2
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

write_plist() {
  mkdir -p "${HOME}/Library/LaunchAgents" "${LOG_DIR}"
  cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>${RUN_SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${RUNTIME_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/backend.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/backend.err.log</string>
  </dict>
</plist>
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

bootout_if_loaded() {
  launchctl bootout "${DOMAIN}" "${PLIST_PATH}" >/dev/null 2>&1 || true
}

install_service() {
  sync_runtime
  write_plist
  bootout_if_loaded
  launchctl bootstrap "${DOMAIN}" "${PLIST_PATH}"
  launchctl enable "${DOMAIN}/${LABEL}" || true
  launchctl kickstart -k "${DOMAIN}/${LABEL}"
  run_warmup_if_enabled
  echo "Installed and started ${LABEL}"
}

uninstall_service() {
  bootout_if_loaded
  rm -f "${PLIST_PATH}"
  echo "Uninstalled ${LABEL}"
}

start_service() {
  if [[ ! -f "${PLIST_PATH}" ]]; then
    echo "Service plist missing. Run: bash ./scripts/service_macos.sh install" >&2
    exit 1
  fi
  sync_runtime
  bootout_if_loaded
  launchctl bootstrap "${DOMAIN}" "${PLIST_PATH}"
  launchctl enable "${DOMAIN}/${LABEL}" || true
  launchctl kickstart -k "${DOMAIN}/${LABEL}"
  run_warmup_if_enabled
  echo "Started ${LABEL}"
}

stop_service() {
  bootout_if_loaded
  echo "Stopped ${LABEL}"
}

status_service() {
  if launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    launchctl print "${DOMAIN}/${LABEL}" | sed -n '1,80p'
  else
    echo "${LABEL} is not loaded"
  fi
}

logs_service() {
  mkdir -p "${LOG_DIR}"
  touch "${LOG_DIR}/backend.out.log" "${LOG_DIR}/backend.err.log"
  tail -n 80 -f "${LOG_DIR}/backend.out.log" "${LOG_DIR}/backend.err.log"
}

main() {
  require_macos
  local cmd="${1:-}"
  case "${cmd}" in
    install) install_service ;;
    uninstall) uninstall_service ;;
    sync) sync_runtime; echo "Synced runtime to ${RUNTIME_DIR}" ;;
    start) start_service ;;
    stop) stop_service ;;
    restart) stop_service; start_service ;;
    status) status_service ;;
    logs) logs_service ;;
    warmup) "${WARMUP_SCRIPT}" ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
