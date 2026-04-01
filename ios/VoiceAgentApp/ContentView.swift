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
                .navigationTitle(activeNavigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showConnectionSettings = true
                        } label: {
                            Image(systemName: vm.hasConfiguredConnection ? "slider.horizontal.3" : "gearshape.fill")
                        }
                        .foregroundStyle(vm.hasConfiguredConnection ? Color.primary : Color.orange)
                        .accessibilityLabel("Settings")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showThreads = true
                        } label: {
                            Image(systemName: "text.bubble")
                        }
                        .accessibilityLabel("Threads")

                        Menu {
                            Button {
                                vm.startNewChat()
                            } label: {
                                Label("New Chat", systemImage: "square.and.pencil")
                            }

                            Button {
                                showLogs = true
                            } label: {
                                Label("Run Logs", systemImage: "doc.text.magnifyingglass")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
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
            }
            .sheet(isPresented: $showLogs) {
                LogsView(events: vm.events)
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
            .confirmationDialog("Add attachment", isPresented: $showAttachmentOptions, titleVisibility: .visible) {
                Button("Photo Library") {
                    showPhotoPicker = true
                }
                Button("Files") {
                    showFileImporter = true
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
            ScrollView {
                LazyVStack(spacing: 12) {
                    if vm.conversation.isEmpty {
                        ConversationEmptyStateView(
                            isConfigured: vm.hasConfiguredConnection,
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
                        .padding(.top, 24)
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
            .simultaneousGesture(
                TapGesture().onEnded {
                    composerFocused = false
                }
            )
            .safeAreaInset(edge: .bottom) {
                composerBar
            }
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                if !vm.hasConfiguredConnection {
                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("You only need to do this once", systemImage: "list.number")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 10) {
                                SetupGuideStepSummaryRow(
                                    stepNumber: 1,
                                    title: "Install MOBaiLE on your computer",
                                    detail: "Run one install command on your Mac or Linux machine. The installer asks three quick questions. Keep the default answers for the normal setup."
                                )
                                SetupGuideStepSummaryRow(
                                    stepNumber: 2,
                                    title: "Scan the pairing QR in MOBaiLE",
                                    detail: "Open `backend/pairing-qr.png` on the computer, then tap Scan Pairing QR here. MOBaiLE reads it directly and fills the connection for you."
                                )
                            }

                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) {
                                    Button {
                                        showPairingScanner = true
                                    } label: {
                                        Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button {
                                        showSetupGuide = true
                                    } label: {
                                        Label("Show Setup Guide", systemImage: "arrow.right.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                VStack(spacing: 10) {
                                    Button {
                                        showPairingScanner = true
                                    } label: {
                                        Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button {
                                        showSetupGuide = true
                                    } label: {
                                        Label("Show Setup Guide", systemImage: "arrow.right.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Getting Started")
                    } footer: {
                        Text("Fastest path: run the installer, keep the defaults, then use QR pairing. Manual fields below are only the fallback.")
                    }
                }

                Section {
                    if vm.hasConfiguredConnection {
                        connectionFields
                    } else {
                        DisclosureGroup("Already have a server URL and token?", isExpanded: $showManualConnectionFields) {
                            VStack(spacing: 14) {
                                connectionFields
                            }
                            .padding(.top, 8)
                        }
                    }
                } header: {
                    Text(vm.hasConfiguredConnection ? "Connection" : "Manual Connection")
                } footer: {
                    Text(
                        vm.hasConfiguredConnection
                            ? "Server URL and token are the only required setup."
                            : "Most people should pair by QR instead of typing these fallback fields."
                    )
                }

                Section {
                    settingsConnectionCard
                }

                if vm.hasConfiguredConnection {
                    Section {
                        Picker("Executor", selection: $vm.executor) {
                            ForEach(vm.selectableExecutors, id: \.self) { option in
                                Text(option.capitalized).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)

                        if vm.effectiveExecutor == "codex" {
                            TextField("Codex model", text: $vm.codexModelOverride)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.footnote.monospaced())

                            Picker("Codex effort", selection: $vm.codexReasoningEffort) {
                                Text("Backend default").tag("")
                                ForEach(vm.backendCodexReasoningEffortOptions, id: \.self) { option in
                                    Text(option.uppercased()).tag(option)
                                }
                            }
                        } else if vm.effectiveExecutor == "claude" {
                            TextField("Claude model", text: $vm.claudeModelOverride)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.footnote.monospaced())
                        }
                    } header: {
                        Text("Agent Runtime")
                    } footer: {
                        Text(agentRuntimeFooterText)
                    }

                    Section {
                        Picker("Agent guidance", selection: $vm.agentGuidanceMode) {
                            Text("Guided").tag("guided")
                            Text("Minimal").tag("minimal")
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Conversation Style")
                    } footer: {
                        Text(vm.agentGuidanceMode == "minimal"
                            ? "Minimal keeps chat focused on final results."
                            : "Guided adds short progress updates and clearer result context.")
                    }

                    Section {
                        Toggle("AirPods Click To Record", isOn: $vm.airPodsClickToRecordEnabled)
                        Toggle("Haptic Cues", isOn: $vm.hapticCuesEnabled)
                        Toggle("Audio Cues", isOn: $vm.audioCuesEnabled)
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
                                ? "AirPods click uses headset controls. Auto-send submits after the selected silence window. Voice mode always auto-sends and reopens the mic after each reply."
                                : "AirPods click uses headset controls to start recording and stop+send. Voice mode keeps the conversation going by reopening the mic after each reply."
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
            HStack(alignment: .center, spacing: 12) {
                Label(settingsConnectionTitle, systemImage: settingsConnectionSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(settingsConnectionTint)

                Spacer(minLength: 0)

                if vm.hasConfiguredConnection {
                    Button {
                        Task { await checkSettingsConnection() }
                    } label: {
                        if isCheckingSettingsConnection {
                            ProgressView()
                        } else {
                            Text("Check")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCheckingSettingsConnection)
                }
            }

            Text(settingsConnectionMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsSettingsRuntimeDetails {
                ViewThatFits(in: .vertical) {
                    HStack(spacing: 8) {
                        RuntimeContextChip(icon: "lock.shield", label: "Mode", value: vm.backendSecurityMode.uppercased())
                        RuntimeContextChip(icon: "bolt.horizontal.circle", label: "Exec", value: runtimeExecutorLabel)
                        RuntimeContextChip(icon: "sparkles", label: "Model", value: vm.currentBackendModelLabel)
                        if let runtimeEffortLabel {
                            RuntimeContextChip(icon: "brain.head.profile", label: "Effort", value: runtimeEffortLabel)
                        }
                        if !vm.backendWorkdirRoot.isEmpty {
                            RuntimeContextChip(icon: "externaldrive", label: "Root", value: shortPathLabel(vm.backendWorkdirRoot))
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            RuntimeContextChip(icon: "lock.shield", label: "Mode", value: vm.backendSecurityMode.uppercased())
                            RuntimeContextChip(icon: "bolt.horizontal.circle", label: "Exec", value: runtimeExecutorLabel)
                            RuntimeContextChip(icon: "sparkles", label: "Model", value: vm.currentBackendModelLabel)
                            if let runtimeEffortLabel {
                                RuntimeContextChip(icon: "brain.head.profile", label: "Effort", value: runtimeEffortLabel)
                            }
                        }
                        if !vm.backendWorkdirRoot.isEmpty {
                            RuntimeContextChip(icon: "externaldrive", label: "Root", value: shortPathLabel(vm.backendWorkdirRoot))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var showsSettingsRuntimeDetails: Bool {
        guard vm.hasConfiguredConnection else { return false }
        switch settingsConnectionState {
        case .idle:
            return false
        case .checking, .success, .failure:
            return true
        }
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
            return vm.hasConfiguredConnection ? "Verify connection" : "Waiting for pairing"
        case .checking:
            return "Checking connection"
        case .success:
            return "Connection verified"
        case .failure:
            return "Connection failed"
        }
    }

    private var settingsConnectionMessage: String {
        switch settingsConnectionState {
        case .idle:
            return vm.hasConfiguredConnection
                ? "Check after editing either field."
                : "Use the installer and QR pairing for the fastest setup, or expand the manual fallback section if you already have connection details."
        case .checking:
            return "Checking the current backend session."
        case let .success(message), let .failure(message):
            return message
        }
    }

    private var settingsConnectionTint: Color {
        switch settingsConnectionState {
        case .idle:
            return vm.hasConfiguredConnection ? .primary : .orange
        case .checking:
            return .blue
        case .success:
            return .green
        case .failure:
            return .red
        }
    }

    private var settingsConnectionSymbol: String {
        switch settingsConnectionState {
        case .idle:
            return vm.hasConfiguredConnection ? "server.rack" : "exclamationmark.triangle.fill"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.octagon.fill"
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
            settingsConnectionState = .failure(error.localizedDescription)
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
                    title: "Human input needed",
                    message: unblock.instructions,
                    tint: .orange,
                    systemImage: "hand.raised.fill",
                    actionTitle: "Prepare Reply",
                    action: {
                        vm.prepareHumanUnblockReply()
                        composerFocused = true
                    }
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
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(.separator).opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 14, y: 4)
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.18), value: vm.isRecording)
        .animation(.easeInOut(duration: 0.18), value: shouldShowRecordingNotice)
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

                if !vm.runID.isEmpty && shouldShowComposerStatusSummary {
                    Text("Run \(shortRunID(vm.runID))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 2)
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private var standardComposerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                composerUtilityActionTray
                composerTextEditorSurface
                    .frame(minWidth: 140)
                composerPrimaryActionButton
            }

            VStack(spacing: 8) {
                composerTextEditorSurface

                HStack(spacing: 10) {
                    composerUtilityActionTray
                    Spacer(minLength: 0)
                    composerPrimaryActionButton
                }
            }
        }
    }

    private var composerTextEditorSurface: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $vm.promptText)
                .focused($composerFocused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(height: composerHeight)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            composerFocused
                                ? Color.accentColor.opacity(0.30)
                                : Color(.separator).opacity(0.12),
                            lineWidth: 1
                        )
                )

            if vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(composerPlaceholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .padding(.top, 16)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: composerHeight)
    }

    private var composerUtilityActionTray: some View {
        HStack(spacing: 4) {
            Button {
                composerFocused = false
                showAttachmentOptions = true
            } label: {
                ComposerTrayButtonLabel(
                    systemImage: vm.draftAttachments.isEmpty ? "paperclip" : "paperclip.circle.fill",
                    tint: vm.draftAttachments.isEmpty ? Color.secondary : Color.accentColor,
                    fill: vm.draftAttachments.isEmpty ? .clear : Color.accentColor.opacity(0.16)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add attachment")
            .disabled(!vm.hasConfiguredConnection || vm.isLoading)
            .opacity((!vm.hasConfiguredConnection || vm.isLoading) ? 0.45 : 1)

            let canStartVoiceMode = !vm.isLoading && vm.hasConfiguredConnection
            Button {
                composerFocused = false
                handleVoiceModeButtonTap()
            } label: {
                ComposerTrayButtonLabel(
                    systemImage: vm.isVoiceModeActiveForCurrentThread ? "waveform.circle.fill" : "waveform.circle",
                    tint: Color.blue,
                    fill: vm.isVoiceModeActiveForCurrentThread ? Color.blue.opacity(0.16) : .clear
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(vm.isVoiceModeActiveForCurrentThread ? "End voice mode" : "Start voice mode")
            .disabled(!vm.isVoiceModeActiveForCurrentThread && !canStartVoiceMode)
            .opacity((!vm.isVoiceModeActiveForCurrentThread && !canStartVoiceMode) ? 0.45 : 1)

            if vm.hasDraftContent && !vm.canCancelActiveOperation {
                Button {
                    composerFocused = false
                    handleRecordingButtonTap()
                } label: {
                    ComposerTrayButtonLabel(
                        systemImage: "mic.fill",
                        tint: .blue,
                        fill: Color.blue.opacity(0.12)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a voice note")
                .disabled(vm.isLoading || !vm.hasConfiguredConnection)
                .opacity((vm.isLoading || !vm.hasConfiguredConnection) ? 0.45 : 1)
            }
        }
        .padding(4)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var composerPrimaryActionButton: some View {
        if vm.canCancelActiveOperation {
            Button {
                composerFocused = false
                vm.cancelActiveOperation()
            } label: {
                ComposerActionButtonLabel(
                    systemImage: "stop.fill",
                    tint: .white,
                    fill: .red,
                    size: 46,
                    iconSize: 13,
                    weight: .semibold
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(vm.isUploadingAttachments ? "Cancel upload" : "Cancel run")
        } else if vm.hasDraftContent {
            Button {
                handleComposerSend()
            } label: {
                ComposerActionButtonLabel(
                    systemImage: "arrow.up",
                    tint: .white,
                    fill: .accentColor,
                    size: 46,
                    iconSize: 14,
                    weight: .bold
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send prompt")
            .disabled(
                !vm.hasConfiguredConnection ||
                !vm.hasDraftContent
            )
            .opacity((!vm.hasConfiguredConnection || !vm.hasDraftContent) ? 0.45 : 1)
        } else {
            Button {
                composerFocused = false
                handleRecordingButtonTap()
            } label: {
                ComposerActionButtonLabel(
                    systemImage: "mic.fill",
                    tint: .white,
                    fill: .blue,
                    size: 46,
                    iconSize: 14,
                    weight: .bold
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start recording")
            .disabled(vm.isLoading || !vm.hasConfiguredConnection)
            .opacity((vm.isLoading || !vm.hasConfiguredConnection) ? 0.45 : 1)
        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)

                if let startedAt = vm.recordingStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(recordingDurationLabel(since: startedAt, now: context.date))
                            .font(.headline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                } else {
                    Text("Recording")
                        .font(.headline.weight(.semibold))
                }

                if vm.isVoiceModeActiveForCurrentThread {
                    ComposerMetaPill(
                        text: "Voice",
                        systemImage: "waveform.circle.fill",
                        tint: .blue
                    )
                }
            }

            Text(recordingSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let typedNoteSummary = recordingTypedNoteSummaryText {
                ComposerMetaPill(
                    text: typedNoteSummary,
                    systemImage: "text.bubble.fill",
                    tint: .blue
                )
            }

            if let preview = recordingDraftPreviewText {
                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !vm.draftAttachments.isEmpty {
                ComposerMetaPill(
                    text: attachmentSummaryText,
                    systemImage: "paperclip.circle.fill",
                    tint: .accentColor
                )
            }
        }
    }

    private var recordingComposerActions: some View {
        HStack(spacing: 8) {
            Button {
                handleRecordingDiscardTap()
            } label: {
                ComposerActionButtonLabel(
                    systemImage: "xmark",
                    tint: .secondary,
                    fill: Color(.secondarySystemBackground),
                    size: 40,
                    iconSize: 13,
                    weight: .semibold
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard recording")

            Button {
                handleRecordingButtonTap()
            } label: {
                ComposerActionButtonLabel(
                    systemImage: "paperplane.fill",
                    tint: .white,
                    fill: .blue,
                    size: 44,
                    iconSize: 14,
                    weight: .semibold
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording and send")
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

    private var shouldShowComposerStatusSummary: Bool {
        guard !vm.isRecording else { return false }

        let lower = composerStatusSummaryText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !lower.isEmpty, lower != "idle" else { return false }

        if lower == "ready for prompts" || lower == "completed" {
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
        return vm.draftAttachments.isEmpty ? "Typed note included" : "Typed note + files included"
    }

    private var recordingDraftPreviewText: String? {
        let preview = vm.promptText
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return nil }
        return preview
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
        if !vm.hasConfiguredConnection {
            return "Connect backend"
        }
        if vm.isRecording {
            return "Voice recording in progress"
        }
        if vm.draftAttachments.isEmpty {
            return composerFocused ? "Ask MOBaiLE about this repo or type /" : "Ask MOBaiLE about this repo"
        }
        return composerFocused ? "Add context for these files" : "Add context"
    }

    private var headerStatusText: String {
        if vm.isRecording {
            return "Recording voice prompt"
        }
        if vm.isLoading {
            return bottomRunStatusText
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

    private var emptyStateRuntimeContext: EmptyStateRuntimeContext? {
        guard vm.hasConfiguredConnection else { return nil }
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
        guard vm.effectiveExecutor == "codex" else { return nil }
        let label = vm.currentCodexReasoningEffortLabel
        return label == "DEFAULT" ? nil : label
    }

    private var agentRuntimeFooterText: String {
        if vm.effectiveExecutor == "codex" {
            return vm.hasCodexRuntimeOverrides
                ? "These Codex values override the backend default for this session only."
                : "Leave model blank and effort on Backend default to follow the backend defaults."
        }
        if vm.effectiveExecutor == "claude" {
            return vm.hasClaudeRuntimeOverrides
                ? "This Claude model override applies only to the current session."
                : "Leave the Claude model blank to follow the backend default."
        }
        return "Choose an agent executor to expose per-session model controls."
    }

    private var runtimeDirectoryLabel: String {
        let resolved = vm.resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { return resolved }
        return vm.workingDirectory
    }

    private var runtimeDirectorySummary: String {
        compactPathLabel(runtimeDirectoryLabel)
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
        if lower.contains("fail") || lower.contains("timed out") {
            return "Needs attention"
        }
        if lower.contains("cancel") {
            return "Cancelled"
        }
        if vm.isLoading || lower.contains("think") || lower.contains("plan") || lower.contains("execut") || lower.contains("summar") {
            return "Thinking"
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
        if lower.contains("input") {
            return "hand.raised.fill"
        }
        if lower.contains("cancel") || lower.contains("attention") {
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
        if lower.contains("input") || lower.contains("setup") {
            return .orange
        }
        if lower.contains("cancel") || lower.contains("attention") {
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
        if vm.conversation.isEmpty && runtimeStatusText == "Ready" {
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
        Group {
            if !vm.hasConfiguredConnection {
                setupRuntimeInfoBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                compactRuntimeInfoBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .overlay(
            Rectangle()
                .fill(Color(.separator).opacity(0.35))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var setupRuntimeInfoBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Finish setup to start a run")
                    .font(.subheadline.weight(.semibold))
                Text("Run one install command on your computer, keep the default answers, then scan the pairing QR. Manual connection fields are only the fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            runtimeWorkspaceButton
        }
    }

    private var compactRuntimeInfoBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                if shouldShowRuntimeStatusBadge {
                    RuntimeStatusBadge(
                        text: runtimeStatusText,
                        systemImage: runtimeStatusIcon,
                        tint: runtimeStatusTint
                    )
                }

                Spacer(minLength: 0)

                runtimeWorkspaceButton
            }

            VStack(alignment: .leading, spacing: 8) {
                if shouldShowRuntimeStatusBadge {
                    RuntimeStatusBadge(
                        text: runtimeStatusText,
                        systemImage: runtimeStatusIcon,
                        tint: runtimeStatusTint
                    )
                }

                runtimeWorkspaceButton
            }
        }
    }

    private var runtimeWorkspaceButton: some View {
        Group {
            if vm.hasConfiguredConnection {
                Button {
                    showWorkspaceBrowser = true
                    Task { await vm.refreshDirectoryBrowser() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(runtimeDirectorySummary)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse workspace \(runtimeDirectoryLabel)")
            } else {
                Button {
                    showSetupGuide = true
                } label: {
                    Label("Setup Guide", systemImage: "list.number")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
    }

    private var workspaceBrowserSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    directoryBrowserPanel
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showWorkspaceBrowser = false
                    }
                }
            }
            .task {
                if vm.directoryBrowserEntries.isEmpty && !vm.isLoadingDirectoryBrowser {
                    await vm.refreshDirectoryBrowser()
                }
            }
        }
    }

    private var directoryBrowserPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(vm.directoryBrowserPath.isEmpty ? runtimeDirectoryLabel : vm.directoryBrowserPath)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Use Folder") {
                    Task { await vm.useCurrentBrowserDirectoryAsWorkingDirectory() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canUseBrowsedDirectory || vm.isLoadingDirectoryBrowser)
            }

            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if vm.directoryBreadcrumbs.isEmpty {
                            Text(runtimeDirectoryLabel)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(vm.directoryBreadcrumbs) { crumb in
                                Button(crumb.title) {
                                    Task { await vm.openDirectory(path: crumb.path) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                Button {
                    Task { await vm.navigateDirectoryUp() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!vm.canNavigateDirectoryUp || vm.isLoadingDirectoryBrowser)

                Button {
                    Task { await vm.refreshDirectoryBrowser() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.isLoadingDirectoryBrowser)
            }

            if isCreatingDirectory {
                HStack(spacing: 6) {
                    TextField("New folder", text: $newDirectoryName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .textFieldStyle(.roundedBorder)
                    Button("Create") {
                        Task {
                            let created = await vm.createDirectoryInCurrentBrowser(name: newDirectoryName)
                            if created {
                                newDirectoryName = ""
                                isCreatingDirectory = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        vm.isLoadingDirectoryBrowser ||
                        newDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    Button("Cancel") {
                        newDirectoryName = ""
                        isCreatingDirectory = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button {
                    isCreatingDirectory = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.isLoadingDirectoryBrowser)
            }

            if vm.isLoadingDirectoryBrowser {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading folder contents...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !vm.directoryBrowserError.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(vm.directoryBrowserError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    if !vm.directoryBrowserMissingPath.isEmpty {
                        Button("Create missing directory") {
                            Task { await vm.createDirectoryFromBrowser() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                }
            } else if vm.directoryBrowserEntries.isEmpty {
                Text("This folder is empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                directoryEntriesContent
            }

            if !canUseBrowsedDirectory,
               !vm.directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Current working directory.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var directoryEntriesContent: some View {
        if vm.filteredDirectoryBrowserEntries.isEmpty {
            Text("Only hidden folders in this directory. Disable filter in Settings to view them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(vm.filteredDirectoryBrowserEntries) { entry in
                    Button {
                        Task { await vm.openDirectoryEntry(entry) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                            Text(entry.name)
                                .font(.footnote.monospaced())
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if entry.isDirectory {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.systemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isDirectory)
                    .opacity(entry.isDirectory ? 1 : 0.82)
                }
            }
        }

        if vm.hideDotFoldersInBrowser && vm.hiddenDotFolderCount > 0 {
            Text("Hidden folders filtered: \(vm.hiddenDotFolderCount).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        if vm.directoryBrowserTruncated {
            Text("Listing truncated by backend.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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

    private func applyPreviewPresentationIfNeeded() {
        let raw = ProcessInfo.processInfo.environment["MOBAILE_PREVIEW_PRESENTATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let previewPairingPayload = "mobaile://pair?server_url=http%3A%2F%2F127.0.0.1%3A8000&pair_code=abc123&session_id=iphone-app"

        switch raw {
        case "setup":
            showSetupGuide = true
        case "pairing-scanner":
            showPairingScanner = true
        case "pairing-confirmation":
            _ = vm.applyPairingPayload(previewPairingPayload)
        case "settings":
            showConnectionSettings = true
        case "threads":
            showThreads = true
        case "logs":
            showLogs = true
        default:
            break
        }
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
        if vm.isVoiceModeActiveForCurrentThread && vm.usesAutoSendForCurrentTurn {
            return "Send now, or pause for silence. The mic reopens after the reply."
        }
        if vm.isVoiceModeActiveForCurrentThread {
            return "Send now. The mic reopens after the reply."
        }
        if vm.usesAutoSendForCurrentTurn {
            return "Send now, or wait for silence to submit."
        }
        return "Tap Send when you're ready."
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
        guard vm.hasConfiguredConnection, !vm.isLoading else { return }
        if vm.shouldPresentMicrophonePrimer {
            vm.markMicrophonePrimerSeen()
        }
        Task { await vm.startRecording() }
    }

    private func handleRecordingDiscardTap() {
        Task { await vm.discardRecording() }
    }

    private func handleVoiceModeButtonTap() {
        if !vm.isVoiceModeActiveForCurrentThread && vm.shouldPresentMicrophonePrimer {
            vm.markMicrophonePrimerSeen()
        }
        Task { await vm.toggleVoiceMode() }
    }

    private func handleVoiceModeStartTap() {
        guard !vm.isVoiceModeActiveForCurrentThread else { return }
        if vm.shouldPresentMicrophonePrimer {
            vm.markMicrophonePrimerSeen()
        }
        Task { await vm.startVoiceModeIfNeeded() }
    }

    private func handleComposerSend() {
        composerFocused = false
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

private struct ComposerSlashCommandMenu: View {
    let state: ComposerSlashCommandState
    let onSelect: (ComposerSlashCommand) -> Void

    private var visibleCommands: [ComposerSlashCommand] {
        Array(state.suggestions.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Slash Commands", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(state.exactMatch == nil ? "Tap to insert" : "Tap to run")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if state.hasUnknownCommand {
                Text("No slash command matches /\(state.query).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleCommands) { command in
                    Button {
                        onSelect(command)
                    } label: {
                        ComposerSlashCommandRow(
                            command: command,
                            arguments: state.arguments,
                            isReadyToRun: state.exactMatch == command
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator).opacity(0.12), lineWidth: 1)
        )
    }
}

private struct ComposerMetaPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct ComposerActionButtonLabel: View {
    let systemImage: String
    let tint: Color
    let fill: Color
    let size: CGFloat
    let iconSize: CGFloat
    let weight: Font.Weight

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: weight))
            .frame(width: size, height: size)
            .foregroundStyle(tint)
            .background(
                Circle()
                    .fill(fill)
            )
    }
}

private struct ComposerTrayButtonLabel: View {
    let systemImage: String
    let tint: Color
    let fill: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(fill)
            )
    }
}

private struct RuntimeStatusBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }
}

private struct RuntimeContextChip: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospaced())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ComposerSlashCommandRow: View {
    let command: ComposerSlashCommand
    let arguments: String
    let isReadyToRun: Bool

    private var hintText: String {
        if isReadyToRun {
            if command.acceptsArguments && !arguments.isEmpty {
                return "Run"
            }
            return "Use"
        }
        return "Insert"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(command.usage)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.primary)
                    if let group = command.group, !group.isEmpty {
                        Text(group.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
                Text(command.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Text(hintText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isReadyToRun ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background((isReadyToRun ? Color.accentColor : Color.secondary).opacity(0.10))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DraftAttachmentChip: View {
    let attachment: DraftAttachment
    let transferState: DraftAttachmentTransferState
    let isBusy: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tintColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if showsDetailText {
                    Text(detailText)
                        .font(detailFont)
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                }
            }
            if let progress = transferState.progressValue {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(tintColor)
                    .frame(width: 44)
            }
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.fileName)")
            .disabled(isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var iconName: String {
        switch attachment.kind {
        case .image:
            return "photo"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .file:
            return "doc"
        }
    }

    private var tintColor: Color {
        if case .failed = transferState {
            return .red
        }
        if transferState.isUploading {
            return .accentColor
        }
        switch attachment.kind {
        case .image:
            return .blue
        case .code:
            return .green
        case .file:
            return .secondary
        }
    }

    private var detailText: String {
        switch transferState {
        case .idle:
            return ""
        case let .uploading(progress):
            return "Uploading \(Int((min(1, max(0, progress)) * 100).rounded()))%"
        case let .failed(message):
            return message
        }
    }

    private var showsDetailText: Bool {
        switch transferState {
        case .idle:
            return false
        case .uploading, .failed:
            return true
        }
    }

    private var detailFont: Font {
        switch transferState {
        case .idle:
            return .caption2
        case .uploading:
            return .caption2.weight(.semibold)
        case .failed:
            return .caption2.weight(.medium)
        }
    }

    private var detailColor: Color {
        switch transferState {
        case .idle:
            return .secondary
        case .uploading:
            return tintColor
        case .failed:
            return .red
        }
    }

    private var backgroundColor: Color {
        switch transferState {
        case .idle:
            return Color(.secondarySystemBackground)
        case .uploading:
            return tintColor.opacity(0.12)
        case .failed:
            return Color.red.opacity(0.10)
        }
    }
}

private struct PairingConfirmationSheet: View {
    let pending: VoiceAgentViewModel.PendingPairing
    @Binding var trustHost: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    LabeledContent("Host", value: pending.serverHost.isEmpty ? pending.serverURL : pending.serverHost)
                        .font(.footnote.monospaced())
                    LabeledContent("URL", value: pending.serverURL)
                        .font(.footnote.monospaced())
                    LabeledContent("Security", value: pending.badgeText)
                }

                if let warning = pending.localNetworkWarning {
                    Section("Network") {
                        Label("Local network HTTP detected", systemImage: "wifi.exclamationmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Session") {
                    LabeledContent("Session ID", value: pending.sessionID ?? "default")
                    LabeledContent(
                        "Method",
                        value: pending.pairCode != nil ? "One-time pair code" : "Legacy token (developer mode)"
                    )
                }

                Section("Trust") {
                    Toggle("Trust this server", isOn: $trustHost)
                    Text("Trusted hosts auto-enable this toggle the next time you pair.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Confirm Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pair") {
                        onConfirm()
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}

private struct SetupGuideSheet: View {
    let bootstrapInstallCommand: String
    let checkoutInstallCommand: String
    let quickStartURL: URL
    let supportURL: URL
    let onOpenScanner: () -> Void
    let onManualSetup: () -> Void

    @State private var copiedLabel: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Set it up", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("Start on your computer. Pair once. Then the app is ready.")
                            .font(.title3.weight(.semibold))
                        Text("MOBaiLE does not run code on iPhone. It connects to a backend on your own Mac or Linux machine.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SetupGuideStepSummaryRow(
                            stepNumber: 1,
                            title: "Run the installer on your computer",
                            detail: "This is the easiest path. The installer asks three quick questions. For the normal setup, keep `Full Access`, `Anywhere with Tailscale`, and `Yes` for the background service."
                        )
                        SetupGuideCommandBlock(command: bootstrapInstallCommand)

                        HStack(spacing: 10) {
                            Button(copiedLabel == "bootstrap" ? "Copied" : "Copy Command") {
                                UIPasteboard.general.string = bootstrapInstallCommand
                                copiedLabel = "bootstrap"
                            }
                            .buttonStyle(.borderedProminent)

                            Spacer(minLength: 0)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Already inside this repo?")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(checkoutInstallCommand)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        SetupGuideStepSummaryRow(
                            stepNumber: 2,
                            title: "Scan the pairing QR in MOBaiLE",
                            detail: "After install, open `backend/pairing-qr.png` on the computer. In MOBaiLE, tap Scan Pairing QR and point the phone at the screen."
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Text("What to do next")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("1. Open `backend/pairing-qr.png` on the computer.")
                            Text("2. Tap Scan Pairing QR in MOBaiLE.")
                            Text("3. Point the phone at the screen and confirm the pairing.")
                            Text("4. Later, run `mobaile status` on the computer. If your shell does not find it yet, run `~/.local/bin/mobaile status`.")
                        }
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)

                        Button {
                            onOpenScanner()
                        } label: {
                            Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Manual fallback", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                        Text("If QR pairing is not available, open Settings and paste the `server_url` from `backend/pairing.json` plus `VOICE_AGENT_API_TOKEN` from `backend/.env`.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Enter URL and Token Manually") {
                            onManualSetup()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Link("Open Set It Up", destination: quickStartURL)
                        Link("Open Support", destination: supportURL)
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Set It Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SetupGuideStepSummaryRow: View {
    let stepNumber: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                Text("\(stepNumber)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct SetupGuideCommandBlock: View {
    let command: String

    var body: some View {
        Text(command)
            .font(.footnote.monospaced())
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator).opacity(0.14), lineWidth: 1)
        )
    }
}


#Preview {
    ContentView()
}
