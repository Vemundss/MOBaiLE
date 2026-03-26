import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    private let privacyPolicyURL = URL(string: "https://vemundss.github.io/MOBaiLE/privacy-policy.html")!
    private let supportURL = URL(string: "https://vemundss.github.io/MOBaiLE/support.html")!
    @StateObject private var vm = VoiceAgentViewModel()
    @State private var showConnectionSettings = false
    @State private var showLogs = false
    @State private var showThreads = false
    @State private var showAttachmentOptions = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showWorkspaceBrowser = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var newDirectoryName = ""
    @State private var trustPairHost = false
    @State private var showAdvancedSettings = false
    @State private var settingsConnectionState: SettingsConnectionState = .idle
    @State private var showMicrophonePrimer = false
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

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
                .navigationTitle("MOBaiLE")
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
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { await vm.consumePendingShortcutActionIfNeeded() }
                }
            }
            .onChange(of: showConnectionSettings) {
                if showConnectionSettings {
                    resetSettingsSheetState()
                }
            }
            .onChange(of: showWorkspaceBrowser) {
                if !showWorkspaceBrowser {
                    newDirectoryName = ""
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
                if handleShortcutURL(url) {
                    return
                }
                vm.applyPairingURL(url)
            }
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
            .alert("Before you record", isPresented: $showMicrophonePrimer) {
                Button("Not now", role: .cancel) {}
                Button("Continue") {
                    vm.markMicrophonePrimerSeen()
                    Task { await vm.startRecording() }
                }
            } message: {
                Text("MOBaiLE will ask for microphone and Speech Recognition access. It transcribes on your iPhone first, and only falls back to backend audio upload when local speech is unavailable.")
            }
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
        guard let scheme = url.scheme?.lowercased(), scheme == "mobaile" else { return false }
        guard let host = url.host?.lowercased(), host == "shortcut" else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let action = components.queryItems?.first(where: { $0.name == "action" })?.value?.lowercased() ?? ""
        guard !action.isEmpty else { return false }

        Task {
            switch action {
            case "start-voice":
                await vm.handleStartVoiceTaskShortcut()
            case "send-last-prompt":
                await vm.handleSendLastPromptShortcut()
            default:
                break
            }
        }
        return true
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
                LazyVStack(spacing: 10) {
                    if vm.conversation.isEmpty {
                        ConversationEmptyStateView(
                            isConfigured: vm.hasConfiguredConnection,
                            statusText: headerStatusText,
                            canRetryLastPrompt: vm.canRetryLastPrompt,
                            onOpenSettings: {
                                showConnectionSettings = true
                            },
                            onRetryLastPrompt: {
                                Task { await vm.retryLastPrompt() }
                            },
                            onUsePrompt: { prompt in
                                vm.promptText = prompt
                                composerFocused = true
                            }
                        )
                        .padding(.top, 8)
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
            .padding(.bottom, 4)
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
                Section("Connection") {
                    TextField("Server URL", text: $vm.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    SecureField("API Token", text: $vm.apiToken)
                        .font(.footnote.monospaced())
                    Text("These are the only fields required before you can send prompts or start recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    settingsConnectionCard
                }

                Section("Conversation Style") {
                    Picker("Agent guidance", selection: $vm.agentGuidanceMode) {
                        Text("Guided").tag("guided")
                        Text("Minimal").tag("minimal")
                    }
                    .pickerStyle(.segmented)
                    Text(vm.agentGuidanceMode == "minimal"
                        ? "Minimal: keeps chat focused on final results with fewer progress updates."
                        : "Guided: includes short progress updates and clearer result context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Voice & Feedback") {
                    Toggle("AirPods Click To Record", isOn: $vm.airPodsClickToRecordEnabled)
                    Toggle("Haptic Cues", isOn: $vm.hapticCuesEnabled)
                    Toggle("Audio Cues", isOn: $vm.audioCuesEnabled)
                    Toggle("Auto-send After Silence", isOn: $vm.autoSendAfterSilenceEnabled)
                    if vm.autoSendAfterSilenceEnabled {
                        TextField("Silence seconds", text: $vm.autoSendAfterSilenceSeconds)
                            .keyboardType(.decimalPad)
                        Text("Hands-free mode: auto-submits after this much silence while recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("AirPods click uses headset play/pause controls to start recording and stop+send.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        Text("Most people can leave these alone. The workspace picker on the main screen is the easiest way to change folders for new runs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        Text("Client-side run timeout in seconds. Set 0 to wait indefinitely.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Executor", selection: $vm.executor) {
                            ForEach(vm.selectableExecutors, id: \.self) { option in
                                Text(option.capitalized).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Hide Hidden Folders", isOn: $vm.hideDotFoldersInBrowser)
                        if !vm.backendWorkdirRoot.isEmpty {
                            LabeledContent("Backend Root", value: vm.backendWorkdirRoot)
                                .font(.footnote.monospaced())
                        }
                        LabeledContent("Backend Mode", value: vm.backendSecurityMode)
                        ForEach(vm.backendExecutorModelRows, id: \.id) { row in
                            LabeledContent("\(row.title) Model", value: row.model)
                        }
                        Text(vm.developerMode
                            ? "Developer Mode exposes every reported agent executor plus the internal local fallback."
                            : "Standard mode follows the backend defaults. Local appears only when the backend is explicitly using its internal fallback.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Support") {
                    Link("Privacy Policy", destination: privacyPolicyURL)
                    Link("Support", destination: supportURL)
                    Text("These links are the public pages used for App Store distribution.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var settingsConnectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(settingsConnectionTitle, systemImage: settingsConnectionSymbol)
                        .font(.headline)
                        .foregroundStyle(settingsConnectionTint)
                    Text(settingsConnectionMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await checkSettingsConnection() }
                } label: {
                    if isCheckingSettingsConnection {
                        ProgressView()
                    } else {
                        Label("Check", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isCheckingSettingsConnection || !vm.hasConfiguredConnection)
            }

            if showsSettingsRuntimeDetails {
                ViewThatFits(in: .vertical) {
                    HStack(spacing: 8) {
                        RuntimeContextChip(icon: "lock.shield", label: "Mode", value: vm.backendSecurityMode.uppercased())
                        RuntimeContextChip(icon: "bolt.horizontal.circle", label: "Exec", value: runtimeExecutorLabel)
                        RuntimeContextChip(icon: "sparkles", label: "Model", value: vm.currentBackendModelLabel)
                        if !vm.backendWorkdirRoot.isEmpty {
                            RuntimeContextChip(icon: "externaldrive", label: "Root", value: shortPathLabel(vm.backendWorkdirRoot))
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            RuntimeContextChip(icon: "lock.shield", label: "Mode", value: vm.backendSecurityMode.uppercased())
                            RuntimeContextChip(icon: "bolt.horizontal.circle", label: "Exec", value: runtimeExecutorLabel)
                            RuntimeContextChip(icon: "sparkles", label: "Model", value: vm.currentBackendModelLabel)
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
            return vm.hasConfiguredConnection ? "Check this backend" : "Connection required"
        case .checking:
            return "Checking backend"
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
                ? "Validate the saved URL and token after you update either field."
                : "Enter a server URL and API token to unlock sending, recording, and live run updates."
        case .checking:
            return "Fetching backend config and validating the current token."
        case let .success(message), let .failure(message):
            return message
        }
    }

    private var settingsConnectionTint: Color {
        switch settingsConnectionState {
        case .idle:
            return vm.hasConfiguredConnection ? .blue : .orange
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

    private func resetSettingsSheetState() {
        showAdvancedSettings = false
        settingsConnectionState = .idle
    }

    private func checkSettingsConnection() async {
        settingsConnectionState = .checking
        do {
            let cfg = try await vm.refreshRuntimeConfiguration()
            let host = URL(string: vm.serverURL)?.host ?? vm.serverURL
            settingsConnectionState = .success(
                "Connected to \(host). Security mode: \(cfg.securityMode). Active provider: \(vm.executor.uppercased()). Model: \(vm.currentBackendModelLabel)."
            )
        } catch {
            settingsConnectionState = .failure(error.localizedDescription)
        }
    }

    private var composerSlashCommandState: ComposerSlashCommandState? {
        vm.composerSlashCommandState
    }

    private var composerBar: some View {
        VStack(spacing: 6) {
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

            VStack(spacing: 8) {
                if shouldShowComposerSummaryRow && !vm.isRecording {
                    HStack(spacing: 8) {
                        if shouldShowComposerStatusSummary {
                            Label(composerStatusSummaryText, systemImage: composerStatusSummaryIcon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(composerStatusSummaryTint)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(composerStatusSummaryTint.opacity(0.12))
                                .clipShape(Capsule())
                        }

                        if !vm.draftAttachments.isEmpty {
                            Label(attachmentSummaryText, systemImage: "paperclip.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(Capsule())
                        }

                        Spacer(minLength: 0)

                        if vm.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if !vm.runID.isEmpty && shouldShowComposerStatusSummary {
                            Text("Run \(shortRunID(vm.runID))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
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
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(.separator).opacity(0.16), lineWidth: 1)
            )
        }
        .padding(.horizontal)
        .padding(.bottom, 5)
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

    private var standardComposerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                composerFocused = false
                showAttachmentOptions = true
            } label: {
                Image(systemName: vm.draftAttachments.isEmpty ? "paperclip" : "paperclip.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .foregroundStyle(vm.draftAttachments.isEmpty ? .secondary : Color.accentColor)
            .background(
                Circle()
                    .fill(Color(.systemBackground))
            )
            .accessibilityLabel("Add attachment")
            .disabled(!vm.hasConfiguredConnection || vm.isLoading)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $vm.promptText)
                    .focused($composerFocused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(height: composerHeight)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                composerFocused
                                    ? Color.accentColor.opacity(0.28)
                                    : Color(.separator).opacity(0.10),
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

            HStack(spacing: 6) {
                Button {
                    composerFocused = false
                    handleRecordingButtonTap()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .background(
                    Circle()
                        .fill(Color(.systemBackground))
                )
                .contentShape(Circle())
                .accessibilityLabel("Start recording")
                .disabled(vm.isLoading || !vm.hasConfiguredConnection)

                if vm.canCancelActiveOperation {
                    Button {
                        composerFocused = false
                        vm.cancelActiveOperation()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(
                        Circle()
                            .fill(Color.red)
                    )
                    .contentShape(Circle())
                    .accessibilityLabel(vm.isUploadingAttachments ? "Cancel upload" : "Cancel run")
                } else {
                    Button {
                        handleComposerSend()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(
                        Circle()
                            .fill(Color.accentColor)
                    )
                    .contentShape(Circle())
                    .accessibilityLabel("Send prompt")
                    .disabled(
                        !vm.hasConfiguredConnection ||
                        !vm.hasDraftContent
                    )
                }
            }
            .opacity(vm.hasConfiguredConnection ? 1 : 0.6)
        }
    }

    private var recordingComposerRow: some View {
        HStack(alignment: .center, spacing: 12) {
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

                    if vm.autoSendAfterSilenceEnabled {
                        Text("Auto-send")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(recordingSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !vm.draftAttachments.isEmpty {
                    Label(attachmentSummaryText, systemImage: "paperclip.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Spacer(minLength: 0)

            Button {
                handleRecordingButtonTap()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(
                Circle()
                    .fill(Color.red)
            )
            .contentShape(Circle())
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
        shouldShowComposerStatusSummary || !vm.draftAttachments.isEmpty
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

    private var composerHeight: CGFloat {
        let trimmed = vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !composerFocused && trimmed.isEmpty {
            return 52
        }
        let lineCount = max(1, vm.promptText.split(separator: "\n", omittingEmptySubsequences: false).count)
        return min(148, max(80, CGFloat(lineCount) * 22 + 28))
    }

    private var composerPlaceholder: String {
        if !vm.hasConfiguredConnection {
            return "Connect backend"
        }
        if vm.isRecording {
            return "Voice recording in progress"
        }
        if vm.draftAttachments.isEmpty {
            return composerFocused ? "Ask about this repo or type /" : "Ask about this repo"
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
        return "Add server URL and API token"
    }

    private var runtimeExecutorLabel: String {
        let value = vm.runID.isEmpty ? vm.executor : vm.activeRunExecutor
        return value.uppercased()
    }

    private var runtimeDirectoryLabel: String {
        let resolved = vm.resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { return resolved }
        return vm.workingDirectory
    }

    private var runtimeDirectorySummary: String {
        compactPathLabel(runtimeDirectoryLabel)
    }

    private var shouldShowRuntimeInfoBar: Bool {
        vm.hasConfiguredConnection || !vm.conversation.isEmpty
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
        .background(Color(.systemBackground).opacity(0.96))
        .overlay(
            Rectangle()
                .fill(Color(.separator).opacity(0.35))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var setupRuntimeInfoBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Finish setup to start a run")
                    .font(.subheadline.weight(.semibold))
                Text("Add your backend URL and token once. After that, prompts, recording, and workspace tools are ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            runtimeWorkspaceButton
        }
    }

    private var compactRuntimeInfoBar: some View {
        HStack(spacing: 12) {
            Label {
                Text(runtimeDirectorySummary)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("Current workspace \(runtimeDirectoryLabel)")

            Spacer(minLength: 0)

            if vm.isLoading || vm.isUploadingAttachments {
                ProgressView()
                    .controlSize(.small)
            }

            runtimeWorkspaceButton
        }
    }

    private var runtimeWorkspaceButton: some View {
        Group {
            if vm.hasConfiguredConnection {
                Button {
                    showWorkspaceBrowser = true
                    Task { await vm.refreshDirectoryBrowser() }
                } label: {
                    Text("Browse")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Browse workspace")
            } else {
                Button {
                    showConnectionSettings = true
                } label: {
                    Label("Setup", systemImage: "slider.horizontal.3")
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
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Choose the next working folder", systemImage: "folder.badge.gearshape")
                            .font(.headline)
                        Text("Browse the backend workspace, then promote a folder so future commands run from there.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(.separator).opacity(0.25), lineWidth: 1)
                    )

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
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Browsing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(vm.directoryBrowserPath.isEmpty ? runtimeDirectoryLabel : vm.directoryBrowserPath)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Use This Folder") {
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
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    vm.isLoadingDirectoryBrowser ||
                    newDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
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
                Text("No files found in this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                directoryEntriesContent
            }

            if !canUseBrowsedDirectory,
               !vm.directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("This folder is already the active working directory.")
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

        switch raw {
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

                    Text(vm.autoSendAfterSilenceEnabled ? "Auto-send" : "Manual")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(vm.autoSendAfterSilenceEnabled ? .blue : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background((vm.autoSendAfterSilenceEnabled ? Color.blue : Color.secondary).opacity(0.12))
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
        if vm.autoSendAfterSilenceEnabled {
            return "Auto-sends after \(vm.autoSendAfterSilenceSeconds)s of silence"
        }
        return "Tap stop when you're ready to send"
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
            showMicrophonePrimer = true
            return
        }
        Task { await vm.startRecording() }
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

        switch command {
        case .new:
            vm.clearComposerText()
            vm.startNewChat()
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
        case .cwd:
            let message = await vm.setWorkingDirectoryFromSlashCommand(arguments)
            vm.clearComposerText()
            vm.statusText = message
        case .executor:
            if !arguments.isEmpty && !vm.selectableExecutors.contains(arguments.lowercased()) {
                vm.errorText = "Executor \(arguments.lowercased()) isn't available. Options: \(vm.selectableExecutors.joined(separator: ", "))."
                composerFocused = true
                return
            }
            let message = await vm.setExecutorFromSlashCommand(arguments)
            vm.clearComposerText()
            vm.statusText = message
        case .retry:
            vm.clearComposerText()
            await vm.retryLastPrompt()
        case .voice:
            vm.clearComposerText()
            handleRecordingButtonTap()
        case .paste:
            vm.clearComposerText()
            await vm.pasteClipboardContentIntoDraft()
        case .clear:
            vm.clearComposerDraft()
            vm.statusText = "Cleared the draft."
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
                Text(command.usage)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)
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


#Preview {
    ContentView()
}
