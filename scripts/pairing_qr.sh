#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PAIRING_FILE="${REPO_ROOT}/backend/pairing.json"
OUT_FILE="${REPO_ROOT}/backend/pairing-qr.png"
FORMAT="url"
QR_SCALE="12"
QUIET="false"
SHOW_PREVIEW="true"

ensure_uv_available() {
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi

  export PATH="${HOME}/.local/bin:${PATH}"
  command -v uv >/dev/null 2>&1
}

usage() {
  cat <<EOF
Usage: bash ./scripts/pairing_qr.sh [--out <path>] [--format url|json] [--scale <int>] [--quiet] [--no-preview]

Reads backend/pairing.json and generates a local QR code image.
  --format url   QR encodes mobaile://pair deep link (default)
  --format json  QR encodes raw {"server_url","server_urls","pair_code","session_id"} JSON
  --scale <int>  QR pixel scale (default: 12)
  --quiet        Suppress success output
  --no-preview   Skip terminal QR preview
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_FILE="$2"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --scale)
      QR_SCALE="$2"
      shift 2
      ;;
    --quiet)
      QUIET="true"
      shift
      ;;
    --no-preview)
      SHOW_PREVIEW="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "${PAIRING_FILE}" ]]; then
  echo "Missing pairing file: ${PAIRING_FILE}" >&2
  echo "Run: bash ./scripts/install_backend.sh" >&2
  exit 1
fi

PAYLOAD_JSON="$(PAIRING_PATH="${PAIRING_FILE}" python3 - <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path

p = Path(os.environ["PAIRING_PATH"])
data = json.loads(p.read_text(encoding="utf-8"))
expires_at = str(data.get("pair_code_expires_at", "")).strip()
if expires_at:
    try:
        parsed = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
    except ValueError:
        parsed = None
    if parsed is not None and parsed <= datetime.now(timezone.utc):
        raise SystemExit(
            f"pair_code in pairing.json expired at {expires_at}; "
            "run scripts/rotate_api_token.sh or scripts/install_backend.sh again"
        )
print(
    json.dumps(
        {
            "server_url": data["server_url"],
            "server_urls": data.get("server_urls", [data["server_url"]]),
            "pair_code": data["pair_code"],
            "session_id": data.get("session_id", "iphone-app"),
        },
        separators=(",", ":"),
    )
)
PY
)"

if [[ "${FORMAT}" == "json" ]]; then
  PAYLOAD="${PAYLOAD_JSON}"
elif [[ "${FORMAT}" == "url" ]]; then
  PAYLOAD="$(PAIRING_PATH="${PAIRING_FILE}" python3 - <<'PY'
import json
import os
import urllib.parse
from pathlib import Path

p = Path(os.environ["PAIRING_PATH"])
data = json.loads(p.read_text(encoding="utf-8"))
if "pair_code" not in data or not str(data["pair_code"]).strip():
    raise SystemExit("pair_code missing in pairing.json; run scripts/install_backend.sh again")
pair_code = urllib.parse.quote(data["pair_code"], safe="")
session = urllib.parse.quote(data.get("session_id", "iphone-app"), safe="")
server_urls = data.get("server_urls", [data["server_url"]])
parts = []
for raw in server_urls:
    if not str(raw).strip():
        continue
    parts.append(f"server_url={urllib.parse.quote(str(raw), safe='')}")
if not parts:
    parts.append(f"server_url={urllib.parse.quote(data['server_url'], safe='')}")
parts.append(f"pair_code={pair_code}")
parts.append(f"session_id={session}")
print("mobaile://pair?" + "&".join(parts))
PY
)"
else
  echo "Invalid --format: ${FORMAT} (expected: url or json)" >&2
  exit 1
fi

if command -v qrencode >/dev/null 2>&1; then
  if ! [[ "${QR_SCALE}" =~ ^[0-9]+$ ]] || [[ "${QR_SCALE}" -lt 1 ]]; then
    echo "Invalid --scale: ${QR_SCALE} (expected positive integer)" >&2
    exit 1
  fi

  qrencode -s "${QR_SCALE}" -o "${OUT_FILE}" "${PAYLOAD}"
  if [[ "${QUIET}" != "true" ]]; then
    echo "QR image written to: ${OUT_FILE}"
    echo "Format: ${FORMAT}"
    echo "Scale: ${QR_SCALE}"
    if [[ "${SHOW_PREVIEW}" == "true" ]]; then
      echo
      echo "Terminal preview:"
      qrencode -t ansiutf8 "${PAYLOAD}" || true
    fi
  fi
  exit 0
fi

if ensure_uv_available; then
  (
    cd "${REPO_ROOT}/backend"
    uv run python - "${OUT_FILE}" "${PAYLOAD}" "${QR_SCALE}" <<'PY'
import sys
from pathlib import Path

import qrcode

out_path = Path(sys.argv[1])
payload = sys.argv[2]
scale = int(sys.argv[3])
out_path.parent.mkdir(parents=True, exist_ok=True)
img = qrcode.make(payload, box_size=scale, border=4)
img.save(out_path)
PY
  )
  if [[ "${QUIET}" != "true" ]]; then
    echo "QR image written to: ${OUT_FILE}"
    echo "Format: ${FORMAT}"
    echo "Scale: ${QR_SCALE}"
  fi
  exit 0
fi

echo "Could not generate a QR image automatically." >&2
echo "Install qrencode, or make sure uv is available in ~/.local/bin or PATH." >&2
echo >&2
echo "Fallback payload (copy into your phone manually):" >&2
echo "${PAYLOAD}" >&2
exit 1
