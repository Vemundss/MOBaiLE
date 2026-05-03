import Foundation

extension VoiceAgentViewModel {
    var runtimeCatalogDefaults: RuntimeCatalogDefaults {
        RuntimeCatalogDefaults(
            codexReasoningEffortOptions: Self.defaultCodexReasoningEffortOptions,
            codexModelOptions: Self.defaultCodexModelOptions,
            claudeModelOptions: Self.defaultClaudeModelOptions
        )
    }

    var runtimeLegacySettingInputs: RuntimeLegacySettingInputs {
        RuntimeLegacySettingInputs(
            codexModel: normalizedBackendCodexModel,
            codexModelOptions: backendCodexModelOptions,
            codexReasoningEffort: normalizedBackendCodexReasoningEffort,
            codexReasoningEffortOptions: backendCodexReasoningEffortOptions,
            claudeModel: normalizedBackendClaudeModel,
            claudeModelOptions: backendClaudeModelOptions
        )
    }

    var codexModelOverride: String {
        get { runtimeSettingOverrideValue(for: "model", executor: "codex") }
        set { updateRuntimeSettingOverride(newValue, for: "model", executor: "codex") }
    }

    var codexReasoningEffort: String {
        get { runtimeSettingOverrideValue(for: "reasoning_effort", executor: "codex") }
        set { updateRuntimeSettingOverride(newValue, for: "reasoning_effort", executor: "codex") }
    }

    var claudeModelOverride: String {
        get { runtimeSettingOverrideValue(for: "model", executor: "claude") }
        set { updateRuntimeSettingOverride(newValue, for: "model", executor: "claude") }
    }
}

// MARK: - Session Context

extension VoiceAgentViewModel {
    func workingDirectorySlashSummary() -> String {
        let current = slashWorkingDirectoryDisplayPath()
        if current.isEmpty {
            return "Working directory follows the backend default."
        }
        return "Working directory: \(current)"
    }

    func setWorkingDirectoryFromSlashCommand(_ rawPath: String) async -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return workingDirectorySlashSummary()
        }
        workingDirectory = trimmed
        if let normalized = normalizedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !normalized.isEmpty {
            resolvedWorkingDirectory = normalized
        } else {
            resolvedWorkingDirectory = trimmed
        }
        persistSettings()
        errorText = ""
        let fallback = "Working directory set to \(slashWorkingDirectoryDisplayPath())."
        guard hasConfiguredConnection else { return fallback }
        do {
            let context = try await syncSessionContextToBackend()
            return "Working directory set to \(context.resolvedWorkingDirectory)."
        } catch {
            errorText = registerConnectionRepairIfNeeded(from: error) ?? error.localizedDescription
            return fallback
        }
    }

    func executorSlashSummary() -> String {
        let options = selectableExecutors.joined(separator: ", ")
        let model = currentBackendModelLabel
        return "Executor: \(effectiveExecutor.uppercased()) (\(model)). Available: \(options)."
    }

    func setExecutorFromSlashCommand(_ rawExecutor: String) async -> String {
        let normalized = rawExecutor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return executorSlashSummary()
        }
        guard selectableExecutors.contains(normalized) else {
            return "Executor \(normalized) isn't available. Options: \(selectableExecutors.joined(separator: ", "))."
        }
        executor = normalized
        persistSettings()
        errorText = ""
        let fallback = "Executor set to \(effectiveExecutor.uppercased()) (\(currentBackendModelLabel))."
        guard hasConfiguredConnection else { return fallback }
        do {
            _ = try await syncSessionContextToBackend()
            return "Executor set to \(effectiveExecutor.uppercased()) (\(currentBackendModelLabel))."
        } catch {
            errorText = registerConnectionRepairIfNeeded(from: error) ?? error.localizedDescription
            return fallback
        }
    }

    @discardableResult
    func refreshSessionContextFromBackend() async throws -> SessionContext {
        guard hasConfiguredConnection else {
            throw APIError.missingCredentials
        }
        do {
            let context = try await client.fetchSessionContext(
                serverURL: normalizedServerURL,
                token: apiToken,
                sessionID: sessionID
            )
            applySessionContext(context)
            return context
        } catch {
            _ = registerConnectionRepairIfNeeded(from: error)
            throw error
        }
    }

    @discardableResult
    func syncSessionContextToBackend() async throws -> SessionContext {
        guard hasConfiguredConnection else {
            throw APIError.missingCredentials
        }
        do {
            let context = try await client.updateSessionContext(
                serverURL: normalizedServerURL,
                token: apiToken,
                sessionID: sessionID,
                requestBody: runtimeSessionContextUpdateRequest()
            )
            clearConnectionRepairState()
            applySessionContext(context)
            return context
        } catch {
            _ = registerConnectionRepairIfNeeded(from: error)
            throw error
        }
    }

    func runtimeSessionContextUpdateRequest() -> SessionContextUpdateRequest {
        let executorOverride: String? = {
            let current = effectiveExecutor
            let backendDefault = normalizedExecutor(from: backendDefaultExecutor) ?? current
            return current == backendDefault ? nil : current
        }()

        let workingDirectoryOverride: String? = {
            let normalized = normalizedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalized.isEmpty else { return nil }
            let root = backendWorkdirRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            if !root.isEmpty && normalized == root {
                return nil
            }
            return normalized
        }()

        return SessionContextUpdateRequest(
            executor: executorOverride,
            workingDirectory: workingDirectoryOverride,
            runtimeSettings: runtimeSessionContextSettingsPayload(),
            codexModel: runtimeSessionContextValue(for: "model", executor: "codex"),
            codexReasoningEffort: runtimeSessionContextValue(for: "reasoning_effort", executor: "codex"),
            claudeModel: runtimeSessionContextValue(for: "model", executor: "claude")
        )
    }

    func persistAndSyncRuntimeSettings() async {
        persistSettings()
        guard hasConfiguredConnection else { return }
        do {
            let normalizedSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSession.isEmpty else { return }
            _ = try await syncSessionContextToBackend()
            errorText = ""
        } catch {
            errorText = registerConnectionRepairIfNeeded(from: error) ?? error.localizedDescription
        }
    }

    func applySessionContext(_ context: SessionContext) {
        clearConnectionRepairState()
        let normalizedSession = context.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedSession.isEmpty {
            sessionID = normalizedSession
        }
        if let normalizedExecutorValue = normalizedExecutor(from: context.executor) {
            executor = normalizedExecutorValue
        }
        let rawWorkingDirectory = context.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = context.resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawWorkingDirectory.isEmpty {
            workingDirectory = rawWorkingDirectory
        } else if !backendWorkdirRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workingDirectory = backendWorkdirRoot
        } else if !resolved.isEmpty {
            workingDirectory = resolved
        }
        if !resolved.isEmpty {
            resolvedWorkingDirectory = resolved
        }
        if let runtimeSettings = context.runtimeSettings, !runtimeSettings.isEmpty {
            var appliedKeys: Set<String> = []
            for setting in runtimeSettings {
                setRuntimeSettingValue(setting.value, for: setting.settingID, executor: setting.executor)
                appliedKeys.insert("\(setting.executor).\(setting.settingID)")
            }
            for (executorID, setting) in allRuntimeSettingDescriptors() {
                let key = "\(executorID).\(setting.id)"
                if !appliedKeys.contains(key) {
                    setRuntimeSettingValue(nil, for: setting.id, executor: executorID)
                }
            }
        } else {
            setRuntimeSettingValue(context.codexModel, for: "model", executor: "codex")
            setRuntimeSettingValue(context.codexReasoningEffort, for: "reasoning_effort", executor: "codex")
            setRuntimeSettingValue(context.claudeModel, for: "model", executor: "claude")
        }
        lastHydratedSessionContextID = normalizedSession.isEmpty ? lastHydratedSessionContextID : normalizedSession
        lastHydratedSessionContextServerURL = normalizedServerURL
        persistSettings()
    }

    func restoreLatestRunFromSessionContext(_ context: SessionContext) async throws -> Bool {
        let latestRunID = context.latestRunId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let latestStatus = context.latestRunStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !latestRunID.isEmpty, !latestStatus.isEmpty else {
            return false
        }
        guard let targetThreadID = threads.first(where: { $0.runID == latestRunID })?.id else {
            return false
        }

        let latestSummary = context.latestRunSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updateThreadMetadata(
            threadID: targetThreadID,
            runID: latestRunID,
            summaryText: latestSummary.isEmpty ? nil : latestSummary,
            statusText: "Run status: \(latestStatus)",
            runStatus: latestStatus,
            persist: false
        )
        setThreadPendingHumanUnblock(
            threadID: targetThreadID,
            request: latestStatus == "blocked" ? context.latestRunPendingHumanUnblock : nil,
            persist: false
        )

        if latestStatus == "running" {
            if activeThreadID == targetThreadID {
                isLoading = true
                didCompleteRun = false
                runPhaseText = "Executing"
                runEndedAt = nil
            }
            if !hasObservedRunContext(runID: latestRunID, threadID: targetThreadID) {
                try await observeRun(runID: latestRunID, threadID: targetThreadID)
            }
        } else if isTerminalStatus(latestStatus) {
            let run = try await client.fetchRun(
                serverURL: normalizedServerURL,
                token: apiToken,
                runID: latestRunID,
                eventsLimit: 0
            )
            try await fetchAndIngestMissingRunEvents(runID: latestRunID, threadID: targetThreadID)
            applyTerminalRunStateIfNeeded(run, threadID: targetThreadID)
        }

        persistThreadSnapshot(threadID: targetThreadID)
        return true
    }

    func useCurrentBrowserDirectoryAsWorkingDirectory() async {
        let path = directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        workingDirectory = path
        resolvedWorkingDirectory = path
        persistSettings()
        guard hasConfiguredConnection else { return }
        do {
            _ = try await syncSessionContextToBackend()
            errorText = ""
        } catch {
            errorText = registerConnectionRepairIfNeeded(from: error) ?? error.localizedDescription
        }
    }
}

// MARK: - Runtime Settings

extension VoiceAgentViewModel {
    var selectableExecutors: [String] {
        var values = backendAvailableExecutors.filter { $0 == "local" || $0 == "codex" || $0 == "claude" }
        if values.isEmpty {
            if let preferred = normalizedExecutor(from: backendDefaultExecutor) {
                values = [preferred]
            } else {
                values = ["codex"]
            }
        }
        if developerMode {
            if !values.contains("local") {
                values.append("local")
            }
            return values
        }
        if effectiveExecutor == "local" && !values.contains("local") {
            values.insert("local", at: 0)
        }
        if backendDefaultExecutor == "local", values.contains("local") {
            return ["local"]
        }
        let agentExecutors = values.filter { $0 == "codex" || $0 == "claude" }
        if effectiveExecutor == "local" && values.contains("local") {
            return ["local"] + agentExecutors
        }
        if !agentExecutors.isEmpty {
            return agentExecutors
        }
        return values
    }

    var selectedRuntimeExecutorDescriptor: RuntimeExecutorDescriptor? {
        runtimeExecutorDescriptor(for: effectiveExecutor)
    }

    var selectedRuntimeSettings: [RuntimeSettingDescriptor] {
        runtimeSettings(for: effectiveExecutor)
    }

    var backendExecutorModelRows: [(id: String, title: String, model: String)] {
        backendExecutorDescriptors
            .filter { $0.kind == "agent" }
            .map { descriptor in
                (
                    id: descriptor.id,
                    title: descriptor.title,
                    model: RuntimeConfigurationCatalog.displayModelName(descriptor.model)
                )
            }
    }

    var currentBackendModelLabel: String {
        if effectiveExecutor == "local" {
            return "n/a"
        }
        return runtimeSettingDisplayValue(for: "model", executor: effectiveExecutor)
    }

    var currentCodexModelLabel: String {
        runtimeSettingDisplayValue(for: "model", executor: "codex")
    }

    var codexRuntimeModelOptions: [String] {
        runtimeSettingPickerOptions(for: "model", executor: "codex").filter { !$0.isEmpty }
    }

    var codexBackendDefaultOptionLabel: String {
        runtimeSettingDefaultOptionLabel(for: "model", executor: "codex")
    }

    var currentClaudeModelLabel: String {
        runtimeSettingDisplayValue(for: "model", executor: "claude")
    }

    var claudeRuntimeModelOptions: [String] {
        runtimeSettingPickerOptions(for: "model", executor: "claude").filter { !$0.isEmpty }
    }

    var claudeBackendDefaultOptionLabel: String {
        runtimeSettingDefaultOptionLabel(for: "model", executor: "claude")
    }

    var currentCodexReasoningEffortLabel: String {
        runtimeSettingDisplayValue(for: "reasoning_effort", executor: "codex")
    }

    var hasCodexRuntimeOverrides: Bool {
        runtimeSettingHasOverride(for: "model", executor: "codex")
            || runtimeSettingHasOverride(for: "reasoning_effort", executor: "codex")
    }

    var hasClaudeRuntimeOverrides: Bool {
        runtimeSettingHasOverride(for: "model", executor: "claude")
    }

    func runtimeSettings(for executor: String? = nil) -> [RuntimeSettingDescriptor] {
        guard let descriptor = runtimeExecutorDescriptor(for: executor) else {
            return []
        }
        if let settings = descriptor.settings, !settings.isEmpty {
            return settings
        }
        return legacyRuntimeSettings(for: descriptor.id)
    }

    func runtimeSettingDescriptor(for settingID: String, executor: String? = nil) -> RuntimeSettingDescriptor? {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        return runtimeSettings(for: executor).first(where: { $0.id == normalizedSettingID })
    }

    func runtimeSettingCurrentValue(for settingID: String, executor: String? = nil) -> String? {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        let override = runtimeSettingStoredValue(for: normalizedSettingID, executor: executor)
        if !override.isEmpty {
            return override
        }
        let backendValue = runtimeSettingBackendValue(for: normalizedSettingID, executor: executor)
        return backendValue.isEmpty ? nil : backendValue
    }

    func runtimeSettingDisplayValue(for settingID: String, executor: String? = nil) -> String {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        guard let currentValue = runtimeSettingCurrentValue(for: normalizedSettingID, executor: executor) else {
            return "Backend default"
        }
        return runtimeSettingPresentationValue(currentValue, settingID: normalizedSettingID)
    }

    func runtimeSettingPickerOptions(for settingID: String, executor: String? = nil) -> [String] {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        let descriptor = runtimeSettingDescriptor(for: normalizedSettingID, executor: executor)
        let backendValue = runtimeSettingBackendValue(for: normalizedSettingID, executor: executor)
        var values: [String] = [""]

        if !backendValue.isEmpty {
            values.append(backendValue)
        }

        if let currentValue = runtimeSettingCurrentValue(for: normalizedSettingID, executor: executor),
           !currentValue.isEmpty,
           !values.contains(currentValue) {
            values.append(currentValue)
        }

        for option in descriptor?.options ?? [] {
            let normalizedValue = normalizedRuntimeSettingText(option) ?? ""
            guard !normalizedValue.isEmpty, !values.contains(normalizedValue) else { continue }
            values.append(normalizedValue)
        }

        return values
    }

    func runtimeSettingDefaultOptionLabel(for settingID: String, executor: String? = nil) -> String {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        let backendValue = runtimeSettingBackendValue(for: normalizedSettingID, executor: executor)
        let defaultPrefix = isProfileContextRuntimeSetting(normalizedSettingID) ? "Follow backend default" : "Backend default"
        guard !backendValue.isEmpty else { return defaultPrefix }
        return "\(defaultPrefix) (\(runtimeSettingPresentationValue(backendValue, settingID: normalizedSettingID)))"
    }

    func runtimeSettingHasOverride(for settingID: String, executor: String? = nil) -> Bool {
        !runtimeSettingStoredValue(for: settingID, executor: executor).isEmpty
    }

    func isProfileContextRuntimeSetting(_ settingID: String) -> Bool {
        Self.globalAgentRuntimeSettingIDs.contains(normalizedRuntimeSettingIdentifier(settingID))
    }

    func runtimeSettingUsesBackendDefault(for settingID: String, executor: String? = nil) -> Bool {
        !runtimeSettingHasOverride(for: settingID, executor: executor)
    }

    func runtimeSettingPickerTitle(for value: String, settingID: String, executor: String? = nil) -> String {
        if value.isEmpty {
            return runtimeSettingDefaultOptionLabel(for: settingID, executor: executor)
        }
        return runtimeSettingPresentationValue(value, settingID: settingID)
    }

    func runtimeSettingIconName(for settingID: String) -> String {
        switch normalizedRuntimeSettingIdentifier(settingID) {
        case "model":
            return "sparkles"
        case "reasoning_effort":
            return "brain.head.profile"
        case "profile_agents":
            return "person.text.rectangle"
        case "profile_memory":
            return "brain"
        default:
            return "slider.horizontal.3"
        }
    }

    func runtimeSettingAllowsCustom(_ settingID: String, executor: String? = nil) -> Bool {
        runtimeSettingDescriptor(for: settingID, executor: executor)?.allowCustom ?? false
    }

    func runtimeSettingSummary(for settingID: String) -> String {
        switch normalizedRuntimeSettingIdentifier(settingID) {
        case "profile_agents":
            return "Your saved instructions for this profile, such as preferred workflow, tone, or standing rules."
        case "profile_memory":
            return "Durable notes learned across sessions, like project facts, paths, or stable preferences."
        default:
            return ""
        }
    }

    func runtimeSettingToggleTitle(for settingID: String) -> String {
        switch normalizedRuntimeSettingIdentifier(settingID) {
        case "profile_agents":
            return "Include saved instructions in new runs"
        case "profile_memory":
            return "Use saved memory in new runs"
        default:
            return "Use setting"
        }
    }

    func runtimeSettingStateLabel(for settingID: String, executor: String? = nil) -> String {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        let currentValue = runtimeSettingCurrentValue(for: normalizedSettingID, executor: executor) ?? ""
        switch (normalizedSettingID, currentValue) {
        case ("profile_agents", "enabled"), ("profile_memory", "enabled"):
            return "Included"
        case ("profile_agents", "disabled"), ("profile_memory", "disabled"):
            return "Skipped"
        default:
            return runtimeSettingDisplayValue(for: normalizedSettingID, executor: executor)
        }
    }

    func runtimeSettingEffectSummary(for settingID: String, executor: String? = nil) -> String {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        let currentValue = runtimeSettingCurrentValue(for: normalizedSettingID, executor: executor) ?? ""
        switch (normalizedSettingID, currentValue) {
        case ("profile_agents", "enabled"):
            return "New runs include your saved profile instructions on top of the repo and runtime rules."
        case ("profile_agents", "disabled"):
            return "New runs skip your saved profile instructions. Repo and runtime rules still apply."
        case ("profile_memory", "enabled"):
            return "New runs can use your saved profile memory from earlier sessions."
        case ("profile_memory", "disabled"):
            return "New runs start without saved profile memory. Existing saved notes stay untouched."
        default:
            return ""
        }
    }

    func runtimeSettingBackendDefaultSummary(for settingID: String, executor: String? = nil) -> String {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        let backendValue = runtimeSettingBackendValue(for: normalizedSettingID, executor: executor)
        guard !backendValue.isEmpty else { return "No backend default available." }
        switch normalizedSettingID {
        case "profile_agents":
            if backendValue == "enabled" {
                return "Backend default: include saved instructions."
            }
            return "Backend default: skip saved instructions."
        case "profile_memory":
            if backendValue == "enabled" {
                return "Backend default: use saved memory."
            }
            return "Backend default: start without saved memory."
        default:
            return "Backend default: \(runtimeSettingPresentationValue(backendValue, settingID: normalizedSettingID))."
        }
    }

    func runtimeSettingStoredValue(for settingID: String, executor: String? = nil) -> String {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        let targetExecutor = normalizedExecutor(from: executor ?? effectiveExecutor) ?? effectiveExecutor
        return runtimeSettingOverrideValue(for: normalizedSettingID, executor: targetExecutor)
    }

    func setRuntimeSettingValue(_ value: String?, for settingID: String, executor: String? = nil) {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        let targetExecutor = normalizedExecutor(from: executor ?? effectiveExecutor) ?? effectiveExecutor
        updateRuntimeSettingOverride(value, for: normalizedSettingID, executor: targetExecutor)
    }

    var effectiveExecutor: String {
        let trimmed = executor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "local" {
            return "local"
        }
        if trimmed == "codex" || trimmed == "claude" {
            return trimmed
        }
        let backendDefault = backendDefaultExecutor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if backendDefault == "local" || backendDefault == "codex" || backendDefault == "claude" {
            return backendDefault
        }
        return "codex"
    }

    func modelLabel(for executor: String) -> String {
        let normalized = executor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "local" {
            return "n/a"
        }
        if normalized == "codex" {
            return currentCodexModelLabel
        }
        if normalized == "claude" {
            return currentClaudeModelLabel
        }
        if let descriptor = backendExecutorDescriptors.first(where: { $0.id == normalized }) {
            return RuntimeConfigurationCatalog.displayModelName(descriptor.model)
        }
        return "default"
    }
}

private extension VoiceAgentViewModel {
    func slashWorkingDirectoryDisplayPath() -> String {
        let normalized = normalizedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalized.isEmpty {
            return normalized
        }
        let resolved = resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty {
            return resolved
        }
        return workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func runtimeSessionContextValue(for settingID: String, executor: String) -> String? {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        let overrideValue = runtimeSettingStoredValue(for: normalizedSettingID, executor: executor)
        guard !overrideValue.isEmpty else { return nil }
        let backendValue = runtimeSettingBackendValue(for: normalizedSettingID, executor: executor)
        if overrideValue == backendValue {
            return nil
        }
        return overrideValue
    }

    func runtimeSessionContextSettingsPayload() -> [SessionRuntimeSetting] {
        runtimeSettingPayloadEntries().map { executorID, settingID in
            SessionRuntimeSetting(
                executor: executorID,
                settingID: settingID,
                value: runtimeSessionContextValue(for: settingID, executor: executorID)
            )
        }
    }

    func runtimeSettingBackendValue(for settingID: String, executor: String? = nil) -> String {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        if let descriptor = runtimeSettingDescriptor(for: normalizedSettingID, executor: executor) {
            if let value = normalizedRuntimeSettingText(descriptor.value) {
                return value
            }
        }

        let targetExecutor = normalizedExecutor(from: executor ?? effectiveExecutor) ?? effectiveExecutor
        switch targetExecutor {
        case "codex":
            switch normalizedSettingID {
            case "model":
                return normalizedBackendCodexModel
            case "reasoning_effort":
                return normalizedBackendCodexReasoningEffort
            default:
                return ""
            }
        case "claude":
            switch normalizedSettingID {
            case "model":
                return normalizedBackendClaudeModel
            default:
                return ""
            }
        default:
            return ""
        }
    }

    func runtimeSettingPresentationValue(_ value: String, settingID: String) -> String {
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalizedSettingID {
        case "reasoning_effort":
            return trimmedValue.uppercased()
        case "profile_agents":
            switch trimmedValue.lowercased() {
            case "enabled":
                return "Include saved instructions"
            case "disabled":
                return "Ignore saved instructions"
            default:
                return trimmedValue.capitalized
            }
        case "profile_memory":
            switch trimmedValue.lowercased() {
            case "enabled":
                return "Use saved memory"
            case "disabled":
                return "Start without saved memory"
            default:
                return trimmedValue.capitalized
            }
        default:
            return trimmedValue
        }
    }

    func runtimeExecutorDescriptor(for executor: String? = nil) -> RuntimeExecutorDescriptor? {
        let normalizedExecutorValue = normalizedExecutor(from: executor ?? effectiveExecutor)
        if let normalizedExecutorValue,
           let descriptor = backendExecutorDescriptors.first(where: { $0.id == normalizedExecutorValue }) {
            return descriptor
        }
        if let descriptor = backendExecutorDescriptors.first(where: { $0.id == backendDefaultExecutor }) {
            return descriptor
        }
        return backendExecutorDescriptors.first(where: { $0.available && !$0.internalOnly })
            ?? backendExecutorDescriptors.first
    }

    func allRuntimeSettingDescriptors() -> [(String, RuntimeSettingDescriptor)] {
        var pairs: [(String, RuntimeSettingDescriptor)] = []
        for descriptor in backendExecutorDescriptors {
            for setting in descriptor.settings ?? [] {
                pairs.append((descriptor.id, setting))
            }
        }
        if !pairs.isEmpty {
            return pairs
        }
        return [
            ("codex", legacyRuntimeSettings(for: "codex")),
            ("claude", legacyRuntimeSettings(for: "claude")),
        ].flatMap { executorID, settings in
            settings.map { (executorID, $0) }
        }
    }

    func runtimeSettingPayloadEntries() -> [(String, String)] {
        var entries: [(String, String)] = []
        var seen: Set<String> = []

        for (executorID, setting) in allRuntimeSettingDescriptors() {
            let key = "\(executorID).\(setting.id)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            entries.append((executorID, setting.id))
        }

        for executorID in runtimeSettingOverrides.keys.sorted() {
            let settings = runtimeSettingOverrides[executorID] ?? [:]
            for settingID in settings.keys.sorted() {
                let key = "\(executorID).\(settingID)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                entries.append((executorID, settingID))
            }
        }

        return entries
    }

    func legacyRuntimeSettings(for executorID: String) -> [RuntimeSettingDescriptor] {
        RuntimeConfigurationCatalog.legacySettings(
            for: executorID,
            inputs: runtimeLegacySettingInputs,
            defaults: runtimeCatalogDefaults
        )
    }

    var normalizedBackendCodexModel: String {
        let descriptor = backendExecutorDescriptors.first(where: { $0.id == "codex" })
        if let value = descriptor?
            .settings?
            .first(where: { $0.id == "model" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return descriptor?.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var normalizedBackendClaudeModel: String {
        let descriptor = backendExecutorDescriptors.first(where: { $0.id == "claude" })
        if let value = descriptor?
            .settings?
            .first(where: { $0.id == "model" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return descriptor?.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var normalizedBackendCodexReasoningEffort: String {
        backendCodexReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension VoiceAgentViewModel {
    var normalizedWorkingDirectory: String? {
        let value = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return nil
        }
        let root = backendWorkdirRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "~" || value == "." {
            return root.isEmpty ? value : root
        }
        if value.hasPrefix("/") {
            return value
        }
        if !root.isEmpty {
            return root + "/" + value
        }
        return value
    }

    func normalizedRuntimeSettingIdentifier(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.replacingOccurrences(of: " ", with: "_")
    }

    func normalizedRuntimeSettingText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizedExecutor(from rawValue: String?) -> String? {
        RuntimeConfigurationCatalog.normalizedExecutorID(from: rawValue)
    }
}
