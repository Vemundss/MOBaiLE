import Foundation

enum WidgetURLSchemeConfiguration {
    static var activeScheme: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "MOBaiLEURLScheme") as? String
        let normalized = configured?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (normalized?.isEmpty == false ? normalized : nil) ?? "mobaile"
    }
}
