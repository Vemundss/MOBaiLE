# MOBaiLE Feature Roadmap

This file tracks product-facing improvements and implementation status.

## Current Focus

- [x] Thread/session history in iOS chat (`switch`, `new`, `rename`, `delete`)
- [x] Developer Mode gating for advanced controls (`local`, run logs)
- [ ] Structured assistant rendering v2 (sections + artifacts as first-class UI cards)
  - [x] Robust envelope decoding (direct JSON + escaped JSON string + embedded JSON extraction)
  - [x] Server-side envelope unwrapping to avoid nested/raw JSON in chat bubbles
  - [x] Baseline `assistant_response` generation for raw codex text fallback
- [ ] Multimedia artifact polish (inline image galleries, file cards, share/open actions)
  - [x] Added artifact cards with `Open` links for image/file artifacts
- [ ] Composer polish (clearer recording/sending states, better disabled-state hints)

## Near-Term UX Improvements

- [ ] Group run lifecycle into a single expandable "Run Card" instead of many tiny status bubbles
- [ ] Improve markdown rendering fidelity (tables, nested lists, better code theme contrast)
- [ ] Message-level copy/share actions
- [ ] Better long-message readability (collapsible sections)
- [ ] Optional "compact mode" for high-density logs/output

## Backend / Contract Improvements

- [x] Add explicit artifact list to chat envelope (`artifacts: [{type,path,mime,title}]`)
- [x] Add per-message IDs and timestamps in stream events for stable client reconciliation
- [ ] Add lightweight schema version negotiation between app and backend
- [ ] Add server-side "final summary only" channel for cleaner phone UX
- [x] Introduce security modes (`safe` vs `full-access`) with clear runtime/config surfaces
- [x] Replace token-in-QR with one-time pair-code exchange + rotation
- [x] Move iOS token persistence to Keychain

## Distribution / Onboarding

- [x] One-command server bootstrap script
- [x] QR-based deep-link pairing (`mobaile://pair?...`)
- [ ] TestFlight distribution checklist + release script
- [ ] Homebrew tap packaging for server bootstrap
- [ ] Linux systemd service installer (parity with macOS launchd installer)

## Notes

- Principle: keep defaults simple for normal users; keep advanced controls in Developer Mode.
- Principle: prefer typed backend contracts over fragile UI text heuristics.
