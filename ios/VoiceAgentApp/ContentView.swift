import Foundation
import PhotosUI
import SwiftUI
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
    @State private var threadSheetDetent = PresentationDetent.large
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
    @State private var openSetupGuideAfterSettings = false
    @State private var openPairingScannerAfterSettings = false
    @State private var expandManualConnectionOnNextSettingsOpen = false
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var incomingURLStore: IncomingURLStore

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
            .sheet(isPresented: $showConnectionSettings, onDismiss: {
                expandManualConnectionOnNextSettingsOpen = false
                if openSetupGuideAfterSettings {
                    openSetupGuideAfterSettings = false
                    showSetupGuide = true
                } else if openPairingScannerAfterSettings {
                    openPairingScannerAfterSettings = false
                    showPairingScanner = true
                }
            }) {
                settingsSheet
            }
            .sheet(isPresented: $showThreads, onDismiss: {
                threadSheetDetent = .large
            }) {
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
                .presentationDetents([.medium, .large], selection: $threadSheetDetent)
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showLogs) {
                LogsView(
                    events: vm.visibleRunLogEvents,
                    diagnostics: vm.currentRunDiagnostics,
                    canLoadOlderEvents: vm.canLoadOlderRunLogEvents,
                    isLoadingOlderEvents: vm.isLoadingRunLogEvents,
                    errorText: vm.runLogErrorText,
                    onLoadOlderEvents: {
                        await vm.loadOlderRunLogsIfPossible()
                    }
                )
                .task {
                    await vm.refreshRunLogsIfPossible()
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
                trustPairHost = vm.shouldTrustPendingPairingByDefault(pending)
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
                        let didPair = await vm.confirmPendingPairing(trustHost: trustPairHost)
                        if didPair {
                            return nil
                        }
                        return vm.errorText.isEmpty
                            ? "Pairing failed. Check that the QR is fresh and the backend is reachable."
                            : vm.errorText
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
                            if canUseConnectedFeatures {
                                ConversationReadyEmptyStateView(
                                    canRetryLastPrompt: vm.canRetryLastPrompt,
                                    onRetryLastPrompt: {
                                        Task { await vm.retryLastPrompt() }
                                    }
                                )
                                .padding(.top, 44)
                            } else {
                                ConversationEmptyStateView(
                                    isConfigured: vm.hasConfiguredConnection,
                                    needsConnectionRepair: vm.needsConnectionRepair,
                                    statusText: headerStatusText,
                                    onOpenSetupGuide: {
                                        showSetupGuide = true
                                    },
                                    onOpenPairingScanner: {
                                        showPairingScanner = true
                                    },
                                    onOpenSettings: {
                                        expandManualConnectionOnNextSettingsOpen = true
                                        showConnectionSettings = true
                                    }
                                )
                                .padding(.top, 20)
                            }
                        }

                        ForEach(vm.conversation) { message in
                            HStack {
                                if message.role == "user" {
                                    Spacer(minLength: 52)
                                }
                                MessageBubble(
                                    message: message,
                                    serverURL: vm.serverURL,
                                    apiToken: vm.apiToken,
                                    workspacePath: runtimeDirectoryLabel
                                )
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
                if shouldShowComposerBar {
                    composerBar
                }
            }
        }
    }

    private var settingsSheet: some View {
        ConnectionSettingsSheet(
            vm: vm,
            isRuntimeSettingsPreviewFocus: isRuntimeSettingsPreviewFocus,
            quickStartURL: quickStartURL,
            privacyPolicyURL: privacyPolicyURL,
            supportURL: supportURL,
            expandManualConnectionInitially: expandManualConnectionOnNextSettingsOpen,
            onDismiss: { showConnectionSettings = false },
            onOpenSetupGuide: {
                openSetupGuideAfterSettings = true
                showConnectionSettings = false
            },
            onOpenPairingScanner: {
                openPairingScannerAfterSettings = true
                showConnectionSettings = false
            }
        )
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

    private var composerSlashCommandState: ComposerSlashCommandState? {
        vm.composerSlashCommandState
    }

    private var composerBar: some View {
        ConversationComposerBar(
            vm: vm,
            composerFocused: $composerFocused,
            bottomRunStatusText: bottomRunStatusText,
            hasVisibleLiveActivityMessage: hasVisibleLiveActivityMessage,
            shouldShowRecordingNotice: shouldShowRecordingNotice,
            onOpenLogs: { showLogs = true },
            onOpenAttachmentOptions: { showAttachmentOptions = true },
            onRecordingButtonTap: handleRecordingButtonTap,
            onRecordingStopTap: handleRecordingStopTap,
            onVoiceModeButtonTap: handleVoiceModeButtonTap,
            onSend: handleComposerSend,
            onSelectSlashCommand: handleSlashCommandSelection
        )
    }

    private var shouldShowComposerBar: Bool {
        canUseConnectedFeatures
            || !vm.conversation.isEmpty
            || vm.isLoading
            || vm.isRecording
            || vm.isVoiceModeActiveForCurrentThread
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
        vm.conversation.isEmpty && !shouldShowRuntimeInfoBar ? activeNavigationTitle : "MOBaiLE"
    }

    private var activeThread: ChatThread? {
        guard let activeThreadID = vm.activeThreadID else { return nil }
        return vm.threads.first(where: { $0.id == activeThreadID })
    }

    private var activeThreadPresentationStatus: ChatThreadPresentationStatus {
        activeThread?.presentationStatus ?? .ready
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
        canUseConnectedFeatures || !vm.conversation.isEmpty
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

#if DEBUG
        if ProcessInfo.processInfo.environment["MOBAILE_UI_TESTING"] == "1",
           let testPairingPayload = ProcessInfo.processInfo.environment["MOBAILE_TEST_PAIRING_PAYLOAD"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !testPairingPayload.isEmpty {
            let didStagePairing = vm.applyPairingPayload(testPairingPayload)
            if didStagePairing,
               ProcessInfo.processInfo.environment["MOBAILE_TEST_AUTO_CONFIRM_PAIRING"] == "1" {
                Task {
                    _ = await vm.confirmPendingPairing(trustHost: true)
                }
            }
            return
        }
#endif

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
        case "workspace":
            showWorkspaceBrowser = true
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
                if arguments.isEmpty {
                    showWorkspaceBrowser = true
                    vm.statusText = "Opened the workspace browser."
                } else {
                    await vm.openDirectory(path: arguments)
                    showWorkspaceBrowser = true
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
