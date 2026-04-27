from __future__ import annotations

import json
import socket
import subprocess
from pathlib import Path
from typing import Literal

try:
    from app.pairing_url_policy import dedupe_server_urls as _dedupe_server_urls
    from app.pairing_url_policy import is_ipv4 as _is_ipv4
    from app.pairing_url_policy import is_loopback_host as _is_loopback_host
    from app.pairing_url_policy import (
        is_network_exposed_host as _is_network_exposed_host,
    )
    from app.pairing_url_policy import (
        is_private_non_loopback_ipv4 as _is_private_non_loopback_ipv4,
    )
    from app.pairing_url_policy import is_public_server_url as _is_public_server_url
    from app.pairing_url_policy import is_routable_local_ipv4 as _is_routable_local_ipv4
    from app.pairing_url_policy import is_tailscale_ipv4 as _is_tailscale_ipv4
    from app.pairing_url_policy import loopback_server_url as _loopback_server_url
    from app.pairing_url_policy import normalize_server_url as _normalize_server_url
    from app.pairing_url_policy import (
        server_url_matches_mode as _server_url_matches_mode,
    )
    from app.phone_access_mode import PhoneAccessMode
    from app.phone_access_mode import (
        normalize_phone_access_mode as _normalize_phone_access_mode,
    )
except ModuleNotFoundError:
    import ipaddress
    from urllib.parse import urlparse

    PhoneAccessMode = Literal["tailscale", "wifi", "local"]
    _PHONE_ACCESS_MODE_OPTIONS = ("tailscale", "wifi", "local")

    def _normalize_phone_access_mode(phone_access_mode: str) -> PhoneAccessMode:
        normalized = phone_access_mode.strip().lower()
        if normalized not in _PHONE_ACCESS_MODE_OPTIONS:
            return "tailscale"
        return normalized  # type: ignore[return-value]

    def _is_network_exposed_host(host: str) -> bool:
        return not host or host in {"0.0.0.0", "::", "[::]"}

    def _is_loopback_host(host: str) -> bool:
        return host in {"localhost", "::1", "[::1]"} or host.startswith("127.")

    def _loopback_server_url(bind_port: int) -> str:
        return f"http://127.0.0.1:{bind_port}"

    def _normalize_server_url(server_url: str) -> str:
        candidate = server_url.strip().rstrip("/")
        if not candidate:
            return ""
        if "://" not in candidate:
            candidate = f"https://{candidate}"
        try:
            parsed = urlparse(candidate)
        except ValueError:
            return ""
        scheme = parsed.scheme.lower()
        host = (parsed.hostname or "").strip()
        if scheme not in {"http", "https"} or not host:
            return ""
        netloc = host
        if parsed.port is not None:
            netloc = f"{host}:{parsed.port}"
        return f"{scheme}://{netloc}"

    def _dedupe_server_urls(urls: list[str]) -> list[str]:
        seen: set[str] = set()
        ordered: list[str] = []
        for url in urls:
            normalized = _normalize_server_url(url)
            if not normalized or normalized in seen:
                continue
            seen.add(normalized)
            ordered.append(normalized)
        return ordered

    def _server_url_matches_mode(server_url: str, *, phone_access_mode: PhoneAccessMode) -> bool:
        try:
            parsed = urlparse(server_url)
        except ValueError:
            return False
        host = (parsed.hostname or "").strip().lower()
        if not host:
            return False
        if phone_access_mode == "tailscale":
            return host.endswith(".ts.net") or _is_tailscale_ipv4(host)
        if phone_access_mode == "wifi":
            if host.endswith(".local"):
                return True
            return _is_private_non_loopback_ipv4(host)
        return False

    def _is_public_server_url(server_url: str) -> bool:
        try:
            parsed = urlparse(server_url)
        except ValueError:
            return False
        host = (parsed.hostname or "").strip().lower()
        if not host:
            return False
        if host.endswith(".local") or _is_loopback_host(host):
            return False
        if _is_tailscale_ipv4(host) or host.endswith(".ts.net"):
            return False
        if _is_private_non_loopback_ipv4(host):
            return False
        return True

    def _is_ipv4(value: str) -> bool:
        try:
            return isinstance(ipaddress.ip_address(value), ipaddress.IPv4Address)
        except ValueError:
            return False

    def _is_private_non_loopback_ipv4(value: str) -> bool:
        try:
            addr = ipaddress.ip_address(value)
        except ValueError:
            return False
        return bool(addr.is_private and not addr.is_loopback)

    def _is_tailscale_ipv4(value: str) -> bool:
        try:
            addr = ipaddress.ip_address(value)
        except ValueError:
            return False
        return addr.version == 4 and addr in ipaddress.ip_network("100.64.0.0/10")

    def _is_routable_local_ipv4(value: str) -> bool:
        if not _is_ipv4(value):
            return False
        return not value.startswith("127.") and value != "0.0.0.0"


def refresh_pairing_server_url(
    pairing_file: Path,
    *,
    bind_host: str,
    bind_port: int,
    public_server_url: str = "",
    phone_access_mode: PhoneAccessMode = "tailscale",
) -> None:
    if not pairing_file.exists():
        return
    try:
        payload = json.loads(pairing_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return
    if not isinstance(payload, dict):
        return

    current = _normalize_server_url(str(payload.get("server_url", "")))
    detected = detect_server_urls(
        bind_host=bind_host,
        bind_port=bind_port,
        public_server_url=public_server_url,
        phone_access_mode=phone_access_mode,
    )
    normalized_phone_access_mode = _normalize_phone_access_mode(phone_access_mode)
    if normalized_phone_access_mode == "tailscale":
        detected = _tailscale_reachable_server_urls(detected)

    preferred: list[str] = []
    explicit_public_url = _normalize_server_url(public_server_url)
    if explicit_public_url:
        preferred.append(explicit_public_url)
    elif normalized_phone_access_mode == "tailscale" and isinstance(payload.get("server_urls"), list):
        preferred.extend(_previous_public_server_urls(payload))

    next_urls = _dedupe_server_urls(preferred + detected)
    if (
        not explicit_public_url
        and normalized_phone_access_mode in {"tailscale", "wifi"}
        and not _has_mode_url(detected, phone_access_mode=normalized_phone_access_mode)
    ):
        fallback_urls = _matching_previous_server_urls(payload, phone_access_mode=normalized_phone_access_mode)
        if fallback_urls:
            next_urls = _dedupe_server_urls(preferred + fallback_urls + detected)
    if not next_urls and current:
        next_urls = [current]
    if not next_urls:
        return

    next_primary = next_urls[0]
    if current == next_primary and _read_pairing_server_urls(payload) == next_urls:
        return

    payload["server_url"] = next_primary
    payload["server_urls"] = next_urls
    pairing_file.parent.mkdir(parents=True, exist_ok=True)
    pairing_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def detect_server_url(
    *,
    bind_host: str,
    bind_port: int,
    public_server_url: str = "",
    phone_access_mode: PhoneAccessMode = "tailscale",
) -> str:
    urls = detect_server_urls(
        bind_host=bind_host,
        bind_port=bind_port,
        public_server_url=public_server_url,
        phone_access_mode=phone_access_mode,
    )
    if urls:
        return urls[0]
    return f"http://127.0.0.1:{bind_port}"


def detect_server_urls(
    *,
    bind_host: str,
    bind_port: int,
    public_server_url: str = "",
    phone_access_mode: PhoneAccessMode = "tailscale",
) -> list[str]:
    candidates: list[str] = []
    explicit_public_url = _normalize_server_url(public_server_url)
    if explicit_public_url:
        candidates.append(explicit_public_url)

    host = bind_host.strip().lower()
    normalized_phone_access_mode = _normalize_phone_access_mode(phone_access_mode)
    if normalized_phone_access_mode == "local":
        candidates.append(_loopback_server_url(bind_port))
        return _dedupe_server_urls(candidates)

    if _is_network_exposed_host(host):
        if normalized_phone_access_mode == "wifi":
            lan_ip = detect_lan_ip()
            if lan_ip:
                candidates.append(f"http://{lan_ip}:{bind_port}")
            else:
                candidates.append(_loopback_server_url(bind_port))
            return _dedupe_server_urls(candidates)

        tailscale_dns_name = detect_tailscale_dns_name()
        if tailscale_dns_name:
            candidates.append(f"http://{tailscale_dns_name}:{bind_port}")
        tailscale_ip = detect_tailscale_ip()
        if tailscale_ip:
            candidates.append(f"http://{tailscale_ip}:{bind_port}")
        if len(candidates) == (1 if explicit_public_url else 0):
            candidates.append(_loopback_server_url(bind_port))
        return _dedupe_server_urls(candidates)

    if _is_loopback_host(host):
        candidates.append(_loopback_server_url(bind_port))
        return _dedupe_server_urls(candidates)

    candidates.append(f"http://{bind_host.strip()}:{bind_port}")
    return _dedupe_server_urls(candidates)


def detect_tailscale_dns_name() -> str | None:
    status = _read_tailscale_status()
    if not isinstance(status, dict):
        return None
    self_node = status.get("Self")
    if not isinstance(self_node, dict):
        return None
    candidate = str(self_node.get("DNSName", "")).strip().rstrip(".").lower()
    if not candidate.endswith(".ts.net"):
        return None
    return candidate


def detect_tailscale_ip() -> str | None:
    status = _read_tailscale_status()
    if isinstance(status, dict):
        self_node = status.get("Self")
        if isinstance(self_node, dict):
            raw_ips = self_node.get("TailscaleIPs")
            if isinstance(raw_ips, list):
                for item in raw_ips:
                    candidate = str(item).strip()
                    if _is_tailscale_ipv4(candidate):
                        return candidate
    try:
        result = subprocess.run(
            ["tailscale", "ip", "-4"],
            capture_output=True,
            check=False,
            text=True,
            timeout=2,
        )
    except (FileNotFoundError, OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        candidate = line.strip()
        if _is_ipv4(candidate):
            return candidate
    return None


def _read_tailscale_status() -> dict[str, object] | None:
    try:
        result = subprocess.run(
            ["tailscale", "status", "--json"],
            capture_output=True,
            check=False,
            text=True,
            timeout=2,
        )
    except (FileNotFoundError, OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def detect_lan_ip() -> str | None:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("1.1.1.1", 80))
            candidate = str(sock.getsockname()[0]).strip()
    except OSError:
        return None
    return candidate if _is_routable_local_ipv4(candidate) else None


def _read_pairing_server_urls(payload: dict[str, object]) -> list[str]:
    raw_urls = payload.get("server_urls")
    urls: list[str] = []
    if isinstance(raw_urls, list):
        for item in raw_urls:
            if not isinstance(item, str):
                continue
            normalized = _normalize_server_url(item)
            if normalized:
                urls.append(normalized)
    return _dedupe_server_urls(urls)


def _matching_previous_server_urls(payload: dict[str, object], *, phone_access_mode: PhoneAccessMode) -> list[str]:
    candidates: list[str] = []
    current = _normalize_server_url(str(payload.get("server_url", "")))
    if current and _server_url_matches_mode(current, phone_access_mode=phone_access_mode):
        candidates.append(current)
    for url in _read_pairing_server_urls(payload):
        if _server_url_matches_mode(url, phone_access_mode=phone_access_mode):
            candidates.append(url)
    return _dedupe_server_urls(candidates)


def _has_mode_url(urls: list[str], *, phone_access_mode: PhoneAccessMode) -> bool:
    return any(_server_url_matches_mode(url, phone_access_mode=phone_access_mode) for url in urls)


def _previous_public_server_urls(payload: dict[str, object]) -> list[str]:
    return [
        url
        for url in _read_pairing_server_urls(payload)
        if _is_public_server_url(url)
    ]


def _tailscale_reachable_server_urls(urls: list[str]) -> list[str]:
    return [
        url
        for url in _dedupe_server_urls(urls)
        if _server_url_matches_mode(url, phone_access_mode="tailscale") or _is_public_server_url(url)
    ]
