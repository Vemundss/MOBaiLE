#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/ios/VoiceAgentApp.xcodeproj"
SCHEME="VoiceAgentApp"
BUNDLE_ID="com.vemundss.voiceagentapp"
DERIVED_DATA_PATH="${ROOT_DIR}/build/app-store-screenshots/DerivedData"
RAW_OUTPUT_DIR="${ROOT_DIR}/build/app-store-screenshots/raw"
OUTPUT_DIR="${ROOT_DIR}/fastlane/screenshots/en-US"
RENDERER="${ROOT_DIR}/scripts/render_app_store_screenshots.py"

DEVICES=(
  "iPhone 17 Pro Max"
)

SCENARIOS=(
  "configured-empty|main|01-configured-empty"
  "conversation|main|02-live-conversation"
  "recording|main|03-voice-recording"
  "configured-empty|settings|04-settings"
  "conversation|threads|05-threads"
)

echo "Building ${SCHEME} for iOS Simulator..."
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  CODE_SIGNING_ALLOWED=NO \
  build >/tmp/mobaile-app-store-screens-build.log

APP_PATH="$(find "${DERIVED_DATA_PATH}/Build/Products" -path '*iphonesimulator/VoiceAgentApp.app' -print -quit)"
if [[ -z "${APP_PATH}" ]]; then
  echo "Could not locate built simulator app" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
mkdir -p "${RAW_OUTPUT_DIR}"
find "${OUTPUT_DIR}" -maxdepth 1 -type f -name '*.png' -delete
find "${RAW_OUTPUT_DIR}" -maxdepth 1 -type f -name '*.png' -delete

for device in "${DEVICES[@]}"; do
  echo "Preparing simulator: ${device}"
  xcrun simctl boot "${device}" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "${device}" -b
  xcrun simctl ui "${device}" appearance light >/dev/null
  xcrun simctl status_bar "${device}" clear >/dev/null 2>&1 || true
  xcrun simctl status_bar "${device}" override \
    --time "9:41" \
    --dataNetwork wifi \
    --wifiBars 3 \
    --batteryState charged \
    --batteryLevel 100 >/dev/null
  xcrun simctl uninstall "${device}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
  xcrun simctl install "${device}" "${APP_PATH}"

  for config in "${SCENARIOS[@]}"; do
    IFS="|" read -r scenario presentation filename_base <<<"${config}"
    output_name="${filename_base}-$(echo "${device}" | tr '[:upper:]' '[:lower:]' | tr ' .' '---').png"
    output_path="${RAW_OUTPUT_DIR}/${output_name}"

    echo "Capturing ${output_name}"
    xcrun simctl terminate "${device}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

    if [[ "${presentation}" == "main" ]]; then
      env \
        SIMCTL_CHILD_MOBAILE_PREVIEW_SCENARIO="${scenario}" \
        xcrun simctl launch "${device}" "${BUNDLE_ID}" >/dev/null
    else
      env \
        SIMCTL_CHILD_MOBAILE_PREVIEW_SCENARIO="${scenario}" \
        SIMCTL_CHILD_MOBAILE_PREVIEW_PRESENTATION="${presentation}" \
        xcrun simctl launch "${device}" "${BUNDLE_ID}" >/dev/null
    fi

    sleep 3
    xcrun simctl io "${device}" screenshot "${output_path}" >/dev/null
  done

  xcrun simctl status_bar "${device}" clear >/dev/null 2>&1 || true
done

python3 "${RENDERER}" --input-dir "${RAW_OUTPUT_DIR}" --output-dir "${OUTPUT_DIR}"

echo "Saved screenshots to ${OUTPUT_DIR}"
