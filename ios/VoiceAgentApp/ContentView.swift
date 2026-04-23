import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    private let privacyPolicyURL = URL(string: "https://vemundss.github.io/MOBaiLE/privacy-policy.html")!
    private let supportURL = URL(string: "https://vemundss.github.io/MOBaiLE/support.html")!
    private let quickStartURL = URL(string: "https://github.com/vemundss/MOBaiLE#set-it-up")!
    private let bootstrapInstallCommand = "curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/install.sh | bash"
    private let checkoutInstallCommand = "bash ./scripts/install.sh"
    @AppStorage(AppAppearancePreference.storageKey) private var appearancePreferenceRaw = AppAppearancePreference.system.rawValue
    @StateObject private var vm = VoiceAgentViewModel()
    @State private var showConnectionSettings = false
    @State private var showSetupGuide = false
    @State private var showPairingScanner = false
    @State private var showLogs = false
    @State private var showThreads = false
    @State private var showAttachmentOptions = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showWorkspaceBrowser = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var newDirectoryName = ""
    @State private var isCreatingDirectory = false
    @State private var trustPairHost = false
    @State private var openSettingsAfterSetupGuide = false
    @State private var openPairingScannerAfterSetupGuide = false
    @State private var openSettingsAfterPairingScanner = false
    @State private var expandManualConnectionOnNextSettingsOpen = false
    @State private var showAdvancedSettings = false
    @State private var showManualConnectionFields = false
    @State private var settingsConnectionState: SettingsConnectionState = .idle
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var incomingURLStore: IncomingURLStore

    private enum SettingsConnectionState: Equatable {
        case idle
        case checking
        case success(String)
        case failure(String)
    }

    var body: some View {
        mainView
    }

    private var mainView: some View {
        pairingSheetView
    }

    private var baseNavigationView: some View {
        NavigationStack {
            conversationView
                .navigationTitle(navigationBarTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showConnectionSettings = true
                        } label: {
                            Image(systemName: settingsToolbarSymbol)
                        }
                        .foregroundStyle(settingsToolbarTint)
                        .accessibilityLabel("Settings")
                    }
                }
        }
    }

    private var modalSheetView: some View {
        baseNavigationView
            .sheet(isPresented: $showSetupGuide, onDismiss: {
                if openSettingsAfterSetupGuide {
                    openSettingsAfterSetupGuide = false
                    showConnectionSettings = true
                } else if openPairingScannerAfterSetupGuide {
                    openPairingScannerAfterSetupGuide = false
                    showPairingScanner = true
                }
            }) {
                setupGuideSheet
            }
            .sheet(isPresented: $showPairingScanner, onDismiss: {
                if openSettingsAfterPairingScanner {
                    openSettingsAfterPairingScanner = false
                    showConnectionSettings = true
                }
            }) {
                pairingScannerSheet
            }
            .sheet(isPresented: $showConnectionSettings) {
                settingsSheet
            }
            .sheet(isPresented: $showThreads) {
                ThreadsView(
                    threads: vm.sortedThreads,
                    activeThreadID: vm.activeThreadID,
                    onSelect: { threadID in
                        vm.switchToThread(threadID)
                        showThreads = false
                    },
                    onRename: { threadID, title in
                        vm.renameThread(threadID, title: title)
                    },
                    onDelete: { threadID in
                        vm.deleteThread(threadID)
                    },
                    onNewChat: {
                        vm.startNewChat()
                        showThreads = false
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showLogs) {
                LogsView(
                    events: vm.events,
                    diagnostics: vm.currentRunDiagnostics
                )
                .task {
                    await vm.refreshRunDiagnosticsIfPossible()
                }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showWorkspaceBrowser, onDismiss: {
                newDirectoryName = ""
                isCreatingDirectory = false
                vm.hideDirectoryBrowser()
            }) {
                workspaceBrowserSheet
            }
    }

    private var lifecycleManagedView: some View {
        modalSheetView
            .task {
                await vm.bootstrapSessionIfNeeded()
                await vm.consumePendingShortcutActionIfNeeded()
                applyPreviewPresentationIfNeeded()
                consumePendingIncomingURLIfNeeded()
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task {
                        await vm.refreshSessionPresenceFromBackendIfPossible()
                        await vm.consumePendingShortcutActionIfNeeded()
                        consumePendingIncomingURLIfNeeded()
                    }
                }
            }
            .onReceive(incomingURLStore.$pendingURL) { pendingURL in
                guard pendingURL != nil else { return }
                consumePendingIncomingURLIfNeeded()
            }
            .onChange(of: showConnectionSettings) {
                if showConnectionSettings {
                    resetSettingsSheetState(expandManualConnection: expandManualConnectionOnNextSettingsOpen)
                    expandManualConnectionOnNextSettingsOpen = false
                }
            }
            .onChange(of: showWorkspaceBrowser) {
                if !showWorkspaceBrowser {
                    newDirectoryName = ""
                    isCreatingDirectory = false
                    vm.hideDirectoryBrowser()
                }
            }
            .onChange(of: vm.didCompleteRun) {
                if vm.didCompleteRun {
                    showConnectionSettings = false
                    composerFocused = false
                }
            }
            .onChange(of: vm.pendingPairing) {
                guard let pending = vm.pendingPairing else {
                    trustPairHost = false
                    return
                }
                trustPairHost = vm.isTrustedPairHost(pending.serverHost)
            }
            .onOpenURL { url in
                incomingURLStore.receive(url)
            }
    }

    private func consumePendingIncomingURLIfNeeded() {
        guard let url = incomingURLStore.takePendingURL() else { return }
        if handleShortcutURL(url) {
            return
        }
        vm.applyPairingURL(url)
    }

    private var pairingSheetView: some View {
        lifecycleManagedView
            .sheet(item: Binding(
                get: { vm.pendingPairing },
                set: { if $0 == nil { vm.cancelPendingPairing() } }
            )) { pending in
                PairingConfirmationSheet(
                    pending: pending,
                    trustHost: $trustPairHost,
                    onCancel: { vm.cancelPendingPairing() },
                    onConfirm: {
                        vm.confirmPendingPairing(trustHost: trustPairHost)
                    }
                )
            }
            .confirmationDialog("Add context", isPresented: $showAttachmentOptions, titleVisibility: .visible) {
                Button("Photo Library") {
                    showPhotoPicker = true
                }
                Button("Files") {
                    showFileImporter = true
                }
                if canUseConnectedFeatures && !vm.isLoading && vm.hasDraftContent {
                    Button("Voice Note") {
                        composerFocused = false
                        handleRecordingButtonTap()
                    }
                }
                Button("Paste from Clipboard") {
                    Task {
                        await vm.pasteClipboardContentIntoDraft()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: 6,
                matching: .images
            )
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: handleFileImport
            )
            .onChange(of: selectedPhotoItems) {
                let items = selectedPhotoItems
                guard !items.isEmpty else { return }
                selectedPhotoItems = []
                Task {
                    await importSelectedPhotos(items)
                }
            }
    }

    private func handleShortcutURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), MOBaiLEURLSchemeConfiguration.acceptedSchemes.contains(scheme) else { return false }
        guard let host = url.host?.lowercased(), host == "shortcut" else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let action = components.queryItems?.first(where: { $0.name == "action" })?.value?.lowercased() ?? ""
        guard !action.isEmpty else { return false }

        Task {
            switch action {
            case "start-voice":
                await vm.handleStartVoiceTaskShortcut()
            case "start-new-voice":
                await vm.handleStartNewVoiceThreadShortcut()
            case "send-last-prompt":
                await vm.handleSendLastPromptShortcut()
            default:
                break
            }
        }
        return true
    }

    private func handlePairingScannerPayload(_ payload: String) -> String? {
        if vm.applyPairingPayload(payload) {
            return nil
        }
        return vm.errorText.isEmpty ? "That QR code is not a MOBaiLE pairing link." : vm.errorText
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            Task {
                for url in urls {
                    await vm.addDraftAttachment(fromImportedFile: url)
                }
            }
        case let .failure(error):
            vm.errorText = error.localizedDescription
        }
    }

    private func importSelectedPhotos(_ items: [PhotosPickerItem]) async {
        let timestamp = Int(Date().timeIntervalSince1970)
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                vm.errorText = "Couldn't import one of the selected photos."
                continue
            }
            let contentType = item.supportedContentTypes.first
            let fileExtension = contentType?.preferredFilenameExtension ?? "jpg"
            let mimeType = contentType?.preferredMIMEType ?? "image/jpeg"
            await vm.addDraftAttachment(
                data: data,
                fileName: "image-\(timestamp)-\(index + 1).\(fileExtension)",
                mimeType: mimeType
            )
        }
    }

    private var conversationView: some View {
        ScrollViewReader { proxy in
            ZStack {
                conversationBackground
                    .ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 12) {
                        if vm.conversation.isEmpty {
                            ConversationEmptyStateView(
                                isConfigured: vm.hasConfiguredConnection,
                                needsConnectionRepair: vm.needsConnectionRepair,
                                statusText: headerStatusText,
                                canRetryLastPrompt: vm.canRetryLastPrompt,
                                runtimeContext: emptyStateRuntimeContext,
                                onOpenSetupGuide: {
                                    showSetupGuide = true
                                },
                                onOpenPairingScanner: {
                                    showPairingScanner = true
                                },
                                onOpenSettings: {
                                    showConnectionSettings = true
                                },
                                onRetryLastPrompt: {
                                    Task { await vm.retryLastPrompt() }
                                },
                                onStartVoiceMode: {
                                    handleVoiceModeStartTap()
                                },
                                onUsePrompt: { prompt in
                                    vm.promptText = prompt
                                    composerFocused = true
                                }
                            )
                            .padding(.top, 20)
                        }

                        ForEach(vm.conversation) { message in
                            HStack {
                                if message.role == "user" {
                                    Spacer(minLength: 52)
                                }
                                MessageBubble(message: message, serverURL: vm.serverURL, apiToken: vm.apiToken)
                                if message.role != "user" {
                                    Spacer(minLength: 52)
                                }
                            }
                            .id(message.id)
                        }

                        if !vm.errorText.isEmpty && !shouldShowRecordingNotice {
                            InlineNoticeCard(
                                title: "Something went wrong",
                                message: vm.errorText,
                                tint: .red,
                                systemImage: "exclamationmark.triangle.fill",
                                actionTitle: vm.hasConfiguredConnection ? nil : "Open Settings",
                                action: vm.hasConfiguredConnection ? nil : {
                                    showConnectionSettings = true
                                }
                            )
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("conversation-bottom")
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .scrollDismissesKeyboard(.never)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if shouldShowRuntimeInfoBar {
                    runtimeInfoBar
                }
            }
            .onChange(of: vm.conversation.last) {
                withAnimation(.easeOut(duration: 0.18)) {
                    if let last = vm.conversation.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    } else {
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                composerBar
            }
        }
    }

    private var settingsSheet: some View {
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

                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) {
                                    Button {
                                        showPairingScanner = true
                                    } label: {
                                        Label(vm.needsConnectionRepair ? "Scan Pairing QR Again" : "Scan Pairing QR", systemImage: "qrcode.viewfinder")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button {
                                        showSetupGuide = true
                                    } label: {
                                        Label(vm.needsConnectionRepair ? "Show Repair Guide" : "Show Setup Guide", systemImage: "arrow.right.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                VStack(spacing: 10) {
                                    Button {
                                        showPairingScanner = true
                                    } label: {
                                        Label(vm.needsConnectionRepair ? "Scan Pairing QR Again" : "Scan Pairing QR", systemImage: "qrcode.viewfinder")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button {
                                        showSetupGuide = true
                                    } label: {
                                        Label(vm.needsConnectionRepair ? "Show Repair Guide" : "Show Setup Guide", systemImage: "arrow.right.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
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
                        showConnectionSettings = false
                    }
                }
            }
        }
        .preferredColorScheme(resolvedAppearancePreference.colorScheme)
    }

    private var setupGuideSheet: some View {
        SetupGuideSheet(
            bootstrapInstallCommand: bootstrapInstallCommand,
            checkoutInstallCommand: checkoutInstallCommand,
            quickStartURL: quickStartURL,
            supportURL: supportURL,
            onOpenScanner: {
                openPairingScannerAfterSetupGuide = true
                showSetupGuide = false
            },
            onManualSetup: {
                expandManualConnectionOnNextSettingsOpen = true
                openSettingsAfterSetupGuide = true
                showSetupGuide = false
            }
        )
    }

    private var pairingScannerSheet: some View {
        PairingScannerSheet(
            isRepairMode: vm.needsConnectionRepair,
            onSubmitPayload: handlePairingScannerPayload,
            onOpenManualSetup: {
                expandManualConnectionOnNextSettingsOpen = true
                openSettingsAfterPairingScanner = true
            }
        )
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    if vm.hasConfiguredConnection && !vm.needsConnectionRepair {
                        Button {
                            Task { await checkSettingsConnection() }
                        } label: {
                            if isCheckingSettingsConnection {
                                ProgressView()
                            } else {
                                Text("Test")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCheckingSettingsConnection)
                    }

                    settingsPairingScannerButton()

                    if vm.needsConnectionRepair {
                        Button("Show Repair Steps") {
                            showSetupGuide = true
                        }
                        .buttonStyle(.bordered)
                    }
                }

                VStack(spacing: 10) {
                    settingsPairingScannerButton(frameLabelToFillWidth: true)

                    if vm.needsConnectionRepair {
                        Button("Show Repair Steps") {
                            showSetupGuide = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
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
    private func settingsPairingScannerButton(frameLabelToFillWidth: Bool = false) -> some View {
        let label = Label(
            vm.needsConnectionRepair ? "Scan Pairing QR Again" : "Scan New Pairing QR",
            systemImage: "qrcode.viewfinder"
        )

        if vm.needsConnectionRepair {
            Button {
                showPairingScanner = true
            } label: {
                if frameLabelToFillWidth {
                    label.frame(maxWidth: .infinity)
                } else {
                    label
                }
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                showPairingScanner = true
            } label: {
                if frameLabelToFillWidth {
                    label.frame(maxWidth: .infinity)
                } else {
                    label
                }
            }
            .buttonStyle(.bordered)
        }
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
        LabeledContent {
            Text(item.value)
                .font(.footnote.monospaced())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        } label: {
            Label(item.label, systemImage: item.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
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

    private func resetSettingsSheetState(expandManualConnection: Bool = false) {
        showAdvancedSettings = false
        showManualConnectionFields = expandManualConnection
        settingsConnectionState = .idle
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

    private var composerSlashCommandState: ComposerSlashCommandState? {
        vm.composerSlashCommandState
    }

    private var composerBar: some View {
        VStack(spacing: 8) {
            if shouldShowRecordingNotice {
                recordingStatusBanner
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let unblock = vm.pendingHumanUnblockRequest, !vm.isLoading {
                InlineNoticeCard(
                    title: "Continue this run",
                    message: unblock.instructions,
                    tint: .orange,
                    systemImage: "hand.raised.fill",
                    actionTitle: "Use Suggested Reply",
                    action: {
                        vm.prepareHumanUnblockReply()
                        composerFocused = true
                    }
                )
            }

            if let retryNotice = runRetryNotice {
                InlineNoticeCard(
                    title: retryNotice.title,
                    message: retryNotice.message,
                    tint: .red,
                    systemImage: "arrow.clockwise.circle.fill",
                    actionTitle: "Retry Last Prompt",
                    action: {
                        Task { await vm.retryLastPrompt() }
                    },
                    secondaryActionTitle: vm.events.isEmpty ? nil : "Open Run Logs",
                    secondaryAction: vm.events.isEmpty ? nil : { showLogs = true }
                )
            }

            if let attachmentFailureNotice = vm.draftAttachmentFailureNotice, !vm.isLoading {
                InlineNoticeCard(
                    title: "Attachment upload failed",
                    message: attachmentFailureNotice,
                    tint: .red,
                    systemImage: "exclamationmark.triangle.fill",
                    actionTitle: nil,
                    action: nil
                )
            }

            VStack(spacing: 10) {
                if shouldShowComposerSummaryRow && !vm.isRecording {
                    composerSummaryRow
                }

                if shouldShowVoiceInteractionNotice {
                    voiceInteractionNoticeCard
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !vm.draftAttachments.isEmpty && !vm.isRecording {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(vm.draftAttachments) { attachment in
                                DraftAttachmentChip(
                                    attachment: attachment,
                                    transferState: vm.draftAttachmentTransferState(for: attachment),
                                    isBusy: vm.isLoading,
                                    onRemove: { vm.removeDraftAttachment(attachment) }
                                )
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let slashState = composerSlashCommandState, !vm.isRecording {
                    ComposerSlashCommandMenu(
                        state: slashState,
                        onSelect: { command in
                            handleSlashCommandSelection(command, state: slashState)
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if vm.isRecording {
                    recordingComposerRow
                } else {
                    standardComposerRow
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color(.separator).opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 18, y: 8)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.18), value: vm.isRecording)
        .animation(.easeInOut(duration: 0.18), value: shouldShowRecordingNotice)
        .animation(.easeInOut(duration: 0.18), value: vm.voiceInteractionNoticeText)
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onEnded { value in
                    let downward = value.translation.height
                    let sideways = abs(value.translation.width)
                    guard downward > 24, downward > sideways else { return }
                    composerFocused = false
                }
        )
    }

    private var composerSummaryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if vm.isVoiceModeActiveForCurrentThread {
                    Button {
                        handleVoiceModeButtonTap()
                    } label: {
                        ComposerMetaPill(
                            text: vm.voiceModeStatusText,
                            systemImage: "waveform.circle.fill",
                            tint: .blue
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("End voice mode")
                }

                if shouldShowComposerStatusSummary {
                    ComposerMetaPill(
                        text: composerStatusSummaryText,
                        systemImage: composerStatusSummaryIcon,
                        tint: composerStatusSummaryTint
                    )
                }

                if !vm.runID.isEmpty && shouldShowComposerStatusSummary && !hasVisibleLiveActivityMessage {
                    Text("Run \(shortRunID(vm.runID))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 2)
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private var shouldShowVoiceInteractionNotice: Bool {
        !vm.isRecording && !shouldShowRecordingNotice && vm.voiceInteractionNoticeText != nil
    }

    private var voiceInteractionNoticeCard: some View {
        InlineNoticeCard(
            title: "Voice mode",
            message: vm.voiceInteractionNoticeText ?? "",
            tint: .blue,
            systemImage: "waveform.circle",
            actionTitle: nil,
            action: nil
        )
    }

    private var standardComposerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            composerUtilityActionTray
            composerTextEditorSurface
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
            composerPrimaryActionButton
        }
    }

    private var composerTextEditorSurface: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $vm.promptText)
                .focused($composerFocused)
                .accessibilityIdentifier("composer.textEditor")
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(height: composerHeight)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            composerFocused
                                ? Color.accentColor.opacity(0.30)
                                : Color(.separator).opacity(0.12),
                            lineWidth: 1
                        )
                )
                .onTapGesture {
                    composerFocused = true
                }

            if vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(composerPlaceholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .padding(.top, 16)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: composerHeight)
    }

    private var composerUtilityActionTray: some View {
        HStack(spacing: 8) {
            Button {
                composerFocused = false
                showAttachmentOptions = true
            } label: {
                ComposerTrayButtonLabel(
                    systemImage: "plus",
                    tint: vm.draftAttachments.isEmpty ? Color.secondary : Color.accentColor,
                    fill: vm.draftAttachments.isEmpty ? Color(.tertiarySystemGroupedBackground) : Color.accentColor.opacity(0.16)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add context")
            .disabled(!canUseConnectedFeatures || vm.isLoading)
            .opacity((!canUseConnectedFeatures || vm.isLoading) ? 0.45 : 1)

            let canStartVoiceMode = !vm.isLoading && canUseConnectedFeatures
            Button {
                composerFocused = false
                handleVoiceModeButtonTap()
            } label: {
                ComposerTrayButtonLabel(
                    systemImage: vm.isVoiceModeActiveForCurrentThread ? "waveform.circle.fill" : "waveform.circle",
                    tint: Color.blue,
                    fill: vm.isVoiceModeActiveForCurrentThread ? Color.blue.opacity(0.16) : Color(.tertiarySystemGroupedBackground)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(vm.isVoiceModeActiveForCurrentThread ? "End voice mode" : "Start voice mode")
            .disabled(!vm.isVoiceModeActiveForCurrentThread && !canStartVoiceMode)
            .opacity((!vm.isVoiceModeActiveForCurrentThread && !canStartVoiceMode) ? 0.45 : 1)
        }
    }

    private var composerPrimaryActionButtonConfiguration: ComposerPrimaryActionConfiguration {
        if vm.canCancelActiveOperation {
            return ComposerPrimaryActionConfiguration(
                systemImage: "stop.fill",
                tint: .white,
                fill: .red,
                size: 46,
                iconSize: 13,
                weight: .semibold,
                accessibilityLabel: vm.isUploadingAttachments ? "Cancel upload" : "Cancel run",
                isDisabled: false,
                opacity: 1
            ) {
                composerFocused = false
                vm.cancelActiveOperation()
            }
        }

        if vm.hasDraftContent {
            return ComposerPrimaryActionConfiguration(
                systemImage: "arrow.up",
                tint: .white,
                fill: .accentColor,
                size: 46,
                iconSize: 14,
                weight: .bold,
                accessibilityLabel: "Send prompt",
                isDisabled: !canUseConnectedFeatures || !vm.hasDraftContent,
                opacity: (!canUseConnectedFeatures || !vm.hasDraftContent) ? 0.45 : 1
            ) {
                handleComposerSend()
            }
        }

        return ComposerPrimaryActionConfiguration(
            systemImage: "mic.fill",
            tint: .white,
            fill: .blue,
            size: 46,
            iconSize: 14,
            weight: .bold,
            accessibilityLabel: "Start recording",
            isDisabled: vm.isLoading || !canUseConnectedFeatures,
            opacity: (vm.isLoading || !canUseConnectedFeatures) ? 0.45 : 1
        ) {
            composerFocused = false
            handleRecordingButtonTap()
        }
    }

    private var composerPrimaryActionButton: some View {
        let configuration = composerPrimaryActionButtonConfiguration
        return Button(action: configuration.action) {
            ComposerActionButtonLabel(
                systemImage: configuration.systemImage,
                tint: configuration.tint,
                fill: configuration.fill,
                size: configuration.size,
                iconSize: configuration.iconSize,
                weight: configuration.weight
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(configuration.accessibilityLabel)
        .disabled(configuration.isDisabled)
        .opacity(configuration.opacity)
    }

    private var recordingComposerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                recordingComposerDetails
                Spacer(minLength: 0)
                recordingComposerActions
            }

            VStack(alignment: .leading, spacing: 10) {
                recordingComposerDetails
                HStack {
                    Spacer(minLength: 0)
                    recordingComposerActions
                }
            }
        }
    }

    private var recordingComposerDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)

                Text("Listening")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let startedAt = vm.recordingStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(recordingDurationLabel(since: startedAt, now: context.date))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.red.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
            }

            Text(recordingSubtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !recordingContextItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(recordingContextItems.enumerated()), id: \.offset) { _, item in
                            ComposerMetaPill(
                                text: item.text,
                                systemImage: item.systemImage,
                                tint: item.tint
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    private var recordingComposerActions: some View {
        HStack(spacing: 10) {
            Button {
                handleRecordingStopTap()
            } label: {
                ComposerActionButtonLabel(
                    systemImage: "stop.fill",
                    tint: .white,
                    fill: .red,
                    size: 42,
                    iconSize: 12,
                    weight: .bold
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(vm.isVoiceModeActiveForCurrentThread ? "Stop voice mode" : "Discard recording")

            Button {
                handleRecordingButtonTap()
            } label: {
                ComposerActionButtonLabel(
                    systemImage: "paperplane.fill",
                    tint: .white,
                    fill: .accentColor,
                    size: 42,
                    iconSize: 12,
                    weight: .bold
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send voice prompt")
        }
    }

    private func shortRunID(_ runID: String) -> String {
        if runID.count <= 8 {
            return runID
        }
        return String(runID.prefix(8))
    }

    private var bottomRunStatusText: String {
        if vm.runPhaseText == "Planning" || vm.runPhaseText == "Executing" || vm.runPhaseText == "Summarizing" {
            return "Thinking"
        }
        if vm.runPhaseText != "Idle" {
            return vm.runPhaseText
        }
        return vm.statusText
    }

    private var hasVisibleLiveActivityMessage: Bool {
        vm.conversation.contains { $0.presentation == .liveActivity }
    }

    private func isProgressChromeStatus(_ rawText: String) -> Bool {
        let lower = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !lower.isEmpty else { return false }

        if lower.contains("input")
            || lower.contains("blocked")
            || lower.contains("fail")
            || lower.contains("cancel")
            || lower.contains("timed out")
            || lower.contains("reconnect")
            || lower.contains("setup")
            || lower.contains("attention") {
            return false
        }

        return lower.contains("think")
            || lower.contains("plan")
            || lower.contains("execut")
            || lower.contains("summar")
            || lower.contains("start")
            || lower.contains("prepar")
            || lower.contains("running")
    }

    private var shouldShowComposerStatusSummary: Bool {
        guard !vm.isRecording else { return false }
        guard runRetryNotice == nil else { return false }

        let lower = composerStatusSummaryText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !lower.isEmpty, lower != "idle" else { return false }

        if lower == "ready for prompts" || lower == "completed" {
            return false
        }

        if hasVisibleLiveActivityMessage && isProgressChromeStatus(composerStatusSummaryText) {
            return false
        }

        if vm.isLoading || vm.isUploadingAttachments {
            return true
        }

        return lower.contains("input")
            || lower.contains("blocked")
            || lower.contains("fail")
            || lower.contains("cancel")
            || lower.contains("timed out")
            || lower.contains("upload")
            || lower.contains("start")
            || lower.contains("preparing")
            || lower.contains("transcrib")
            || lower.contains("microphone")
            || lower.contains("recorder")
            || lower.contains("access")
            || lower.contains("set server")
            || lower.contains("token")
    }

    private var shouldShowComposerSummaryRow: Bool {
        vm.isVoiceModeActiveForCurrentThread || shouldShowComposerStatusSummary
    }

    private var runRetryNotice: (title: String, message: String)? {
        guard !vm.isLoading,
              !vm.needsConnectionRepair,
              !vm.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              vm.pendingHumanUnblockRequest == nil,
              vm.canRetryLastPrompt else {
            return nil
        }

        let lower = vm.statusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }

        if lower.contains("upload failed") || lower.contains("failed to start recording") {
            return nil
        }

        if lower.contains("timed out") {
            return (
                "Run timed out",
                "Retry the last prompt or inspect Run Logs."
            )
        }

        if lower.contains("cancel") {
            return (
                "Run stopped early",
                "Retry the last prompt or inspect Run Logs."
            )
        }

        if lower.contains("fail") || lower.contains("rejected") {
            return (
                "Run failed",
                "Retry the last prompt or inspect Run Logs."
            )
        }

        return nil
    }

    private var composerStatusSummaryText: String {
        bottomRunStatusText
    }

    private var composerStatusSummaryIcon: String {
        let lower = composerStatusSummaryText.lowercased()
        if lower.contains("input") || lower.contains("blocked") {
            return "hand.raised.fill"
        }
        if lower.contains("fail") || lower.contains("cancel") || lower.contains("timed out") {
            return "exclamationmark.circle.fill"
        }
        if lower.contains("complete") {
            return "checkmark.circle.fill"
        }
        if vm.isLoading || lower.contains("think") || lower.contains("plan") || lower.contains("execut") || lower.contains("summar") {
            return "bolt.horizontal.circle.fill"
        }
        return "info.circle.fill"
    }

    private var composerStatusSummaryTint: Color {
        let lower = composerStatusSummaryText.lowercased()
        if lower.contains("input") || lower.contains("blocked") {
            return .orange
        }
        if lower.contains("fail") || lower.contains("cancel") || lower.contains("timed out") {
            return .red
        }
        if lower.contains("complete") {
            return .green
        }
        if vm.isLoading || lower.contains("think") || lower.contains("plan") || lower.contains("execut") || lower.contains("summar") {
            return .blue
        }
        return .secondary
    }

    private var attachmentSummaryText: String {
        if vm.draftAttachments.count == 1 {
            return "1 attachment"
        }
        return "\(vm.draftAttachments.count) attachments"
    }

    private var hasRecordingDraftText: Bool {
        !vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var recordingTypedNoteSummaryText: String? {
        guard hasRecordingDraftText else { return nil }
        return vm.draftAttachments.isEmpty ? "Typed note" : "Typed note + files"
    }

    private var composerHeight: CGFloat {
        let trimmed = vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !composerFocused && trimmed.isEmpty {
            return 50
        }
        let lineCount = max(1, vm.promptText.split(separator: "\n", omittingEmptySubsequences: false).count)
        return min(136, max(74, CGFloat(lineCount) * 22 + 24))
    }

    private var composerPlaceholder: String {
        if vm.needsConnectionRepair {
            return "Scan pairing QR again to reconnect"
        }
        if !vm.hasConfiguredConnection {
            return "Connect backend"
        }
        if vm.isRecording {
            return "Voice recording in progress"
        }
        if vm.draftAttachments.isEmpty {
            return composerFocused ? "Type a prompt or /" : "Type a prompt"
        }
        return composerFocused ? "Add a note or /" : "Add a note"
    }

    private var headerStatusText: String {
        if vm.isRecording {
            return "Recording voice prompt"
        }
        if vm.isLoading {
            return bottomRunStatusText
        }
        if vm.needsConnectionRepair {
            return "Scan pairing QR again to reconnect"
        }
        if vm.hasConfiguredConnection {
            return "Ready for prompts"
        }
        return "Scan pairing QR to connect"
    }

    private var activeNavigationTitle: String {
        let trimmed = vm.activeThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "MOBaiLE" : trimmed
    }

    private var navigationBarTitle: String {
        vm.conversation.isEmpty ? activeNavigationTitle : "MOBaiLE"
    }

    private var activeThread: ChatThread? {
        guard let activeThreadID = vm.activeThreadID else { return nil }
        return vm.threads.first(where: { $0.id == activeThreadID })
    }

    private var activeThreadPresentationStatus: ChatThreadPresentationStatus {
        activeThread?.presentationStatus ?? .ready
    }

    private var connectionHostLabel: String {
        let trimmed = vm.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host, !host.isEmpty else { return trimmed }
        return host
    }

    private var settingsToolbarSymbol: String {
        if vm.needsConnectionRepair {
            return "exclamationmark.triangle.fill"
        }
        return vm.hasConfiguredConnection ? "slider.horizontal.3" : "gearshape.fill"
    }

    private var settingsToolbarTint: Color {
        if vm.needsConnectionRepair {
            return .orange
        }
        return vm.hasConfiguredConnection ? Color.primary : Color.orange
    }

    private var canUseConnectedFeatures: Bool {
        vm.hasConfiguredConnection && !vm.needsConnectionRepair
    }

    private var emptyStateRuntimeContext: EmptyStateRuntimeContext? {
        guard canUseConnectedFeatures else { return nil }
        let workspace = compactPathLabel(runtimeDirectoryLabel)
        return EmptyStateRuntimeContext(
            executor: runtimeExecutorLabel,
            model: vm.currentBackendModelLabel,
            effort: runtimeEffortLabel,
            workspace: workspace
        )
    }

    private var runtimeExecutorLabel: String {
        let value = vm.runID.isEmpty ? vm.effectiveExecutor : vm.activeRunExecutor
        return value.uppercased()
    }

    private var runtimeEffortLabel: String? {
        let label = vm.runtimeSettingDisplayValue(for: "reasoning_effort", executor: vm.effectiveExecutor)
        return label == "Backend default" ? nil : label
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
            .joined(separator: " · ")
    }

    private var runtimeStatusText: String {
        let lower = bottomRunStatusText.lowercased()

        if vm.isRecording {
            return "Recording"
        }
        if vm.isUploadingAttachments {
            return "Uploading"
        }
        if lower.contains("input") || lower.contains("blocked") {
            return "Needs input"
        }
        if lower.contains("timed out") {
            return "Timed out"
        }
        if lower.contains("fail") {
            return "Failed"
        }
        if lower.contains("cancel") {
            return "Cancelled"
        }
        if vm.isLoading || lower.contains("think") || lower.contains("plan") || lower.contains("execut") || lower.contains("summar") {
            return "Thinking"
        }
        if vm.needsConnectionRepair {
            return "Reconnect"
        }
        if vm.hasConfiguredConnection {
            return "Ready"
        }
        return "Setup needed"
    }

    private var runtimeStatusIcon: String {
        let lower = runtimeStatusText.lowercased()

        if lower.contains("record") {
            return "mic.fill"
        }
        if lower.contains("upload") || lower.contains("thinking") {
            return "bolt.horizontal.circle.fill"
        }
        if lower.contains("reconnect") {
            return "qrcode.viewfinder"
        }
        if lower.contains("input") {
            return "hand.raised.fill"
        }
        if lower.contains("cancel") || lower.contains("attention") || lower.contains("fail") || lower.contains("timed out") {
            return "exclamationmark.circle.fill"
        }
        if lower.contains("ready") {
            return "checkmark.circle.fill"
        }
        return "gearshape.fill"
    }

    private var runtimeStatusTint: Color {
        let lower = runtimeStatusText.lowercased()

        if lower.contains("record") {
            return .red
        }
        if lower.contains("upload") || lower.contains("thinking") {
            return .blue
        }
        if lower.contains("input") || lower.contains("setup") || lower.contains("reconnect") {
            return .orange
        }
        if lower.contains("cancel") || lower.contains("attention") || lower.contains("fail") || lower.contains("timed out") {
            return .red
        }
        if lower.contains("ready") {
            return .green
        }
        return .secondary
    }

    private var shouldShowRuntimeInfoBar: Bool {
        !vm.conversation.isEmpty
    }

    private var shouldShowRuntimeStatusBadge: Bool {
        if vm.isRecording {
            return false
        }
        if runtimeStatusText == "Ready" {
            return false
        }
        if hasVisibleLiveActivityMessage && isProgressChromeStatus(runtimeStatusText) {
            return false
        }
        return true
    }

    private var canUseBrowsedDirectory: Bool {
        let browsed = vm.directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = runtimeDirectoryLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return !browsed.isEmpty && browsed != current
    }

    private var runtimeInfoBar: some View {
        RuntimeInfoBar(
            vm: vm,
            activeNavigationTitle: activeNavigationTitle,
            runtimeDirectorySummary: runtimeDirectorySummary,
            runtimeDirectoryLabel: runtimeDirectoryLabel,
            runtimeDescriptorSummary: runtimeDescriptorSummary,
            shouldShowRuntimeStatusBadge: shouldShowRuntimeStatusBadge,
            runtimeStatusText: runtimeStatusText,
            runtimeStatusIcon: runtimeStatusIcon,
            runtimeStatusTint: runtimeStatusTint,
            onOpenThreads: {
                showThreads = true
            },
            onOpenWorkspace: {
                showWorkspaceBrowser = true
                Task { await vm.refreshDirectoryBrowser() }
            },
            onOpenPairingScanner: {
                showPairingScanner = true
            },
            onOpenSetupGuide: {
                showSetupGuide = true
            }
        )
    }

    private var workspaceBrowserSheet: some View {
        WorkspaceBrowserSheet(
            vm: vm,
            runtimeDirectoryLabel: runtimeDirectoryLabel,
            canUseBrowsedDirectory: canUseBrowsedDirectory,
            newDirectoryName: $newDirectoryName,
            isCreatingDirectory: $isCreatingDirectory,
            onDismiss: {
                showWorkspaceBrowser = false
            }
        )
    }

    private func shortPathLabel(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "~" }
        if trimmed == "/" { return "/" }
        let last = URL(fileURLWithPath: trimmed).lastPathComponent
        return last.isEmpty ? trimmed : last
    }

    private func compactPathLabel(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "~" }
        if trimmed == "/" { return "/" }

        let url = URL(fileURLWithPath: trimmed)
        let last = url.lastPathComponent
        guard !last.isEmpty else { return trimmed }

        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty, parent != "/", parent != last else { return last }

        return "\(parent)/\(last)"
    }

    private var conversationBackground: some View {
        ZStack {
            Color(.systemGroupedBackground)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.04),
                    Color.clear,
                    Color.blue.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 12,
                endRadius: 240
            )
            .offset(x: 70, y: -40)
        }
    }

    private func applyPreviewPresentationIfNeeded() {
        let previewPairingPayload = "mobaile://pair?server_url=http%3A%2F%2F127.0.0.1%3A8000&pair_code=abc123&session_id=iphone-app"

        switch previewPresentation {
        case "setup":
            showSetupGuide = true
        case "pairing-scanner":
            showPairingScanner = true
        case "pairing-confirmation":
            _ = vm.applyPairingPayload(previewPairingPayload)
        case "settings", "settings-runtime":
            showConnectionSettings = true
        case "threads":
            showThreads = true
        case "logs":
            showLogs = true
        default:
            break
        }
    }

    private var previewPresentation: String? {
        ProcessInfo.processInfo.environment["MOBAILE_PREVIEW_PRESENTATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var isRuntimeSettingsPreviewFocus: Bool {
        previewPresentation == "settings-runtime"
    }

    private var shouldShowRecordingNotice: Bool {
        !vm.isRecording && (
            vm.statusText == "Microphone access needed" ||
            vm.statusText == "Recorder unavailable" ||
            vm.statusText == "Failed to start recording"
        )
    }

    private var recordingStatusBanner: some View {
        Group {
            if vm.isRecording, let startedAt = vm.recordingStartedAt {
                HStack(alignment: .center, spacing: 10) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recording voice prompt")
                            .font(.caption.weight(.semibold))
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text("\(recordingDurationLabel(since: startedAt, now: context.date)) • \(recordingSubtitle)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Text(vm.usesAutoSendForCurrentTurn ? "Auto-send" : "Manual")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(vm.usesAutoSendForCurrentTurn ? .blue : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background((vm.usesAutoSendForCurrentTurn ? Color.blue : Color.secondary).opacity(0.12))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.red.opacity(0.12), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if vm.statusText == "Microphone access needed" {
                InlineNoticeCard(
                    title: "Microphone access is off",
                    message: "Enable microphone permission for MOBaiLE in iOS Settings, then try recording again.",
                    tint: .orange,
                    systemImage: "mic.slash.fill",
                    actionTitle: "Open App Settings",
                    action: openAppSettings
                )
            } else {
                InlineNoticeCard(
                    title: "Recording unavailable",
                    message: vm.errorText.isEmpty ? "The app couldn't start the microphone." : vm.errorText,
                    tint: .red,
                    systemImage: "exclamationmark.triangle.fill",
                    actionTitle: nil,
                    action: nil
                )
            }
        }
    }

    private var recordingSubtitle: String {
        if vm.isVoiceModeActiveForCurrentThread {
            return "Pause to auto-send. Voice mode resumes after the reply."
        }
        if vm.usesAutoSendForCurrentTurn {
            return "Pause to auto-send this prompt."
        }
        return "Tap send when you are ready."
    }

    private var recordingContextItems: [(text: String, systemImage: String, tint: Color)] {
        var items: [(text: String, systemImage: String, tint: Color)] = []
        if vm.isVoiceModeActiveForCurrentThread {
            items.append(("Voice mode", "waveform.circle.fill", .blue))
        }
        if let recordingTypedNoteSummaryText {
            items.append((recordingTypedNoteSummaryText, "square.and.pencil", .secondary))
        }
        if !vm.draftAttachments.isEmpty {
            items.append((attachmentSummaryText, "paperclip", .secondary))
        }
        return items
    }

    private func recordingDurationLabel(since startedAt: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }

    private func handleRecordingButtonTap() {
        if vm.isRecording {
            Task { await vm.stopRecordingAndSend() }
            return
        }
        if vm.needsConnectionRepair {
            showPairingScanner = true
            return
        }
        guard vm.hasConfiguredConnection, !vm.isLoading else { return }
        if vm.shouldPresentMicrophonePrimer {
            vm.markMicrophonePrimerSeen()
        }
        Task { await vm.startRecording() }
    }

    private func handleRecordingDiscardTap() {
        Task { await vm.discardRecording() }
    }

    private func handleRecordingStopTap() {
        if vm.isVoiceModeActiveForCurrentThread {
            Task {
                await vm.discardRecording()
                vm.endVoiceMode()
            }
            return
        }
        handleRecordingDiscardTap()
    }

    private func handleVoiceModeButtonTap() {
        if vm.needsConnectionRepair && !vm.isVoiceModeActiveForCurrentThread {
            showPairingScanner = true
            return
        }
        if !vm.isVoiceModeActiveForCurrentThread && vm.shouldPresentMicrophonePrimer {
            vm.markMicrophonePrimerSeen()
        }
        Task { await vm.toggleVoiceMode() }
    }

    private func handleVoiceModeStartTap() {
        if vm.needsConnectionRepair {
            showPairingScanner = true
            return
        }
        guard !vm.isVoiceModeActiveForCurrentThread else { return }
        if vm.shouldPresentMicrophonePrimer {
            vm.markMicrophonePrimerSeen()
        }
        Task { await vm.startVoiceModeIfNeeded() }
    }

    private var resolvedAppearancePreference: AppAppearancePreference {
        AppAppearancePreference.resolve(from: appearancePreferenceRaw)
    }

    private func handleComposerSend() {
        composerFocused = false
        if vm.needsConnectionRepair {
            showPairingScanner = true
            return
        }
        guard let slashState = composerSlashCommandState else {
            Task { await vm.sendPrompt() }
            return
        }
        guard let command = slashState.exactMatch else {
            if slashState.query.isEmpty {
                vm.errorText = "Choose a slash command from the list."
            } else {
                vm.errorText = "Unknown slash command /\(slashState.query)."
            }
            composerFocused = true
            return
        }
        Task { await executeSlashCommand(command, arguments: slashState.arguments) }
    }

    private func handleSlashCommandSelection(_ command: ComposerSlashCommand, state: ComposerSlashCommandState) {
        if state.exactMatch == command {
            composerFocused = false
            Task { await executeSlashCommand(command, arguments: state.arguments) }
            return
        }
        vm.prepareSlashCommand(command)
        composerFocused = true
    }

    private func executeSlashCommand(_ command: ComposerSlashCommand, arguments rawArguments: String) async {
        let arguments = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)

        if !command.acceptsArguments && !arguments.isEmpty {
            vm.errorText = "\(command.usage) does not take extra arguments."
            composerFocused = true
            return
        }
        if command.argumentKind == "enum" && !arguments.isEmpty {
            let normalized = arguments.lowercased()
            if !command.argumentOptions.isEmpty && !command.argumentOptions.contains(normalized) {
                vm.errorText = "\(command.usage) expects one of: \(command.argumentOptions.joined(separator: ", "))."
                composerFocused = true
                return
            }
        }

        switch command.source {
        case let .local(action):
            switch action {
            case .new:
                vm.clearComposerText()
                vm.startNewChat()
            case .voiceNew:
                vm.clearComposerText()
                await vm.handleStartNewVoiceThreadShortcut()
            case .threads:
                vm.clearComposerText()
                showThreads = true
                vm.errorText = ""
            case .logs:
                vm.clearComposerText()
                showLogs = true
                vm.errorText = ""
            case .settings:
                vm.clearComposerText()
                showConnectionSettings = true
                vm.errorText = ""
            case .browse:
                vm.clearComposerText()
                showWorkspaceBrowser = true
                if arguments.isEmpty {
                    await vm.refreshDirectoryBrowser()
                    vm.statusText = "Opened the workspace browser."
                } else {
                    await vm.openDirectory(path: arguments)
                    vm.statusText = "Opened \(arguments)."
                }
            case .retry:
                vm.clearComposerText()
                await vm.retryLastPrompt()
            case .voice:
                vm.clearComposerText()
                handleVoiceModeStartTap()
            case .paste:
                vm.clearComposerText()
                await vm.pasteClipboardContentIntoDraft()
            case .clear:
                vm.clearComposerDraft()
                vm.statusText = "Cleared the draft."
            }
        case .backend:
            do {
                let response = try await vm.executeBackendSlashCommand(command, arguments: arguments)
                vm.clearComposerText()
                vm.errorText = ""
                vm.statusText = response.message
            } catch {
                vm.errorText = error.localizedDescription
                composerFocused = true
            }
        }
    }

}


#Preview {
    ContentView()
}
