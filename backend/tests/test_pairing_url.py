from __future__ import annotations

import importlib
import json
from pathlib import Path


def test_detect_server_url_prefers_tailscale_for_network_exposed_backend(monkeypatch):
    module = importlib.import_module("app.pairing_url")
    module = importlib.reload(module)
    monkeypatch.setattr(module, "detect_tailscale_dns_name", lambda: "mobaile.tail6a5903.ts.net")
    monkeypatch.setattr(module, "detect_tailscale_ip", lambda: "100.111.99.51")
    monkeypatch.setattr(module, "detect_lan_ip", lambda: "192.168.1.20")

    resolved = module.detect_server_url(bind_host="0.0.0.0", bind_port=8000)

    assert resolved == "http://mobaile.tail6a5903.ts.net:8000"
    assert module.detect_server_urls(bind_host="0.0.0.0", bind_port=8000) == [
        "http://mobaile.tail6a5903.ts.net:8000",
        "http://100.111.99.51:8000",
        "http://192.168.1.20:8000",
    ]


def test_detect_server_url_keeps_loopback_for_local_only_backend(monkeypatch):
    module = importlib.import_module("app.pairing_url")
    module = importlib.reload(module)
    monkeypatch.setattr(module, "detect_tailscale_dns_name", lambda: "mobaile.tail6a5903.ts.net")
    monkeypatch.setattr(module, "detect_tailscale_ip", lambda: "100.111.99.51")
    monkeypatch.setattr(module, "detect_lan_ip", lambda: "192.168.1.20")

    resolved = module.detect_server_url(bind_host="127.0.0.1", bind_port=8000)

    assert resolved == "http://127.0.0.1:8000"


def test_detect_server_urls_wifi_mode_prefers_lan_only(monkeypatch):
    module = importlib.import_module("app.pairing_url")
    module = importlib.reload(module)
    monkeypatch.setattr(module, "detect_tailscale_dns_name", lambda: "mobaile.tail6a5903.ts.net")
    monkeypatch.setattr(module, "detect_tailscale_ip", lambda: "100.111.99.51")
    monkeypatch.setattr(module, "detect_lan_ip", lambda: "192.168.1.20")

    resolved = module.detect_server_urls(
        bind_host="0.0.0.0",
        bind_port=8000,
        phone_access_mode="wifi",
    )

    assert resolved == ["http://192.168.1.20:8000"]


def test_detect_tailscale_dns_name_reads_status_json(monkeypatch):
    module = importlib.import_module("app.pairing_url")
    module = importlib.reload(module)

    class Result:
        returncode = 0
        stdout = '{"Self":{"DNSName":"Vemunds-MacBook-Air.tail6a5903.ts.net.","TailscaleIPs":["100.111.99.51"]}}'

    monkeypatch.setattr(module.subprocess, "run", lambda *args, **kwargs: Result())

    assert module.detect_tailscale_dns_name() == "vemunds-macbook-air.tail6a5903.ts.net"


def test_refresh_pairing_server_url_updates_stale_private_host(monkeypatch, tmp_path: Path):
    module = importlib.import_module("app.pairing_url")
    module = importlib.reload(module)
    monkeypatch.setattr(
        module,
        "detect_server_urls",
        lambda **_: [
            "http://mobaile.tail6a5903.ts.net:8000",
            "http://100.111.99.51:8000",
            "http://192.168.1.20:8000",
        ],
    )

    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        json.dumps(
            {
                "server_url": "http://172.20.10.4:8000",
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )

    module.refresh_pairing_server_url(pairing_file, bind_host="0.0.0.0", bind_port=8000)

    updated = json.loads(pairing_file.read_text(encoding="utf-8"))
    assert updated["server_url"] == "http://mobaile.tail6a5903.ts.net:8000"
    assert updated["server_urls"] == [
        "http://mobaile.tail6a5903.ts.net:8000",
        "http://100.111.99.51:8000",
        "http://192.168.1.20:8000",
    ]
    assert updated["pair_code"] == "pair-1234"


def test_refresh_pairing_server_url_preserves_explicit_public_url(monkeypatch, tmp_path: Path):
    module = importlib.import_module("app.pairing_url")
    module = importlib.reload(module)
    monkeypatch.setattr(
        module,
        "detect_server_urls",
        lambda **_: [
            "http://mobaile.tail6a5903.ts.net:8000",
            "http://100.111.99.51:8000",
            "http://192.168.1.20:8000",
        ],
    )

    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        json.dumps(
            {
                "server_url": "https://demo.mobaile.app",
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )

    module.refresh_pairing_server_url(pairing_file, bind_host="0.0.0.0", bind_port=8000)

    updated = json.loads(pairing_file.read_text(encoding="utf-8"))
    assert updated["server_url"] == "https://demo.mobaile.app"
    assert updated["server_urls"] == [
        "https://demo.mobaile.app",
        "http://mobaile.tail6a5903.ts.net:8000",
        "http://100.111.99.51:8000",
        "http://192.168.1.20:8000",
    ]


def test_refresh_pairing_server_url_prefers_explicit_public_override(monkeypatch, tmp_path: Path):
    module = importlib.import_module("app.pairing_url")
    module = importlib.reload(module)
    monkeypatch.setattr(
        module,
        "detect_server_urls",
        lambda **_: [
            "https://relay.example.com",
            "http://mobaile.tail6a5903.ts.net:8000",
            "http://100.111.99.51:8000",
        ],
    )

    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        json.dumps(
            {
                "server_url": "http://172.20.10.4:8000",
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )

    module.refresh_pairing_server_url(
        pairing_file,
        bind_host="0.0.0.0",
        bind_port=8000,
        public_server_url="https://relay.example.com",
    )

    updated = json.loads(pairing_file.read_text(encoding="utf-8"))
    assert updated["server_url"] == "https://relay.example.com"
    assert updated["server_urls"] == [
        "https://relay.example.com",
        "http://mobaile.tail6a5903.ts.net:8000",
        "http://100.111.99.51:8000",
    ]


def test_backend_startup_refreshes_pairing_server_url(monkeypatch, tmp_path: Path):
    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        json.dumps(
            {
                "server_url": "http://172.20.10.4:8000",
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv("VOICE_AGENT_PAIRING_FILE", str(pairing_file))
    monkeypatch.setenv("VOICE_AGENT_HOST", "0.0.0.0")
    monkeypatch.setenv("VOICE_AGENT_PORT", "8000")
    monkeypatch.setenv("VOICE_AGENT_TRANSCRIBE_PROVIDER", "mock")
    monkeypatch.setenv("VOICE_AGENT_API_TOKEN", "test-token")
    monkeypatch.setenv("VOICE_AGENT_DB_PATH", str(tmp_path / "runs.db"))
    monkeypatch.setenv("VOICE_AGENT_CAPABILITIES_REPORT_PATH", str(tmp_path / "capabilities.json"))

    pairing_module = importlib.import_module("app.pairing_url")
    pairing_module = importlib.reload(pairing_module)
    monkeypatch.setattr(
        pairing_module,
        "detect_server_urls",
        lambda **_: [
            "http://mobaile.tail6a5903.ts.net:8000",
            "http://100.111.99.51:8000",
            "http://192.168.1.20:8000",
        ],
    )

    main_module = importlib.import_module("app.main")
    importlib.reload(main_module)

    updated = json.loads(pairing_file.read_text(encoding="utf-8"))
    assert updated["server_url"] == "http://mobaile.tail6a5903.ts.net:8000"
    assert updated["server_urls"] == [
        "http://mobaile.tail6a5903.ts.net:8000",
        "http://100.111.99.51:8000",
        "http://192.168.1.20:8000",
    ]
