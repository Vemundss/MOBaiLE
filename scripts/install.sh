#!/usr/bin/env bash
set -euo pipefail

REPO_URL_DEFAULT="https://github.com/vemundss/MOBaiLE.git"
CHECKOUT_DEFAULT="${HOME}/MOBaiLE"

CHECKOUT=""
MODE="full-access"
PHONE_ACCESS_MODE="tailscale"
BACKGROUND_SERVICE="yes"
PUBLIC_SERVER_URL=""
NON_INTERACTIVE="false"
DRY_RUN="false"

step() {
  echo
  echo "== ${1} =="
}

fail() {
  echo "${1}" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: bash ./scripts/install.sh [options]

Options:
  --checkout <path>            Use an existing checkout
  --non-interactive            Skip prompts and use flags/defaults
  --dry-run                    Print choices and commands without changing anything
  --phone-access <mode>        tailscale, wifi, or local
  --background-service <value> yes or no
  --mode <value>               full-access or safe
  --public-url <url>           Use a public URL for pairing
  -h, --help                   Show this help
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    fail "Missing command: ${cmd}"
  fi
}

normalize_existing_path() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    (
      cd "${path}"
      pwd -P
    )
    return
  fi
  printf "%s\n" "${path}"
}

validate_mode() {
  case "${MODE}" in
    full-access|safe) ;;
    *) fail "Invalid --mode '${MODE}'. Expected full-access or safe." ;;
  esac
}

validate_phone_access() {
  case "${PHONE_ACCESS_MODE}" in
    tailscale|wifi|local) ;;
    *) fail "Invalid --phone-access '${PHONE_ACCESS_MODE}'. Expected tailscale, wifi, or local." ;;
  esac
}

validate_background_service() {
  case "${BACKGROUND_SERVICE}" in
    yes|no) ;;
    *) fail "Invalid --background-service '${BACKGROUND_SERVICE}'. Expected yes or no." ;;
  esac
}

validate_public_server_url() {
  if [[ -z "${PUBLIC_SERVER_URL}" ]]; then
    return
  fi
  case "${PUBLIC_SERVER_URL}" in
    http://*|https://*) ;;
    *) fail "Invalid --public-url '${PUBLIC_SERVER_URL}'. Expected http://... or https://..." ;;
  esac
}

format_command() {
  local formatted=""
  local arg
  for arg in "$@"; do
    if [[ -n "${formatted}" ]]; then
      formatted+=" "
    fi
    printf -v arg "%q" "${arg}"
    formatted+="${arg}"
  done
  printf "%s\n" "${formatted}"
}

print_command() {
  echo "  $(format_command "$@")"
}

run_command() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    print_command "$@"
    return
  fi
  "$@"
}

service_script_path() {
  case "$(uname -s)" in
    Darwin) printf "%s\n" "${CHECKOUT}/scripts/service_macos.sh" ;;
    Linux) printf "%s\n" "${CHECKOUT}/scripts/service_linux.sh" ;;
    *) printf "\n" ;;
  esac
}

build_reexec_args() {
  local args=(
    --checkout "${CHECKOUT_DEFAULT}"
    --mode "${MODE}"
    --phone-access "${PHONE_ACCESS_MODE}"
    --background-service "${BACKGROUND_SERVICE}"
  )

  if [[ -n "${PUBLIC_SERVER_URL}" ]]; then
    args+=(--public-url "${PUBLIC_SERVER_URL}")
  fi
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    args+=(--non-interactive)
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    args+=(--dry-run)
  fi

  printf "%s\n" "${args[@]}"
}

ensure_checkout() {
  if [[ -n "${CHECKOUT}" ]]; then
    CHECKOUT="$(normalize_existing_path "${CHECKOUT}")"
    [[ -f "${CHECKOUT}/scripts/install_backend.sh" ]] || fail "Missing ${CHECKOUT}/scripts/install_backend.sh"
    [[ -f "${CHECKOUT}/scripts/pairing_qr.sh" ]] || fail "Missing ${CHECKOUT}/scripts/pairing_qr.sh"
    [[ -f "${CHECKOUT}/scripts/mobaile" ]] || fail "Missing ${CHECKOUT}/scripts/mobaile"
    return
  fi

  local target="${CHECKOUT_DEFAULT}"
  local reexec_args=()
  local arg
  while IFS= read -r arg; do
    reexec_args+=("${arg}")
  done < <(build_reexec_args)

  CHECKOUT="${target}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    step "Checkout"
    if [[ -d "${target}/.git" ]]; then
      print_command git -C "${target}" fetch --all --prune
      print_command git -C "${target}" pull --ff-only
    else
      print_command git clone "${REPO_URL_DEFAULT}" "${target}"
    fi
    print_command bash "${target}/scripts/install.sh" "${reexec_args[@]}"
    return
  fi

  require_cmd git
  mkdir -p "$(dirname "${target}")"
  if [[ -d "${target}/.git" ]]; then
    (
      cd "${target}"
      git fetch --all --prune
      git pull --ff-only
    )
  else
    git clone "${REPO_URL_DEFAULT}" "${target}"
  fi

  exec bash "${target}/scripts/install.sh" "${reexec_args[@]}"
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local answer=""

  read -r -p "${prompt}" answer
  if [[ -z "${answer}" ]]; then
    printf "%s\n" "${default_value}"
    return
  fi
  printf "%s\n" "${answer}"
}

choose_mode() {
  local answer=""
  local default_choice="1"
  if [[ "${MODE}" == "safe" ]]; then
    default_choice="2"
  fi
  while true; do
    echo
    echo "How much access should MOBaiLE have?"
    echo "  1) Full Access"
    echo "  2) Safer setup"
    answer="$(prompt_with_default "Choose 1-2 [${default_choice}]: " "${default_choice}")"
    case "${answer}" in
      1)
        MODE="full-access"
        return
        ;;
      2)
        MODE="safe"
        return
        ;;
    esac
    echo "Please choose 1 or 2."
  done
}

choose_public_server_url() {
  local answer=""
  while true; do
    answer="$(prompt_with_default "Public URL: " "")"
    if [[ -z "${answer}" ]]; then
      echo "Please enter a URL."
      continue
    fi
    PUBLIC_SERVER_URL="${answer%/}"
    validate_public_server_url
    PHONE_ACCESS_MODE="tailscale"
    return
  done
}

choose_phone_access() {
  local answer=""
  local default_choice="1"
  if [[ -n "${PUBLIC_SERVER_URL}" || "${PHONE_ACCESS_MODE}" == "local" ]]; then
    default_choice="3"
  elif [[ "${PHONE_ACCESS_MODE}" == "wifi" ]]; then
    default_choice="2"
  fi
  while true; do
    echo
    echo "Where should your phone work?"
    echo "  1) Anywhere with Tailscale"
    echo "  2) On this Wi-Fi"
    echo "  3) Advanced..."
    answer="$(prompt_with_default "Choose 1-3 [${default_choice}]: " "${default_choice}")"
    case "${answer}" in
      1)
        PHONE_ACCESS_MODE="tailscale"
        PUBLIC_SERVER_URL=""
        return
        ;;
      2)
        PHONE_ACCESS_MODE="wifi"
        PUBLIC_SERVER_URL=""
        return
        ;;
      3)
        while true; do
          local advanced_default="1"
          if [[ -n "${PUBLIC_SERVER_URL}" ]]; then
            advanced_default="2"
          fi
          echo
          echo "Advanced..."
          echo "  1) This computer only"
          echo "  2) Use a public URL"
          answer="$(prompt_with_default "Choose 1-2 [${advanced_default}]: " "${advanced_default}")"
          case "${answer}" in
            1)
              PHONE_ACCESS_MODE="local"
              PUBLIC_SERVER_URL=""
              return
              ;;
            2)
              choose_public_server_url
              return
              ;;
          esac
          echo "Please choose 1 or 2."
        done
        ;;
    esac
    echo "Please choose 1, 2, or 3."
  done
}

choose_background_service() {
  local answer=""
  local default_choice="1"
  if [[ "${BACKGROUND_SERVICE}" == "no" ]]; then
    default_choice="2"
  fi
  while true; do
    echo
    echo "Should MOBaiLE stay running in the background?"
    echo "  1) Yes"
    echo "  2) No"
    answer="$(prompt_with_default "Choose 1-2 [${default_choice}]: " "${default_choice}")"
    case "${answer}" in
      1)
        BACKGROUND_SERVICE="yes"
        return
        ;;
      2)
        BACKGROUND_SERVICE="no"
        return
        ;;
    esac
    echo "Please choose 1 or 2."
  done
}

run_wizard() {
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    return
  fi

  echo "Press Enter to keep the recommended choice."

  choose_mode
  choose_phone_access
  choose_background_service
}

print_dry_run_summary() {
  local service_script
  service_script="$(service_script_path)"
  local install_backend_cmd=(
    bash "${CHECKOUT}/scripts/install_backend.sh"
    --mode "${MODE}"
    --phone-access "${PHONE_ACCESS_MODE}"
  )
  if [[ -n "${PUBLIC_SERVER_URL}" ]]; then
    install_backend_cmd+=(--public-url "${PUBLIC_SERVER_URL}")
  fi

  echo
  echo "Resolved choices:"
  echo "  checkout: ${CHECKOUT}"
  echo "  mode: ${MODE}"
  echo "  phone_access: ${PHONE_ACCESS_MODE}"
  if [[ -n "${PUBLIC_SERVER_URL}" ]]; then
    echo "  public_server_url: ${PUBLIC_SERVER_URL}"
  else
    echo "  public_server_url: (none)"
  fi
  echo "  background_service: ${BACKGROUND_SERVICE}"

  echo
  echo "Commands:"
  print_command "${install_backend_cmd[@]}"
  print_command mkdir -p "${HOME}/.local/bin"
  print_command ln -sfn "${CHECKOUT}/scripts/mobaile" "${HOME}/.local/bin/mobaile"
  if [[ "${BACKGROUND_SERVICE}" == "yes" ]]; then
    if [[ -n "${service_script}" ]]; then
      print_command bash "${service_script}" install
    else
      echo "  # background service skipped on unsupported platform"
    fi
  fi
  print_command bash "${CHECKOUT}/scripts/pairing_qr.sh"
}

install_wrapper() {
  run_command mkdir -p "${HOME}/.local/bin"
  run_command ln -sfn "${CHECKOUT}/scripts/mobaile" "${HOME}/.local/bin/mobaile"
}

run_install() {
  local install_backend_cmd=(
    bash "${CHECKOUT}/scripts/install_backend.sh"
    --mode "${MODE}"
    --phone-access "${PHONE_ACCESS_MODE}"
  )
  local service_script
  service_script="$(service_script_path)"

  if [[ -n "${PUBLIC_SERVER_URL}" ]]; then
    install_backend_cmd+=(--public-url "${PUBLIC_SERVER_URL}")
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    print_dry_run_summary
    return
  fi

  step "Installing MOBaiLE"
  "${install_backend_cmd[@]}"

  step "Installing command"
  install_wrapper

  if [[ "${BACKGROUND_SERVICE}" == "yes" ]]; then
    if [[ -n "${service_script}" ]]; then
      step "Setting up background service"
      bash "${service_script}" install
    else
      echo
      echo "Background service is not supported on $(uname -s)."
    fi
  fi

  step "Preparing pairing QR"
  bash "${CHECKOUT}/scripts/pairing_qr.sh"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --checkout)
        CHECKOUT="$2"
        shift 2
        ;;
      --non-interactive)
        NON_INTERACTIVE="true"
        shift
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --phone-access)
        PHONE_ACCESS_MODE="$2"
        shift 2
        ;;
      --background-service)
        BACKGROUND_SERVICE="$2"
        shift 2
        ;;
      --mode)
        MODE="$2"
        shift 2
        ;;
      --public-url)
        PUBLIC_SERVER_URL="${2%/}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        fail "Unknown argument: $1"
        ;;
    esac
  done

  validate_mode
  validate_phone_access
  validate_background_service
  validate_public_server_url

  ensure_checkout
  echo "MOBaiLE runs on this computer. Your iPhone connects to it."
  run_wizard

  validate_mode
  validate_phone_access
  validate_background_service
  validate_public_server_url

  run_install
}

main "$@"
