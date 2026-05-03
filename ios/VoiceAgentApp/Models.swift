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

enum ConversationMessagePresentation: String, Codable {
    case standard
    case liveActivity
}

enum ConversationInputOrigin: String, Codable {
    case text
    case voice
}

struct ConversationMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: String
    let text: String
    let attachments: [ChatArtifact]
    let presentation: ConversationMessagePresentation
    let sourceRunID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case attachments
        case presentation
        case sourceRunID = "source_run_id"
    }

    init(
        id: UUID = UUID(),
        role: String,
        text: String,
        attachments: [ChatArtifact] = [],
        presentation: ConversationMessagePresentation = .standard,
        sourceRunID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.presentation = presentation
        self.sourceRunID = sourceRunID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(String.self, forKey: .role)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try container.decodeIfPresent([ChatArtifact].self, forKey: .attachments) ?? []
        presentation = try container.decodeIfPresent(ConversationMessagePresentation.self, forKey: .presentation) ?? .standard
        sourceRunID = try container.decodeIfPresent(String.self, forKey: .sourceRunID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(presentation, forKey: .presentation)
        try container.encodeIfPresent(sourceRunID, forKey: .sourceRunID)
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
    var lastSubmittedInputOrigin: ConversationInputOrigin
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
        case lastSubmittedInputOrigin
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
        lastSubmittedInputOrigin: ConversationInputOrigin = .text,
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
        self.lastSubmittedInputOrigin = lastSubmittedInputOrigin
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
        lastSubmittedInputOrigin = try container.decodeIfPresent(
            ConversationInputOrigin.self,
            forKey: .lastSubmittedInputOrigin
        ) ?? .text
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
        try container.encode(lastSubmittedInputOrigin, forKey: .lastSubmittedInputOrigin)
        try container.encode(draftText, forKey: .draftText)
        try container.encode(draftAttachments, forKey: .draftAttachments)
    }
}

enum ChatThreadPresentationStatus: Equatable {
    case running
    case needsInput
    case completed
    case failed
    case cancelled
    case ready
    case draft
    case saved

    var label: String {
        switch self {
        case .running:
            return "Running"
        case .needsInput:
            return "Needs Input"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .ready:
            return "Ready"
        case .draft:
            return "Draft"
        case .saved:
            return "Saved"
        }
    }
}

extension ChatThread {
    var hasDraftState: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty
    }

    var presentationStatus: ChatThreadPresentationStatus {
        let lower = statusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if pendingHumanUnblock != nil || lower.contains("input") || lower.contains("blocked") {
            return .needsInput
        }

        if lower.contains("complete") {
            return .completed
        }

        if lower.contains("fail") || lower.contains("reject") || lower.contains("timed out") {
            return .failed
        }

        if lower.contains("cancel") {
            return .cancelled
        }

        if lower.contains("running")
            || lower.contains("starting")
            || lower.contains("planning")
            || lower.contains("execut")
            || lower.contains("summar")
            || lower.contains("recording") {
            return .running
        }

        if lower.contains("ready") {
            return .ready
        }

        if hasDraftState {
            return .draft
        }

        if !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .saved
        }

        return .ready
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

struct PairRefreshRequest: Encodable {
    let refreshToken: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case sessionId = "session_id"
    }
}

struct PairExchangeResponse: Decodable {
    let apiToken: String
    let refreshToken: String?
    let sessionId: String
    let securityMode: String
    let serverURL: String?
    let serverURLs: [String]?

    enum CodingKeys: String, CodingKey {
        case apiToken = "api_token"
        case refreshToken = "refresh_token"
        case sessionId = "session_id"
        case securityMode = "security_mode"
        case serverURL = "server_url"
        case serverURLs = "server_urls"
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
    let stage: String?
    let title: String?
    let displayMessage: String?
    let level: String?
    let eventID: String?
    let createdAt: String?

    init(
        seq: Int? = nil,
        type: String,
        actionIndex: Int? = nil,
        message: String,
        stage: String? = nil,
        title: String? = nil,
        displayMessage: String? = nil,
        level: String? = nil,
        eventID: String? = nil,
        createdAt: String? = nil
    ) {
        self.seq = seq
        self.type = type
        self.actionIndex = actionIndex
        self.message = message
        self.stage = stage
        self.title = title
        self.displayMessage = displayMessage
        self.level = level
        self.eventID = eventID
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case seq
        case type
        case actionIndex = "action_index"
        case message
        case stage
        case title
        case displayMessage = "display_message"
        case level
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
    let activityStageCounts: [String: Int]
    let latestActivity: String?
    let hasStderr: Bool
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case status
        case summary
        case eventCount = "event_count"
        case eventTypeCounts = "event_type_counts"
        case activityStageCounts = "activity_stage_counts"
        case latestActivity = "latest_activity"
        case hasStderr = "has_stderr"
        case lastError = "last_error"
    }
}

struct RunEventsPage: Decodable {
    let runId: String
    let events: [ExecutionEvent]
    let limit: Int
    let totalCount: Int
    let hasMoreBefore: Bool
    let hasMoreAfter: Bool
    let nextBeforeSeq: Int?
    let nextAfterSeq: Int?

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case events
        case limit
        case totalCount = "total_count"
        case hasMoreBefore = "has_more_before"
        case hasMoreAfter = "has_more_after"
        case nextBeforeSeq = "next_before_seq"
        case nextAfterSeq = "next_after_seq"
    }
}

extension RunDiagnostics {
    static func derived(
        runId: String,
        status: String,
        summary: String,
        events: [ExecutionEvent]
    ) -> RunDiagnostics {
        var eventTypeCounts: [String: Int] = [:]
        var activityStageCounts: [String: Int] = [:]
        var latestActivity: String?
        var hasStderr = false
        var lastError: String?

        for event in events {
            eventTypeCounts[event.type, default: 0] += 1

            if let stage = normalizedDiagnosticsText(event.stage), !stage.isEmpty {
                activityStageCounts[stage, default: 0] += 1
                latestActivity = normalizedDiagnosticsText(event.displayMessage) ?? normalizedDiagnosticsText(event.message)
            }

            if event.level?.lowercased() == "error" {
                lastError = normalizedDiagnosticsText(event.displayMessage) ?? normalizedDiagnosticsText(event.message)
            }

            if event.type == "action.stderr" {
                hasStderr = true
                lastError = normalizedDiagnosticsText(event.message)
            }

            if event.type == "run.failed" {
                lastError = normalizedDiagnosticsText(event.message)
            }
        }

        return RunDiagnostics(
            runId: normalizedDiagnosticsText(runId) ?? "",
            status: normalizedDiagnosticsStatus(status),
            summary: normalizedDiagnosticsText(summary) ?? "",
            eventCount: events.count,
            eventTypeCounts: eventTypeCounts,
            activityStageCounts: activityStageCounts,
            latestActivity: latestActivity,
            hasStderr: hasStderr,
            lastError: lastError
        )
    }
}

private func normalizedDiagnosticsText(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func normalizedDiagnosticsStatus(_ status: String) -> String {
    let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "unknown" }

    let lower = trimmed.lowercased()
    if lower.hasPrefix("run status:") {
        let suffix = trimmed.dropFirst("Run status:".count)
        return suffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    return lower
}

struct RuntimeSettingDescriptor: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let kind: String
    let allowCustom: Bool
    let value: String?
    let options: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case allowCustom = "allow_custom"
        case value
        case options
    }

    init(
        id: String,
        title: String,
        kind: String,
        allowCustom: Bool,
        value: String? = nil,
        options: [String] = []
    ) {
        self.id = normalizedRuntimeSettingIdentifier(id) ?? id
        self.title = normalizedRuntimeSettingText(title) ?? self.id
        self.kind = normalizedRuntimeSettingKind(kind)
        self.allowCustom = allowCustom
        self.value = normalizedRuntimeSettingText(value)
        self.options = RuntimeSettingDescriptor.normalizedOptions(options)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = normalizedRuntimeSettingIdentifier(try container.decode(String.self, forKey: .id)) ?? "setting"
        title = normalizedRuntimeSettingText(try container.decode(String.self, forKey: .title)) ?? id
        kind = normalizedRuntimeSettingKind(try container.decode(String.self, forKey: .kind))
        allowCustom = try container.decodeIfPresent(Bool.self, forKey: .allowCustom) ?? false
        value = normalizedRuntimeSettingText(try container.decodeIfPresent(String.self, forKey: .value))
        options = RuntimeSettingDescriptor.normalizedOptions(
            try container.decodeIfPresent([String].self, forKey: .options) ?? []
        )
    }

    private static func normalizedOptions(_ options: [String]) -> [String] {
        var values: [String] = []
        for option in options {
            guard let normalized = normalizedRuntimeSettingText(option), !values.contains(normalized) else { continue }
            values.append(normalized)
        }
        return values
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
    let settings: [RuntimeSettingDescriptor]?

    init(
        id: String,
        title: String,
        kind: String,
        available: Bool,
        isDefault: Bool,
        internalOnly: Bool,
        model: String?,
        settings: [RuntimeSettingDescriptor]? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.available = available
        self.isDefault = isDefault
        self.internalOnly = internalOnly
        self.model = model
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case available
        case isDefault = "default"
        case internalOnly = "internal_only"
        case model
        case settings
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
    let codexModelOptions: [String]?
    let codexReasoningEffort: String?
    let codexReasoningEffortOptions: [String]?
    let claudeModel: String?
    let claudeModelOptions: [String]?
    let workdirRoot: String?
    let allowAbsoluteFileReads: Bool?
    let fileRoots: [String]?
    let serverURL: String?
    let serverURLs: [String]?

    enum CodingKeys: String, CodingKey {
        case securityMode = "security_mode"
        case defaultExecutor = "default_executor"
        case availableExecutors = "available_executors"
        case executors
        case transcribeProvider = "transcribe_provider"
        case transcribeReady = "transcribe_ready"
        case codexModel = "codex_model"
        case codexModelOptions = "codex_model_options"
        case codexReasoningEffort = "codex_reasoning_effort"
        case codexReasoningEffortOptions = "codex_reasoning_effort_options"
        case claudeModel = "claude_model"
        case claudeModelOptions = "claude_model_options"
        case workdirRoot = "workdir_root"
        case allowAbsoluteFileReads = "allow_absolute_file_reads"
        case fileRoots = "file_roots"
        case serverURL = "server_url"
        case serverURLs = "server_urls"
    }
}

private extension KeyedDecodingContainer {
    func firstString(forKeys keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                let normalized = normalizedRuntimeSettingText(value)
                if normalized != nil {
                    return normalized
                }
            }
        }
        return nil
    }

    func firstBool(forKeys keys: [Key]) -> Bool? {
        for key in keys {
            if let value = try? decodeIfPresent(Bool.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}

private func normalizedRuntimeSettingText(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

private func normalizedRuntimeSettingIdentifier(_ value: String?) -> String? {
    normalizedRuntimeSettingText(value)?.lowercased().replacingOccurrences(of: " ", with: "_")
}

private func normalizedRuntimeSettingKind(_ value: String?) -> String {
    normalizedRuntimeSettingText(value)?.lowercased() ?? "enum"
}

struct SessionContextUpdateRequest: Encodable {
    let executor: String?
    let workingDirectory: String?
    let runtimeSettings: [SessionRuntimeSetting]?
    let codexModel: String?
    let codexReasoningEffort: String?
    let claudeModel: String?

    enum CodingKeys: String, CodingKey {
        case executor
        case workingDirectory = "working_directory"
        case runtimeSettings = "runtime_settings"
        case codexModel = "codex_model"
        case codexReasoningEffort = "codex_reasoning_effort"
        case claudeModel = "claude_model"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let executor {
            try container.encode(executor, forKey: .executor)
        } else {
            try container.encodeNil(forKey: .executor)
        }
        if let workingDirectory {
            try container.encode(workingDirectory, forKey: .workingDirectory)
        } else {
            try container.encodeNil(forKey: .workingDirectory)
        }
        if let runtimeSettings {
            try container.encode(runtimeSettings, forKey: .runtimeSettings)
        } else {
            try container.encodeNil(forKey: .runtimeSettings)
        }
        if let codexModel {
            try container.encode(codexModel, forKey: .codexModel)
        } else {
            try container.encodeNil(forKey: .codexModel)
        }
        if let codexReasoningEffort {
            try container.encode(codexReasoningEffort, forKey: .codexReasoningEffort)
        } else {
            try container.encodeNil(forKey: .codexReasoningEffort)
        }
        if let claudeModel {
            try container.encode(claudeModel, forKey: .claudeModel)
        } else {
            try container.encodeNil(forKey: .claudeModel)
        }
    }
}

struct SessionRuntimeSetting: Codable, Equatable, Identifiable {
    let executor: String
    let settingID: String
    let value: String?

    var id: String { "\(executor).\(settingID)" }

    enum CodingKeys: String, CodingKey {
        case executor
        case settingID = "id"
        case value
    }

    init(executor: String, settingID: String, value: String?) {
        self.executor = executor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.settingID = normalizedRuntimeSettingIdentifier(settingID) ?? settingID
        self.value = normalizedRuntimeSettingText(value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executor = try container.decode(String.self, forKey: .executor)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        settingID = normalizedRuntimeSettingIdentifier(try container.decode(String.self, forKey: .settingID)) ?? "setting"
        value = normalizedRuntimeSettingText(try container.decodeIfPresent(String.self, forKey: .value))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(executor, forKey: .executor)
        try container.encode(settingID, forKey: .settingID)
        if let value {
            try container.encode(value, forKey: .value)
        } else {
            try container.encodeNil(forKey: .value)
        }
    }
}

struct SessionContext: Decodable {
    let sessionId: String
    let executor: String
    let workingDirectory: String?
    let runtimeSettings: [SessionRuntimeSetting]?
    let codexModel: String?
    let codexReasoningEffort: String?
    let claudeModel: String?
    let resolvedWorkingDirectory: String
    let latestRunId: String?
    let latestRunStatus: String?
    let latestRunSummary: String?
    let latestRunUpdatedAt: String?
    let latestRunPendingHumanUnblock: HumanUnblockRequest?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case executor
        case workingDirectory = "working_directory"
        case runtimeSettings = "runtime_settings"
        case codexModel = "codex_model"
        case codexReasoningEffort = "codex_reasoning_effort"
        case claudeModel = "claude_model"
        case resolvedWorkingDirectory = "resolved_working_directory"
        case latestRunId = "latest_run_id"
        case latestRunStatus = "latest_run_status"
        case latestRunSummary = "latest_run_summary"
        case latestRunUpdatedAt = "latest_run_updated_at"
        case latestRunPendingHumanUnblock = "latest_run_pending_human_unblock"
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
    let sizeBytes: Int64?
    let mime: String?
    let modifiedAt: String?

    var previewCacheVersion: String? {
        guard let modifiedAt else { return nil }
        return "\(modifiedAt):\(sizeBytes ?? -1)"
    }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case isDirectory = "is_directory"
        case sizeBytes = "size_bytes"
        case mime
        case modifiedAt = "modified_at"
    }

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        sizeBytes: Int64? = nil,
        mime: String? = nil,
        modifiedAt: String? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.mime = mime
        self.modifiedAt = modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        mime = try container.decodeIfPresent(String.self, forKey: .mime)
        modifiedAt = try container.decodeIfPresent(String.self, forKey: .modifiedAt)
    }
}

struct FileInspectionResponse: Decodable {
    let name: String
    let path: String
    let sizeBytes: Int64
    let mime: String?
    let artifactType: String
    let modifiedAt: String?
    let textPreview: String?
    let textPreviewBytes: Int
    let textPreviewTruncated: Bool
    let textPreviewOffset: Int
    let textPreviewNextOffset: Int?
    let previewBlockedReason: String?
    let textSearchQuery: String?
    let textSearchMatchCount: Int?
    let textSearchMatches: [TextSearchMatch]
    let imageWidth: Int?
    let imageHeight: Int?

    var previewCacheVersion: String? {
        if let modifiedAt {
            return "\(modifiedAt):\(sizeBytes)"
        }
        return "size:\(sizeBytes)"
    }

    init(
        name: String,
        path: String,
        sizeBytes: Int64,
        mime: String?,
        artifactType: String,
        modifiedAt: String?,
        textPreview: String?,
        textPreviewBytes: Int,
        textPreviewTruncated: Bool,
        textPreviewOffset: Int = 0,
        textPreviewNextOffset: Int? = nil,
        previewBlockedReason: String? = nil,
        textSearchQuery: String? = nil,
        textSearchMatchCount: Int? = nil,
        textSearchMatches: [TextSearchMatch] = [],
        imageWidth: Int?,
        imageHeight: Int?
    ) {
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.mime = mime
        self.artifactType = artifactType
        self.modifiedAt = modifiedAt
        self.textPreview = textPreview
        self.textPreviewBytes = textPreviewBytes
        self.textPreviewTruncated = textPreviewTruncated
        self.textPreviewOffset = textPreviewOffset
        self.textPreviewNextOffset = textPreviewNextOffset
        self.previewBlockedReason = previewBlockedReason
        self.textSearchQuery = textSearchQuery
        self.textSearchMatchCount = textSearchMatchCount
        self.textSearchMatches = textSearchMatches
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case sizeBytes = "size_bytes"
        case mime
        case artifactType = "artifact_type"
        case modifiedAt = "modified_at"
        case textPreview = "text_preview"
        case textPreviewBytes = "text_preview_bytes"
        case textPreviewTruncated = "text_preview_truncated"
        case textPreviewOffset = "text_preview_offset"
        case textPreviewNextOffset = "text_preview_next_offset"
        case previewBlockedReason = "preview_blocked_reason"
        case textSearchQuery = "text_search_query"
        case textSearchMatchCount = "text_search_match_count"
        case textSearchMatches = "text_search_matches"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        mime = try container.decodeIfPresent(String.self, forKey: .mime)
        artifactType = try container.decode(String.self, forKey: .artifactType)
        modifiedAt = try container.decodeIfPresent(String.self, forKey: .modifiedAt)
        textPreview = try container.decodeIfPresent(String.self, forKey: .textPreview)
        textPreviewBytes = try container.decodeIfPresent(Int.self, forKey: .textPreviewBytes) ?? 0
        textPreviewTruncated = try container.decodeIfPresent(Bool.self, forKey: .textPreviewTruncated) ?? false
        textPreviewOffset = try container.decodeIfPresent(Int.self, forKey: .textPreviewOffset) ?? 0
        textPreviewNextOffset = try container.decodeIfPresent(Int.self, forKey: .textPreviewNextOffset)
        previewBlockedReason = try container.decodeIfPresent(String.self, forKey: .previewBlockedReason)
        textSearchQuery = try container.decodeIfPresent(String.self, forKey: .textSearchQuery)
        textSearchMatchCount = try container.decodeIfPresent(Int.self, forKey: .textSearchMatchCount)
        textSearchMatches = try container.decodeIfPresent([TextSearchMatch].self, forKey: .textSearchMatches) ?? []
        imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight)
    }
}

struct TextSearchMatch: Decodable, Identifiable, Equatable {
    var id: String { "\(lineNumber):\(lineText)" }
    let lineNumber: Int
    let lineText: String

    enum CodingKeys: String, CodingKey {
        case lineNumber = "line_number"
        case lineText = "line_text"
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
    let messageKind: String
    let messageID: String?
    let createdAt: String?
    let summary: String
    let sections: [ChatSection]
    let agendaItems: [ChatAgendaItem]
    let artifacts: [ChatArtifact]
    let fileChanges: [ChatFileChange]
    let commandsRun: [ChatCommandRun]
    let testsRun: [ChatTestRun]
    let warnings: [ChatWarning]
    let nextActions: [ChatNextAction]

    enum CodingKeys: String, CodingKey {
        case type
        case version
        case messageKind = "message_kind"
        case messageID = "message_id"
        case createdAt = "created_at"
        case summary
        case sections
        case agendaItems = "agenda_items"
        case artifacts
        case fileChanges = "file_changes"
        case commandsRun = "commands_run"
        case testsRun = "tests_run"
        case warnings
        case nextActions = "next_actions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "assistant_response"
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        messageKind = try container.decodeIfPresent(String.self, forKey: .messageKind) ?? "final"
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        sections = try container.decodeIfPresent([ChatSection].self, forKey: .sections) ?? []
        agendaItems = try container.decodeIfPresent([ChatAgendaItem].self, forKey: .agendaItems) ?? []
        artifacts = try container.decodeIfPresent([ChatArtifact].self, forKey: .artifacts) ?? []
        fileChanges = try container.decodeIfPresent([ChatFileChange].self, forKey: .fileChanges) ?? []
        commandsRun = try container.decodeIfPresent([ChatCommandRun].self, forKey: .commandsRun) ?? []
        testsRun = try container.decodeIfPresent([ChatTestRun].self, forKey: .testsRun) ?? []
        warnings = try container.decodeIfPresent([ChatWarning].self, forKey: .warnings) ?? []
        nextActions = try container.decodeIfPresent([ChatNextAction].self, forKey: .nextActions) ?? []
    }
}

struct ChatSection: Codable, Equatable {
    let title: String
    let body: String
}

struct ChatFileChange: Codable, Equatable, Identifiable {
    var id: String { "\(status)-\(path)" }
    let path: String
    let status: String
    let summary: String?
    let artifact: ChatArtifact?
}

struct ChatCommandRun: Codable, Equatable, Identifiable {
    var id: String { "\(command)-\(status)-\(exitCode.map(String.init) ?? "")" }
    let command: String
    let status: String
    let exitCode: Int?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case command
        case status
        case exitCode = "exit_code"
        case summary
    }
}

struct ChatTestRun: Codable, Equatable, Identifiable {
    var id: String { "\(name)-\(status)" }
    let name: String
    let status: String
    let summary: String?
}

struct ChatWarning: Codable, Equatable, Identifiable {
    var id: String { "\(level)-\(message)" }
    let message: String
    let level: String
}

struct ChatNextAction: Codable, Equatable, Identifiable {
    var id: String { "\(kind)-\(title)-\(detail ?? "")-\(path ?? "")-\(artifact?.id ?? "")" }
    let title: String
    let detail: String?
    let kind: String
    let path: String?
    let artifact: ChatArtifact?
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
    case voiceNew = "voice-new"
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
            .voiceNew,
            title: "Start New Voice Thread",
            description: "Create a fresh thread and start voice mode there.",
            symbol: "waveform.badge.plus",
            usage: "/voice-new",
            group: "Session",
            aliases: ["newvoice", "voice-thread"]
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
            title: "Start Voice Mode",
            description: "Start voice mode on the current thread and keep listening after each reply.",
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
