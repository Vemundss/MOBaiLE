import Foundation

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

struct ExecutionEvent: Decodable, Identifiable {
    var id: String { "\(type)-\(actionIndex ?? -1)-\(message)" }
    let type: String
    let actionIndex: Int?
    let message: String

    enum CodingKeys: String, CodingKey {
        case type
        case actionIndex = "action_index"
        case message
    }
}

struct RunRecord: Decodable {
    let runId: String
    let sessionId: String
    let utteranceText: String
    let workingDirectory: String?
    let status: String
    let summary: String
    let events: [ExecutionEvent]

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case sessionId = "session_id"
        case utteranceText = "utterance_text"
        case workingDirectory = "working_directory"
        case status
        case summary
        case events
    }
}
