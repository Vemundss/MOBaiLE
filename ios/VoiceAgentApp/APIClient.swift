import Foundation

enum APIError: Error, LocalizedError {
    case missingCredentials
    case invalidURL
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Enter server URL and API token first."
        case .invalidURL:
            return "Invalid server URL."
        case .invalidResponse:
            return "Invalid server response."
        case let .httpError(code, body):
            if body.isEmpty {
                return "Server returned HTTP \(code)."
            }
            return "Server returned HTTP \(code): \(body)"
        }
    }
}

final class APIClient {
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    func createUtterance(
        serverURL: String,
        token: String,
        requestBody: UtteranceRequest
    ) async throws -> UtteranceResponse {
        guard let url = URL(string: serverURL + "/v1/utterances") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try jsonEncoder.encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try jsonDecoder.decode(UtteranceResponse.self, from: data)
    }

    func exchangePairingCode(
        serverURL: String,
        pairCode: String,
        sessionID: String?
    ) async throws -> PairExchangeResponse {
        guard let url = URL(string: serverURL + "/v1/pair/exchange") else {
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

    func fetchRun(
        serverURL: String,
        token: String,
        runID: String
    ) async throws -> RunRecord {
        guard let url = URL(string: serverURL + "/v1/runs/\(runID)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try jsonDecoder.decode(RunRecord.self, from: data)
    }

    func fetchSessionRuns(
        serverURL: String,
        token: String,
        sessionID: String,
        limit: Int = 20
    ) async throws -> [RunSummary] {
        guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: serverURL + "/v1/sessions/\(encoded)/runs?limit=\(limit)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try jsonDecoder.decode([RunSummary].self, from: data)
    }

    func fetchRunDiagnostics(
        serverURL: String,
        token: String,
        runID: String
    ) async throws -> RunDiagnostics {
        guard let url = URL(string: serverURL + "/v1/runs/\(runID)/diagnostics") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try jsonDecoder.decode(RunDiagnostics.self, from: data)
    }

    func fetchRuntimeConfig(
        serverURL: String,
        token: String
    ) async throws -> RuntimeConfig {
        guard let url = URL(string: serverURL + "/v1/config") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try jsonDecoder.decode(RuntimeConfig.self, from: data)
    }

    func fetchDirectoryListing(
        serverURL: String,
        token: String,
        path: String?
    ) async throws -> DirectoryListingResponse {
        guard var components = URLComponents(string: serverURL + "/v1/directories") else {
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
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try jsonDecoder.decode(DirectoryListingResponse.self, from: data)
    }

    func createDirectory(
        serverURL: String,
        token: String,
        path: String
    ) async throws -> DirectoryCreateResponse {
        guard let url = URL(string: serverURL + "/v1/directories") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try jsonEncoder.encode(DirectoryCreateRequest(path: path))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try jsonDecoder.decode(DirectoryCreateResponse.self, from: data)
    }

    func createAudioRun(
        serverURL: String,
        token: String,
        sessionID: String,
        threadID: String?,
        executor: String,
        workingDirectory: String?,
        responseMode: String?,
        responseProfile: String?,
        audioFileURL: URL
    ) async throws -> AudioRunResponse {
        guard let url = URL(string: serverURL + "/v1/audio") else {
            throw APIError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        var fields: [String: String] = [
            "session_id": sessionID,
            "executor": executor,
            "working_directory": workingDirectory ?? "",
            "response_mode": responseMode ?? "",
            "response_profile": responseProfile ?? ""
        ]
        let trimmedThreadID = (threadID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedThreadID.isEmpty {
            fields["thread_id"] = trimmedThreadID
        }
        request.httpBody = buildMultipartBody(
            boundary: boundary,
            fields: fields,
            fileData: audioData,
            fileFieldName: "audio",
            fileName: audioFileURL.lastPathComponent,
            mimeType: "audio/m4a"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try jsonDecoder.decode(AudioRunResponse.self, from: data)
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
        guard let url = URL(string: serverURL + "/v1/uploads") else {
            throw APIError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        let bodyData = buildMultipartBody(
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

    func streamRunEvents(
        serverURL: String,
        token: String,
        runID: String
    ) -> AsyncThrowingStream<ExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: serverURL + "/v1/runs/\(runID)/events") else {
                        throw APIError.invalidURL
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.timeoutInterval = 60
                    request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
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
        guard let url = URL(string: serverURL + "/v1/runs/\(runID)/cancel") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try jsonDecoder.decode(CancelRunResponse.self, from: data)
    }

    func downloadArtifactToTemporaryFile(
        serverURL: String,
        token: String,
        artifact: ChatArtifact
    ) async throws -> URL {
        guard let requestURL = resolveArtifactURL(serverURL: serverURL, artifact: artifact) else {
            throw APIError.invalidURL
        }
        let data = try await fetchURLData(
            serverURL: serverURL,
            token: token,
            url: requestURL,
            timeout: 30
        )

        let ext = preferredExtension(from: artifact, url: requestURL)
        let baseName = suggestedBaseName(from: artifact, url: requestURL)
        let filename = "\(baseName)-\(UUID().uuidString)\(ext)"
        let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: targetURL, options: .atomic)
        return targetURL
    }

    func fetchURLData(
        serverURL: String,
        token: String,
        url: URL,
        timeout: TimeInterval = 20
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        if shouldAttachAuth(to: url, serverURL: serverURL), !token.isEmpty {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func buildMultipartBody(
        boundary: String,
        fields: [String: String],
        fileData: Data,
        fileFieldName: String,
        fileName: String,
        mimeType: String
    ) -> Data {
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

    private func resolveArtifactURL(serverURL: String, artifact: ChatArtifact) -> URL? {
        if let raw = artifact.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(string: raw)
        }
        if let path = artifact.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let normalizedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return nil
            }
            return URL(string: "\(normalizedServer)/v1/files?path=\(encoded)")
        }
        return nil
    }

    private func shouldAttachAuth(to url: URL, serverURL: String) -> Bool {
        guard let backend = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            return false
        }
        return url.host == backend.host &&
            (url.port ?? defaultPort(for: url.scheme)) == (backend.port ?? defaultPort(for: backend.scheme)) &&
            url.scheme == backend.scheme &&
            url.path.hasPrefix("/v1/")
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
        if let ext = URL(fileURLWithPath: artifact.path ?? "").pathExtension.nonEmpty {
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
            if mime.contains("json") { return ".json" }
            if mime.contains("text/plain") { return ".txt" }
            if mime.contains("python") { return ".py" }
        }
        return ""
    }

    private func suggestedBaseName(from artifact: ChatArtifact, url: URL) -> String {
        if let title = artifact.title.nonEmpty {
            return sanitizeFileName(title)
        }
        if let name = URL(fileURLWithPath: artifact.path ?? "").deletingPathExtension().lastPathComponent.nonEmpty {
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
