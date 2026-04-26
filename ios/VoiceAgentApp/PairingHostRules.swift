import Foundation

enum PairingHostRules {
    private enum ConnectivityFamily: Equatable {
        case publicHTTPS
        case tailscale
        case lan
        case local
    }

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
        return isTailscaleIPHost(lower)
    }

    static func isTailscaleIPHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("100.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (64...127).contains(second) {
                return true
            }
        }
        return false
    }

    static func connectivityPriority(for serverURL: String) -> Int {
        guard let parsed = URL(string: serverURL),
              let host = parsed.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return -1
        }
        let scheme = parsed.scheme?.lowercased() ?? ""
        if scheme == "https" && !isLocalOrPrivateHost(host) {
            return 4
        }
        if isTailscaleIPHost(host) {
            return 3
        }
        if host.hasSuffix(".ts.net") {
            return 2
        }
        if isRFC1918LANHost(host) || host.hasSuffix(".local") {
            return 1
        }
        if isLoopbackOrBonjourHost(host) {
            return 0
        }
        return scheme == "https" ? 4 : -1
    }

    static func serverURLsByReachability(_ serverURLs: [String]) -> [String] {
        serverURLs.enumerated().sorted { lhs, rhs in
            let lhsPriority = connectivityPriority(for: lhs.element)
            let rhsPriority = connectivityPriority(for: rhs.element)
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func shouldPromoteResolvedServerURL(_ resolvedURL: String, over currentURL: String) -> Bool {
        let resolvedPriority = connectivityPriority(for: resolvedURL)
        guard resolvedPriority >= 0 else { return false }

        let currentPriority = connectivityPriority(for: currentURL)
        guard currentPriority >= 0 else { return true }

        if let resolvedFamily = connectivityFamily(for: resolvedURL),
           resolvedFamily == connectivityFamily(for: currentURL) {
            return true
        }
        return resolvedPriority >= currentPriority
    }

    static func preferredServerURL(from serverURLs: [String]) -> String? {
        let ordered = serverURLsByReachability(serverURLs)
        guard let bestURL = ordered.first else { return nil }
        return connectivityPriority(for: bestURL) >= 0 ? bestURL : serverURLs.first
    }

    private static func connectivityFamily(for serverURL: String) -> ConnectivityFamily? {
        guard let parsed = URL(string: serverURL),
              let host = parsed.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        let scheme = parsed.scheme?.lowercased() ?? ""
        if scheme == "https" && !isLocalOrPrivateHost(host) {
            return .publicHTTPS
        }
        if isTailscaleHost(host) {
            return .tailscale
        }
        if isRFC1918LANHost(host) || host.hasSuffix(".local") {
            return .lan
        }
        if isLoopbackOrBonjourHost(host) {
            return .local
        }
        return scheme == "https" ? .publicHTTPS : nil
    }
}
