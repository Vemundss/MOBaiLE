import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
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

    func createAudioRun(
        serverURL: String,
        token: String,
        sessionID: String,
        executor: String,
        workingDirectory: String?,
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
        request.httpBody = buildMultipartBody(
            boundary: boundary,
            fields: [
                "session_id": sessionID,
                "executor": executor,
                "working_directory": workingDirectory ?? ""
            ],
            fileData: audioData,
            fileFieldName: "audio",
            fileName: audioFileURL.lastPathComponent,
            mimeType: "audio/m4a"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try jsonDecoder.decode(AudioRunResponse.self, from: data)
    }

    func streamRunEvents(
        serverURL: String,
        token: String,
        runID: String
    ) -> AsyncThrowingStream<ExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
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
                    if line.hasPrefix("data: ") {
                        dataLines.append(String(line.dropFirst(6)))
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
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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
}

private extension Data {
    mutating func append(_ string: String) {
        self.append(contentsOf: string.utf8)
    }
}
