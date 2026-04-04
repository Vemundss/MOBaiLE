import Foundation

struct RuntimeCatalogDefaults {
    let codexReasoningEffortOptions: [String]
    let codexModelOptions: [String]
    let claudeModelOptions: [String]
}

struct RuntimeLegacySettingInputs {
    let codexModel: String
    let codexModelOptions: [String]
    let codexReasoningEffort: String
    let codexReasoningEffortOptions: [String]
    let claudeModel: String
    let claudeModelOptions: [String]
}

enum RuntimeConfigurationCatalog {
    static func displayModelName(_ rawModel: String?) -> String {
        let value = normalizedText(rawModel) ?? ""
        return value.isEmpty ? "default" : value
    }

    static func dedupedModelOptions(_ rawValues: [String]) -> [String] {
        dedupedValues(rawValues)
    }

    static func normalizedExecutorID(from rawValue: String?) -> String? {
        let value = normalizedText(rawValue)?.lowercased() ?? ""
        if value == "local" || value == "codex" || value == "claude" {
            return value
        }
        return nil
    }

    static func normalizedTranscribeProvider(from rawValue: String?) -> String {
        normalizedText(rawValue)?.lowercased() ?? "unknown"
    }

    static func legacySettings(
        for executorID: String,
        inputs: RuntimeLegacySettingInputs,
        defaults: RuntimeCatalogDefaults
    ) -> [RuntimeSettingDescriptor] {
        switch normalizedExecutorID(from: executorID) ?? executorID {
        case "codex":
            return [
                RuntimeSettingDescriptor(
                    id: "model",
                    title: "Model",
                    kind: "enum",
                    allowCustom: true,
                    value: normalizedText(inputs.codexModel),
                    options: inputs.codexModelOptions.isEmpty ? defaults.codexModelOptions : inputs.codexModelOptions
                ),
                RuntimeSettingDescriptor(
                    id: "reasoning_effort",
                    title: "Reasoning effort",
                    kind: "enum",
                    allowCustom: false,
                    value: normalizedText(inputs.codexReasoningEffort),
                    options: inputs.codexReasoningEffortOptions.isEmpty
                        ? defaults.codexReasoningEffortOptions
                        : inputs.codexReasoningEffortOptions
                ),
            ]
        case "claude":
            return [
                RuntimeSettingDescriptor(
                    id: "model",
                    title: "Model",
                    kind: "enum",
                    allowCustom: true,
                    value: normalizedText(inputs.claudeModel),
                    options: inputs.claudeModelOptions.isEmpty ? defaults.claudeModelOptions : inputs.claudeModelOptions
                )
            ]
        default:
            return []
        }
    }

    static func normalizedAvailableExecutors(
        _ rawValues: [String]?,
        descriptors: [RuntimeExecutorDescriptor],
        defaultExecutor: String
    ) -> [String] {
        var values = (rawValues ?? []).compactMap(normalizedExecutorID(from:))
        if values.isEmpty {
            values = descriptors
                .filter { $0.available && !$0.internalOnly }
                .compactMap { normalizedExecutorID(from: $0.id) }
        }
        if let preferred = normalizedExecutorID(from: defaultExecutor), !values.contains(preferred) {
            values.append(preferred)
        }
        return dedupedValues(values)
    }

    static func normalizedRuntimeExecutors(
        _ rawDescriptors: [RuntimeExecutorDescriptor]?,
        config: RuntimeConfig,
        defaultExecutor: String,
        inputs: RuntimeLegacySettingInputs,
        defaults: RuntimeCatalogDefaults
    ) -> [RuntimeExecutorDescriptor] {
        let normalizedDefaultExecutor = normalizedExecutorID(from: defaultExecutor) ?? "codex"
        let availableExecutors = Set((config.availableExecutors ?? []).compactMap(normalizedExecutorID(from:)))

        var descriptors = (rawDescriptors ?? []).compactMap { descriptor -> RuntimeExecutorDescriptor? in
            guard let normalizedID = normalizedExecutorID(from: descriptor.id) else { return nil }
            let settings = descriptor.settings ?? []
            return RuntimeExecutorDescriptor(
                id: normalizedID,
                title: descriptor.title,
                kind: descriptor.kind,
                available: descriptor.available,
                isDefault: descriptor.isDefault,
                internalOnly: descriptor.internalOnly,
                model: descriptor.model,
                settings: settings.isEmpty
                    ? legacySettings(for: normalizedID, inputs: inputs, defaults: defaults)
                    : settings
            )
        }

        if descriptors.isEmpty {
            descriptors = [
                RuntimeExecutorDescriptor(
                    id: "codex",
                    title: "Codex",
                    kind: "agent",
                    available: availableExecutors.contains("codex"),
                    isDefault: normalizedDefaultExecutor == "codex",
                    internalOnly: false,
                    model: config.codexModel,
                    settings: legacySettings(for: "codex", inputs: inputs, defaults: defaults)
                ),
                RuntimeExecutorDescriptor(
                    id: "claude",
                    title: "Claude Code",
                    kind: "agent",
                    available: availableExecutors.contains("claude"),
                    isDefault: normalizedDefaultExecutor == "claude",
                    internalOnly: false,
                    model: config.claudeModel,
                    settings: legacySettings(for: "claude", inputs: inputs, defaults: defaults)
                ),
                localFallbackDescriptor(defaultExecutor: normalizedDefaultExecutor),
            ]
        }

        if !descriptors.contains(where: { $0.id == "local" }) {
            descriptors.append(localFallbackDescriptor(defaultExecutor: normalizedDefaultExecutor))
        }

        return descriptors
    }

    private static func localFallbackDescriptor(defaultExecutor: String) -> RuntimeExecutorDescriptor {
        RuntimeExecutorDescriptor(
            id: "local",
            title: "Local fallback",
            kind: "internal",
            available: defaultExecutor == "local",
            isDefault: defaultExecutor == "local",
            internalOnly: true,
            model: nil,
            settings: []
        )
    }

    private static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dedupedValues(_ rawValues: [String]) -> [String] {
        var values: [String] = []
        for rawValue in rawValues {
            guard let normalized = normalizedText(rawValue), !values.contains(normalized) else { continue }
            values.append(normalized)
        }
        return values
    }
}
