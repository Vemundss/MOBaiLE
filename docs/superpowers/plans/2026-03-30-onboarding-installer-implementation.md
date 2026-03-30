# Onboarding Installer And Control CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a public one-line installer, a product-style terminal wizard, a stable `mobaile` control command, and simpler top-level onboarding copy across the README and iPhone setup surfaces.

**Architecture:** Keep the current install and service scripts as lower-level building blocks. Add a new public `scripts/install.sh` entrypoint that reuses a checkout or clones into `~/MOBaiLE`, asks the user a few plain-language questions, maps those choices to the existing backend/service scripts, installs a `mobaile` command into `~/.local/bin`, and finishes by generating pairing details plus a simple next-step summary. Extend the shared backend pairing URL logic so “Anywhere with Tailscale” and “On this Wi-Fi” are explicit, testable modes used both during install and at backend startup.

**Tech Stack:** Bash, Python 3.11+, pytest in `backend/`, existing `uv` workflow, SwiftUI string updates, Markdown docs.

---

## File Map

- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/install.sh`
  Public onboarding entrypoint. Handles interactive prompts, default choices, repo bootstrap/re-exec, service install choice, QR generation, and `mobaile` install.
- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/mobaile`
  Stable host control command for `status`, `pair`, `logs`, `restart`, `start`, `stop`, and `config`.
- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_mobaile_cli.py`
  CLI tests for the new `mobaile` wrapper using temp repos and env overrides.
- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_install_script.py`
  Non-interactive/dry-run tests for the public install wizard.
- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_install_backend_script.py`
  Lightweight script-level regression coverage for `scripts/install_backend.sh`.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/pairing_url.py`
  Add explicit phone access mode handling so pairing URLs can prefer Tailscale or LAN deterministically.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/runtime_environment.py`
  Parse and expose the new `VOICE_AGENT_PHONE_ACCESS_MODE`.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/main.py`
  Pass the new phone access mode into pairing URL refresh at startup.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_pairing_url.py`
  Cover Tailscale-first and Wi-Fi-first pairing URL selection.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_runtime_environment.py`
  Cover the new env parsing for phone access mode.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/install_backend.sh`
  Accept the new phone access mode, persist it into `.env`, and generate pairing details using the shared backend pairing logic.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/README.md`
  Simplify the top-level setup story around one command, one QR scan, and `mobaile status`.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/docs/USAGE.md`
  Align operator docs with the new public installer wording while keeping advanced flows lower in the document.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/README.md`
  Use the same simple onboarding language as the new installer.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/ContentView.swift`
  Update setup guide strings and commands to the new entrypoint.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/README.md`
  Document `install.sh` and `mobaile` as the user-facing commands.

### Task 1: Add Explicit Phone Access Mode Plumbing

**Files:**
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/pairing_url.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/runtime_environment.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/main.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_pairing_url.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_runtime_environment.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/install_backend.sh`

- [ ] **Step 1: Write the failing pairing and runtime tests**

```python
def test_detect_server_urls_prefers_lan_when_phone_access_mode_is_wifi(monkeypatch):
    module = importlib.import_module("app.pairing_url")
    module = importlib.reload(module)
    monkeypatch.setattr(module, "detect_tailscale_dns_name", lambda: "mobaile.tail6a5903.ts.net")
    monkeypatch.setattr(module, "detect_tailscale_ip", lambda: "100.111.99.51")
    monkeypatch.setattr(module, "detect_lan_ip", lambda: "192.168.1.20")

    assert module.detect_server_urls(
        bind_host="0.0.0.0",
        bind_port=8000,
        phone_access_mode="wifi",
    ) == ["http://192.168.1.20:8000"]


def test_runtime_environment_reads_phone_access_mode(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("VOICE_AGENT_API_TOKEN", "test-token")
    monkeypatch.setenv("VOICE_AGENT_PHONE_ACCESS_MODE", "wifi")

    env = RuntimeEnvironment.from_env(tmp_path)

    assert env.phone_access_mode == "wifi"
```

Add refresh regression coverage too:

```python
def test_refresh_pairing_server_url_preserves_same_mode_remote_url_on_degraded_wifi_detection(monkeypatch, tmp_path: Path):
    ...
```

```python
def test_install_backend_script_persists_phone_access_mode_and_pairing_urls(tmp_path: Path):
    ...
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_pairing_url.py::test_detect_server_urls_prefers_lan_when_phone_access_mode_is_wifi tests/test_runtime_environment.py::test_runtime_environment_reads_phone_access_mode -q`
Expected: FAIL with `TypeError` for the unexpected `phone_access_mode` keyword and/or missing `RuntimeEnvironment.phone_access_mode`.

- [ ] **Step 3: Add the new phone access mode to backend pairing selection and runtime config**

```python
@dataclass(frozen=True)
class RuntimeEnvironment:
    ...
    public_server_url: str
    phone_access_mode: str
    default_workdir: Path
    ...

    @classmethod
    def from_env(cls, backend_root: Path) -> "RuntimeEnvironment":
        ...
        phone_access_mode = os.getenv("VOICE_AGENT_PHONE_ACCESS_MODE", "tailscale").strip().lower()
        if phone_access_mode not in {"tailscale", "wifi", "local"}:
            phone_access_mode = "tailscale"
        ...
        return cls(
            backend_root=backend_root,
            host=host,
            port=port,
            public_server_url=public_server_url,
            phone_access_mode=phone_access_mode,
            ...
        )
```

```python
def detect_server_urls(
    *,
    bind_host: str,
    bind_port: int,
    public_server_url: str = "",
    phone_access_mode: str = "tailscale",
) -> list[str]:
    candidates: list[str] = []
    explicit_public_url = _normalize_server_url(public_server_url)
    if explicit_public_url:
        candidates.append(explicit_public_url)

    host = bind_host.strip().lower()
    if not host or host in {"0.0.0.0", "::", "[::]"}:
        if phone_access_mode == "wifi":
            lan_ip = detect_lan_ip()
            return [f"http://{lan_ip}:{bind_port}"] if lan_ip else [f"http://127.0.0.1:{bind_port}"]

        if phone_access_mode == "local":
            return [f"http://127.0.0.1:{bind_port}"]

        tailscale_dns_name = detect_tailscale_dns_name()
        if tailscale_dns_name:
            candidates.append(f"http://{tailscale_dns_name}:{bind_port}")
        tailscale_ip = detect_tailscale_ip()
        if tailscale_ip:
            candidates.append(f"http://{tailscale_ip}:{bind_port}")
        lan_ip = detect_lan_ip()
        if lan_ip:
            candidates.append(f"http://{lan_ip}:{bind_port}")
        if not candidates:
            candidates.append(f"http://127.0.0.1:{bind_port}")
        return _dedupe_server_urls(candidates)
```

```python
refresh_pairing_server_url(
    ENV.pairing_file,
    bind_host=ENV.host,
    bind_port=ENV.port,
    public_server_url=ENV.public_server_url,
    phone_access_mode=ENV.phone_access_mode,
)
```

```bash
PHONE_ACCESS_MODE="tailscale"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phone-access)
      PHONE_ACCESS_MODE="$2"
      shift 2
      ;;
    ...
  esac
done

if [[ "${PHONE_ACCESS_MODE}" != "tailscale" && "${PHONE_ACCESS_MODE}" != "wifi" && "${PHONE_ACCESS_MODE}" != "local" ]]; then
  echo "Invalid --phone-access '${PHONE_ACCESS_MODE}'. Expected tailscale, wifi, or local." >&2
  exit 1
fi
```

- [ ] **Step 4: Generate pairing details from the shared Python logic and persist the new env key**

```bash
cat >> "${ENV_FILE}" <<EOF
VOICE_AGENT_PHONE_ACCESS_MODE=${PHONE_ACCESS_MODE}
EOF
```

```bash
local pairing_urls_json
pairing_urls_json="$(
  cd "${BACKEND_DIR}" && \
  VOICE_AGENT_HOST="${host_value}" \
  VOICE_AGENT_PORT="8000" \
  VOICE_AGENT_PUBLIC_SERVER_URL="${public_url_value}" \
  VOICE_AGENT_PHONE_ACCESS_MODE="${PHONE_ACCESS_MODE}" \
  uv run python - <<'PY'
import json
import os
from app.pairing_url import detect_server_urls

urls = detect_server_urls(
    bind_host=os.environ["VOICE_AGENT_HOST"],
    bind_port=int(os.environ["VOICE_AGENT_PORT"]),
    public_server_url=os.environ.get("VOICE_AGENT_PUBLIC_SERVER_URL", ""),
    phone_access_mode=os.environ.get("VOICE_AGENT_PHONE_ACCESS_MODE", "tailscale"),
)
print(json.dumps(urls))
PY
)"

local server_url
server_url="$(PAIRING_URLS_JSON="${pairing_urls_json}" python3 - <<'PY'
import json
import os

urls = json.loads(os.environ["PAIRING_URLS_JSON"])
print(urls[0])
PY
)"
```

Use `pairing_urls_json` when writing `backend/pairing.json` so `server_url` and `server_urls` stay consistent with backend startup behavior.

During backend startup refresh, preserve a previously working same-mode remote URL only when current `tailscale` or `wifi` detection collapses to loopback-only. Do not preserve stale public URLs unless `public_server_url` is explicitly provided on the current run.

- [ ] **Step 5: Run the expanded tests and script syntax check**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_pairing_url.py tests/test_runtime_environment.py tests/test_install_backend_script.py -q`
Expected: PASS

Run: `bash -n /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/install_backend.sh`
Expected: no output

- [ ] **Step 6: Commit the plumbing changes**

```bash
cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE
git add backend/app/pairing_url.py backend/app/runtime_environment.py backend/app/main.py backend/tests/test_pairing_url.py backend/tests/test_runtime_environment.py scripts/install_backend.sh
git commit -m "feat: add explicit phone access modes"
```

### Task 2: Add The `mobaile` Host Control Command

**Files:**
- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/mobaile`
- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_mobaile_cli.py`

- [ ] **Step 1: Write the failing CLI tests**

```python
def test_mobaile_status_reports_running_summary(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / ".env").write_text(
        "\n".join(
            [
                "VOICE_AGENT_SECURITY_MODE=full-access",
                "VOICE_AGENT_PHONE_ACCESS_MODE=tailscale",
                "VOICE_AGENT_API_TOKEN=test-token",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://mobaile.tail6a5903.ts.net:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "status"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_TEST_SERVICE_STATE": "running",
            "MOBAILE_SKIP_OPEN": "1",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "MOBaiLE: Running" in result.stdout
    assert "Security: Full Access" in result.stdout
    assert "Phone access: Anywhere with Tailscale" in result.stdout
    assert "mobaile pair" in result.stdout
```

```python
def test_mobaile_pair_prints_qr_path_when_open_is_skipped(tmp_path: Path):
    repo = tmp_path / "repo"
    backend_dir = repo / "backend"
    backend_dir.mkdir(parents=True)
    (backend_dir / "pairing.json").write_text(
        '{"server_url":"http://127.0.0.1:8000","session_id":"iphone-app","pair_code":"pair-1234","pair_code_expires_at":"2999-01-01T00:00:00Z"}\n',
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts" / "mobaile"), "pair"],
        env={
            **os.environ,
            "MOBAILE_REPO_ROOT": str(repo),
            "MOBAILE_SKIP_OPEN": "1",
            "MOBAILE_TEST_PAIRING_QR": str(backend_dir / "pairing-qr.png"),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "pairing-qr.png" in result.stdout
```

- [ ] **Step 2: Run the new CLI tests to verify they fail**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_mobaile_cli.py -q`
Expected: FAIL because `scripts/mobaile` does not exist yet.

- [ ] **Step 3: Create the wrapper with repo discovery, simple status output, and service delegation**

```bash
#!/usr/bin/env bash
set -euo pipefail

resolve_repo_root() {
  if [[ -n "${MOBAILE_REPO_ROOT:-}" ]]; then
    printf "%s\n" "${MOBAILE_REPO_ROOT}"
    return
  fi

  local source_path="${BASH_SOURCE[0]}"
  while [[ -L "${source_path}" ]]; do
    source_path="$(readlink "${source_path}")"
  done
  printf "%s\n" "$(cd "$(dirname "${source_path}")/.." && pwd)"
}

friendly_security_label() {
  case "$1" in
    full-access) printf "Full Access\n" ;;
    *) printf "Safe\n" ;;
  esac
}

friendly_phone_access_label() {
  case "$1" in
    wifi) printf "On this Wi-Fi\n" ;;
    local) printf "This computer only\n" ;;
    *) printf "Anywhere with Tailscale\n" ;;
  esac
}
```

```bash
status_command() {
  local repo_root="$1"
  local backend_dir="${repo_root}/backend"
  local env_file="${backend_dir}/.env"
  local pairing_file="${backend_dir}/pairing.json"
  local security_mode="safe"
  local phone_access_mode="tailscale"
  local server_url="Not ready"

  if [[ -f "${env_file}" ]]; then
    security_mode="$(awk -F= '/^VOICE_AGENT_SECURITY_MODE=/{print $2}' "${env_file}" | tail -n1)"
    phone_access_mode="$(awk -F= '/^VOICE_AGENT_PHONE_ACCESS_MODE=/{print $2}' "${env_file}" | tail -n1)"
  fi

  if [[ -f "${pairing_file}" ]]; then
    server_url="$(PAIRING_FILE="${pairing_file}" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads(Path(os.environ["PAIRING_FILE"]).read_text(encoding="utf-8"))
print(payload.get("server_url", "Not ready"))
PY
)"
  fi

  cat <<EOF
MOBaiLE: $(service_state_label "${repo_root}")
Security: $(friendly_security_label "${security_mode}")
Phone access: $(friendly_phone_access_label "${phone_access_mode}")
URL: ${server_url}
Pairing QR: $(pairing_qr_label "${backend_dir}")

Actions:
  mobaile pair
  mobaile restart
  mobaile logs
  mobaile config
EOF
}
```

```bash
case "${1:-status}" in
  status) status_command "${repo_root}" ;;
  pair) pair_command "${repo_root}" ;;
  logs|restart|start|stop) delegate_service_command "${repo_root}" "$1" ;;
  config) config_command "${repo_root}" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
```

Implement `service_state_label`, `pair_command`, `delegate_service_command`, and `config_command` with:
- `MOBAILE_TEST_SERVICE_STATE` override for pytest
- `MOBAILE_SKIP_OPEN=1` to suppress `open`/`xdg-open` during tests
- `MOBAILE_TEST_PAIRING_QR` override so tests do not need `qrencode`
- platform-aware delegation to `scripts/service_macos.sh` or `scripts/service_linux.sh`

- [ ] **Step 4: Run the CLI tests and shell syntax checks**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_mobaile_cli.py -q`
Expected: PASS

Run: `bash -n /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/mobaile`
Expected: no output

- [ ] **Step 5: Commit the wrapper**

```bash
cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE
git add scripts/mobaile backend/tests/test_mobaile_cli.py
git commit -m "feat: add mobaile control command"
```

### Task 3: Build The Public `install.sh` Wizard

**Files:**
- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/install.sh`
- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_install_script.py`

- [ ] **Step 1: Write the failing dry-run installer tests**

```python
def test_install_script_defaults_to_full_access_and_tailscale(tmp_path: Path):
    result = subprocess.run(
        [
            "bash",
            str(PROJECT_ROOT / "scripts" / "install.sh"),
            "--checkout",
            str(PROJECT_ROOT),
            "--non-interactive",
            "--dry-run",
        ],
        env={**os.environ, "MOBAILE_SKIP_OPEN": "1"},
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "Security: Full Access" in result.stdout
    assert "Phone access: Anywhere with Tailscale" in result.stdout
    assert "scripts/install_backend.sh --mode full-access --phone-access tailscale --expose-network" in result.stdout
    assert "mobaile status" in result.stdout
```

```python
def test_install_script_can_switch_to_wifi_without_background_service(tmp_path: Path):
    result = subprocess.run(
        [
            "bash",
            str(PROJECT_ROOT / "scripts" / "install.sh"),
            "--checkout",
            str(PROJECT_ROOT),
            "--non-interactive",
            "--dry-run",
            "--phone-access",
            "wifi",
            "--background-service",
            "no",
        ],
        env={**os.environ, "MOBAILE_SKIP_OPEN": "1"},
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "Phone access: On this Wi-Fi" in result.stdout
    assert "Background service: No" in result.stdout
    assert "scripts/service_macos.sh install" not in result.stdout
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_install_script.py -q`
Expected: FAIL because `scripts/install.sh` does not exist yet.

- [ ] **Step 3: Create the wizard with explicit defaults, plain-language prompts, and non-interactive flags**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_URL_DEFAULT="https://github.com/vemundss/MOBaiLE.git"
INSTALL_DIR_DEFAULT="${HOME}/MOBaiLE"
SECURITY_MODE="full-access"
PHONE_ACCESS_MODE="tailscale"
BACKGROUND_SERVICE="yes"
DRY_RUN="false"
NON_INTERACTIVE="false"
CHECKOUT_ROOT=""
PUBLIC_SERVER_URL=""
```

```bash
prompt_choice() {
  local prompt="$1"
  local default_value="$2"
  shift 2
  local options=("$@")

  echo
  echo "${prompt}"
  local index=1
  for option in "${options[@]}"; do
    if [[ "${option}" == "${default_value}" ]]; then
      echo "  ${index}. ${option} (default)"
    else
      echo "  ${index}. ${option}"
    fi
    index=$((index + 1))
  done

  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    printf "%s\n" "${default_value}"
    return
  fi

  read -r -p "> " answer
  if [[ -z "${answer}" ]]; then
    printf "%s\n" "${default_value}"
    return
  fi
  printf "%s\n" "${options[$((answer - 1))]}"
}
```

```bash
print_intro() {
  cat <<'EOF'
MOBaiLE setup

MOBaiLE runs on this computer.
Your iPhone connects to it.
EOF
}

choose_defaults() {
  local security_choice
  security_choice="$(prompt_choice "Choose security:" "Full Access" "Full Access" "Safe")"
  case "${security_choice}" in
    "Safe") SECURITY_MODE="safe" ;;
    *) SECURITY_MODE="full-access" ;;
  esac

  local phone_choice
  phone_choice="$(prompt_choice "Where should your phone work?" "Anywhere with Tailscale" "Anywhere with Tailscale" "On this Wi-Fi" "Advanced...")"
  case "${phone_choice}" in
    "On this Wi-Fi") PHONE_ACCESS_MODE="wifi" ;;
    "Advanced...") choose_advanced_phone_access ;;
    *) PHONE_ACCESS_MODE="tailscale" ;;
  esac
}
```

Implement `choose_advanced_phone_access` with:
- `This computer only` -> `PHONE_ACCESS_MODE="local"` and no `--expose-network`
- `Use a public URL` -> prompt for `PUBLIC_SERVER_URL` and keep `PHONE_ACCESS_MODE="tailscale"` only as a fallback list behind the explicit URL

Implement `ensure_checkout` so the remote/raw script can:
1. clone or update `~/MOBaiLE`
2. `exec bash "${INSTALL_DIR}/scripts/install.sh" --checkout "${INSTALL_DIR}" ...`

Implement `run_install` so the actual lower-level calls become:

```bash
local install_cmd=(bash ./scripts/install_backend.sh --mode "${SECURITY_MODE}" --phone-access "${PHONE_ACCESS_MODE}")
if [[ "${PHONE_ACCESS_MODE}" != "local" ]]; then
  install_cmd+=(--expose-network)
fi
if [[ -n "${PUBLIC_SERVER_URL}" ]]; then
  install_cmd+=(--public-url "${PUBLIC_SERVER_URL}")
fi
"${install_cmd[@]}"
```

Install the control wrapper into `~/.local/bin`:

```bash
mkdir -p "${HOME}/.local/bin"
ln -sf "${CHECKOUT_ROOT}/scripts/mobaile" "${HOME}/.local/bin/mobaile"
```

Finish with a product summary:

```text
Done.

Security: Full Access
Phone access: Anywhere with Tailscale
Background service: Yes

Next:
  1. Scan the QR on this computer with your iPhone.
  2. Run `mobaile status` any time to check the connection.
```

- [ ] **Step 4: Add service install, QR generation, and open-path behavior**

```bash
if [[ "${BACKGROUND_SERVICE}" == "yes" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    bash ./scripts/service_macos.sh install || service_failed="true"
  elif [[ "$(uname -s)" == "Linux" ]]; then
    bash ./scripts/service_linux.sh install || service_failed="true"
  fi
fi

bash ./scripts/pairing_qr.sh || qr_failed="true"

if [[ "${MOBAILE_SKIP_OPEN:-0}" != "1" ]]; then
  if [[ -f "${CHECKOUT_ROOT}/backend/pairing-qr.png" ]] && command -v open >/dev/null 2>&1; then
    open "${CHECKOUT_ROOT}/backend/pairing-qr.png" || true
  elif [[ -f "${CHECKOUT_ROOT}/backend/pairing-qr.png" ]] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${CHECKOUT_ROOT}/backend/pairing-qr.png" >/dev/null 2>&1 || true
  fi
fi
```

Make `--dry-run` print the resolved choices and the commands that would run without mutating the system.

- [ ] **Step 5: Run the installer tests and shell syntax checks**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_install_script.py -q`
Expected: PASS

Run: `bash -n /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/install.sh`
Expected: no output

Run: `bash /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/install.sh --checkout /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE --non-interactive --dry-run`
Expected: prints `Security: Full Access`, `Phone access: Anywhere with Tailscale`, and the delegated install/service commands.

- [ ] **Step 6: Commit the public installer**

```bash
cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE
git add scripts/install.sh backend/tests/test_install_script.py
git commit -m "feat: add guided onboarding installer"
```

### Task 4: Simplify Docs And In-App Setup Copy

**Files:**
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/README.md`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/docs/USAGE.md`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/README.md`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/README.md`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/ContentView.swift`

- [ ] **Step 1: Update the top-level README to lead with the new installer and simpler language**

```markdown
## Set It Up

1. On the computer you want MOBaiLE to use, paste:

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/install.sh | bash
```

2. Keep the defaults unless you know you want something else:
   - `Full Access`
   - `Anywhere with Tailscale`
3. Scan the QR with your iPhone.
4. Later, run `mobaile status` on the computer if you want to check that everything is still running.
```

Keep the old `bootstrap_server.sh` and `install_backend.sh` commands lower in the README as fallback and advanced/operator paths only.

- [ ] **Step 2: Update usage docs, script docs, and iPhone README to use the same product wording**

```markdown
This is the quickest path:

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/install.sh | bash
```

MOBaiLE asks you three things:
- security
- where your phone should work
- whether to keep it running in the background

When setup finishes, scan the QR and use `mobaile status` later if you want a quick check.
```

In `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/README.md`, document:
- `install.sh` as the public installer
- `mobaile` as the stable control command
- `bootstrap_server.sh` and `install_backend.sh` as lower-level helpers

- [ ] **Step 3: Update the iPhone setup guide strings to the new installer command and flow**

```swift
private let quickStartURL = URL(string: "https://github.com/vemundss/MOBaiLE#set-it-up")!
private let bootstrapInstallCommand = "curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/install.sh | bash"
private let checkoutInstallCommand = "bash ./scripts/install.sh"
```

```swift
Text("Start on your computer. Pick a few simple options. Scan once. Then the app is ready.")

SetupGuideStepSummaryRow(
    stepNumber: 1,
    title: "Run the setup command on your computer",
    detail: "MOBaiLE asks about security, where your phone should work, and whether to keep it running in the background."
)

Text("After setup, you can run `mobaile status` on the computer any time to check that everything is still connected.")
```

Update the settings card and setup guide copy so:
- `Full Access` is mentioned as the default choice in the install wizard
- `Anywhere with Tailscale` is explained in plain language
- manual URL/token entry remains clearly labeled as the fallback

- [ ] **Step 4: Run the final verification commands**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_pairing_url.py tests/test_runtime_environment.py tests/test_mobaile_cli.py tests/test_install_script.py -q`
Expected: PASS

Run: `bash -n /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/install.sh /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/install_backend.sh /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/mobaile`
Expected: no output

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios && xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: `** BUILD SUCCEEDED **`

Run: `bash /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/scripts/install.sh --checkout /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE --non-interactive --dry-run`
Expected: the final summary mentions `Full Access`, `Anywhere with Tailscale`, and `mobaile status`.

- [ ] **Step 5: Commit the onboarding copy and docs**

```bash
cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE
git add README.md docs/USAGE.md ios/README.md ios/VoiceAgentApp/ContentView.swift scripts/README.md
git commit -m "docs: simplify onboarding language"
```

## Self-Review

- Spec coverage: the plan covers the public one-line installer, explicit defaults, the `mobaile` command family, simpler README/docs wording, and iPhone setup-guide alignment. Deferred items from the spec remain deferred.
- Placeholder scan: no `TODO`, `TBD`, or “implement later” placeholders remain. Each code step includes concrete functions, commands, or text to add.
- Type consistency: `phone_access_mode` is named the same way in backend env parsing, pairing URL logic, installer flags, and CLI status output.
