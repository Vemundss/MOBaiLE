import Foundation

struct ConversationMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: String
    let text: String

    init(id: UUID = UUID(), role: String, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

struct ChatThread: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var conversation: [ConversationMessage]
    var runID: String
    var summaryText: String
    var transcriptText: String
    var statusText: String
    var resolvedWorkingDirectory: String
    var activeRunExecutor: String
}

struct UtteranceRequest: Encodable {
    let sessionId: String
    let utteranceText: String
    let mode: String
    let executor: String
    let workingDirectory: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case utteranceText = "utterance_text"
        case mode
        case executor
        case workingDirectory = "working_directory"
    }
}

struct UtteranceResponse: Decodable {
    let runId: String
    let status: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case status
        case message
    }
}

struct AudioRunResponse: Decodable {
    let runId: String
    let status: String
    let message: String
    let transcriptText: String

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case status
        case message
        case transcriptText = "transcript_text"
    }
}

struct PairExchangeRequest: Encodable {
    let pairCode: String
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case pairCode = "pair_code"
        case sessionId = "session_id"
    }
}

struct PairExchangeResponse: Decodable {
    let apiToken: String
    let sessionId: String
    let securityMode: String

    enum CodingKeys: String, CodingKey {
        case apiToken = "api_token"
        case sessionId = "session_id"
        case securityMode = "security_mode"
    }
}

struct CancelRunResponse: Decodable {
    let runId: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case status
    }
}

struct ExecutionEvent: Decodable, Identifiable {
    var id: String { eventID ?? "\(type)-\(actionIndex ?? -1)-\(message)" }
    let type: String
    let actionIndex: Int?
    let message: String
    let eventID: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case type
        case actionIndex = "action_index"
        case message
        case eventID = "event_id"
        case createdAt = "created_at"
    }
}

struct RunRecord: Decodable {
    let runId: String
    let sessionId: String
    let executor: String?
    let utteranceText: String
    let workingDirectory: String?
    let status: String
    let summary: String
    let events: [ExecutionEvent]
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case sessionId = "session_id"
        case executor
        case utteranceText = "utterance_text"
        case workingDirectory = "working_directory"
        case status
        case summary
        case events
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct RunSummary: Decodable {
    let runId: String
    let sessionId: String
    let executor: String?
    let utteranceText: String
    let status: String
    let summary: String
    let updatedAt: String?
    let workingDirectory: String?

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case sessionId = "session_id"
        case executor
        case utteranceText = "utterance_text"
        case status
        case summary
        case updatedAt = "updated_at"
        case workingDirectory = "working_directory"
    }
}

struct RunDiagnostics: Decodable {
    let runId: String
    let status: String
    let summary: String
    let eventCount: Int
    let eventTypeCounts: [String: Int]
    let hasStderr: Bool
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case status
        case summary
        case eventCount = "event_count"
        case eventTypeCounts = "event_type_counts"
        case hasStderr = "has_stderr"
        case lastError = "last_error"
    }
}

struct RuntimeConfig: Decodable {
    let securityMode: String
    let workdirRoot: String?
    let allowAbsoluteFileReads: Bool?
    let fileRoots: [String]?

    enum CodingKeys: String, CodingKey {
        case securityMode = "security_mode"
        case workdirRoot = "workdir_root"
        case allowAbsoluteFileReads = "allow_absolute_file_reads"
        case fileRoots = "file_roots"
    }
}

struct ChatEnvelope: Decodable {
    let type: String
    let version: String
    let messageID: String?
    let createdAt: String?
    let summary: String
    let sections: [ChatSection]
    let agendaItems: [ChatAgendaItem]
    let artifacts: [ChatArtifact]

    enum CodingKeys: String, CodingKey {
        case type
        case version
        case messageID = "message_id"
        case createdAt = "created_at"
        case summary
        case sections
        case agendaItems = "agenda_items"
        case artifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "assistant_response"
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        sections = try container.decodeIfPresent([ChatSection].self, forKey: .sections) ?? []
        agendaItems = try container.decodeIfPresent([ChatAgendaItem].self, forKey: .agendaItems) ?? []
        artifacts = try container.decodeIfPresent([ChatArtifact].self, forKey: .artifacts) ?? []
    }
}

struct ChatSection: Decodable {
    let title: String
    let body: String
}

struct ChatAgendaItem: Decodable, Identifiable {
    var id: String { "\(start)-\(end)-\(title)-\(calendar)-\(location ?? "")" }
    let start: String
    let end: String
    let title: String
    let calendar: String
    let location: String?
}

struct ChatArtifact: Decodable, Identifiable {
    var id: String { path ?? url ?? "\(type)-\(title)" }
    let type: String
    let title: String
    let path: String?
    let mime: String?
    let url: String?
}
