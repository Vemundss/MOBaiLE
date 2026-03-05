import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var vm = VoiceAgentViewModel()
    @State private var showConnectionSettings = false
    @State private var showLogs = false
    @State private var showThreads = false
    @State private var newDirectoryName = ""
    @State private var trustPairHost = false
    private let privacyPolicyURL = URL(string: "https://gist.github.com/Vemundss/c2ae60485e23c0c8a93115c039b03044")
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

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
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 10) {
                            Button {
                                showThreads = true
                            } label: {
                                Image(systemName: "text.bubble")
                            }
                            .accessibilityLabel("Threads")
                            Button {
                                showLogs = true
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                            Button("New Chat") {
                                vm.startNewChat()
                            }
                            .font(.subheadline.weight(.semibold))
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
    }

    private var lifecycleManagedView: some View {
        modalSheetView
            .task {
                await vm.bootstrapSessionIfNeeded()
                await vm.consumePendingShortcutActionIfNeeded()
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { await vm.consumePendingShortcutActionIfNeeded() }
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

    private var conversationView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    BrandHeaderView()
                        .padding(.top, 6)

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

                    if vm.conversation.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Start by typing or recording a prompt.")
                                .font(.subheadline.weight(.medium))
                            Text("MOBaiLE will stream the agent response here.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 20)
                    }

                    if !vm.errorText.isEmpty {
                        Text(vm.errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
            .safeAreaInset(edge: .top, spacing: 4) {
                runtimeInfoBar
            }
            .onChange(of: vm.conversation.count) {
                if let last = vm.conversation.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
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
                    TextField("Session ID", text: $vm.sessionID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Execution") {
                    TextField("Working directory", text: $vm.workingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Text("Folder where commands run and files are created. In safe mode, this must stay inside the backend workdir root.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Timeout seconds", text: $vm.runTimeoutSeconds)
                        .keyboardType(.numberPad)
                    Text("Max time to wait for a run before the app marks it as timed out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    LabeledContent("Chat detail", value: "Concise")
                    Text("Verbose chat mode removed. Use Run Logs for full execution events.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if vm.developerMode {
                        Picker("Executor", selection: $vm.executor) {
                            Text("Local").tag("local")
                            Text("Codex").tag("codex")
                        }
                        .pickerStyle(.segmented)
                    } else {
                        LabeledContent("Executor", value: "Codex")
                    }
                }
                Section("App") {
                    Toggle("Developer Mode", isOn: $vm.developerMode)
                    Toggle("AirPods Click To Record", isOn: $vm.airPodsClickToRecordEnabled)
                    Toggle("Hide Hidden Folders", isOn: $vm.hideDotFoldersInBrowser)
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
                    LabeledContent("Backend mode", value: vm.backendSecurityMode)
                    LabeledContent("Codex model", value: vm.backendCodexModel)
                    if let privacyPolicyURL {
                        Link("Privacy Policy", destination: privacyPolicyURL)
                    }
                    Text(vm.developerMode
                        ? "Enables local executor switching."
                        : "Keeps production-safe defaults (Codex executor only).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("AirPods click uses headset play/pause controls to start recording and stop+send.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        vm.hideDirectoryBrowser()
                        vm.persistSettings()
                        showConnectionSettings = false
                    }
                }
            }
        }
    }

    private var composerBar: some View {
        VStack(spacing: 6) {
            if !vm.statusText.isEmpty && vm.statusText != "Idle" {
                HStack {
                    if !vm.runID.isEmpty {
                        Text("Run \(shortRunID(vm.runID))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if vm.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(bottomRunStatusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $vm.promptText)
                        .focused($composerFocused)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .frame(height: composerHeight)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Message MOBaiLE")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                            .padding(.top, 14)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.16), value: composerHeight)

                HStack(spacing: 6) {
                    Button {
                        Task {
                            if vm.isRecording {
                                await vm.stopRecordingAndSend()
                            } else {
                                await vm.startRecording()
                            }
                        }
                    } label: {
                        Image(systemName: vm.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(vm.isRecording ? .red : .blue)
                    .background(
                        Circle()
                            .fill(Color(.tertiarySystemBackground))
                    )
                    .disabled(vm.isLoading || vm.apiToken.isEmpty || vm.serverURL.isEmpty)

                    if vm.isLoading && !vm.runID.isEmpty {
                        Button {
                            Task { await vm.cancelCurrentRun() }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(
                            Circle()
                                .fill(Color.red)
                        )
                    } else {
                        Button {
                            Task { await vm.sendPrompt() }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(
                            Circle()
                                .fill(Color.accentColor)
                        )
                        .disabled(
                            vm.apiToken.isEmpty ||
                            vm.serverURL.isEmpty ||
                            vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            vm.isRecording
                        )
                    }
                }
                .opacity((vm.apiToken.isEmpty || vm.serverURL.isEmpty) ? 0.55 : 1)
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal)
        .padding(.bottom, 5)
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

    private var composerHeight: CGFloat {
        let trimmed = vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !composerFocused && trimmed.isEmpty {
            return 38
        }
        let lineCount = max(1, vm.promptText.split(separator: "\n", omittingEmptySubsequences: false).count)
        return min(132, max(66, CGFloat(lineCount) * 22 + 24))
    }

    private var runtimeExecutorLabel: String {
        let value = vm.runID.isEmpty ? (vm.developerMode ? vm.executor : "codex") : vm.activeRunExecutor
        return value.uppercased()
    }

    private var runtimeDirectoryLabel: String {
        let resolved = vm.resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { return resolved }
        return vm.workingDirectory
    }

    private var runtimeInfoBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    Task { await vm.toggleDirectoryBrowser() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: vm.showDirectoryBrowser ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(runtimeExecutorLabel)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(Capsule())
                        Text("cwd: \(runtimeDirectoryLabel)")
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                        if !vm.statusText.isEmpty && vm.statusText != "Idle" {
                            Text(bottomRunStatusText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            if vm.showDirectoryBrowser {
                directoryBrowserPanel
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.systemBackground).opacity(0.96))
        .overlay(
            Rectangle()
                .fill(Color(.separator).opacity(0.35))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var directoryBrowserPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                                .controlSize(.mini)
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
                .controlSize(.mini)
                .disabled(!vm.canNavigateDirectoryUp || vm.isLoadingDirectoryBrowser)

                Button {
                    Task { await vm.refreshDirectoryBrowser() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(vm.isLoadingDirectoryBrowser)
            }

            HStack(spacing: 6) {
                TextField("New folder", text: $newDirectoryName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption2.monospaced())
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
                .controlSize(.mini)
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
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var directoryEntriesContent: some View {
        if vm.filteredDirectoryBrowserEntries.isEmpty {
            Text("Only hidden folders in this directory. Disable filter in Settings to view them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(vm.filteredDirectoryBrowserEntries) { entry in
                        Button {
                            Task { await vm.openDirectoryEntry(entry) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                    .font(.caption2)
                                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                Text(entry.name)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if entry.isDirectory {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!entry.isDirectory)
                    }
                }
            }
            .frame(maxHeight: 220)
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
