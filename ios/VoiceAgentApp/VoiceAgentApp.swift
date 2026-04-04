import SwiftUI
import UIKit

enum AppAppearancePreference: String, CaseIterable, Identifiable {
    static let storageKey = "ui.appearancePreference"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    static func resolve(from rawValue: String?) -> AppAppearancePreference {
        guard let rawValue,
              let preference = AppAppearancePreference(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return .system
        }
        return preference
    }
}

@MainActor
final class IncomingURLStore: ObservableObject {
    static let shared = IncomingURLStore()

    @Published private(set) var pendingURL: URL?

    func receive(_ url: URL) {
        pendingURL = url
    }

    func takePendingURL() -> URL? {
        let value = pendingURL
        pendingURL = nil
        return value
    }
}

final class VoiceAgentAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = VoiceAgentSceneDelegate.self
        return configuration
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Task { @MainActor in
            IncomingURLStore.shared.receive(url)
        }
        return true
    }
}

final class VoiceAgentSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let url = connectionOptions.urlContexts.first?.url else { return }
        Task { @MainActor in
            IncomingURLStore.shared.receive(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        Task { @MainActor in
            IncomingURLStore.shared.receive(url)
        }
    }
}

@main
struct VoiceAgentApp: App {
    @UIApplicationDelegateAdaptor(VoiceAgentAppDelegate.self) private var appDelegate
    @StateObject private var incomingURLStore = IncomingURLStore.shared
    @AppStorage(AppAppearancePreference.storageKey) private var appearancePreferenceRaw = AppAppearancePreference.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(incomingURLStore)
                .preferredColorScheme(resolvedAppearancePreference.colorScheme)
        }
    }

    private var resolvedAppearancePreference: AppAppearancePreference {
        let previewOverride = ProcessInfo.processInfo.environment["MOBAILE_PREVIEW_APPEARANCE"]
        if let previewOverride, !previewOverride.isEmpty {
            return AppAppearancePreference.resolve(from: previewOverride)
        }
        return AppAppearancePreference.resolve(from: appearancePreferenceRaw)
    }
}
