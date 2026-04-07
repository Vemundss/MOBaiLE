from __future__ import annotations

from app.pairing_url_policy import (
    dedupe_server_urls,
    is_public_server_url,
    normalize_server_url,
    server_url_matches_mode,
)


def test_normalize_server_url_adds_https_and_trims_paths() -> None:
    assert normalize_server_url("relay.example.com/path/") == "https://relay.example.com"
    assert normalize_server_url("http://relay.example.com:8000/api") == "http://relay.example.com:8000"


def test_dedupe_server_urls_normalizes_duplicates() -> None:
    assert dedupe_server_urls(
        [
            "relay.example.com",
            "https://relay.example.com/",
            "http://100.64.0.1:8000",
        ]
    ) == [
        "https://relay.example.com",
        "http://100.64.0.1:8000",
    ]


def test_server_url_matches_mode_distinguishes_tailscale_and_wifi() -> None:
    assert server_url_matches_mode(
        "http://mobaile.tail6a5903.ts.net:8000",
        phone_access_mode="tailscale",
    )
    assert server_url_matches_mode(
        "http://192.168.1.20:8000",
        phone_access_mode="wifi",
    )
    assert not server_url_matches_mode(
        "http://192.168.1.20:8000",
        phone_access_mode="tailscale",
    )


def test_is_public_server_url_rejects_private_and_tailscale_hosts() -> None:
    assert is_public_server_url("https://relay.example.com")
    assert not is_public_server_url("http://127.0.0.1:8000")
    assert not is_public_server_url("http://100.111.99.51:8000")
    assert not is_public_server_url("http://192.168.1.20:8000")
