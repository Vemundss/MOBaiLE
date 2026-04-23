import Foundation

extension VoiceAgentViewModel {
    func refreshClientConnectionCandidates() {
        client.fallbackServerURLs = Array(connectionCandidateServerURLs.dropFirst())
    }

    func normalizedServerURLs(
        preferredServerURL: String? = nil,
        additionalServerURLs: [String] = []
    ) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        let candidates = [preferredServerURL] + additionalServerURLs
        for raw in candidates {
            let normalizedValue = normalized(raw ?? "")
            guard !normalizedValue.isEmpty, !seen.contains(normalizedValue) else { continue }
            seen.insert(normalizedValue)
            ordered.append(normalizedValue)
        }
        return ordered
    }

    func applyAdvertisedServerURLs(
        primaryServerURL: String?,
        advertisedServerURLs: [String],
        persist: Bool = true
    ) {
        let resolved = normalizedServerURLs(
            preferredServerURL: primaryServerURL,
            additionalServerURLs: advertisedServerURLs
        )
        let finalCandidates = resolved.isEmpty
            ? normalizedServerURLs(
                preferredServerURL: normalizedServerURL,
                additionalServerURLs: connectionCandidateServerURLs
            )
            : resolved
        if let preferred = finalCandidates.first {
            serverURL = preferred
        }
        connectionCandidateServerURLs = finalCandidates
        refreshClientConnectionCandidates()
        if persist {
            persistSettings()
        }
    }

    func promoteResolvedServerURL(_ resolvedURL: String) {
        let promoted = normalized(resolvedURL)
        guard !promoted.isEmpty else { return }
        if promoted == normalizedServerURL {
            return
        }
        let currentPriority = PairingHostRules.connectivityPriority(for: normalizedServerURL)
        let promotedPriority = PairingHostRules.connectivityPriority(for: promoted)
        if promotedPriority < currentPriority {
            return
        }
        let currentCandidates = connectionCandidateServerURLs.isEmpty ? [normalizedServerURL] : connectionCandidateServerURLs
        applyAdvertisedServerURLs(
            primaryServerURL: promoted,
            advertisedServerURLs: currentCandidates,
            persist: true
        )
    }

    func refreshSessionPresenceFromBackendIfPossible() async {
        guard hasConfiguredConnection else { return }
        do {
            await ensureRefreshCredentialIfPossible()
            if needsConnectionRepair {
                return
            }
            let context = try await refreshSessionContextFromBackend()
            _ = try? await restoreLatestRunFromSessionContext(context)
        } catch {
            if registerConnectionRepairIfNeeded(from: error) != nil {
                statusText = "Connection needs repair"
            }
        }
    }

    @discardableResult
    func applyPairingPayload(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "No pairing code found."
            return false
        }
        guard let url = extractPairingURL(from: trimmed) else {
            errorText = "This QR code is not a MOBaiLE pairing link."
            return false
        }
        applyPairingURL(url)
        if pendingPairing == nil, errorText.isEmpty {
            errorText = "This QR code is not a valid MOBaiLE pairing link."
        }
        return pendingPairing != nil
    }

    func applyPairingURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              MOBaiLEURLSchemeConfiguration.acceptedSchemes.contains(scheme) else { return }
        guard let host = url.host?.lowercased(), host == "pair" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        var advertisedServerURLs: [String] = []
        var updatedToken: String?
        var pairCode: String?
        var updatedSession: String?

        for item in components.queryItems ?? [] {
            switch item.name {
            case "server_url":
                if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    advertisedServerURLs.append(value)
                }
            case "api_token":
                if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    updatedToken = value
                }
            case "pair_code":
                if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    pairCode = value
                }
            case "session_id":
                if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    updatedSession = value
                }
            default:
                continue
            }
        }

        let resolvedServerURLs = normalizedServerURLs(additionalServerURLs: advertisedServerURLs)
        guard let normalizedServer = resolvedServerURLs.first else {
            errorText = "Invalid pairing QR. Missing server URL."
            return
        }
        for candidate in resolvedServerURLs {
            guard let parsedServer = URL(string: candidate),
                  let schemeValue = parsedServer.scheme?.lowercased(),
                  schemeValue == "http" || schemeValue == "https",
                  let hostValue = parsedServer.host?.lowercased() else {
                errorText = "Invalid pairing QR. Server URL must be a valid http(s) URL."
                return
            }
            if schemeValue != "https" && !isLocalOrPrivateHost(hostValue) {
                errorText = "Pairing requires HTTPS for non-local servers."
                return
            }
        }
        if pairCode == nil, updatedToken != nil, !developerMode {
            errorText = "Legacy token pairing links are disabled. Use pair-code QR pairing."
            return
        }
        if pairCode == nil, updatedToken == nil {
            errorText = "Invalid pairing QR. Missing pair_code."
            return
        }

        pendingPairing = PendingPairing(
            serverURL: normalizedServer,
            serverURLs: resolvedServerURLs,
            sessionID: updatedSession,
            pairCode: pairCode,
            legacyToken: developerMode ? updatedToken : nil
        )
        errorText = ""
    }

    func extractPairingURL(from rawValue: String) -> URL? {
        if let url = validatedPairingURLCandidate(rawValue) {
            return url
        }

        let separators = CharacterSet.whitespacesAndNewlines
        let trailingJunk = CharacterSet(charactersIn: ".,;:!?)]}\"'")

        for token in rawValue.components(separatedBy: separators) {
            let candidate = token.trimmingCharacters(in: trailingJunk)
            guard !candidate.isEmpty else { continue }
            if let url = validatedPairingURLCandidate(candidate) {
                return url
            }
        }

        return nil
    }

    func cancelPendingPairing() {
        pendingPairing = nil
    }

    func isTrustedPairHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return false }
        return trustedPairHosts.contains(normalizedHost)
    }

    func setTrustedPairHost(_ host: String, trusted: Bool) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return }
        if trusted {
            trustedPairHosts.insert(normalizedHost)
        } else {
            trustedPairHosts.remove(normalizedHost)
        }
        persistTrustedPairHosts()
    }

    func confirmPendingPairing(trustHost: Bool) {
        guard let pending = pendingPairing else { return }

        if trustHost {
            setTrustedPairHost(pending.serverHost, trusted: true)
        }

        if let oneTimeCode = pending.pairCode {
            Task {
                await exchangePairCode(
                    serverURLs: pending.serverURLs,
                    pairCode: oneTimeCode,
                    sessionID: pending.sessionID
                )
            }
            return
        }
        if let token = pending.legacyToken {
            pendingPairing = nil
            applyAdvertisedServerURLs(
                primaryServerURL: pending.serverURL,
                advertisedServerURLs: pending.serverURLs,
                persist: false
            )
            if let session = pending.sessionID, !session.isEmpty {
                sessionID = session
            }
            apiToken = token
            persistSettings()
            statusText = "Paired successfully (legacy token)"
            errorText = ""
            persistActiveThreadSnapshot()
            return
        }
        errorText = "Invalid pairing QR. Missing pair code."
    }

    func confirmPendingPairing() {
        confirmPendingPairing(trustHost: false)
    }

    var normalizedServerURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var hasConfiguredConnection: Bool {
        !normalizedServerURL.isEmpty && !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasPairedRefreshCredential: Bool {
        !normalizedRefreshToken.isEmpty
    }

    var connectionCandidateServerURLsForTesting: [String] {
        connectionCandidateServerURLs
    }

    var needsConnectionRepair: Bool {
        connectionRepairState != nil
    }

    var connectionRepairTitle: String {
        connectionRepairState?.title ?? "Reconnect this phone"
    }

    var connectionRepairMessage: String {
        connectionRepairState?.message
            ?? "Open the latest pairing QR on your computer and scan it again here."
    }

    func applyPairedClientCredentials(
        _ response: PairExchangeResponse,
        fallbackPrimaryServerURL: String,
        additionalServerURLs: [String] = [],
        statusText statusOverride: String? = nil
    ) {
        apiToken = response.apiToken
        if let refreshToken = response.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refreshToken.isEmpty {
            pairedRefreshToken = refreshToken
        }
        sessionID = response.sessionId
        applyAdvertisedServerURLs(
            primaryServerURL: response.serverURL ?? fallbackPrimaryServerURL,
            advertisedServerURLs: (response.serverURLs ?? []) + additionalServerURLs,
            persist: false
        )
        backendSecurityMode = response.securityMode
        clearConnectionRepairState()
        persistSettings()
        errorText = ""
        if let statusOverride, !statusOverride.isEmpty {
            statusText = statusOverride
        }
    }

    func ensureRefreshCredentialIfPossible() async {
        guard hasConfiguredConnection, normalizedRefreshToken.isEmpty else { return }
        do {
            _ = try await silentlyRefreshPairingCredentials(preferredServerURL: normalizedServerURL)
        } catch let apiError as APIError where apiError.statusCode == 403 {
            return
        } catch {
            if registerConnectionRepairIfNeeded(from: error) != nil {
                statusText = "Connection needs repair"
            }
        }
    }

    func silentlyRefreshPairingCredentials(preferredServerURL: String? = nil) async throws -> String? {
        if let credentialRefreshTask {
            return try await credentialRefreshTask.value
        }

        let task = Task<String?, Error> { @MainActor in
            let targetServerURL = preferredServerURL?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                ?? self.normalizedServerURL
            let currentToken = self.apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let refreshToken = self.normalizedRefreshToken
            guard !targetServerURL.isEmpty, !currentToken.isEmpty || !refreshToken.isEmpty else {
                return nil
            }

            let response = try await self.client.refreshPairingCredentials(
                serverURL: targetServerURL,
                refreshToken: refreshToken.isEmpty ? nil : refreshToken,
                currentToken: currentToken.isEmpty ? nil : currentToken,
                sessionID: self.sessionID
            )
            self.applyPairedClientCredentials(
                response,
                fallbackPrimaryServerURL: targetServerURL,
                additionalServerURLs: self.connectionCandidateServerURLs,
                statusText: refreshToken.isEmpty ? nil : "Reconnected automatically"
            )
            return response.apiToken
        }
        credentialRefreshTask = task

        do {
            let refreshedToken = try await task.value
            credentialRefreshTask = nil
            return refreshedToken
        } catch {
            credentialRefreshTask = nil
            if let apiError = error as? APIError, apiError.statusCode == 404 {
                return nil
            }
            if let apiError = error as? APIError, apiError.isMissingOrInvalidRefreshToken {
                _ = registerConnectionRepairIfNeeded(
                    from: APIError.httpError(401, #"{"detail":"missing or invalid bearer token"}"#)
                )
            }
            throw error
        }
    }

    @discardableResult
    func registerConnectionRepairIfNeeded(from error: Error) -> String? {
        guard let apiError = error as? APIError,
              apiError.isMissingOrInvalidBearerToken || apiError.isMissingOrInvalidRefreshToken else {
            return nil
        }

        let host = URL(string: normalizedServerURL)?.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message: String
        if host.isEmpty {
            message = "This phone is no longer paired with your computer. Open the latest pairing QR on the computer and scan it again here."
        } else {
            message = "This phone is no longer paired with \(host). Open the latest pairing QR on that computer and scan it again here."
        }

        setConnectionRepairState(ConnectionRepairState(
            title: "Reconnect this phone",
            message: message
        ))
        return message
    }

    func clearConnectionRepairState() {
        setConnectionRepairState(nil)
    }
    func normalized(_ rawURL: String) -> String {
        rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private extension VoiceAgentViewModel {
    var normalizedRefreshToken: String {
        pairedRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func validatedPairingURLCandidate(_ candidate: String) -> URL? {
        let leadingJunk = CharacterSet(charactersIn: "\"'([<{")
        let normalized = candidate.trimmingCharacters(in: leadingJunk)
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              MOBaiLEURLSchemeConfiguration.acceptedSchemes.contains(scheme),
              url.host?.lowercased() == "pair" else {
            return nil
        }
        return url
    }

    func exchangePairCode(serverURLs: [String], pairCode: String, sessionID: String?) async {
        let resolvedServerURLs = normalizedServerURLs(additionalServerURLs: serverURLs)
        guard let primaryServerURL = resolvedServerURLs.first else {
            errorText = "Pairing failed"
            statusText = "Missing pairing server URL"
            return
        }
        let previousFallbacks = client.fallbackServerURLs
        client.fallbackServerURLs = Array(resolvedServerURLs.dropFirst())
        defer {
            client.fallbackServerURLs = previousFallbacks
            refreshClientConnectionCandidates()
        }
        do {
            let response = try await client.exchangePairingCode(
                serverURL: primaryServerURL,
                pairCode: pairCode,
                sessionID: sessionID ?? self.sessionID
            )
            applyPairedClientCredentials(
                response,
                fallbackPrimaryServerURL: primaryServerURL,
                additionalServerURLs: resolvedServerURLs
            )
            _ = try? await refreshRuntimeConfiguration()
            _ = try? await refreshSessionContextFromBackend()
            statusText = "Paired successfully (\(response.securityMode))"
            pendingPairing = nil
            persistActiveThreadSnapshot()
        } catch {
            errorText = error.localizedDescription
            statusText = "Pairing failed"
        }
    }

    func isLocalOrPrivateHost(_ host: String) -> Bool {
        PairingHostRules.isLocalOrPrivateHost(host)
    }
}
