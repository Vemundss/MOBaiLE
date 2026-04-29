import Foundation

private struct APIErrorPayload: Decodable {
    let detail: APIErrorDetailPayload?
}

private struct APIErrorDetailPayload: Decodable {
    let message: String?
    let code: String?
    let field: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case code
        case field
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            self.message = stringValue
            self.code = nil
            self.field = nil
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.message = try keyed.decodeIfPresent(String.self, forKey: .message)
        self.code = try keyed.decodeIfPresent(String.self, forKey: .code)
        self.field = try keyed.decodeIfPresent(String.self, forKey: .field)
    }
}

enum APIError: Error, LocalizedError {
    case missingCredentials
    case invalidURL
    case invalidResponse
    case httpError(Int, String)

    var statusCode: Int? {
        if case let .httpError(code, _) = self {
            return code
        }
        return nil
    }

    var backendDetail: String? {
        guard case let .httpError(_, body) = self else { return nil }
        return Self.parseBackendDetail(from: body)
    }

    var backendCode: String? {
        guard case let .httpError(_, body) = self else { return nil }
        return Self.parseBackendCode(from: body)
    }

    var isMissingOrInvalidBearerToken: Bool {
        statusCode == 401 &&
            (backendDetail?.lowercased().contains("missing or invalid bearer token") ?? false)
    }

    var isMissingOrInvalidRefreshToken: Bool {
        statusCode == 401 &&
            (backendDetail?.lowercased().contains("missing or invalid refresh token") ?? false)
    }

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Enter server URL and API token first."
        case .invalidURL:
            return "Invalid server URL."
        case .invalidResponse:
            return "Invalid server response."
        case let .httpError(code, body):
            if let detail = backendDetail {
                return detail
            }
            if body.isEmpty {
                return "Server returned HTTP \(code)."
            }
            return "Server returned HTTP \(code): \(body)"
        }
    }

    private static func parseBackendDetail(from body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data),
           let detail = payload.detail {
            let message = detail.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !message.isEmpty {
                return humanized(message)
            }
            let code = detail.code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !code.isEmpty {
                return humanized(code.replacingOccurrences(of: "_", with: " "))
            }
        }

        return humanized(trimmed)
    }

    private static func parseBackendCode(from body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data) else {
            return nil
        }
        let code = payload.detail?.code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return code.isEmpty ? nil : code
    }

    private static func humanized(_ detail: String) -> String {
        guard let first = detail.first else { return detail }
        return String(first).uppercased() + detail.dropFirst()
    }
}

final class APIClient {
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()
    private let previewDownloadCache = PreviewDownloadCache()
    var fallbackServerURLs: [String] = []
    var onResolvedServerURL: ((String) -> Void)?
    var onUnauthorizedRecovery: ((String) async throws -> String?)?

    func createUtterance(
        serverURL: String,
        token: String,
        requestBody: UtteranceRequest,
        registerCancellation: ((@escaping () -> Void) -> Void)? = nil
    ) async throws -> UtteranceResponse {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard let url = URL(string: baseURL + "/v1/utterances") else {
                throw APIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try jsonEncoder.encode(requestBody)

            let (data, response) = try await data(for: request, registerCancellation: registerCancellation)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(UtteranceResponse.self, from: data)
        }
    }

    func exchangePairingCode(
        serverURL: String,
        pairCode: String,
        sessionID: String?
    ) async throws -> PairExchangeResponse {
        try await withCandidateServerURL(serverURL) { baseURL in
            guard let url = URL(string: baseURL + "/v1/pair/exchange") else {
                throw APIError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try jsonEncoder.encode(
                PairExchangeRequest(pairCode: pairCode, sessionId: sessionID)
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(PairExchangeResponse.self, from: data)
        }
    }

    func checkHealth(serverURL: String, timeoutInterval: TimeInterval = 5) async throws {
        let baseURL = normalizedBaseURL(serverURL)
        guard let url = URL(string: baseURL + "/health") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    func refreshPairingCredentials(
        serverURL: String,
        refreshToken: String?,
        currentToken: String?,
        sessionID: String?
    ) async throws -> PairExchangeResponse {
        try await withCandidateServerURL(serverURL) { baseURL in
            guard let url = URL(string: baseURL + "/v1/pair/refresh") else {
                throw APIError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            let trimmedCurrentToken = (currentToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCurrentToken.isEmpty {
                request.addValue("Bearer \(trimmedCurrentToken)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try jsonEncoder.encode(
                PairRefreshRequest(
                    refreshToken: refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                    sessionId: sessionID
                )
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(PairExchangeResponse.self, from: data)
        }
    }

    func fetchRun(
        serverURL: String,
        token: String,
        runID: String,
        eventsLimit: Int? = nil
    ) async throws -> RunRecord {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard var components = URLComponents(string: baseURL + "/v1/runs/\(runID)") else {
                throw APIError.invalidURL
            }
            if let eventsLimit {
                components.queryItems = [
                    URLQueryItem(name: "events_limit", value: String(max(0, eventsLimit)))
                ]
            }
            guard let url = components.url else {
                throw APIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(RunRecord.self, from: data)
        }
    }

    func fetchRunEventsPage(
        serverURL: String,
        token: String,
        runID: String,
        limit: Int = 100,
        beforeSeq: Int? = nil,
        afterSeq: Int? = nil
    ) async throws -> RunEventsPage {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard var components = URLComponents(string: baseURL + "/v1/runs/\(runID)/events-page") else {
                throw APIError.invalidURL
            }
            var queryItems = [
                URLQueryItem(name: "limit", value: String(limit))
            ]
            if let beforeSeq {
                queryItems.append(URLQueryItem(name: "before_seq", value: String(beforeSeq)))
            }
            if let afterSeq {
                queryItems.append(URLQueryItem(name: "after_seq", value: String(afterSeq)))
            }
            components.queryItems = queryItems
            guard let url = components.url else {
                throw APIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(RunEventsPage.self, from: data)
        }
    }

    func fetchSessionRuns(
        serverURL: String,
        token: String,
        sessionID: String,
        limit: Int = 20
    ) async throws -> [RunSummary] {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: baseURL + "/v1/sessions/\(encoded)/runs?limit=\(limit)") else {
                throw APIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode([RunSummary].self, from: data)
        }
    }

    func fetchRunDiagnostics(
        serverURL: String,
        token: String,
        runID: String
    ) async throws -> RunDiagnostics {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard let url = URL(string: baseURL + "/v1/runs/\(runID)/diagnostics") else {
                throw APIError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(RunDiagnostics.self, from: data)
        }
    }

    func fetchRuntimeConfig(
        serverURL: String,
        token: String
    ) async throws -> RuntimeConfig {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard let url = URL(string: baseURL + "/v1/config") else {
                throw APIError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(RuntimeConfig.self, from: data)
        }
    }

    func fetchSlashCommands(
        serverURL: String,
        token: String
    ) async throws -> [SlashCommandDescriptor] {
        do {
            return try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
                guard let url = URL(string: baseURL + "/v1/slash-commands") else {
                    throw APIError.invalidURL
                }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 10
                request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                try validate(response: response, data: data)
                return try jsonDecoder.decode([SlashCommandDescriptor].self, from: data)
            }
        } catch let APIError.httpError(code, _) where code == 404 {
            return []
        }
    }

    func fetchSessionContext(
        serverURL: String,
        token: String,
        sessionID: String
    ) async throws -> SessionContext {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: baseURL + "/v1/sessions/\(encoded)/context") else {
                throw APIError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(SessionContext.self, from: data)
        }
    }

    func updateSessionContext(
        serverURL: String,
        token: String,
        sessionID: String,
        requestBody: SessionContextUpdateRequest
    ) async throws -> SessionContext {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: baseURL + "/v1/sessions/\(encoded)/context") else {
                throw APIError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.timeoutInterval = 15
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try jsonEncoder.encode(requestBody)
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(SessionContext.self, from: data)
        }
    }

    func executeSlashCommand(
        serverURL: String,
        token: String,
        sessionID: String,
        commandID: String,
        arguments: String?
    ) async throws -> SlashCommandExecutionResponse {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard let encodedSession = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let encodedCommand = commandID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: baseURL + "/v1/sessions/\(encodedSession)/slash-commands/\(encodedCommand)") else {
                throw APIError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try jsonEncoder.encode(
                SlashCommandExecutionRequest(arguments: arguments)
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(SlashCommandExecutionResponse.self, from: data)
        }
    }

    func fetchDirectoryListing(
        serverURL: String,
        token: String,
        path: String?
    ) async throws -> DirectoryListingResponse {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard var components = URLComponents(string: baseURL + "/v1/directories") else {
                throw APIError.invalidURL
            }
            let trimmedPath = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPath.isEmpty {
                components.queryItems = [URLQueryItem(name: "path", value: trimmedPath)]
            }
            guard let url = components.url else {
                throw APIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(DirectoryListingResponse.self, from: data)
        }
    }

    func createDirectory(
        serverURL: String,
        token: String,
        path: String
    ) async throws -> DirectoryCreateResponse {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard let url = URL(string: baseURL + "/v1/directories") else {
                throw APIError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try jsonEncoder.encode(DirectoryCreateRequest(path: path))
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(DirectoryCreateResponse.self, from: data)
        }
    }

    func createAudioRun(
        serverURL: String,
        token: String,
        sessionID: String,
        threadID: String?,
        executor: String?,
        workingDirectory: String?,
        responseMode: String?,
        responseProfile: String?,
        draftText: String,
        attachments: [ChatArtifact],
        audioFileURL: URL,
        runID: String? = nil,
        registerCancellation: ((@escaping () -> Void) -> Void)? = nil
    ) async throws -> AudioRunResponse {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard let url = URL(string: baseURL + "/v1/audio") else {
                throw APIError.invalidURL
            }

            let boundary = "Boundary-\(UUID().uuidString)"
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 75
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
            request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            let audioData = try await readFileData(at: audioFileURL)
            var fields: [String: String] = [
                "session_id": sessionID,
                "response_mode": responseMode ?? "",
                "response_profile": responseProfile ?? ""
            ]
            let trimmedExecutor = (executor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedExecutor.isEmpty {
                fields["executor"] = trimmedExecutor
            }
            let trimmedWorkingDirectory = (workingDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedWorkingDirectory.isEmpty {
                fields["working_directory"] = trimmedWorkingDirectory
            }
            let trimmedThreadID = (threadID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedThreadID.isEmpty {
                fields["thread_id"] = trimmedThreadID
            }
            let trimmedRunID = (runID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRunID.isEmpty {
                fields["run_id"] = trimmedRunID
            }
            let trimmedDraftText = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDraftText.isEmpty {
                fields["draft_text"] = trimmedDraftText
            }
            if !attachments.isEmpty {
                let encodedAttachments = try jsonEncoder.encode(attachments)
                let attachmentsJSON = String(decoding: encodedAttachments, as: UTF8.self)
                fields["attachments_json"] = attachmentsJSON
            }
            request.httpBody = await buildMultipartBody(
                boundary: boundary,
                fields: fields,
                fileData: audioData,
                fileFieldName: "audio",
                fileName: audioFileURL.lastPathComponent,
                mimeType: "audio/m4a"
            )

            let (data, response) = try await data(
                for: request,
                registerCancellation: registerCancellation
            )
            try validate(response: response, data: data)
            return try jsonDecoder.decode(AudioRunResponse.self, from: data)
        }
    }

    func uploadAttachment(
        serverURL: String,
        token: String,
        sessionID: String,
        fileURL: URL,
        mimeType: String?,
        onProgress: ((Double) -> Void)? = nil,
        registerCancellation: ((@escaping () -> Void) -> Void)? = nil
    ) async throws -> UploadResponse {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard let url = URL(string: baseURL + "/v1/uploads") else {
                throw APIError.invalidURL
            }

            let boundary = "Boundary-\(UUID().uuidString)"
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
            request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            let fileData = try await readFileData(at: fileURL)
            let bodyData = await buildMultipartBody(
                boundary: boundary,
                fields: ["session_id": sessionID],
                fileData: fileData,
                fileFieldName: "file",
                fileName: fileURL.lastPathComponent,
                mimeType: inferAttachmentMimeType(fileName: fileURL.lastPathComponent, fallback: mimeType)
            )
            let delegate = UploadTaskDelegate(progressHandler: onProgress)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            let (data, response) = try await delegate.upload(
                session: session,
                request: request,
                bodyData: bodyData,
                registerCancellation: registerCancellation
            )
            try validate(response: response, data: data)
            return try jsonDecoder.decode(UploadResponse.self, from: data)
        }
    }

    func streamRunEvents(
        serverURL: String,
        token: String,
        runID: String,
        afterSeq: Int? = nil
    ) -> AsyncThrowingStream<ExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
                        guard var components = URLComponents(string: baseURL + "/v1/runs/\(runID)/events") else {
                            throw APIError.invalidURL
                        }
                        if let afterSeq, afterSeq >= 0 {
                            components.queryItems = [
                                URLQueryItem(name: "after_seq", value: String(afterSeq))
                            ]
                        }
                        guard let url = components.url else {
                            throw APIError.invalidURL
                        }

                        var request = URLRequest(url: url)
                        request.httpMethod = "GET"
                        request.timeoutInterval = 60
                        request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
                        return try await URLSession.shared.bytes(for: request)
                    }
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError.invalidResponse
                    }
                    guard (200...299).contains(http.statusCode) else {
                        throw APIError.httpError(http.statusCode, "")
                    }

                    let decoder = JSONDecoder()
                    var dataLines: [String] = []

                    for try await line in bytes.lines {
                        if line.hasPrefix("data:") {
                            let raw = String(line.dropFirst(5))
                            let normalized = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
                            dataLines.append(normalized)
                            continue
                        }
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                let payload = dataLines.joined(separator: "\n")
                                dataLines.removeAll()
                                if let payloadData = payload.data(using: .utf8) {
                                    let event = try decoder.decode(ExecutionEvent.self, from: payloadData)
                                    continuation.yield(event)
                                }
                            }
                        }
                    }

                    if !dataLines.isEmpty {
                        let payload = dataLines.joined(separator: "\n")
                        if let payloadData = payload.data(using: .utf8) {
                            let event = try decoder.decode(ExecutionEvent.self, from: payloadData)
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func cancelRun(
        serverURL: String,
        token: String,
        runID: String
    ) async throws -> CancelRunResponse {
        try await withAuthorizedCandidateServerURL(serverURL, token: token) { baseURL, activeToken in
            guard let url = URL(string: baseURL + "/v1/runs/\(runID)/cancel") else {
                throw APIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try jsonDecoder.decode(CancelRunResponse.self, from: data)
        }
    }

    func downloadArtifactToTemporaryFile(
        serverURL: String,
        token: String,
        artifact: ChatArtifact,
        cacheVersion: String? = nil
    ) async throws -> URL {
        try await withCandidateServerURL(serverURL) { baseURL in
            guard let requestURL = resolveArtifactURL(serverURL: baseURL, artifact: artifact) else {
                throw APIError.invalidURL
            }
            let cacheKey = PreviewDownloadCache.cacheKey(for: requestURL, cacheVersion: cacheVersion)
            if let cachedURL = await previewDownloadCache.file(for: cacheKey) {
                return cachedURL
            }
            let data = try await fetchURLData(
                serverURL: baseURL,
                token: token,
                url: requestURL,
                timeout: 30
            )
            return try await previewDownloadCache.store(
                data,
                key: cacheKey,
                baseName: suggestedBaseName(from: artifact, url: requestURL),
                fileExtension: preferredExtension(from: artifact, url: requestURL)
            )
        }
    }

    func inspectArtifactFile(
        serverURL: String,
        token: String,
        artifact: ChatArtifact,
        textPreviewBytes: Int = 64 * 1024,
        textPreviewOffset: Int = 0,
        textSearch: String? = nil
    ) async throws -> FileInspectionResponse {
        try await withCandidateServerURL(serverURL) { baseURL in
            guard let url = resolveArtifactInspectURL(
                serverURL: baseURL,
                artifact: artifact,
                textPreviewBytes: textPreviewBytes,
                textPreviewOffset: textPreviewOffset,
                textSearch: textSearch
            ) else {
                throw APIError.invalidURL
            }
            let data = try await fetchURLData(
                serverURL: baseURL,
                token: token,
                url: url,
                timeout: 15
            )
            return try jsonDecoder.decode(FileInspectionResponse.self, from: data)
        }
    }

    func fetchURLData(
        serverURL: String,
        token: String,
        url: URL,
        timeout: TimeInterval = 20
    ) async throws -> Data {
        if shouldAttachAuth(to: url, serverURL: serverURL), !token.isEmpty {
            return try await withAuthorizedCandidateServerURL(serverURL, token: token) { _, activeToken in
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = timeout
                request.addValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                try validate(response: response, data: data)
                return data
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func withCandidateServerURL<T>(
        _ serverURL: String,
        operation: (String) async throws -> T
    ) async throws -> T {
        let candidates = candidateServerURLs(for: serverURL)
        var lastError: Error?

        for (index, candidate) in candidates.enumerated() {
            do {
                let value = try await operation(candidate)
                if normalizedBaseURL(candidate) != normalizedBaseURL(serverURL) {
                    onResolvedServerURL?(candidate)
                }
                return value
            } catch {
                lastError = error
                if index == candidates.count - 1 || !shouldRetryAcrossCandidates(error) {
                    throw error
                }
            }
        }

        throw lastError ?? APIError.invalidResponse
    }

    private func withAuthorizedCandidateServerURL<T>(
        _ serverURL: String,
        token: String,
        operation: (String, String) async throws -> T
    ) async throws -> T {
        let candidates = candidateServerURLs(for: serverURL)
        var lastError: Error?
        var currentToken = token
        var attemptedRecovery = false

        for (index, candidate) in candidates.enumerated() {
            do {
                let value = try await operation(candidate, currentToken)
                if normalizedBaseURL(candidate) != normalizedBaseURL(serverURL) {
                    onResolvedServerURL?(candidate)
                }
                return value
            } catch {
                if !attemptedRecovery,
                   shouldAttemptUnauthorizedRecovery(error),
                   let onUnauthorizedRecovery,
                   let recoveredToken = try await onUnauthorizedRecovery(candidate)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                   !recoveredToken.isEmpty {
                    attemptedRecovery = true
                    currentToken = recoveredToken
                    do {
                        let value = try await operation(candidate, currentToken)
                        if normalizedBaseURL(candidate) != normalizedBaseURL(serverURL) {
                            onResolvedServerURL?(candidate)
                        }
                        return value
                    } catch {
                        lastError = error
                        if index == candidates.count - 1 || !shouldRetryAcrossCandidates(error) {
                            throw error
                        }
                        continue
                    }
                }

                lastError = error
                if index == candidates.count - 1 || !shouldRetryAcrossCandidates(error) {
                    throw error
                }
            }
        }

        throw lastError ?? APIError.invalidResponse
    }

    private func buildMultipartBody(
        boundary: String,
        fields: [String: String],
        fileData: Data,
        fileFieldName: String,
        fileName: String,
        mimeType: String
    ) async -> Data {
        await Task.detached(priority: .userInitiated) {
            var body = Data()

            for (key, value) in fields {
                body.append("--\(boundary)\r\n")
                body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
                body.append("\(value)\r\n")
            }

            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n")
            body.append("Content-Type: \(mimeType)\r\n\r\n")
            body.append(fileData)
            body.append("\r\n")

            body.append("--\(boundary)--\r\n")
            return body
        }.value
    }

    private func readFileData(at url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(http.statusCode, body)
        }
    }

    private func data(
        for request: URLRequest,
        registerCancellation: ((@escaping () -> Void) -> Void)? = nil
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            func resume(with result: Result<(Data, URLResponse), Error>) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    resume(with: .failure(error))
                    return
                }
                guard let response else {
                    resume(with: .failure(APIError.invalidResponse))
                    return
                }
                resume(with: .success((data ?? Data(), response)))
            }
            registerCancellation? {
                task.cancel()
            }
            task.resume()
        }
    }

    private func shouldAttemptUnauthorizedRecovery(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        return apiError.isMissingOrInvalidBearerToken
    }

    private func resolveArtifactURL(serverURL: String, artifact: ChatArtifact) -> URL? {
        if let raw = artifact.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let rewritten = rewriteProtectedBackendURL(raw, serverURL: serverURL) {
                return rewritten
            }
            return URL(string: raw)
        }
        if let path = artifact.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let normalizedPath = path.removingPercentEncoding ?? path
            guard var components = URLComponents(string: normalizedBaseURL(serverURL)) else {
                return nil
            }
            components.path = "/v1/files"
            components.queryItems = [URLQueryItem(name: "path", value: normalizedPath)]
            return components.url
        }
        return nil
    }

    private func resolveArtifactInspectURL(
        serverURL: String,
        artifact: ChatArtifact,
        textPreviewBytes: Int,
        textPreviewOffset: Int = 0,
        textSearch: String? = nil
    ) -> URL? {
        guard let resolvedURL = resolveArtifactURL(serverURL: serverURL, artifact: artifact),
              let path = artifactFileReference(for: artifact, url: resolvedURL)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              var components = URLComponents(string: normalizedBaseURL(serverURL)) else {
            return nil
        }
        components.path = "/v1/files/inspect"
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "text_preview_bytes", value: String(max(0, textPreviewBytes))),
            URLQueryItem(name: "text_preview_offset", value: String(max(0, textPreviewOffset))),
        ]
        if let textSearch = textSearch?.trimmingCharacters(in: .whitespacesAndNewlines),
           !textSearch.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "text_search", value: textSearch))
        }
        return components.url
    }

    private func rewriteProtectedBackendURL(_ rawURL: String, serverURL: String) -> URL? {
        guard let original = URL(string: rawURL),
              original.path.hasPrefix("/v1/"),
              let backend = URL(string: normalizedBaseURL(serverURL)) else {
            return nil
        }
        let originalComponents = URLComponents(url: original, resolvingAgainstBaseURL: false)
        var components = URLComponents()
        components.scheme = backend.scheme
        components.host = backend.host
        components.port = backend.port
        components.path = original.path
        components.percentEncodedQuery = originalComponents?.percentEncodedQuery
        components.fragment = original.fragment
        return components.url
    }

    private func shouldAttachAuth(to url: URL, serverURL: String) -> Bool {
        guard let backend = URL(string: normalizedBaseURL(serverURL)) else {
            return false
        }
        return url.host == backend.host &&
            (url.port ?? defaultPort(for: url.scheme)) == (backend.port ?? defaultPort(for: backend.scheme)) &&
            url.scheme == backend.scheme &&
            url.path.hasPrefix("/v1/")
    }

    private func candidateServerURLs(for serverURL: String) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for raw in [serverURL] + fallbackServerURLs {
            let normalized = normalizedBaseURL(raw)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            ordered.append(normalized)
        }

        return ordered
    }

    private func normalizedBaseURL(_ rawURL: String) -> String {
        rawURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func shouldRetryAcrossCandidates(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .invalidURL, .missingCredentials:
                return false
            case .invalidResponse:
                return true
            case let .httpError(code, _):
                return code == 404
            }
        }
        if error is DecodingError {
            return true
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return false
            }
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    func _test_shouldRetryAcrossCandidates(_ error: Error) -> Bool {
        shouldRetryAcrossCandidates(error)
    }

    private func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https":
            return 443
        default:
            return 80
        }
    }

    private func preferredExtension(from artifact: ChatArtifact, url: URL) -> String {
        if let ext = artifactFileReference(for: artifact, url: url).flatMap({ URL(fileURLWithPath: $0).pathExtension.nonEmpty }) {
            return "." + ext
        }
        if let ext = url.pathExtension.nonEmpty {
            return "." + ext
        }
        if let mime = artifact.mime?.lowercased() {
            if mime.contains("png") { return ".png" }
            if mime.contains("jpeg") || mime.contains("jpg") { return ".jpg" }
            if mime.contains("gif") { return ".gif" }
            if mime.contains("webp") { return ".webp" }
            if mime.contains("pdf") { return ".pdf" }
            if mime.contains("rtf") { return ".rtf" }
            if mime.contains("zip") { return ".zip" }
            if mime.contains("json") { return ".json" }
            if mime.contains("markdown") { return ".md" }
            if mime.contains("yaml") { return ".yaml" }
            if mime.contains("text/plain") { return ".txt" }
            if mime.contains("python") { return ".py" }
        }
        return ""
    }

    private func suggestedBaseName(from artifact: ChatArtifact, url: URL) -> String {
        if let title = artifact.title.nonEmpty {
            return sanitizeFileName(title)
        }
        if let reference = artifactFileReference(for: artifact, url: url),
           let name = URL(fileURLWithPath: reference).deletingPathExtension().lastPathComponent.nonEmpty {
            return sanitizeFileName(name)
        }
        if let name = url.deletingPathExtension().lastPathComponent.nonEmpty {
            return sanitizeFileName(name)
        }
        return "artifact"
    }

    private func sanitizeFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(cleaned).replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).nonEmpty ?? "artifact"
    }

    private func artifactFileReference(for artifact: ChatArtifact, url: URL) -> String? {
        if let path = artifact.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return path.removingPercentEncoding ?? path
        }
        if let rawURL = artifact.url?.trimmingCharacters(in: .whitespacesAndNewlines),
           let parsedURL = URL(string: rawURL),
           let path = ChatArtifactResolution.backendFilePath(from: parsedURL) {
            return path
        }
        return ChatArtifactResolution.backendFilePath(from: url)
    }
}

#if DEBUG
extension APIClient {
    func _test_resolveArtifactURL(serverURL: String, artifact: ChatArtifact) -> URL? {
        resolveArtifactURL(serverURL: serverURL, artifact: artifact)
    }

    func _test_suggestedDownloadFileName(serverURL: String, artifact: ChatArtifact) -> String? {
        guard let url = resolveArtifactURL(serverURL: serverURL, artifact: artifact) else {
            return nil
        }
        return "\(suggestedBaseName(from: artifact, url: url))\(preferredExtension(from: artifact, url: url))"
    }

    func _test_resolveArtifactInspectURL(
        serverURL: String,
        artifact: ChatArtifact,
        textPreviewBytes: Int = 64 * 1024,
        textPreviewOffset: Int = 0,
        textSearch: String? = nil
    ) -> URL? {
        resolveArtifactInspectURL(
            serverURL: serverURL,
            artifact: artifact,
            textPreviewBytes: textPreviewBytes,
            textPreviewOffset: textPreviewOffset,
            textSearch: textSearch
        )
    }

    func _test_previewDownloadCacheKey(url: URL, cacheVersion: String?) -> String {
        PreviewDownloadCache.cacheKey(for: url, cacheVersion: cacheVersion)
    }
}
#endif

private actor PreviewDownloadCache {
    private struct Entry {
        let url: URL
        let createdAt: Date
    }

    private let prefix = "mobaile-preview-"
    private let reuseInterval: TimeInterval = 10 * 60
    private let staleFileAge: TimeInterval = 24 * 60 * 60
    private var entries: [String: Entry] = [:]
    private var lastCleanup: Date?

    static func cacheKey(for url: URL, cacheVersion: String?) -> String {
        guard let cacheVersion,
              !cacheVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return url.absoluteString
        }
        return "\(url.absoluteString)#\(cacheVersion)"
    }

    func file(for key: String) -> URL? {
        cleanupIfNeeded()
        guard let entry = entries[key],
              Date().timeIntervalSince(entry.createdAt) <= reuseInterval,
              FileManager.default.fileExists(atPath: entry.url.path) else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.url
    }

    func store(
        _ data: Data,
        key: String,
        baseName: String,
        fileExtension: String
    ) throws -> URL {
        cleanupIfNeeded()
        let filename = "\(prefix)\(baseName)-\(UUID().uuidString)\(fileExtension)"
        let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: targetURL, options: .atomic)
        entries[key] = Entry(url: targetURL, createdAt: Date())
        return targetURL
    }

    private func cleanupIfNeeded() {
        let now = Date()
        if let lastCleanup, now.timeIntervalSince(lastCleanup) < 30 * 60 {
            return
        }
        lastCleanup = now
        entries = entries.filter { _, entry in
            now.timeIntervalSince(entry.createdAt) <= reuseInterval &&
                FileManager.default.fileExists(atPath: entry.url.path)
        }

        let directory = FileManager.default.temporaryDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in urls where url.lastPathComponent.hasPrefix(prefix) {
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modifiedAt) > staleFileAge {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        self.append(contentsOf: string.utf8)
    }
}

private final class UploadTaskDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let progressHandler: ((Double) -> Void)?
    private var responseData = Data()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    init(progressHandler: ((Double) -> Void)?) {
        self.progressHandler = progressHandler
    }

    func upload(
        session: URLSession,
        request: URLRequest,
        bodyData: Data,
        registerCancellation: ((@escaping () -> Void) -> Void)?
    ) async throws -> (Data, URLResponse) {
        progressHandler?(0)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.uploadTask(with: request, from: bodyData)
            registerCancellation? { [weak task] in
                task?.cancel()
            }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        progressHandler?(min(1, max(0, progress)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resume(with: .failure(error))
            return
        }
        guard let response = task.response else {
            resume(with: .failure(APIError.invalidResponse))
            return
        }
        progressHandler?(1)
        resume(with: .success((responseData, response)))
    }

    private func resume(with result: Result<(Data, URLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
