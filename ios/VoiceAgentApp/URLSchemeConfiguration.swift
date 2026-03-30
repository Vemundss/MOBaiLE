import Foundation

enum MOBaiLEURLSchemeConfiguration {
    static var activeScheme: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "MOBaiLEURLScheme") as? String
        let normalized = configured?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (normalized?.isEmpty == false ? normalized : nil) ?? "mobaile"
    }

    static var acceptedSchemes: Set<String> {
        var schemes: Set<String> = [activeScheme]
        schemes.insert("mobaile")
        return schemes
    }
}
