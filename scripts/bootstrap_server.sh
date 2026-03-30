#!/usr/bin/env bash
set -euo pipefail

REPO_URL_DEFAULT="https://github.com/vemundss/MOBaiLE.git"
INSTALL_DIR_DEFAULT="${HOME}/MOBaiLE"
BRANCH_DEFAULT=""
MODE_DEFAULT="safe"
AUTONOMY_STACK_DEFAULT="auto"

REPO_URL="${REPO_URL_DEFAULT}"
INSTALL_DIR="${INSTALL_DIR_DEFAULT}"
BRANCH="${BRANCH_DEFAULT}"
MODE="${MODE_DEFAULT}"
AUTONOMY_STACK="${AUTONOMY_STACK_DEFAULT}"

step() {
  echo
  echo "== ${1} =="
}

usage() {
  cat <<EOF
Usage: bash ./scripts/bootstrap_server.sh [--repo-url <url>] [--dir <path>] [--branch <name>] [--mode safe|full-access] [--with-autonomy-stack|--skip-autonomy-stack]

Bootstraps MOBaiLE backend on a server/host machine:
1) clone/update repository
2) run backend install (network exposed for phone pairing)
3) install/start macOS service (on macOS)
4) run doctor checks
5) generate pairing QR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --branch)
      BRANCH="$2"
      shift 2
      ;;
      --mode)
        MODE="$2"
        shift 2
        ;;
      --with-autonomy-stack)
        AUTONOMY_STACK="true"
        shift
        ;;
      --skip-autonomy-stack)
        AUTONOMY_STACK="false"
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

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing command: ${cmd}" >&2
    exit 1
  fi
}

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    return
  fi
  echo "uv not found. Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
  if ! command -v uv >/dev/null 2>&1; then
    echo "uv install completed but uv is still not on PATH." >&2
    echo "Open a new shell and run again, or add ~/.local/bin to PATH." >&2
    exit 1
  fi
}

clone_or_update_repo() {
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "Repository already exists at ${INSTALL_DIR}; pulling latest..."
    (
      cd "${INSTALL_DIR}"
      git fetch --all --prune
      if [[ -n "${BRANCH}" ]]; then
        git checkout "${BRANCH}"
      fi
      git pull --ff-only
    )
    return
  fi

  echo "Cloning repository to ${INSTALL_DIR}..."
  mkdir -p "$(dirname "${INSTALL_DIR}")"
  if [[ -n "${BRANCH}" ]]; then
    git clone --branch "${BRANCH}" --single-branch "${REPO_URL}" "${INSTALL_DIR}"
  else
    git clone "${REPO_URL}" "${INSTALL_DIR}"
  fi
}

main() {
  require_cmd git
  require_cmd python3
  require_cmd curl
  ensure_uv

  echo "MOBaiLE guided bootstrap"
  echo "This is the quickest way to install the backend on a computer and prepare QR pairing for the iPhone app."

  step "Cloning or updating the repository"
  clone_or_update_repo

  cd "${INSTALL_DIR}"
  step "Installing the backend"
  local install_cmd=(bash ./scripts/install_backend.sh --mode "${MODE}" --expose-network)
  if [[ "${AUTONOMY_STACK}" == "true" ]]; then
    install_cmd+=(--with-autonomy-stack)
  elif [[ "${AUTONOMY_STACK}" == "false" ]]; then
    install_cmd+=(--skip-autonomy-stack)
  fi
  "${install_cmd[@]}"

  step "Configuring background service"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    bash ./scripts/service_macos.sh install
  elif [[ "$(uname -s)" == "Linux" ]] && command -v systemctl >/dev/null 2>&1; then
    if ! bash ./scripts/service_linux.sh install; then
      echo
      echo "Linux service install did not complete. Start backend manually:"
      echo "  cd \"${INSTALL_DIR}/backend\" && bash ./run_backend.sh"
    fi
  else
    echo
    echo "Non-macOS host detected. Start backend manually:"
    echo "  cd \"${INSTALL_DIR}/backend\" && bash ./run_backend.sh"
  fi

  step "Running checks and preparing pairing"
  bash ./scripts/doctor.sh || true
  bash ./scripts/pairing_qr.sh || true

  echo
  echo "Bootstrap complete."
  echo "If service installation succeeded, the backend should now stay up automatically."
  echo
  echo "Next on your computer:"
  echo "  1. Open ${INSTALL_DIR}/backend/pairing-qr.png"
  echo
  echo "Next on your iPhone:"
  echo "  1. Scan the QR with Camera"
  echo "  2. Tap Open in MOBaiLE"
}

main "$@"
