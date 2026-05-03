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
PHONE_ACCESS_MODE=""
PROVISION_AUTONOMY_STACK="auto"
PUBLIC_SERVER_URL=""
BRIEF_OUTPUT="false"

step() {
  echo
  echo "== ${1} =="
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
}

ensure_uv() {
  if command -v uv > /dev/null 2>&1; then
    return
  fi
  echo "uv not found. Installing uv..."
  require_cmd curl
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
  if ! command -v uv > /dev/null 2>&1; then
    echo "uv install completed but uv is still not on PATH." >&2
    echo "Open a new shell and run again, or add ~/.local/bin to PATH." >&2
    exit 1
  fi
}

gen_token() {
  if command -v openssl > /dev/null 2>&1; then
    openssl rand -hex 24
    return
  fi
  python3 - << 'PY'
import secrets
print(secrets.token_hex(24))
PY
}

gen_pair_code() {
  python3 - << 'PY'
import secrets
print(secrets.token_urlsafe(10))
PY
}

detect_codex_binary() {
  local codex_path=""
  if command -v codex > /dev/null 2>&1; then
    codex_path="$(command -v codex)"
  fi
  if [[ -z "${codex_path}" && "$(uname -s)" == "Darwin" && -x "/Applications/Codex.app/Contents/Resources/codex" ]]; then
    codex_path="/Applications/Codex.app/Contents/Resources/codex"
  fi
  if [[ -z "${codex_path}" ]]; then
    codex_path="codex"
  fi
  printf "%s\n" "${codex_path}"
}

pair_code_expiry() {
  PAIR_TTL_MIN="${PAIR_CODE_TTL_MIN}" python3 - << 'PY'
from datetime import datetime, timedelta, timezone
import os
ttl = int(os.environ["PAIR_TTL_MIN"])
print((datetime.now(timezone.utc) + timedelta(minutes=ttl)).isoformat().replace("+00:00", "Z"))
PY
}

run_uv_sync() {
  local sync_output=""

  if [[ "${BRIEF_OUTPUT}" == "true" ]]; then
    if sync_output="$(
      cd "${BACKEND_DIR}"
      uv sync 2>&1
    )"; then
      return
    fi
    printf "%s\n" "${sync_output}" >&2
    exit 1
  fi

  (
    cd "${BACKEND_DIR}"
    uv sync
  )
}

write_pairing_details() {
  local bind_host="$1"

  (
    cd "${BACKEND_DIR}"
    PAIRING_FILE="${PAIRING_FILE}" \
      PAIR_CODE="${PAIR_CODE}" \
      PAIR_CODE_EXPIRES_AT="${PAIR_CODE_EXPIRES_AT}" \
      BIND_HOST="${bind_host}" \
      BIND_PORT="8000" \
      PUBLIC_SERVER_URL="${PUBLIC_SERVER_URL%/}" \
      PHONE_ACCESS_MODE="${PHONE_ACCESS_MODE}" \
      uv run python - << 'PY'
import json
import os
from pathlib import Path

from app.pairing_url import refresh_pairing_server_url

pairing_file = Path(os.environ["PAIRING_FILE"])
payload = {
    "session_id": "iphone-app",
    "pair_code": os.environ["PAIR_CODE"],
    "pair_code_expires_at": os.environ["PAIR_CODE_EXPIRES_AT"],
}
pairing_file.parent.mkdir(parents=True, exist_ok=True)
pairing_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
refresh_pairing_server_url(
    pairing_file,
    bind_host=os.environ["BIND_HOST"],
    bind_port=int(os.environ["BIND_PORT"]),
    public_server_url=os.environ.get("PUBLIC_SERVER_URL", ""),
    phone_access_mode=os.environ["PHONE_ACCESS_MODE"],
)
PY
  )
}

read_pairing_value() {
  local key="$1"

  PAIRING_FILE="${PAIRING_FILE}" PAIRING_KEY="${key}" python3 - << 'PY'
import json
import os
from pathlib import Path

payload = json.loads(Path(os.environ["PAIRING_FILE"]).read_text(encoding="utf-8"))
value = payload.get(os.environ["PAIRING_KEY"], "")
if isinstance(value, str):
    print(value)
PY
}

write_env_file() {
  local token="$1"
  local codex_unrestricted="false"
  local allow_abs_reads="false"
  local host_value="127.0.0.1"
  local public_url_value="${PUBLIC_SERVER_URL%/}"
  local phone_access_value="${PHONE_ACCESS_MODE}"
  local default_executor_value="codex"
  local codex_binary_value
  local codex_home_value="${HOME}/.codex"
  local codex_model_value="auto"
  local codex_search_value="true"
  local use_runtime_context_value="true"
  local skip_cloud_profile_staging_value="true"
  local context_file_value="../.mobaile/runtime/RUNTIME_CONTEXT.md"
  local playwright_output_value="data/playwright"
  local playwright_profile_value="data/playwright-profile"
  if [[ "${PHONE_ACCESS_MODE}" != "local" ]]; then
    host_value="0.0.0.0"
  fi
  if [[ "${SECURITY_MODE}" == "full-access" ]]; then
    codex_unrestricted="true"
    allow_abs_reads="true"
  fi
  codex_binary_value="$(detect_codex_binary)"
  if [[ -f "${ENV_FILE}" ]]; then
    if [[ "${BRIEF_OUTPUT}" != "true" ]]; then
      echo "Keeping existing ${ENV_FILE}"
    fi
    local tmp_env
    tmp_env="$(mktemp)"
    awk \
      -v mode="${SECURITY_MODE}" \
      -v codex="${codex_unrestricted}" \
      -v reads="${allow_abs_reads}" \
      -v host="${host_value}" \
      -v public_url="${public_url_value}" \
      -v phone_access="${phone_access_value}" \
      -v default_executor="${default_executor_value}" \
      -v codex_binary="${codex_binary_value}" \
      -v codex_home="${codex_home_value}" \
      -v codex_model="${codex_model_value}" \
      -v codex_search="${codex_search_value}" \
      -v use_runtime_context="${use_runtime_context_value}" \
      -v skip_cloud_profile_staging="${skip_cloud_profile_staging_value}" \
      -v context_file="${context_file_value}" \
      -v playwright_output="${playwright_output_value}" \
      -v playwright_profile="${playwright_profile_value}" \
      '
      BEGIN {
        seen_mode=0
        seen_codex=0
        seen_reads=0
        seen_host=0
        seen_public_url=0
        seen_phone_access=0
        seen_default_executor=0
        seen_codex_binary=0
        seen_codex_home=0
        seen_codex_model=0
        seen_codex_search=0
        seen_use_runtime_context=0
        seen_skip_cloud_profile_staging=0
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
      /^VOICE_AGENT_PHONE_ACCESS_MODE=/ {
        print "VOICE_AGENT_PHONE_ACCESS_MODE=" phone_access
        seen_phone_access=1
        next
      }
      /^VOICE_AGENT_DEFAULT_EXECUTOR=/ {
        print "VOICE_AGENT_DEFAULT_EXECUTOR=" default_executor
        seen_default_executor=1
        next
      }
      /^VOICE_AGENT_CODEX_BINARY=/ {
        print "VOICE_AGENT_CODEX_BINARY=" codex_binary
        seen_codex_binary=1
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
      /^VOICE_AGENT_CODEX_MODEL=/ {
        seen_codex_model=1
        print
        next
      }
      /^VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH=/ {
        seen_codex_search=1
        print
        next
      }
      /^VOICE_AGENT_USE_RUNTIME_CONTEXT=/ {
        seen_use_runtime_context=1
        print
        next
      }
      /^VOICE_AGENT_SKIP_CLOUD_WORKDIR_PROFILE_STAGING=/ {
        seen_skip_cloud_profile_staging=1
        print "VOICE_AGENT_SKIP_CLOUD_WORKDIR_PROFILE_STAGING=" skip_cloud_profile_staging
        next
      }
      /^VOICE_AGENT_CODEX_USE_CONTEXT=/ {
        seen_use_runtime_context=1
        print "VOICE_AGENT_USE_RUNTIME_CONTEXT=" use_runtime_context
        next
      }
      /^VOICE_AGENT_RUNTIME_CONTEXT_FILE=/ {
        seen_context_file=1
        print
        next
      }
      /^VOICE_AGENT_CODEX_CONTEXT_FILE=/ {
        seen_context_file=1
        if ($0 == "VOICE_AGENT_CODEX_CONTEXT_FILE=AGENT_CONTEXT.md" || $0 == "VOICE_AGENT_CODEX_CONTEXT_FILE=../.mobaile/AGENT_CONTEXT.md") {
          print "VOICE_AGENT_RUNTIME_CONTEXT_FILE=" context_file
        } else {
          sub(/^VOICE_AGENT_CODEX_CONTEXT_FILE=/, "VOICE_AGENT_RUNTIME_CONTEXT_FILE=")
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
        if (!seen_phone_access) print "VOICE_AGENT_PHONE_ACCESS_MODE=" phone_access
        if (!seen_default_executor) print "VOICE_AGENT_DEFAULT_EXECUTOR=" default_executor
        if (!seen_codex_binary) print "VOICE_AGENT_CODEX_BINARY=" codex_binary
        if (!seen_codex) print "VOICE_AGENT_CODEX_UNRESTRICTED=" codex
        if (!seen_reads) print "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=" reads
        if (!seen_codex_home) print "VOICE_AGENT_CODEX_HOME=" codex_home
        if (!seen_codex_model) print "VOICE_AGENT_CODEX_MODEL=" codex_model
        if (!seen_codex_search) print "VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH=" codex_search
        if (!seen_use_runtime_context) print "VOICE_AGENT_USE_RUNTIME_CONTEXT=" use_runtime_context
        if (!seen_skip_cloud_profile_staging) print "VOICE_AGENT_SKIP_CLOUD_WORKDIR_PROFILE_STAGING=" skip_cloud_profile_staging
        if (!seen_context_file) print "VOICE_AGENT_RUNTIME_CONTEXT_FILE=" context_file
        if (!seen_playwright_output) print "VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR=" playwright_output
        if (!seen_playwright_profile) print "VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR=" playwright_profile
      }
      ' \
      "${ENV_FILE}" > "${tmp_env}"
    mv "${tmp_env}" "${ENV_FILE}"
    return
  fi
  cat > "${ENV_FILE}" << EOF
# Generated by scripts/install_backend.sh
VOICE_AGENT_API_TOKEN=${token}
VOICE_AGENT_HOST=${host_value}
VOICE_AGENT_PORT=8000
VOICE_AGENT_SECURITY_MODE=${SECURITY_MODE}
VOICE_AGENT_PHONE_ACCESS_MODE=${phone_access_value}
EOF
  if [[ -n "${public_url_value}" ]]; then
    cat >> "${ENV_FILE}" << EOF
VOICE_AGENT_PUBLIC_SERVER_URL=${public_url_value}
EOF
  fi
  cat >> "${ENV_FILE}" << EOF
VOICE_AGENT_DEFAULT_EXECUTOR=codex
VOICE_AGENT_CODEX_BINARY=${codex_binary_value}
VOICE_AGENT_CODEX_HOME=${codex_home_value}
VOICE_AGENT_CODEX_MODEL=${codex_model_value}
VOICE_AGENT_CODEX_UNRESTRICTED=${codex_unrestricted}
VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH=${codex_search_value}
VOICE_AGENT_CODEX_GUARDRAILS=warn
VOICE_AGENT_CODEX_DANGEROUS_CONFIRM_TOKEN=[allow-dangerous]
VOICE_AGENT_USE_RUNTIME_CONTEXT=${use_runtime_context_value}
VOICE_AGENT_SKIP_CLOUD_WORKDIR_PROFILE_STAGING=${skip_cloud_profile_staging_value}
VOICE_AGENT_RUNTIME_CONTEXT_FILE=${context_file_value}
# Optional Claude Code support:
VOICE_AGENT_CLAUDE_BINARY=claude
# VOICE_AGENT_CLAUDE_MODEL=sonnet
# VOICE_AGENT_CLAUDE_PERMISSION_MODE=acceptEdits
VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS=${allow_abs_reads}
VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR=${playwright_output_value}
VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR=${playwright_profile_value}
VOICE_AGENT_PAIR_CODE_TTL_MIN=${PAIR_CODE_TTL_MIN}
# Optional model override:
# VOICE_AGENT_CODEX_MODEL=gpt-5.5
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
  if [[ "${BRIEF_OUTPUT}" != "true" ]]; then
    echo "Created ${ENV_FILE}"
  fi
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
      --phone-access)
        PHONE_ACCESS_MODE="$2"
        shift 2
        ;;
      --brief)
        BRIEF_OUTPUT="true"
        shift
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
      -h | --help)
        echo "Usage: bash ./scripts/install_backend.sh [--mode safe|full-access] [--pair-ttl-min <minutes>] [--public-url <https://host[:port]>] [--phone-access tailscale|wifi|local] [--brief] [--expose-network] [--with-autonomy-stack|--skip-autonomy-stack]"
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
  if [[ -n "${PHONE_ACCESS_MODE}" && "${PHONE_ACCESS_MODE}" != "tailscale" && "${PHONE_ACCESS_MODE}" != "wifi" && "${PHONE_ACCESS_MODE}" != "local" ]]; then
    echo "Invalid --phone-access '${PHONE_ACCESS_MODE}'. Expected tailscale, wifi, or local." >&2
    exit 1
  fi
  if [[ -z "${PHONE_ACCESS_MODE}" ]]; then
    if [[ "${EXPOSE_NETWORK}" == "true" ]]; then
      PHONE_ACCESS_MODE="tailscale"
    else
      PHONE_ACCESS_MODE="local"
    fi
  fi
  if [[ "${PHONE_ACCESS_MODE}" == "local" ]]; then
    EXPOSE_NETWORK="false"
  else
    EXPOSE_NETWORK="true"
  fi
  if [[ -n "${PUBLIC_SERVER_URL}" && "${PUBLIC_SERVER_URL}" != https://* ]]; then
    echo "Invalid --public-url '${PUBLIC_SERVER_URL}'. Expected https://..." >&2
    exit 1
  fi

  require_cmd python3
  ensure_uv

  if [[ "${BRIEF_OUTPUT}" != "true" ]]; then
    echo "MOBaiLE backend setup"
    echo "This will prepare the backend, create pairing details, and get the host ready for the iPhone app."
  fi

  local token
  token="$(gen_token)"
  local pair_code
  pair_code="$(gen_pair_code)"
  local pair_code_expires_at
  pair_code_expires_at="$(pair_code_expiry)"
  PAIR_CODE="${pair_code}"
  PAIR_CODE_EXPIRES_AT="${pair_code_expires_at}"
  write_env_file "${token}"

  if [[ "${BRIEF_OUTPUT}" != "true" ]]; then
    step "Installing backend dependencies"
  fi
  run_uv_sync

  if [[ "${PROVISION_AUTONOMY_STACK}" == "auto" ]]; then
    if [[ "${SECURITY_MODE}" == "full-access" ]]; then
      PROVISION_AUTONOMY_STACK="true"
    else
      PROVISION_AUTONOMY_STACK="false"
    fi
  fi

  if [[ "${PROVISION_AUTONOMY_STACK}" == "true" ]]; then
    if [[ "${BRIEF_OUTPUT}" != "true" ]]; then
      step "Provisioning autonomy extras"
    fi
    python3 "${REPO_ROOT}/scripts/provision_codex_autonomy.py" --mode "${SECURITY_MODE}" || true
  fi

  if [[ "${BRIEF_OUTPUT}" != "true" ]]; then
    step "Writing pairing details"
  fi
  local bind_host="127.0.0.1"
  if [[ "${PHONE_ACCESS_MODE}" != "local" ]]; then
    bind_host="0.0.0.0"
  fi
  write_pairing_details "${bind_host}"
  local server_url
  server_url="$(read_pairing_value "server_url")"

  if [[ "${BRIEF_OUTPUT}" == "true" ]]; then
    return
  fi

  local pairing_qr_path=""
  if command -v qrencode > /dev/null 2>&1; then
    if bash "${REPO_ROOT}/scripts/pairing_qr.sh" > /dev/null 2>&1; then
      pairing_qr_path="${REPO_ROOT}/backend/pairing-qr.png"
    fi
  fi

  local has_codex="false"
  local has_claude="false"
  if command -v codex > /dev/null 2>&1; then
    has_codex="true"
  fi
  if command -v claude > /dev/null 2>&1; then
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
  echo "  2. In MOBaiLE, tap Scan Pairing QR."
  echo "  3. Point the phone at the QR and confirm the pairing."
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
  echo "Phone access mode:"
  echo "  ${PHONE_ACCESS_MODE}"
  echo
  echo "Use in iOS app onboarding:"
  echo "  server_url: ${server_url}"
  if [[ -n "${PUBLIC_SERVER_URL}" ]]; then
    echo "  public_url override: ${PUBLIC_SERVER_URL%/}"
  fi
  echo "  pair_code: ${pair_code} (expires ${pair_code_expires_at})"
  echo "  session_id: iphone-app"
  echo "  # token is stored in backend/.env (not printed)"
  if [[ "${PHONE_ACCESS_MODE}" == "local" ]]; then
    echo
    echo "This install is local-only."
    echo "A real iPhone cannot reach 127.0.0.1, so re-run with --phone-access wifi or --phone-access tailscale if you want phone pairing beyond this computer."
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
  if [[ "${PHONE_ACCESS_MODE}" != "local" && "${server_url}" == "http://127.0.0.1:8000" ]]; then
    echo
    echo "Warning: could not detect a LAN/Tailscale IP, so pairing URL still points to 127.0.0.1." >&2
    echo "Set server_url manually in the app if your machine is reachable at another address." >&2
  fi
}

main "$@"
