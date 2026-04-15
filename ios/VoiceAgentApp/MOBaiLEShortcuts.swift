import AppIntents
import Foundation

private let pendingShortcutActionKey = "mobaile.pending_shortcut_action"

struct StartVoiceTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Voice Mode"
    static var description = IntentDescription("Open MOBaiLE and resume voice mode on the active or last voice thread.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("start-voice", forKey: pendingShortcutActionKey)
        return .result()
    }
}

struct StartNewVoiceThreadIntent: AppIntent {
    static var title: LocalizedStringResource = "Start New Voice Thread"
    static var description = IntentDescription("Open MOBaiLE, create a fresh thread, and start voice mode there.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("start-new-voice", forKey: pendingShortcutActionKey)
        return .result()
    }
}

struct SendLastPromptIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Last Prompt"
    static var description = IntentDescription("Open MOBaiLE and resend your last prompt.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("send-last-prompt", forKey: pendingShortcutActionKey)
        return .result()
    }
}

struct MOBaiLEAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceTaskIntent(),
            phrases: [
                "Resume voice mode in \(.applicationName)",
                "Continue voice mode in \(.applicationName)",
                "Resume hands-free in \(.applicationName)",
                "Talk to my computer again with \(.applicationName)",
                "Continue talking hands-free with \(.applicationName)",
            ],
            shortTitle: "Resume Voice",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StartNewVoiceThreadIntent(),
            phrases: [
                "Start a new voice thread in \(.applicationName)",
                "Start a new conversation with \(.applicationName)",
                "Open a fresh voice task in \(.applicationName)",
            ],
            shortTitle: "New Voice Thread",
            systemImageName: "waveform.badge.plus"
        )
        AppShortcut(
            intent: SendLastPromptIntent(),
            phrases: [
                "Send last prompt in \(.applicationName)",
                "Retry last prompt in \(.applicationName)",
            ],
            shortTitle: "Send Last",
            systemImageName: "arrow.up.circle.fill"
        )
    }
}
