#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${MOBAILE_RELEASE_OUT_DIR:-${ROOT_DIR}/dist}"
PACKAGE_NAME="MOBaiLE-Setup-macOS"
LAUNCHER_SOURCE="${ROOT_DIR}/scripts/MOBaiLE Setup.command"

usage() {
  cat << 'EOF'
Usage: bash ./scripts/package_macos_setup_launcher.sh [--out-dir <path>]

Packages the clickable macOS MOBaiLE setup launcher as a zip that preserves the
executable bit for GitHub release downloads.
EOF
}

while (($#)); do
  case "$1" in
    --out-dir)
      shift
      if (($# == 0)); then
        echo "Missing value for --out-dir." >&2
        exit 1
      fi
      OUT_DIR="$1"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -z "${OUT_DIR}" || "${OUT_DIR}" == "/" ]]; then
  echo "Refusing unsafe output directory: ${OUT_DIR:-<empty>}" >&2
  exit 1
fi

if [[ ! -f "${LAUNCHER_SOURCE}" ]]; then
  echo "Missing setup launcher: ${LAUNCHER_SOURCE}" >&2
  exit 1
fi

PACKAGE_DIR="${OUT_DIR}/${PACKAGE_NAME}"
ASSET_PATH="${OUT_DIR}/${PACKAGE_NAME}.zip"

mkdir -p "${OUT_DIR}"
rm -rf "${PACKAGE_DIR}" "${ASSET_PATH}"
mkdir -p "${PACKAGE_DIR}"
cp "${LAUNCHER_SOURCE}" "${PACKAGE_DIR}/MOBaiLE Setup.command"
chmod 755 "${PACKAGE_DIR}/MOBaiLE Setup.command"

if command -v ditto > /dev/null 2>&1; then
  (
    cd "${OUT_DIR}"
    ditto -c -k --keepParent "${PACKAGE_NAME}" "${PACKAGE_NAME}.zip"
  )
elif command -v zip > /dev/null 2>&1; then
  (
    cd "${OUT_DIR}"
    zip -qr "${PACKAGE_NAME}.zip" "${PACKAGE_NAME}"
  )
else
  echo "Missing zip tool. Install zip, or run on macOS where ditto is available." >&2
  exit 1
fi

echo "Wrote ${ASSET_PATH}"
