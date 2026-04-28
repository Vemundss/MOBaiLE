from __future__ import annotations

import plistlib
from pathlib import Path


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def test_release_info_plist_allows_insecure_http_for_tailscale_magicdns() -> None:
    info_plist_path = _repo_root() / "ios" / "VoiceAgentApp" / "Info.plist"
    payload = plistlib.loads(info_plist_path.read_bytes())

    ats = payload["NSAppTransportSecurity"]
    assert ats["NSAllowsLocalNetworking"] is True

    tailscale_exception = ats["NSExceptionDomains"]["ts.net"]
    assert tailscale_exception["NSExceptionAllowsInsecureHTTPLoads"] is True
    assert tailscale_exception["NSIncludesSubdomains"] is True


def test_xcodegen_source_keeps_tailscale_ats_exception() -> None:
    project_yml_path = _repo_root() / "ios" / "project.yml"
    text = project_yml_path.read_text(encoding="utf-8")

    assert "NSExceptionDomains:" in text
    assert "ts.net:" in text
    assert "NSExceptionAllowsInsecureHTTPLoads: true" in text
    assert "NSIncludesSubdomains: true" in text


def test_debug_info_plist_claims_standard_pairing_scheme() -> None:
    info_plist_path = _repo_root() / "ios" / "VoiceAgentApp" / "Info-Debug.plist"
    payload = plistlib.loads(info_plist_path.read_bytes())

    schemes = {
        scheme
        for url_type in payload["CFBundleURLTypes"]
        for scheme in url_type["CFBundleURLSchemes"]
    }

    assert "$(MOBAILE_URL_SCHEME)" in schemes
    assert "mobaile" in schemes


def test_debug_info_plist_allows_insecure_http_for_tailscale_magicdns() -> None:
    info_plist_path = _repo_root() / "ios" / "VoiceAgentApp" / "Info-Debug.plist"
    payload = plistlib.loads(info_plist_path.read_bytes())

    ats = payload["NSAppTransportSecurity"]
    assert ats["NSAllowsLocalNetworking"] is True

    tailscale_exception = ats["NSExceptionDomains"]["ts.net"]
    assert tailscale_exception["NSExceptionAllowsInsecureHTTPLoads"] is True
    assert tailscale_exception["NSIncludesSubdomains"] is True
