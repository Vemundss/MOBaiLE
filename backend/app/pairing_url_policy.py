from __future__ import annotations

import ipaddress
from urllib.parse import urlparse

from app.phone_access_mode import PhoneAccessMode


def is_network_exposed_host(host: str) -> bool:
    return not host or host in {"0.0.0.0", "::", "[::]"}


def is_loopback_host(host: str) -> bool:
    return host in {"localhost", "::1", "[::1]"} or host.startswith("127.")


def loopback_server_url(bind_port: int) -> str:
    return f"http://127.0.0.1:{bind_port}"


def is_loopback_only_server_urls(urls: list[str], *, bind_port: int) -> bool:
    normalized = dedupe_server_urls(urls)
    return normalized == [loopback_server_url(bind_port)]


def normalize_server_url(server_url: str) -> str:
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


def dedupe_server_urls(urls: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for url in urls:
        normalized = normalize_server_url(url)
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        ordered.append(normalized)
    return ordered


def server_url_matches_mode(server_url: str, *, phone_access_mode: PhoneAccessMode) -> bool:
    try:
        parsed = urlparse(server_url)
    except ValueError:
        return False
    host = (parsed.hostname or "").strip().lower()
    if not host:
        return False
    if phone_access_mode == "tailscale":
        return host.endswith(".ts.net") or is_tailscale_ipv4(host)
    if phone_access_mode == "wifi":
        if host.endswith(".local"):
            return True
        return is_private_non_loopback_ipv4(host)
    return False


def is_public_server_url(server_url: str) -> bool:
    try:
        parsed = urlparse(server_url)
    except ValueError:
        return False
    host = (parsed.hostname or "").strip().lower()
    if not host:
        return False
    if host.endswith(".local") or is_loopback_host(host):
        return False
    if is_tailscale_ipv4(host) or host.endswith(".ts.net"):
        return False
    if is_private_non_loopback_ipv4(host):
        return False
    return True


def is_ipv4(value: str) -> bool:
    try:
        return isinstance(ipaddress.ip_address(value), ipaddress.IPv4Address)
    except ValueError:
        return False


def is_private_or_loopback_ipv4(value: str) -> bool:
    try:
        addr = ipaddress.ip_address(value)
    except ValueError:
        return False
    return bool(addr.is_loopback or addr.is_private)


def is_private_non_loopback_ipv4(value: str) -> bool:
    try:
        addr = ipaddress.ip_address(value)
    except ValueError:
        return False
    return bool(addr.is_private and not addr.is_loopback)


def is_tailscale_ipv4(value: str) -> bool:
    try:
        addr = ipaddress.ip_address(value)
    except ValueError:
        return False
    return addr.version == 4 and addr in ipaddress.ip_network("100.64.0.0/10")


def is_routable_local_ipv4(value: str) -> bool:
    if not is_ipv4(value):
        return False
    return not value.startswith("127.") and value != "0.0.0.0"
