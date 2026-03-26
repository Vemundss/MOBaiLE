import Foundation

struct HumanUnblockRequest: Codable, Equatable {
    let instructions: String
    let suggestedReply: String

    enum CodingKeys: String, CodingKey {
        case instructions
        case suggestedReply = "suggested_reply"
    }

    init(
        instructions: String,
        suggestedReply: String = "I completed the requested unblock step. Continue from the preserved state."
    ) {
        self.instructions = instructions
        self.suggestedReply = suggestedReply
    }
}

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
    var pendingHumanUnblock: HumanUnblockRequest?
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
        case pendingHumanUnblock
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
        pendingHumanUnblock: HumanUnblockRequest? = nil,
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
        self.pendingHumanUnblock = pendingHumanUnblock
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
        pendingHumanUnblock = try container.decodeIfPresent(HumanUnblockRequest.self, forKey: .pendingHumanUnblock)
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
        try container.encodeIfPresent(pendingHumanUnblock, forKey: .pendingHumanUnblock)
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
    var id: String { eventID ?? (seq.map { "seq-\($0)" }) ?? "\(type)-\(actionIndex ?? -1)-\(message)" }
    let seq: Int?
    let type: String
    let actionIndex: Int?
    let message: String
    let eventID: String?
    let createdAt: String?

    init(
        seq: Int? = nil,
        type: String,
        actionIndex: Int? = nil,
        message: String,
        eventID: String? = nil,
        createdAt: String? = nil
    ) {
        self.seq = seq
        self.type = type
        self.actionIndex = actionIndex
        self.message = message
        self.eventID = eventID
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case seq
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
    let pendingHumanUnblock: HumanUnblockRequest?
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
        case pendingHumanUnblock = "pending_human_unblock"
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

struct SlashCommandDescriptor: Decodable, Equatable {
    let id: String
    let title: String
    let description: String
    let usage: String
    let group: String?
    let aliases: [String]
    let symbol: String
    let argumentKind: String
    let argumentOptions: [String]
    let argumentPlaceholder: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case usage
        case group
        case aliases
        case symbol
        case argumentKind = "argument_kind"
        case argumentOptions = "argument_options"
        case argumentPlaceholder = "argument_placeholder"
    }
}

struct SlashCommandExecutionRequest: Encodable {
    let arguments: String?
}

struct SlashCommandExecutionResponse: Decodable {
    let commandId: String
    let message: String
    let sessionContext: SessionContext?

    enum CodingKeys: String, CodingKey {
        case commandId = "command_id"
        case message
        case sessionContext = "session_context"
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

enum ComposerLocalSlashAction: String, CaseIterable {
    case new
    case threads
    case logs
    case settings
    case browse
    case retry
    case voice
    case paste
    case clear
}

struct ComposerSlashCommand: Identifiable, Equatable {
    enum Source: Equatable {
        case local(ComposerLocalSlashAction)
        case backend
    }

    let id: String
    let title: String
    let description: String
    let symbol: String
    let usage: String
    let group: String?
    let aliases: [String]
    let argumentKind: String
    let argumentOptions: [String]
    let argumentPlaceholder: String?
    let source: Source

    var acceptsArguments: Bool {
        argumentKind != "none"
    }

    var insertionText: String {
        acceptsArguments ? "/\(id) " : "/\(id)"
    }

    init(descriptor: SlashCommandDescriptor) {
        id = descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        title = descriptor.title
        description = descriptor.description
        symbol = descriptor.symbol
        usage = descriptor.usage
        let normalizedGroup = descriptor.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        group = normalizedGroup.isEmpty ? nil : normalizedGroup
        aliases = descriptor.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        argumentKind = descriptor.argumentKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        argumentOptions = descriptor.argumentOptions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        argumentPlaceholder = descriptor.argumentPlaceholder
        source = .backend
    }

    private init(
        id: String,
        title: String,
        description: String,
        symbol: String,
        usage: String,
        group: String? = nil,
        aliases: [String],
        argumentKind: String,
        argumentOptions: [String] = [],
        argumentPlaceholder: String? = nil,
        source: Source
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.symbol = symbol
        self.usage = usage
        self.group = group
        self.aliases = aliases
        self.argumentKind = argumentKind
        self.argumentOptions = argumentOptions
        self.argumentPlaceholder = argumentPlaceholder
        self.source = source
    }

    static let localCommands: [ComposerSlashCommand] = [
        .local(
            .new,
            title: "New Chat",
            description: "Start a fresh thread without leaving the current session.",
            symbol: "square.and.pencil",
            usage: "/new",
            group: "Session",
            aliases: ["chat"]
        ),
        .local(
            .threads,
            title: "Threads",
            description: "Open the thread list and jump between conversations.",
            symbol: "text.bubble",
            usage: "/threads",
            group: "Session",
            aliases: ["history"]
        ),
        .local(
            .logs,
            title: "Run Logs",
            description: "Open the current run event log view.",
            symbol: "doc.text.magnifyingglass",
            usage: "/logs",
            group: "Session",
            aliases: ["events"]
        ),
        .local(
            .settings,
            title: "Settings",
            description: "Open backend connection and runtime settings.",
            symbol: "slider.horizontal.3",
            usage: "/settings",
            group: "App",
            aliases: ["config"]
        ),
        .local(
            .browse,
            title: "Browse Workspace",
            description: "Open the workspace browser at the current folder or a specific path.",
            symbol: "folder",
            usage: "/browse [path]",
            group: "Workspace",
            aliases: ["dir", "files", "workspace"],
            argumentKind: "path",
            argumentPlaceholder: "path"
        ),
        .local(
            .retry,
            title: "Retry Last Prompt",
            description: "Resend the most recent submitted prompt.",
            symbol: "arrow.clockwise",
            usage: "/retry",
            group: "Session",
            aliases: ["rerun", "resend"]
        ),
        .local(
            .voice,
            title: "Start Recording",
            description: "Start hands-free voice capture.",
            symbol: "mic",
            usage: "/voice",
            group: "Input",
            aliases: ["record", "mic"]
        ),
        .local(
            .paste,
            title: "Paste Clipboard",
            description: "Paste text or an image from the clipboard into the draft.",
            symbol: "doc.on.clipboard",
            usage: "/paste",
            group: "Input",
            aliases: ["clipboard"]
        ),
        .local(
            .clear,
            title: "Clear Draft",
            description: "Clear the current prompt and staged attachments.",
            symbol: "xmark.circle",
            usage: "/clear",
            group: "Input",
            aliases: ["reset"]
        ),
    ]

    static func mergedCatalog(
        local: [ComposerSlashCommand] = ComposerSlashCommand.localCommands,
        backend: [ComposerSlashCommand]
    ) -> [ComposerSlashCommand] {
        let localIDs = Set(local.map(\.id))
        let remote = backend.filter { !localIDs.contains($0.id) }
        return local + remote
    }

    private static func local(
        _ action: ComposerLocalSlashAction,
        title: String,
        description: String,
        symbol: String,
        usage: String,
        group: String? = nil,
        aliases: [String],
        argumentKind: String = "none",
        argumentOptions: [String] = [],
        argumentPlaceholder: String? = nil
    ) -> ComposerSlashCommand {
        ComposerSlashCommand(
            id: action.rawValue,
            title: title,
            description: description,
            symbol: symbol,
            usage: usage,
            group: group,
            aliases: aliases,
            argumentKind: argumentKind,
            argumentOptions: argumentOptions,
            argumentPlaceholder: argumentPlaceholder,
            source: .local(action)
        )
    }

    fileprivate func matches(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        let candidates = [id] + aliases
        return candidates.contains { candidate in
            candidate.hasPrefix(normalized)
        }
    }

    fileprivate func matchesExactly(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized == id || aliases.contains(normalized)
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

func resolveComposerSlashCommandState(
    from input: String,
    commands: [ComposerSlashCommand] = ComposerSlashCommand.localCommands
) -> ComposerSlashCommandState? {
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
    let suggestions = commands.filter { command in
        command.matches(query: normalizedQuery)
    }
    let exactMatch = commands.first { command in
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
func _test_resolveComposerSlashCommandState(
    _ input: String,
    commands: [ComposerSlashCommand] = ComposerSlashCommand.localCommands
) -> ComposerSlashCommandState? {
    resolveComposerSlashCommandState(from: input, commands: commands)
}
#endif
