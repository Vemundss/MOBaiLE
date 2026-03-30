#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${REPO_ROOT}/backend"
ENV_FILE="${BACKEND_DIR}/.env"
PAIRING_FILE="${BACKEND_DIR}/pairing.json"
SECURITY_MODE="safe"
PAIR_CODE_TTL_MIN="30"
EXPOSE_NETWORK="false"
PROVISION_AUTONOMY_STACK="auto"
PUBLIC_SERVER_URL=""

step() {
  echo
  echo "== ${1} =="
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
}

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    return
  fi
  echo "uv not found. Installing uv..."
  require_cmd curl
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
  if ! command -v uv >/dev/null 2>&1; then
    echo "uv install completed but uv is still not on PATH." >&2
    echo "Open a new shell and run again, or add ~/.local/bin to PATH." >&2
    exit 1
  fi
}

gen_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
    return
  fi
  python3 - <<'PY'
import secrets
print(secrets.token_hex(24))
PY
}

gen_pair_code() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(10))
PY
}

pair_code_expiry() {
  PAIR_TTL_MIN="${PAIR_CODE_TTL_MIN}" python3 - <<'PY'
from datetime import datetime, timedelta, timezone
import os
ttl = int(os.environ["PAIR_TTL_MIN"])
print((datetime.now(timezone.utc) + timedelta(minutes=ttl)).isoformat().replace("+00:00", "Z"))
PY
}

detect_lan_ip() {
  local ip=""

  if command -v ipconfig >/dev/null 2>&1; then
    local iface
    for iface in en0 en1 en2; do
      ip="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
      if [[ -n "${ip}" ]]; then
        printf "%s" "${ip}"
        return
      fi
    done
  fi

  if command -v hostname >/dev/null 2>&1; then
    local candidate
    for candidate in $(hostname -I 2>/dev/null || true); do
      if [[ "${candidate}" != 127.* && "${candidate}" != "::1" ]]; then
        printf "%s" "${candidate}"
        return
      fi
    done
  fi

  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
    if [[ -n "${ip}" && "${ip}" != 127.* ]]; then
      printf "%s" "${ip}"
      return
    fi
  fi
}

detect_tailscale_dns_name() {
  if ! command -v tailscale >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    return
  fi

  tailscale status --json 2>/dev/null | python3 - <<'PY'
import json
import sys

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(0)

self_node = payload.get("Self")
if not isinstance(self_node, dict):
    raise SystemExit(0)

name = str(self_node.get("DNSName", "")).strip().rstrip(".").lower()
if name.endswith(".ts.net"):
    print(name)
PY
}

detect_url() {
  if [[ -n "${PUBLIC_SERVER_URL}" ]]; then
    printf "%s" "${PUBLIC_SERVER_URL%/}"
    return
  fi
  if [[ "${EXPOSE_NETWORK}" != "true" ]]; then
    printf "http://127.0.0.1:8000"
    return
  fi
  local url=""
  if command -v tailscale >/dev/null 2>&1; then
    local ts_dns
    ts_dns="$(detect_tailscale_dns_name || true)"
    if [[ -n "${ts_dns}" ]]; then
      url="http://${ts_dns}:8000"
    fi
  fi
  if [[ -z "${url}" ]] && command -v tailscale >/dev/null 2>&1; then
    local ts_ip
    ts_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    if [[ -n "${ts_ip}" ]]; then
      url="http://${ts_ip}:8000"
    fi
  fi
  if [[ -z "${url}" ]]; then
    local lan_ip
    lan_ip="$(detect_lan_ip)"
    if [[ -n "${lan_ip}" ]]; then
      url="http://${lan_ip}:8000"
    else
      url="http://127.0.0.1:8000"
    fi
  fi
  printf "%s" "${url}"
}

write_env_file() {
  local token="$1"
  local codex_unrestricted="false"
  local allow_abs_reads="false"
  local host_value="127.0.0.1"
  local public_url_value="${PUBLIC_SERVER_URL%/}"
  local codex_home_value="~/.codex"
  local codex_search_value="true"
  local context_file_value="../.mobaile/AGENT_CONTEXT.md"
  local playwright_output_value="data/playwright"
  local playwright_profile_value="data/playwright-profile"
  if [[ "${EXPOSE_NETWORK}" == "true" ]]; then
    host_value="0.0.0.0"
  fi
  if [[ "${SECURITY_MODE}" == "full-access" ]]; then
    codex_unrestricted="true"
    allow_abs_reads="true"
  fi
  if [[ -f "${ENV_FILE}" ]]; then
    echo "Keeping existing ${ENV_FILE}"
    local tmp_env
    tmp_env="$(mktemp)"
    awk \
      -v mode="${SECURITY_MODE}" \
      -v codex="${codex_unrestricted}" \
      -v reads="${allow_abs_reads}" \
      -v host="${host_value}" \
      -v public_url="${public_url_value}" \
      '
      BEGIN {
        seen_mode=0
        seen_codex=0
        seen_reads=0
        seen_host=0
        seen_public_url=0
        seen_codex_home=0
        seen_codex_search=0
        seen_context_file=0
        seen_playwright_output=0
        seen_playwright_profile=0
      }
      /^VOICE_AGENT_HOST=/ {
        print "VOICE_AGENT_HOST=" host
        seen_host=1
        next
      }
      /^VOICE_AGENT_SECURITY_MODE=/ {
        print "VOICE_AGENT_SECURITY_MODE=" mode
        seen_mode=1
        next
      }
      /^VOICE_AGENT_PUBLIC_SERVER_URL=/ {
        seen_public_url=1
        if (public_url != "") {
          print "VOICE_AGENT_PUBLIC_SERVER_URL=" public_url
        }
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
      /^VOICE_AGENT_CODEX_HOME=/ {
        seen_codex_home=1
        print
        next
      }
      /^VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH=/ {
        seen_codex_search=1
        print
        next
      }
      /^VOICE_AGENT_CODEX_CONTEXT_FILE=/ {
        seen_context_file=1
        if ($0 == "VOICE_AGENT_CODEX_CONTEXT_FILE=AGENT_CONTEXT.md") {
          print "VOICE_AGENT_CODEX_CONTEXT_FILE=" context_file
        } else {
          print
        }
        next
      }
      /^VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR=/ {
        seen_playwright_output=1
        print
        next
      }
      /^VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR=/ {
        seen_playwright_profile=1
        print
        next
      }
      { print }
      END {
        if (!seen_host) print "VOICE_AGENT_HOST=" host
        if (!seen_mode) print "VOICE_AGENT_SECURITY_MODE=" mode
        if (!seen_public_url && public_url != "") print "VOICE_AGENT_PUBLIC_SERVER_URL=" public_url
        if (!seen_codex) print "VOICE_AGENT_CODEX_UNRESTRICTED=" codex
        if (!seen_reads) print "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=" reads
        if (!seen_codex_home) print "VOICE_AGENT_CODEX_HOME=" codex_home
        if (!seen_codex_search) print "VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH=" codex_search
        if (!seen_context_file) print "VOICE_AGENT_CODEX_CONTEXT_FILE=" context_file
        if (!seen_playwright_output) print "VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR=" playwright_output
        if (!seen_playwright_profile) print "VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR=" playwright_profile
      }
      ' \
      -v codex_home="${codex_home_value}" \
      -v codex_search="${codex_search_value}" \
      -v context_file="${context_file_value}" \
      -v playwright_output="${playwright_output_value}" \
      -v playwright_profile="${playwright_profile_value}" \
      "${ENV_FILE}" > "${tmp_env}"
    mv "${tmp_env}" "${ENV_FILE}"
    return
  fi
  cat > "${ENV_FILE}" <<EOF
# Generated by scripts/install_backend.sh
VOICE_AGENT_API_TOKEN=${token}
VOICE_AGENT_HOST=${host_value}
VOICE_AGENT_PORT=8000
VOICE_AGENT_SECURITY_MODE=${SECURITY_MODE}
EOF
  if [[ -n "${public_url_value}" ]]; then
    cat >> "${ENV_FILE}" <<EOF
VOICE_AGENT_PUBLIC_SERVER_URL=${public_url_value}
EOF
  fi
  cat >> "${ENV_FILE}" <<EOF
VOICE_AGENT_DEFAULT_EXECUTOR=codex
VOICE_AGENT_CODEX_BINARY=codex
VOICE_AGENT_CODEX_HOME=${codex_home_value}
VOICE_AGENT_CODEX_UNRESTRICTED=${codex_unrestricted}
VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH=${codex_search_value}
VOICE_AGENT_CODEX_GUARDRAILS=warn
VOICE_AGENT_CODEX_DANGEROUS_CONFIRM_TOKEN=[allow-dangerous]
VOICE_AGENT_CODEX_USE_CONTEXT=true
VOICE_AGENT_CODEX_CONTEXT_FILE=${context_file_value}
# Optional Claude Code support:
VOICE_AGENT_CLAUDE_BINARY=claude
# VOICE_AGENT_CLAUDE_MODEL=sonnet
# VOICE_AGENT_CLAUDE_PERMISSION_MODE=acceptEdits
VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=${allow_abs_reads}
VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR=${playwright_output_value}
VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR=${playwright_profile_value}
VOICE_AGENT_PAIR_CODE_TTL_MIN=${PAIR_CODE_TTL_MIN}
# Optional model override:
# VOICE_AGENT_CODEX_MODEL=gpt-5.1
# Transcription provider: openai or mock
# Set this to mock for deterministic local testing.
VOICE_AGENT_TRANSCRIBE_PROVIDER=openai
# SQLite run store path:
VOICE_AGENT_DB_PATH=data/runs.db
# Optional fixed transcript text for /v1/audio mock mode:
# VOICE_AGENT_TRANSCRIBE_MOCK_TEXT=hello from audio
# OpenAI key is required when provider=openai:
# OPENAI_API_KEY=sk-...
# Optional OpenAI transcription model when provider=openai:
# VOICE_AGENT_TRANSCRIBE_MODEL=whisper-1
EOF
  echo "Created ${ENV_FILE}"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        SECURITY_MODE="$2"
        shift 2
        ;;
      --pair-ttl-min)
        PAIR_CODE_TTL_MIN="$2"
        shift 2
        ;;
      --public-url)
        PUBLIC_SERVER_URL="$2"
        shift 2
        ;;
      --expose-network)
        EXPOSE_NETWORK="true"
        shift
        ;;
      --with-autonomy-stack)
        PROVISION_AUTONOMY_STACK="true"
        shift
        ;;
      --skip-autonomy-stack)
        PROVISION_AUTONOMY_STACK="false"
        shift
        ;;
      -h|--help)
        echo "Usage: bash ./scripts/install_backend.sh [--mode safe|full-access] [--pair-ttl-min <minutes>] [--public-url <https://host[:port]>] [--expose-network] [--with-autonomy-stack|--skip-autonomy-stack]"
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ "${SECURITY_MODE}" != "safe" && "${SECURITY_MODE}" != "full-access" ]]; then
    echo "Invalid --mode '${SECURITY_MODE}'. Expected safe or full-access." >&2
    exit 1
  fi

  require_cmd python3
  ensure_uv

  echo "MOBaiLE backend setup"
  echo "This will prepare the backend, create pairing details, and get the host ready for the iPhone app."

  local token
  token="$(gen_token)"
  local pair_code
  pair_code="$(gen_pair_code)"
  local pair_code_expires_at
  pair_code_expires_at="$(pair_code_expiry)"
  write_env_file "${token}"

  step "Installing backend dependencies"
  (
    cd "${BACKEND_DIR}"
    uv sync
  )

  if [[ "${PROVISION_AUTONOMY_STACK}" == "auto" ]]; then
    if [[ "${SECURITY_MODE}" == "full-access" ]]; then
      PROVISION_AUTONOMY_STACK="true"
    else
      PROVISION_AUTONOMY_STACK="false"
    fi
  fi

  if [[ "${PROVISION_AUTONOMY_STACK}" == "true" ]]; then
    step "Provisioning autonomy extras"
    python3 "${REPO_ROOT}/scripts/provision_codex_autonomy.py" --mode "${SECURITY_MODE}" || true
  fi

  step "Writing pairing details"
  local server_url
  server_url="$(detect_url)"

  cat > "${PAIRING_FILE}" <<EOF
{
  "server_url": "${server_url}",
  "server_urls": ["${server_url}"],
  "session_id": "iphone-app",
  "pair_code": "${pair_code}",
  "pair_code_expires_at": "${pair_code_expires_at}"
}
EOF

  local pairing_qr_path=""
  if command -v qrencode >/dev/null 2>&1; then
    if bash "${REPO_ROOT}/scripts/pairing_qr.sh" >/dev/null 2>&1; then
      pairing_qr_path="${REPO_ROOT}/backend/pairing-qr.png"
    fi
  fi

  local has_codex="false"
  local has_claude="false"
  if command -v codex >/dev/null 2>&1; then
    has_codex="true"
  fi
  if command -v claude >/dev/null 2>&1; then
    has_claude="true"
  fi

  echo
  echo "Setup complete."
  echo
  echo "What you have now:"
  echo "  backend config: ${ENV_FILE}"
  echo "  pairing file:   ${PAIRING_FILE}"
  if [[ -n "${pairing_qr_path}" ]]; then
    echo "  pairing QR:     ${pairing_qr_path}"
  fi
  echo "  server URL:     ${server_url}"
  echo
  echo "Next on your computer:"
  echo "  1. Start the backend:"
  echo "     cd \"${BACKEND_DIR}\" && bash ./run_backend.sh"
  echo "  2. Or install the always-on service:"
  echo "     bash ./scripts/service_macos.sh install"
  echo "     bash ./scripts/service_linux.sh install"
  echo
  echo "Next on your iPhone:"
  if [[ -n "${pairing_qr_path}" ]]; then
    echo "  1. Open backend/pairing-qr.png on the computer."
  else
    echo "  1. Generate the pairing QR on the computer:"
    echo "     bash ./scripts/pairing_qr.sh"
  fi
  echo "  2. Scan it with iPhone Camera."
  echo "  3. Tap Open in MOBaiLE."
  echo
  echo "Runtime security mode:"
  echo "  ${SECURITY_MODE}"
  echo "Autonomy stack:"
  if [[ "${PROVISION_AUTONOMY_STACK}" == "true" ]]; then
    echo "  enabled (Codex MCP + skills provisioning attempted)"
  else
    echo "  disabled"
  fi
  echo "Bind host:"
  if [[ "${EXPOSE_NETWORK}" == "true" ]]; then
    echo "  0.0.0.0 (network-exposed)"
  else
    echo "  127.0.0.1 (local-only)"
  fi
  echo
  echo "Use in iOS app onboarding:"
  echo "  server_url: ${server_url}"
  if [[ -n "${PUBLIC_SERVER_URL}" ]]; then
    echo "  public_url override: ${PUBLIC_SERVER_URL%/}"
  fi
  echo "  pair_code: ${pair_code} (expires ${pair_code_expires_at})"
  echo "  session_id: iphone-app"
  echo "  # token is stored in backend/.env (not printed)"
  if [[ "${EXPOSE_NETWORK}" != "true" ]]; then
    echo
    echo "This install is local-only."
    echo "A real iPhone cannot reach 127.0.0.1, so re-run with --expose-network if you want phone pairing over LAN or Tailscale."
  fi
  echo
  if [[ "${has_codex}" == "true" || "${has_claude}" == "true" ]]; then
    echo "Agent executors detected:"
    [[ "${has_codex}" == "true" ]] && echo "  codex"
    [[ "${has_claude}" == "true" ]] && echo "  claude"
  else
    echo "No Codex/Claude CLI detected. MOBaiLE will keep only the internal local smoke/dev fallback available."
  fi
  echo
  echo "Re-provision the autonomous Codex stack later:"
  echo "  python3 ./scripts/provision_codex_autonomy.py --mode ${SECURITY_MODE}"
  if [[ "${EXPOSE_NETWORK}" == "true" && "${server_url}" == "http://127.0.0.1:8000" ]]; then
    echo
    echo "Warning: could not detect a LAN/Tailscale IP, so pairing URL still points to 127.0.0.1." >&2
    echo "Set server_url manually in the app if your machine is reachable at another address." >&2
  fi
}

main "$@"
