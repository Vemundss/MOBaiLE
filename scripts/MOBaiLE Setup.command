#!/usr/bin/env bash
set -euo pipefail

INSTALL_URL="${MOBAILE_INSTALL_URL:-https://raw.githubusercontent.com/vemundss/mobaile/main/scripts/install.sh}"
INSTALL_ARGS=(--yes --high-autonomy)

pause_before_close() {
  local status="$1"
  if [[ "${MOBAILE_COMMAND_NO_PAUSE:-0}" == "1" ]]; then
    return
  fi
  echo
  if [[ "${status}" -eq 0 ]]; then
    read -r -p "MOBaiLE setup finished. Press Return to close this window. " _ || true
  else
    read -r -p "MOBaiLE setup stopped. Press Return to close this window. " _ || true
  fi
}

finish() {
  local status="$?"
  pause_before_close "${status}"
  exit "${status}"
}

require_command() {
  local command_name="$1"
  local install_hint="$2"
  if command -v "${command_name}" > /dev/null 2>&1; then
    return
  fi
  echo "Missing required command: ${command_name}"
  echo "${install_hint}"
  exit 1
}

trap finish EXIT

if [[ -t 1 ]] && command -v clear > /dev/null 2>&1; then
  clear
fi

echo "MOBaiLE Host Setup"
echo
echo "This will install or update MOBaiLE on this Mac with the high-autonomy setup path:"
echo "  - Full Access mode"
echo "  - background service"
echo "  - pairing QR"
echo "  - high-autonomy readiness checks"
echo "  - local setup page"
echo
echo "You will still approve account sign-in, Tailscale, and macOS privacy prompts when needed."
echo

require_command curl "Install curl, then open this setup launcher again."
require_command git "Install Git or run xcode-select --install, then open this setup launcher again."

if [[ "${MOBAILE_COMMAND_ASSUME_YES:-0}" != "1" ]]; then
  read -r -p "Press Return to start MOBaiLE setup, or close this window to cancel. " _ || true
fi

echo
echo "Downloading MOBaiLE installer..."
curl -fsSL "${INSTALL_URL}" | bash -s -- "${INSTALL_ARGS[@]}"
