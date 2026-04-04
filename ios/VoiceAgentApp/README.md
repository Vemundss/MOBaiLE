# VoiceAgentApp Code Map

This folder contains the SwiftUI client that pairs with the backend and renders the phone-side run experience.

## File Ownership

- `ContentView.swift`: top-level screen composition, modal routing, lifecycle hooks, and app-level UI state wiring.
- `ContentViewSupportViews.swift`: smaller UI building blocks used by `ContentView` so the root screen file stays focused on orchestration.
- `VoiceAgentPreviewFixtures.swift`: preview-only fixtures and sample thread content used for screenshots and SwiftUI previews.
- `PairingHostRules.swift`: host classification helpers for pairing safety labels and local-network warnings.
- `RuntimeConfigurationCatalog.swift`: pure runtime-executor normalization and fallback descriptor building used by the view model.
- `VoiceAgentViewModel.swift`: the main client-side state machine. It owns pairing, backend requests, run observation, draft persistence, and voice-mode orchestration.
- `APIClient.swift`: HTTP transport, streaming, and upload logic.
- `ChatRenderers.swift` and `ChatScaffoldViews.swift`: chat message rendering plus empty/setup scaffolding.
- `ChatThreadStore.swift`: local SQLite persistence for thread metadata and messages.
- `Models.swift`: shared app-side models and contract decoding.

## Editing Guidelines

- Prefer extracting focused SwiftUI views instead of growing `ContentView.swift`.
- Keep network/state orchestration in `VoiceAgentViewModel.swift`; keep pure rendering logic in view files.
- Treat `Models.swift` as the client contract boundary. If backend response shapes change, update tests and generated contracts in the same pass.
- Store secrets in `KeychainStore.swift`, not in `UserDefaults`.

## Safe Refactor Boundaries

- UI-only changes usually belong in `ContentView*`, `ChatRenderers.swift`, or `ChatScaffoldViews.swift`.
- Persistence changes usually belong in `ChatThreadStore.swift` plus the unit tests.
- Pairing and run lifecycle changes usually touch both `VoiceAgentViewModel.swift` and backend schemas or endpoints.
