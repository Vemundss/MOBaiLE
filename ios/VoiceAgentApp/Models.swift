import Foundation

struct ConversationMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: String
    let text: String
    let attachments: [ChatArtifact]

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case attachments
    }

    init(id: UUID = UUID(), role: String, text: String, attachments: [ChatArtifact] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(String.self, forKey: .role)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try container.decodeIfPresent([ChatArtifact].self, forKey: .attachments) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(attachments, forKey: .attachments)
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
    var draftText: String
    var draftAttachments: [DraftAttachment]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case updatedAt
        case conversation
        case runID
        case summaryText
        case transcriptText
        case statusText
        case resolvedWorkingDirectory
        case activeRunExecutor
        case draftText
        case draftAttachments
    }

    init(
        id: UUID,
        title: String,
        updatedAt: Date,
        conversation: [ConversationMessage],
        runID: String,
        summaryText: String,
        transcriptText: String,
        statusText: String,
        resolvedWorkingDirectory: String,
        activeRunExecutor: String,
        draftText: String = "",
        draftAttachments: [DraftAttachment] = []
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.conversation = conversation
        self.runID = runID
        self.summaryText = summaryText
        self.transcriptText = transcriptText
        self.statusText = statusText
        self.resolvedWorkingDirectory = resolvedWorkingDirectory
        self.activeRunExecutor = activeRunExecutor
        self.draftText = draftText
        self.draftAttachments = draftAttachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New Chat"
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        conversation = try container.decodeIfPresent([ConversationMessage].self, forKey: .conversation) ?? []
        runID = try container.decodeIfPresent(String.self, forKey: .runID) ?? ""
        summaryText = try container.decodeIfPresent(String.self, forKey: .summaryText) ?? ""
        transcriptText = try container.decodeIfPresent(String.self, forKey: .transcriptText) ?? ""
        statusText = try container.decodeIfPresent(String.self, forKey: .statusText) ?? "Idle"
        resolvedWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .resolvedWorkingDirectory) ?? ""
        activeRunExecutor = try container.decodeIfPresent(String.self, forKey: .activeRunExecutor) ?? "codex"
        draftText = try container.decodeIfPresent(String.self, forKey: .draftText) ?? ""
        draftAttachments = try container.decodeIfPresent([DraftAttachment].self, forKey: .draftAttachments) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(runID, forKey: .runID)
        try container.encode(summaryText, forKey: .summaryText)
        try container.encode(transcriptText, forKey: .transcriptText)
        try container.encode(statusText, forKey: .statusText)
        try container.encode(resolvedWorkingDirectory, forKey: .resolvedWorkingDirectory)
        try container.encode(activeRunExecutor, forKey: .activeRunExecutor)
        try container.encode(draftText, forKey: .draftText)
        try container.encode(draftAttachments, forKey: .draftAttachments)
    }
}

struct UtteranceRequest: Encodable {
    let sessionId: String
    let threadID: String?
    let utteranceText: String
    let attachments: [ChatArtifact]
    let mode: String
    let executor: String?
    let workingDirectory: String?
    let responseMode: String?
    let responseProfile: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case threadID = "thread_id"
        case utteranceText = "utterance_text"
        case attachments
        case mode
        case executor
        case workingDirectory = "working_directory"
        case responseMode = "response_mode"
        case responseProfile = "response_profile"
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

struct RuntimeExecutorDescriptor: Decodable, Identifiable {
    let id: String
    let title: String
    let kind: String
    let available: Bool
    let isDefault: Bool
    let internalOnly: Bool
    let model: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case available
        case isDefault = "default"
        case internalOnly = "internal_only"
        case model
    }
}

struct RuntimeConfig: Decodable {
    let securityMode: String
    let defaultExecutor: String?
    let availableExecutors: [String]?
    let executors: [RuntimeExecutorDescriptor]?
    let transcribeProvider: String?
    let transcribeReady: Bool?
    let codexModel: String?
    let claudeModel: String?
    let workdirRoot: String?
    let allowAbsoluteFileReads: Bool?
    let fileRoots: [String]?

    enum CodingKeys: String, CodingKey {
        case securityMode = "security_mode"
        case defaultExecutor = "default_executor"
        case availableExecutors = "available_executors"
        case executors
        case transcribeProvider = "transcribe_provider"
        case transcribeReady = "transcribe_ready"
        case codexModel = "codex_model"
        case claudeModel = "claude_model"
        case workdirRoot = "workdir_root"
        case allowAbsoluteFileReads = "allow_absolute_file_reads"
        case fileRoots = "file_roots"
    }
}

struct SessionContextUpdateRequest: Encodable {
    let executor: String?
    let workingDirectory: String?

    enum CodingKeys: String, CodingKey {
        case executor
        case workingDirectory = "working_directory"
    }
}

struct SessionContext: Decodable {
    let sessionId: String
    let executor: String
    let workingDirectory: String?
    let resolvedWorkingDirectory: String
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case executor
        case workingDirectory = "working_directory"
        case resolvedWorkingDirectory = "resolved_working_directory"
        case updatedAt = "updated_at"
    }
}

struct DirectoryEntry: Decodable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case isDirectory = "is_directory"
    }
}

struct DirectoryListingResponse: Decodable {
    let path: String
    let entries: [DirectoryEntry]
    let truncated: Bool
}

struct DirectoryCreateRequest: Encodable {
    let path: String
}

struct DirectoryCreateResponse: Decodable {
    let path: String
    let created: Bool
}

struct UploadResponse: Decodable {
    let artifact: ChatArtifact
    let sizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case artifact
        case sizeBytes = "size_bytes"
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

struct ChatSection: Codable, Equatable {
    let title: String
    let body: String
}

struct ChatAgendaItem: Codable, Equatable, Identifiable {
    var id: String { "\(start)-\(end)-\(title)-\(calendar)-\(location ?? "")" }
    let start: String
    let end: String
    let title: String
    let calendar: String
    let location: String?
}

struct ChatArtifact: Codable, Equatable, Identifiable {
    var id: String { path ?? url ?? "\(type)-\(title)" }
    let type: String
    let title: String
    let path: String?
    let mime: String?
    let url: String?
}

enum ComposerSlashCommand: String, CaseIterable, Identifiable {
    case new
    case threads
    case logs
    case settings
    case browse
    case cwd
    case executor
    case retry
    case voice
    case paste
    case clear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .new:
            return "New Chat"
        case .threads:
            return "Threads"
        case .logs:
            return "Run Logs"
        case .settings:
            return "Settings"
        case .browse:
            return "Browse Workspace"
        case .cwd:
            return "Working Directory"
        case .executor:
            return "Executor"
        case .retry:
            return "Retry Last Prompt"
        case .voice:
            return "Start Recording"
        case .paste:
            return "Paste Clipboard"
        case .clear:
            return "Clear Draft"
        }
    }

    var description: String {
        switch self {
        case .new:
            return "Start a fresh thread without leaving the current session."
        case .threads:
            return "Open the thread list and jump between conversations."
        case .logs:
            return "Open the current run event log view."
        case .settings:
            return "Open backend connection and runtime settings."
        case .browse:
            return "Open the workspace browser at the current folder or a specific path."
        case .cwd:
            return "Show or change the working directory used for new runs."
        case .executor:
            return "Show or switch the active executor."
        case .retry:
            return "Resend the most recent submitted prompt."
        case .voice:
            return "Start hands-free voice capture."
        case .paste:
            return "Paste text or an image from the clipboard into the draft."
        case .clear:
            return "Clear the current prompt and staged attachments."
        }
    }

    var symbol: String {
        switch self {
        case .new:
            return "square.and.pencil"
        case .threads:
            return "text.bubble"
        case .logs:
            return "doc.text.magnifyingglass"
        case .settings:
            return "slider.horizontal.3"
        case .browse:
            return "folder"
        case .cwd:
            return "arrow.triangle.branch"
        case .executor:
            return "bolt.horizontal.circle"
        case .retry:
            return "arrow.clockwise"
        case .voice:
            return "mic"
        case .paste:
            return "doc.on.clipboard"
        case .clear:
            return "xmark.circle"
        }
    }

    var usage: String {
        switch self {
        case .new:
            return "/new"
        case .threads:
            return "/threads"
        case .logs:
            return "/logs"
        case .settings:
            return "/settings"
        case .browse:
            return "/browse [path]"
        case .cwd:
            return "/cwd [path]"
        case .executor:
            return "/executor [codex|claude|local]"
        case .retry:
            return "/retry"
        case .voice:
            return "/voice"
        case .paste:
            return "/paste"
        case .clear:
            return "/clear"
        }
    }

    var acceptsArguments: Bool {
        switch self {
        case .browse, .cwd, .executor:
            return true
        default:
            return false
        }
    }

    var insertionText: String {
        acceptsArguments ? "/\(rawValue) " : "/\(rawValue)"
    }

    var aliases: [String] {
        switch self {
        case .new:
            return ["chat"]
        case .threads:
            return ["history"]
        case .logs:
            return ["events"]
        case .settings:
            return ["config"]
        case .browse:
            return ["dir", "files", "workspace"]
        case .cwd:
            return ["pwd", "workdir"]
        case .executor:
            return ["exec", "agent"]
        case .retry:
            return ["rerun", "resend"]
        case .voice:
            return ["record", "mic"]
        case .paste:
            return ["clipboard"]
        case .clear:
            return ["reset"]
        }
    }

    fileprivate func matches(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        let candidates = [rawValue] + aliases
        return candidates.contains { candidate in
            candidate.hasPrefix(normalized)
        }
    }

    fileprivate func matchesExactly(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized == rawValue || aliases.contains(normalized)
    }
}

struct ComposerSlashCommandState: Equatable {
    let query: String
    let arguments: String
    let suggestions: [ComposerSlashCommand]
    let exactMatch: ComposerSlashCommand?

    var hasUnknownCommand: Bool {
        !query.isEmpty && exactMatch == nil && suggestions.isEmpty
    }
}

func resolveComposerSlashCommandState(from input: String) -> ComposerSlashCommandState? {
    let trimmedLeading = String(input.drop(while: { $0.isWhitespace }))
    guard trimmedLeading.hasPrefix("/") else { return nil }
    guard !trimmedLeading.contains("\n") else { return nil }

    let payload = String(trimmedLeading.dropFirst())
    let token = String(payload.prefix(while: { !$0.isWhitespace }))
    if token.contains("/") {
        return nil
    }

    let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
    let normalizedQuery = token.lowercased()
    let tokenIsValid = normalizedQuery.unicodeScalars.allSatisfy { scalar in
        allowedScalars.contains(scalar)
    }
    guard tokenIsValid else { return nil }

    let arguments = String(payload.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    let suggestions = ComposerSlashCommand.allCases.filter { command in
        command.matches(query: normalizedQuery)
    }
    let exactMatch = ComposerSlashCommand.allCases.first { command in
        command.matchesExactly(query: normalizedQuery)
    }

    return ComposerSlashCommandState(
        query: normalizedQuery,
        arguments: arguments,
        suggestions: suggestions,
        exactMatch: exactMatch
    )
}

#if DEBUG
func _test_resolveComposerSlashCommandState(_ input: String) -> ComposerSlashCommandState? {
    resolveComposerSlashCommandState(from: input)
}
#endif
