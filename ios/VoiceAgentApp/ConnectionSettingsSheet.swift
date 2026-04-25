import SwiftUI

struct ConnectionSettingsSheet: View {
    @ObservedObject var vm: VoiceAgentViewModel
    let isRuntimeSettingsPreviewFocus: Bool
    let quickStartURL: URL
    let privacyPolicyURL: URL
    let supportURL: URL
    let onDismiss: () -> Void
    let onOpenSetupGuide: () -> Void
    let onOpenPairingScanner: () -> Void

    @AppStorage(AppAppearancePreference.storageKey) private var appearancePreferenceRaw = AppAppearancePreference.system.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showAdvancedSettings = false
    @State private var showManualConnectionFields: Bool
    @State private var settingsConnectionState: SettingsConnectionState = .idle

    private enum SettingsConnectionState: Equatable {
        case idle
        case checking
        case success(String)
        case failure(String)
    }

    init(
        vm: VoiceAgentViewModel,
        isRuntimeSettingsPreviewFocus: Bool,
        quickStartURL: URL,
        privacyPolicyURL: URL,
        supportURL: URL,
        expandManualConnectionInitially: Bool,
        onDismiss: @escaping () -> Void,
        onOpenSetupGuide: @escaping () -> Void,
        onOpenPairingScanner: @escaping () -> Void
    ) {
        self.vm = vm
        self.isRuntimeSettingsPreviewFocus = isRuntimeSettingsPreviewFocus
        self.quickStartURL = quickStartURL
        self.privacyPolicyURL = privacyPolicyURL
        self.supportURL = supportURL
        self.onDismiss = onDismiss
        self.onOpenSetupGuide = onOpenSetupGuide
        self.onOpenPairingScanner = onOpenPairingScanner
        _showManualConnectionFields = State(initialValue: expandManualConnectionInitially)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !vm.hasConfiguredConnection || vm.needsConnectionRepair {
                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            Label(
                                vm.needsConnectionRepair ? "This usually takes a few seconds" : "You only need to do this once",
                                systemImage: "list.number"
                            )
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 10) {
                                SetupGuideStepSummaryRow(
                                    stepNumber: 1,
                                    title: vm.needsConnectionRepair ? "Open a fresh pairing QR on your computer" : "Install MOBaiLE on your computer",
                                    detail: vm.needsConnectionRepair
                                        ? "Run `mobaile pair` on the computer if you need a new QR, then keep it visible on screen."
                                        : "Run one install command on your Mac or Linux machine. The installer asks three quick questions. Keep the default answers for the normal setup."
                                )
                                SetupGuideStepSummaryRow(
                                    stepNumber: 2,
                                    title: vm.needsConnectionRepair ? "Scan the QR again in MOBaiLE" : "Scan the pairing QR in MOBaiLE",
                                    detail: "Open `backend/pairing-qr.png` on the computer, then tap Scan Pairing QR here. MOBaiLE reads it directly and fills the connection for you."
                                )
                            }

                            setupActionButtons
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text(vm.needsConnectionRepair ? "Reconnect" : "Getting Started")
                    } footer: {
                        Text(
                            vm.needsConnectionRepair
                                ? "Fastest fix: run `mobaile pair` on the computer if needed, then scan the QR again here."
                                : "Fastest path: run the installer, keep the defaults, then use QR pairing. Manual fields below are only the fallback."
                        )
                    }
                }

                if !isRuntimeSettingsPreviewFocus {
                    Section {
                        settingsConnectionCard
                    } header: {
                        Text(settingsConnectionTitle)
                    }
                }

                if canUseConnectedFeatures {
                    Section {
                        Picker("Executor", selection: $vm.executor) {
                            ForEach(vm.selectableExecutors, id: \.self) { option in
                                Text(option.capitalized).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)

                        if showsProfileContextRuntimeGuidance {
                            RuntimeProfileContextOverviewCard()
                        }

                        ForEach(vm.selectedRuntimeSettings) { setting in
                            runtimeSettingControl(setting)
                        }
                    } header: {
                        Text("Agent Runtime")
                    } footer: {
                        Text(agentRuntimeFooterText)
                    }

                    Section {
                        Toggle("AirPods Click To Record", isOn: $vm.airPodsClickToRecordEnabled)
                        Toggle("Haptic Cues", isOn: $vm.hapticCuesEnabled)
                        Toggle("Audio Cues", isOn: $vm.audioCuesEnabled)
                        Toggle("Speak Replies", isOn: $vm.speakRepliesEnabled)
                        Toggle("Auto-send After Silence", isOn: $vm.autoSendAfterSilenceEnabled)
                        if vm.autoSendAfterSilenceEnabled {
                            TextField("Silence seconds", text: $vm.autoSendAfterSilenceSeconds)
                                .keyboardType(.decimalPad)
                        }
                    } header: {
                        Text("Voice & Feedback")
                    } footer: {
                        Text(
                            vm.autoSendAfterSilenceEnabled
                                ? "AirPods click uses headset controls. Audio cues cover start and sent confirmations, while failures stay haptic-only. Speak Replies reads cleaned assistant responses for voice turns, keeping long code-heavy details on screen. Auto-send submits after the selected silence window, and voice mode reopens the mic after each reply."
                                : "AirPods click uses headset controls to start recording and stop+send. Audio cues cover start and sent confirmations, while failures stay haptic-only. Speak Replies reads cleaned assistant responses for voice turns, keeping long code-heavy details on screen. Voice mode keeps the conversation going by reopening the mic after each reply."
                        )
                    }

                    Section {
                        DisclosureGroup("Advanced Runtime", isExpanded: $showAdvancedSettings) {
                            TextField("Session ID", text: $vm.sessionID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Starting directory", text: $vm.workingDirectory)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.footnote.monospaced())

                            ForEach(vm.selectedRuntimeSettings.filter { vm.runtimeSettingAllowsCustom($0.id) }) { setting in
                                TextField("Custom \(setting.title)", text: runtimeSettingBinding(for: setting.id))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.footnote.monospaced())
                                    .accessibilityIdentifier("settings.runtime.custom.\(setting.id)")
                            }
                            if !vm.backendWorkdirRoot.isEmpty {
                                Button {
                                    vm.workingDirectory = vm.backendWorkdirRoot
                                } label: {
                                    Label("Use Backend Root", systemImage: "arrow.down.to.line.compact")
                                }
                                .buttonStyle(.bordered)
                                .disabled(vm.workingDirectory == vm.backendWorkdirRoot)
                            }
                            Toggle("Developer Mode", isOn: $vm.developerMode)
                                .onChange(of: vm.developerMode) { _, enabled in
                                    if !enabled && vm.executor == "local" {
                                        vm.executor = vm.backendDefaultExecutor
                                    }
                                }
                            TextField("Timeout seconds", text: $vm.runTimeoutSeconds)
                                .keyboardType(.numberPad)
                            Toggle("Hide Hidden Folders", isOn: $vm.hideDotFoldersInBrowser)
                            if !vm.backendWorkdirRoot.isEmpty {
                                LabeledContent("Backend Root", value: vm.backendWorkdirRoot)
                                    .font(.footnote.monospaced())
                            }
                            LabeledContent("Backend Mode", value: vm.backendSecurityMode)
                            ForEach(vm.backendExecutorModelRows, id: \.id) { row in
                                LabeledContent("\(row.title) Model", value: row.model)
                            }
                            if !vm.backendCodexReasoningEffort.isEmpty {
                                LabeledContent("Codex Effort", value: vm.backendCodexReasoningEffort.uppercased())
                            }
                        }
                    } footer: {
                        Text(vm.developerMode
                            ? "Advanced Runtime overrides backend defaults and exposes the internal local fallback."
                            : "Advanced Runtime overrides backend defaults when you need them.")
                    }
                }

                Section {
                    Picker("Appearance", selection: appearancePreferenceBinding) {
                        ForEach(AppAppearancePreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.appearance")

                    Picker("Progress updates", selection: $vm.agentGuidanceMode) {
                        Text("Guided").tag("guided")
                        Text("Minimal").tag("minimal")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Experience")
                } footer: {
                    Text(
                        (vm.agentGuidanceMode == "minimal"
                            ? "Minimal keeps chat focused on final results."
                            : "Guided shows a live activity stream while the agent works, then compresses it into the final result.")
                        + " System follows your iPhone appearance automatically unless you lock MOBaiLE to Light or Dark."
                    )
                }

                Section {
                    DisclosureGroup(
                        vm.hasConfiguredConnection ? "Edit server URL and token" : "Already have a server URL and token?",
                        isExpanded: $showManualConnectionFields
                    ) {
                        VStack(spacing: 14) {
                            connectionFields
                        }
                        .padding(.top, 8)
                    }
                } header: {
                    Text(vm.hasConfiguredConnection ? "Connection Details" : "Manual Connection")
                } footer: {
                    Text(
                        vm.needsConnectionRepair
                            ? "The saved server URL is still here. Scanning a fresh QR replaces the broken token without retyping everything."
                            : vm.hasConfiguredConnection
                                ? "Only change these when you want this phone to talk to a different backend."
                                : "Most people should pair by QR instead of typing these fallback fields."
                    )
                }

                Section("Support") {
                    if !vm.hasConfiguredConnection {
                        Link("Set It Up", destination: quickStartURL)
                    }
                    Link("Privacy Policy", destination: privacyPolicyURL)
                    Link("Support", destination: supportURL)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                vm.hideDirectoryBrowser()
                Task { await vm.persistAndSyncRuntimeSettings() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        vm.hideDirectoryBrowser()
                        onDismiss()
                    }
                }
            }
        }
        .preferredColorScheme(resolvedAppearancePreference.colorScheme)
    }

    @ViewBuilder
    private var connectionFields: some View {
        Group {
            TextField("Server URL", text: $vm.serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            SecureField("API Token", text: $vm.apiToken)
                .font(.footnote.monospaced())
        }
    }

    private var settingsConnectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !settingsConnectionMessage.isEmpty {
                Text(settingsConnectionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if vm.hasConfiguredConnection && !settingsSummaryItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(settingsSummaryItems) { item in
                        settingsSummaryRow(item)
                    }
                }
                .padding(.vertical, 4)
            }

            settingsConnectionActions
        }
        .padding(.vertical, 4)
    }

    private var settingsSummaryItems: [SettingsRuntimeDetailItem] {
        settingsConnectionDetails + settingsRuntimeDetails
    }

    private var settingsConnectionDetails: [SettingsRuntimeDetailItem] {
        guard vm.hasConfiguredConnection else { return [] }
        return [
            SettingsRuntimeDetailItem(icon: "server.rack", label: "Server", value: connectionHostLabel),
            SettingsRuntimeDetailItem(icon: "iphone", label: "Session", value: vm.sessionID),
        ]
    }

    @ViewBuilder
    private func primaryScannerButton(fillWidth: Bool) -> some View {
        let title = vm.needsConnectionRepair
            ? (fillWidth ? "Scan QR Again" : "Scan QR")
            : (fillWidth ? "Scan New QR" : "Scan QR")
        let label = SettingsActionButtonLabel(title: title, systemImage: "qrcode.viewfinder")
            .frame(maxWidth: fillWidth ? .infinity : nil)

        if vm.needsConnectionRepair {
            Button {
                onOpenPairingScanner()
            } label: {
                label
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                onOpenPairingScanner()
            } label: {
                label
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func secondaryGuideButton(fillWidth: Bool) -> some View {
        Button {
            onOpenSetupGuide()
        } label: {
            SettingsActionButtonLabel(
                title: vm.needsConnectionRepair ? "Repair Guide" : "Setup Guide",
                systemImage: "arrow.right.circle.fill"
            )
            .frame(maxWidth: fillWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var setupActionButtons: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                primaryScannerButton(fillWidth: true)
                secondaryGuideButton(fillWidth: true)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    primaryScannerButton(fillWidth: true)
                    secondaryGuideButton(fillWidth: true)
                }

                VStack(spacing: 10) {
                    primaryScannerButton(fillWidth: true)
                    secondaryGuideButton(fillWidth: true)
                }
            }
        }
    }

    @ViewBuilder
    private var settingsConnectionActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                settingsTestButton(fillWidth: true)
                primaryScannerButton(fillWidth: true)
                if vm.needsConnectionRepair {
                    repairStepsButton(fillWidth: true)
                }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    settingsTestButton(fillWidth: false)
                    primaryScannerButton(fillWidth: false)
                    if vm.needsConnectionRepair {
                        repairStepsButton(fillWidth: false)
                    }
                }

                VStack(spacing: 10) {
                    settingsTestButton(fillWidth: true)
                    primaryScannerButton(fillWidth: true)
                    if vm.needsConnectionRepair {
                        repairStepsButton(fillWidth: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func settingsTestButton(fillWidth: Bool) -> some View {
        if vm.hasConfiguredConnection && !vm.needsConnectionRepair {
            Button {
                Task { await checkSettingsConnection() }
            } label: {
                if isCheckingSettingsConnection {
                    ProgressView()
                        .frame(maxWidth: fillWidth ? .infinity : nil)
                } else {
                    SettingsActionButtonLabel(title: "Test", systemImage: "checkmark.circle")
                        .frame(maxWidth: fillWidth ? .infinity : nil)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isCheckingSettingsConnection)
        }
    }

    private func repairStepsButton(fillWidth: Bool) -> some View {
        Button {
            onOpenSetupGuide()
        } label: {
            SettingsActionButtonLabel(title: "Repair Steps", systemImage: "list.number")
                .frame(maxWidth: fillWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
    }

    private var settingsRuntimeDetails: [SettingsRuntimeDetailItem] {
        guard showsSettingsRuntimeDetails else { return [] }
        var items = [
            SettingsRuntimeDetailItem(icon: "lock.shield", label: "Mode", value: vm.backendSecurityMode.uppercased()),
            SettingsRuntimeDetailItem(icon: "sparkles", label: "Runtime", value: runtimeDescriptorSummary),
            SettingsRuntimeDetailItem(icon: "folder.fill", label: "Workspace", value: runtimeDirectorySummary),
        ]
        if !vm.backendWorkdirRoot.isEmpty {
            items.append(SettingsRuntimeDetailItem(icon: "externaldrive", label: "Root", value: shortPathLabel(vm.backendWorkdirRoot)))
        }
        return items
    }

    private func settingsSummaryRow(_ item: SettingsRuntimeDetailItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(item.label, systemImage: item.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(item.value)
                .font(settingsSummaryValueFont(for: item))
                .foregroundStyle(.primary)
                .lineLimit(item.label == "Runtime" ? 1 : 2)
                .minimumScaleFactor(item.label == "Runtime" ? 0.86 : 1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsSummaryValueFont(for item: SettingsRuntimeDetailItem) -> Font {
        switch item.label {
        case "Server", "Session", "Workspace", "Root":
            return .footnote.monospaced()
        default:
            return .footnote.weight(.medium)
        }
    }

    private func runtimeSettingAccessibilityIdentifier(for settingID: String) -> String {
        switch (vm.effectiveExecutor, settingID) {
        case ("codex", "model"):
            return "settings.runtime.codexModel"
        case ("codex", "reasoning_effort"):
            return "settings.runtime.codexEffort"
        case ("claude", "model"):
            return "settings.runtime.claudeModel"
        default:
            return "settings.runtime.\(vm.effectiveExecutor).\(settingID)"
        }
    }

    private var appearancePreferenceBinding: Binding<AppAppearancePreference> {
        Binding(
            get: { AppAppearancePreference.resolve(from: appearancePreferenceRaw) },
            set: { appearancePreferenceRaw = $0.rawValue }
        )
    }

    private func runtimeSettingBinding(for settingID: String) -> Binding<String> {
        Binding(
            get: { vm.runtimeSettingStoredValue(for: settingID) },
            set: { vm.setRuntimeSettingValue($0, for: settingID) }
        )
    }

    private func runtimeSettingToggleBinding(for settingID: String) -> Binding<Bool> {
        Binding(
            get: { vm.runtimeSettingCurrentValue(for: settingID) == "enabled" },
            set: { vm.setRuntimeSettingValue($0 ? "enabled" : "disabled", for: settingID) }
        )
    }

    private func runtimeSettingTint(for settingID: String) -> Color {
        switch settingID {
        case "profile_agents":
            return .blue
        case "profile_memory":
            return .indigo
        default:
            return .accentColor
        }
    }

    @ViewBuilder
    private func runtimeSettingControl(_ setting: RuntimeSettingDescriptor) -> some View {
        if vm.isProfileContextRuntimeSetting(setting.id) {
            RuntimeProfileContextSettingCard(
                systemImage: vm.runtimeSettingIconName(for: setting.id),
                title: setting.title,
                summary: vm.runtimeSettingSummary(for: setting.id),
                toggleTitle: vm.runtimeSettingToggleTitle(for: setting.id),
                stateLabel: vm.runtimeSettingStateLabel(for: setting.id),
                stateDetail: vm.runtimeSettingEffectSummary(for: setting.id),
                backendDefaultSummary: vm.runtimeSettingBackendDefaultSummary(for: setting.id),
                isUsingBackendDefault: vm.runtimeSettingUsesBackendDefault(for: setting.id),
                tint: runtimeSettingTint(for: setting.id),
                accessibilityIdentifier: runtimeSettingAccessibilityIdentifier(for: setting.id),
                isEnabled: runtimeSettingToggleBinding(for: setting.id),
                onUseBackendDefault: {
                    vm.setRuntimeSettingValue(nil, for: setting.id)
                }
            )
        } else {
            let options = vm.runtimeSettingPickerOptions(for: setting.id)
            if setting.kind == "enum", !options.isEmpty {
                Picker(setting.title, selection: runtimeSettingBinding(for: setting.id)) {
                    ForEach(options, id: \.self) { option in
                        Text(vm.runtimeSettingPickerTitle(for: option, settingID: setting.id)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier(runtimeSettingAccessibilityIdentifier(for: setting.id))
            } else {
                LabeledContent(setting.title, value: vm.runtimeSettingDisplayValue(for: setting.id))
            }
        }
    }

    private var showsSettingsRuntimeDetails: Bool {
        vm.hasConfiguredConnection && !vm.needsConnectionRepair
    }

    private var isCheckingSettingsConnection: Bool {
        if case .checking = settingsConnectionState {
            return true
        }
        return false
    }

    private var settingsConnectionTitle: String {
        switch settingsConnectionState {
        case .idle:
            if vm.needsConnectionRepair {
                return "Reconnect this phone"
            }
            return vm.hasConfiguredConnection ? "Current backend" : "Waiting for pairing"
        case .checking:
            return "Checking connection"
        case .success:
            return "Connection verified"
        case .failure:
            return vm.needsConnectionRepair ? "Reconnect this phone" : "Connection failed"
        }
    }

    private var settingsConnectionMessage: String {
        switch settingsConnectionState {
        case .idle:
            if vm.needsConnectionRepair {
                return vm.connectionRepairMessage
            }
            return vm.hasConfiguredConnection
                ? "Saved on this phone. Pair again if you want to replace this connection."
                : "Use the installer and QR pairing for the fastest setup, or expand the manual fallback section if you already have connection details."
        case .checking:
            return "Checking the current backend session."
        case let .success(message), let .failure(message):
            return message
        }
    }

    private func checkSettingsConnection() async {
        settingsConnectionState = .checking
        do {
            _ = try await vm.refreshRuntimeConfiguration()
            let host = URL(string: vm.serverURL)?.host ?? vm.serverURL
            settingsConnectionState = .success(
                "Connected to \(host)."
            )
        } catch {
            settingsConnectionState = .failure(vm.needsConnectionRepair ? vm.connectionRepairMessage : error.localizedDescription)
        }
    }

    private var resolvedAppearancePreference: AppAppearancePreference {
        AppAppearancePreference.resolve(from: appearancePreferenceRaw)
    }

    private var connectionHostLabel: String {
        let trimmed = vm.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host, !host.isEmpty else { return trimmed }
        return host
    }

    private var canUseConnectedFeatures: Bool {
        vm.hasConfiguredConnection && !vm.needsConnectionRepair
    }

    private var agentRuntimeFooterText: String {
        guard !vm.selectedRuntimeSettings.isEmpty else {
            return "Choose an executor to show its backend-advertised runtime settings."
        }
        if vm.selectedRuntimeSettings.contains(where: { vm.runtimeSettingAllowsCustom($0.id) }) {
            return "Changes here apply to new runs in this session. Custom text fields stay in Advanced Runtime and only appear for backend-marked settings."
        }
        return "Changes here apply to new runs in this session."
    }

    private var showsProfileContextRuntimeGuidance: Bool {
        vm.selectedRuntimeSettings.contains { vm.isProfileContextRuntimeSetting($0.id) }
    }

    private var runtimeExecutorLabel: String {
        let value = vm.runID.isEmpty ? vm.effectiveExecutor : vm.activeRunExecutor
        return value.uppercased()
    }

    private var runtimeEffortLabel: String? {
        let label = vm.runtimeSettingDisplayValue(for: "reasoning_effort", executor: vm.effectiveExecutor)
        return label == "Backend default" ? nil : label
    }

    private var runtimeDirectoryLabel: String {
        let resolved = vm.resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { return resolved }
        return vm.workingDirectory
    }

    private var runtimeDirectorySummary: String {
        compactPathLabel(runtimeDirectoryLabel)
    }

    private var runtimeDescriptorSummary: String {
        var components = [runtimeExecutorLabel, vm.currentBackendModelLabel]
        if let effort = runtimeEffortLabel {
            components.append(effort)
        }
        return components
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "Backend default" }
            .joined(separator: " / ")
    }

    private func shortPathLabel(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Current workspace" }
        let url = URL(fileURLWithPath: trimmed)
        let last = url.lastPathComponent
        guard !last.isEmpty else { return trimmed }
        return last
    }

    private func compactPathLabel(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Current workspace" }
        let url = URL(fileURLWithPath: trimmed)
        let last = url.lastPathComponent
        guard !last.isEmpty else { return trimmed }

        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty, parent != "/", parent != last else { return last }

        return "\(parent)/\(last)"
    }
}

private struct SettingsActionButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .imageScale(.medium)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(minHeight: 28)
    }
}
