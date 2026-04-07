#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/backend/.env"

usage() {
  cat << EOF
Usage: bash ./scripts/set_security_mode.sh <safe|full-access>

Switches backend runtime mode by updating backend/.env:
  safe        restricted defaults
  full-access unrestricted defaults
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

MODE="$1"
if [[ "${MODE}" != "safe" && "${MODE}" != "full-access" ]]; then
  echo "Invalid mode: ${MODE}" >&2
  usage
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Run: bash ./scripts/install_backend.sh" >&2
  exit 1
fi

if [[ "${MODE}" == "full-access" ]]; then
  CODEX_UNRESTRICTED="true"
  ALLOW_ABS_READS="true"
else
  CODEX_UNRESTRICTED="false"
  ALLOW_ABS_READS="false"
fi

TMP_ENV="$(mktemp)"
awk \
  -v mode="${MODE}" \
  -v codex="${CODEX_UNRESTRICTED}" \
  -v reads="${ALLOW_ABS_READS}" \
  '
  BEGIN {
    seen_mode=0
    seen_codex=0
    seen_reads=0
  }
  /^VOICE_AGENT_SECURITY_MODE=/ {
    print "VOICE_AGENT_SECURITY_MODE=" mode
    seen_mode=1
    next
  }
  /^VOICE_AGENT_CODEX_UNRESTRICTED=/ {
    print "VOICE_AGENT_CODEX_UNRESTRICTED=" codex
    seen_codex=1
    next
  }
  /^VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=/ {
    print "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=" reads
    seen_reads=1
    next
  }
  { print }
  END {
    if (!seen_mode) print "VOICE_AGENT_SECURITY_MODE=" mode
    if (!seen_codex) print "VOICE_AGENT_CODEX_UNRESTRICTED=" codex
    if (!seen_reads) print "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=" reads
  }
  ' "${ENV_FILE}" > "${TMP_ENV}"
mv "${TMP_ENV}" "${ENV_FILE}"

echo "Set security mode to ${MODE} in ${ENV_FILE}"
echo "Restart backend:"
echo "  bash ./scripts/service_macos.sh restart"
