#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${REPO_ROOT}/ios/VoiceAgentApp.xcodeproj"
SCHEME="${MOBAILE_IOS_E2E_SCHEME:-VoiceAgentApp}"
CONFIGURATION="${MOBAILE_IOS_E2E_CONFIGURATION:-Debug}"
DERIVED_DATA="${MOBAILE_IOS_E2E_DERIVED_DATA:-/tmp/mobaile-ios-pairing-e2e-deriveddata}"
BUNDLE_ID="${MOBAILE_IOS_E2E_BUNDLE_ID:-com.vemundss.voiceagentapp.dev}"
PAIRING_FILE="${MOBAILE_PAIRING_FILE:-}"
SIMULATOR_SERVER_URL="${MOBAILE_IOS_E2E_SERVER_URL-http://127.0.0.1:8000}"
REFRESH_ON_EXIT=0

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" > /dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
}

default_pairing_file() {
  case "$(uname -s)" in
    Darwin)
      local runtime_pairing="${HOME}/Library/Application Support/MOBaiLE/backend-runtime/pairing.json"
      if [[ -f "${runtime_pairing}" ]]; then
        printf "%s\n" "${runtime_pairing}"
      else
        printf "%s\n" "${REPO_ROOT}/backend/pairing.json"
      fi
      ;;
    Linux)
      local runtime_pairing="${HOME}/.local/share/MOBaiLE/backend-runtime/pairing.json"
      if [[ -f "${runtime_pairing}" ]]; then
        printf "%s\n" "${runtime_pairing}"
      else
        printf "%s\n" "${REPO_ROOT}/backend/pairing.json"
      fi
      ;;
    *)
      printf "%s\n" "${REPO_ROOT}/backend/pairing.json"
      ;;
  esac
}

active_pairing_file() {
  if [[ -n "${PAIRING_FILE}" ]]; then
    printf "%s\n" "${PAIRING_FILE}"
  else
    default_pairing_file
  fi
}

refresh_pairing_code() {
  MOBAILE_SKIP_OPEN=1 bash "${REPO_ROOT}/scripts/mobaile" pair > /dev/null
}

cleanup() {
  if [[ "${REFRESH_ON_EXIT}" == "1" ]]; then
    echo "Refreshing QR after E2E run"
    refresh_pairing_code || true
  fi
}

select_simulator() {
  if [[ -n "${MOBAILE_IOS_E2E_SIMULATOR_UDID:-}" ]]; then
    printf "%s\n" "${MOBAILE_IOS_E2E_SIMULATOR_UDID}"
    return
  fi

  local devices_file booted requested_name candidate
  devices_file="$(mktemp)"
  xcrun simctl list devices booted -j > "${devices_file}"
  booted="$(
    python3 - "${devices_file}" << 'PY'
import json
from pathlib import Path
import sys

devices = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("devices", {})
for runtime_devices in devices.values():
    for device in runtime_devices:
        if device.get("isAvailable") and "iPhone" in device.get("name", ""):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
PY
  )" || true
  rm -f "${devices_file}"
  if [[ -n "${booted}" ]]; then
    printf "%s\n" "${booted}"
    return
  fi

  requested_name="${MOBAILE_IOS_E2E_SIMULATOR_NAME:-}"
  devices_file="$(mktemp)"
  xcrun simctl list devices available -j > "${devices_file}"
  candidate="$(
    SIM_NAME="${requested_name}" python3 - "${devices_file}" << 'PY'
import json
import os
from pathlib import Path
import sys

requested = os.environ.get("SIM_NAME", "").strip()
devices = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("devices", {})
fallback = ""
for runtime_devices in devices.values():
    for device in runtime_devices:
        name = device.get("name", "")
        if not device.get("isAvailable") or "iPhone" not in name:
            continue
        if requested and name == requested:
            print(device["udid"])
            raise SystemExit(0)
        if not fallback:
            fallback = device["udid"]
if fallback:
    print(fallback)
    raise SystemExit(0)
raise SystemExit(1)
PY
  )"
  rm -f "${devices_file}"

  xcrun simctl boot "${candidate}" > /dev/null 2>&1 || true
  xcrun simctl bootstatus "${candidate}" -b > /dev/null
  printf "%s\n" "${candidate}"
}

pairing_payload() {
  local file="$1"
  local simulator_server_url="$2"
  python3 - "${file}" "${simulator_server_url}" << 'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
simulator_server_url = sys.argv[2].strip().rstrip("/")
payload = json.loads(path.read_text(encoding="utf-8"))
server_urls = payload.get("server_urls")
if not isinstance(server_urls, list):
    server_urls = [payload.get("server_url", "")]
server_urls = [str(url).strip().rstrip("/") for url in server_urls if str(url).strip()]
server_url = str(payload.get("server_url", "")).strip().rstrip("/")
if server_url and server_url not in server_urls:
    server_urls.insert(0, server_url)
if simulator_server_url:
    server_urls = [simulator_server_url]
out = {
    "server_urls": server_urls,
    "pair_code": str(payload.get("pair_code", "")).strip(),
    "session_id": str(payload.get("session_id", "iphone-app")).strip() or "iphone-app",
}
if not out["server_urls"] or not out["pair_code"]:
    raise SystemExit("Pairing file is missing server_urls or pair_code")
print(json.dumps(out, separators=(",", ":")))
PY
}

pairing_snapshot() {
  local file="$1"
  python3 - "${file}" << 'PY'
import json
from pathlib import Path
import sys

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
clients = payload.get("paired_clients")
if not isinstance(clients, list):
    clients = []
last_client = clients[-1] if clients else {}
print(json.dumps({
    "pair_code": str(payload.get("pair_code", "")).strip(),
    "client_count": len(clients),
    "last_token_sha256": str(last_client.get("token_sha256", "")).strip(),
    "last_issued_at": str(last_client.get("issued_at", "")).strip(),
}, sort_keys=True))
PY
}

wait_for_pairing_exchange() {
  local file="$1"
  local before="$2"
  local deadline="${MOBAILE_IOS_E2E_TIMEOUT_SECONDS:-45}"
  local elapsed=0
  local current=""

  while [[ "${elapsed}" -lt "${deadline}" ]]; do
    current="$(pairing_snapshot "${file}")"
    if [[ "${current}" != "${before}" ]]; then
      echo "${current}"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo "Timed out waiting for the app to complete pairing." >&2
  echo "Before: ${before}" >&2
  echo "After:  ${current}" >&2
  return 1
}

main() {
  require_cmd xcodebuild
  require_cmd xcrun
  require_cmd python3

  local pairing_file
  pairing_file="$(active_pairing_file)"
  if [[ ! -f "${pairing_file}" ]]; then
    echo "Missing pairing file: ${pairing_file}" >&2
    exit 1
  fi

  echo "Refreshing live pair code"
  refresh_pairing_code
  REFRESH_ON_EXIT=1

  local payload before_snapshot simulator app_path after_snapshot
  payload="$(pairing_payload "${pairing_file}" "${SIMULATOR_SERVER_URL}")"
  before_snapshot="$(pairing_snapshot "${pairing_file}")"
  simulator="$(select_simulator)"
  app_path="${DERIVED_DATA}/Build/Products/${CONFIGURATION}-iphonesimulator/VoiceAgentApp.app"

  if [[ -n "${SIMULATOR_SERVER_URL}" ]]; then
    echo "Simulator pairing URL: ${SIMULATOR_SERVER_URL}"
  else
    echo "Simulator pairing URL: advertised QR URLs"
  fi
  echo "Building ${SCHEME} for simulator ${simulator}"
  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "platform=iOS Simulator,id=${simulator}" \
    -derivedDataPath "${DERIVED_DATA}" \
    build

  if [[ ! -d "${app_path}" ]]; then
    echo "Built app was not found at ${app_path}" >&2
    exit 1
  fi

  xcrun simctl terminate "${simulator}" "${BUNDLE_ID}" > /dev/null 2>&1 || true
  xcrun simctl uninstall "${simulator}" "${BUNDLE_ID}" > /dev/null 2>&1 || true
  xcrun simctl install "${simulator}" "${app_path}"

  echo "Launching app with live pairing payload"
  SIMCTL_CHILD_MOBAILE_UI_TESTING=1 \
    SIMCTL_CHILD_MOBAILE_TEST_PAIRING_PAYLOAD="${payload}" \
    SIMCTL_CHILD_MOBAILE_TEST_AUTO_CONFIRM_PAIRING=1 \
    xcrun simctl launch --terminate-running-process "${simulator}" "${BUNDLE_ID}" > /dev/null

  after_snapshot="$(wait_for_pairing_exchange "${pairing_file}" "${before_snapshot}")"
  echo "Pairing exchange completed"
  echo "Before: ${before_snapshot}"
  echo "After:  ${after_snapshot}"
}

trap cleanup EXIT
main "$@"
