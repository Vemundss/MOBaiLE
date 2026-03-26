#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/backend/.env"
PAIRING_FILE="${REPO_ROOT}/backend/pairing.json"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

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

NEW_TOKEN="$(gen_token)"
NEW_PAIR_CODE="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(10))
PY
)"
PAIR_EXPIRES_AT="$(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) + timedelta(minutes=30)).isoformat().replace("+00:00", "Z"))
PY
)"
TMP_ENV="$(mktemp)"

if grep -q '^VOICE_AGENT_API_TOKEN=' "${ENV_FILE}"; then
  awk -v token="${NEW_TOKEN}" '
    BEGIN { done=0 }
    /^VOICE_AGENT_API_TOKEN=/ { print "VOICE_AGENT_API_TOKEN=" token; done=1; next }
    { print }
    END { if (!done) print "VOICE_AGENT_API_TOKEN=" token }
  ' "${ENV_FILE}" > "${TMP_ENV}"
else
  cat "${ENV_FILE}" > "${TMP_ENV}"
  printf "\nVOICE_AGENT_API_TOKEN=%s\n" "${NEW_TOKEN}" >> "${TMP_ENV}"
fi
mv "${TMP_ENV}" "${ENV_FILE}"

if [[ -f "${PAIRING_FILE}" ]]; then
  python3 - "${PAIRING_FILE}" "${NEW_PAIR_CODE}" "${PAIR_EXPIRES_AT}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
pair_code = sys.argv[2]
expires = sys.argv[3]
payload = json.loads(path.read_text(encoding="utf-8"))
payload.pop("api_token", None)
payload["pair_code"] = pair_code
payload["pair_code_expires_at"] = expires
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
fi

echo "Rotated VOICE_AGENT_API_TOKEN in:"
echo "  ${ENV_FILE}"
if [[ -f "${PAIRING_FILE}" ]]; then
  echo "  ${PAIRING_FILE}"
  echo "Also rotated pairing code (expires ${PAIR_EXPIRES_AT})."
fi
echo
echo "Restart backend for token to take effect:"
echo "  bash ./scripts/service_macos.sh restart"
