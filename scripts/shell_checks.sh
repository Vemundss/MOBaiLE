#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"

prepend_common_tool_paths() {
  local candidate
  for candidate in /opt/homebrew/bin /usr/local/bin; do
    [[ -d "${candidate}" ]] || continue
    [[ ":${PATH}:" == *":${candidate}:"* ]] || PATH="${candidate}:${PATH}"
  done
}

usage() {
  cat << 'EOF'
Usage: bash ./scripts/shell_checks.sh <lint|format>

Commands:
  lint    Run ShellCheck and shfmt in diff mode on repo shell scripts
  format  Rewrite repo shell scripts with shfmt
EOF
}

prepend_common_tool_paths

require_tool() {
  local tool="$1"
  if ! command -v "${tool}" > /dev/null 2>&1; then
    echo "Missing required tool: ${tool}." >&2
    echo "Install shellcheck and shfmt with your preferred package manager to run the full shell checks locally." >&2
    exit 1
  fi
}

shell_targets() {
  printf '%s\n' \
    "${SCRIPTS_DIR}/shell_checks.sh" \
    "${SCRIPTS_DIR}/bootstrap_server.sh" \
    "${SCRIPTS_DIR}/capture_app_store_screenshots.sh" \
    "${SCRIPTS_DIR}/doctor.sh" \
    "${SCRIPTS_DIR}/install.sh" \
    "${SCRIPTS_DIR}/install_backend.sh" \
    "${SCRIPTS_DIR}/pairing_qr.sh" \
    "${SCRIPTS_DIR}/phone_connectivity_smoke.sh" \
    "${SCRIPTS_DIR}/rotate_api_token.sh" \
    "${SCRIPTS_DIR}/service_linux.sh" \
    "${SCRIPTS_DIR}/service_macos.sh" \
    "${SCRIPTS_DIR}/set_security_mode.sh" \
    "${SCRIPTS_DIR}/warmup_capabilities.sh" \
    "${SCRIPTS_DIR}/mobaile"
}

lint() {
  require_tool shellcheck
  require_tool shfmt

  local targets=()
  while IFS= read -r target; do
    [[ -f "${target}" ]] || continue
    targets+=("${target}")
  done < <(shell_targets)

  shellcheck -x "${targets[@]}"
  shfmt -d -i 2 -ci -sr -ln bash "${targets[@]}"
}

format() {
  require_tool shfmt

  local targets=()
  while IFS= read -r target; do
    [[ -f "${target}" ]] || continue
    targets+=("${target}")
  done < <(shell_targets)

  shfmt -w -i 2 -ci -sr -ln bash "${targets[@]}"
}

case "${1:-}" in
  lint)
    lint
    ;;
  format)
    format
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
