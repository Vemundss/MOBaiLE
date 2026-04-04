import Foundation

enum PairingHostRules {
    static func isLocalOrPrivateHost(_ host: String) -> Bool {
        if host.isEmpty { return false }
        return isLoopbackOrBonjourHost(host) || isRFC1918LANHost(host) || isTailscaleHost(host)
    }

    static func isLoopbackOrBonjourHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "localhost" || lower == "::1" || lower.hasSuffix(".local") || lower.hasPrefix("127.")
    }

    static func isRFC1918LANHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("10.") || lower.hasPrefix("192.168.") {
            return true
        }
        if lower.hasPrefix("172.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    static func isTailscaleHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasSuffix(".ts.net") {
            return true
        }
        if lower.hasPrefix("100.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (64...127).contains(second) {
                return true
            }
        }
        return false
    }
}
