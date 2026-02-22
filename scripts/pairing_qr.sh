#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PAIRING_FILE="${REPO_ROOT}/backend/pairing.json"
OUT_FILE="${REPO_ROOT}/backend/pairing-qr.png"

usage() {
  cat <<EOF
Usage: bash ./scripts/pairing_qr.sh [--out <path>]

Reads backend/pairing.json and generates a local QR code image.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_FILE="$2"
      shift 2
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

PAYLOAD="$(PAIRING_PATH="${PAIRING_FILE}" python3 - <<'PY'
import json
import os
from pathlib import Path

p = Path(os.environ["PAIRING_PATH"])
data = json.loads(p.read_text(encoding="utf-8"))
print(json.dumps({"server_url": data["server_url"], "api_token": data["api_token"]}, separators=(",", ":")))
PY
)"

if command -v qrencode >/dev/null 2>&1; then
  qrencode -o "${OUT_FILE}" "${PAYLOAD}"
  echo "QR image written to: ${OUT_FILE}"
  echo
  echo "Terminal preview:"
  qrencode -t ansiutf8 "${PAYLOAD}" || true
  exit 0
fi

echo "qrencode is not installed."
echo "Install with: brew install qrencode"
echo
echo "Fallback payload (copy into your phone manually):"
echo "${PAYLOAD}"
