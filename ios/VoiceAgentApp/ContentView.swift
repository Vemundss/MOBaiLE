import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var vm = VoiceAgentViewModel()
    @State private var showConnectionSettings = false
    @State private var showLogs = false
    @State private var showThreads = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Text(vm.executor.uppercased())
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(Capsule())
                            if !vm.resolvedWorkingDirectory.isEmpty {
                                Text("cwd: \(vm.resolvedWorkingDirectory)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.top, 4)

                        ForEach(vm.conversation) { message in
                            HStack {
                                if message.role == "user" {
                                    Spacer(minLength: 52)
                                }
                                MessageBubble(message: message, serverURL: vm.serverURL)
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
                .padding(.bottom, 8)
                .onChange(of: vm.conversation.count) {
                    if let last = vm.conversation.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if !vm.statusText.isEmpty && vm.statusText != "Idle" {
                            HStack {
                                if !vm.runID.isEmpty {
                                    Text("Run \(shortRunID(vm.runID))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(vm.statusText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(spacing: 8) {
                            TextEditor(text: $vm.promptText)
                                .frame(minHeight: 50, maxHeight: 100)
                                .padding(6)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            HStack(spacing: 10) {
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
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(width: 34, height: 34)
                                }
                                .buttonStyle(.bordered)
                                .tint(vm.isRecording ? .red : .blue)
                                .disabled(vm.isLoading || vm.apiToken.isEmpty || vm.serverURL.isEmpty)

                                Spacer()

                                if vm.isLoading && !vm.runID.isEmpty {
                                    Button("Cancel") {
                                        Task { await vm.cancelCurrentRun() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.red)
                                } else {
                                    Button("Send") {
                                        Task { await vm.sendPrompt() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(vm.apiToken.isEmpty || vm.serverURL.isEmpty || vm.promptText.isEmpty || vm.isRecording)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("MOBaiLE")
            .navigationBarTitleDisplayMode(.large)
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
                        if vm.developerMode {
                            Button {
                                showLogs = true
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                        }
                        Button("New Chat") {
                            vm.startNewChat()
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .sheet(isPresented: $showConnectionSettings) {
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
                            TextField("Timeout seconds", text: $vm.runTimeoutSeconds)
                                .keyboardType(.numberPad)
                            if vm.developerMode {
                                Picker("Executor", selection: $vm.executor) {
                                    Text("Local").tag("local")
                                    Text("Codex").tag("codex")
                                }
                                .pickerStyle(.segmented)
                                Picker("Chat mode", selection: $vm.responseMode) {
                                    Text("Concise").tag("concise")
                                    Text("Verbose").tag("verbose")
                                }
                                .pickerStyle(.segmented)
                            } else {
                                LabeledContent("Executor", value: "Codex")
                                LabeledContent("Chat mode", value: "Concise")
                            }
                        }
                        Section("App") {
                            Toggle("Developer Mode", isOn: $vm.developerMode)
                            LabeledContent("Backend mode", value: vm.backendSecurityMode)
                            if vm.developerMode {
                                Text("Shows local executor, verbose mode, and logs.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showConnectionSettings = false
                            }
                        }
                    }
                }
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
            .task {
                await vm.bootstrapSessionIfNeeded()
            }
            .onChange(of: vm.didCompleteRun) {
                if vm.didCompleteRun {
                    showConnectionSettings = false
                }
            }
            .onChange(of: vm.serverURL) { vm.persistSettings() }
            .onChange(of: vm.apiToken) { vm.persistSettings() }
            .onChange(of: vm.sessionID) { vm.persistSettings() }
            .onChange(of: vm.workingDirectory) { vm.persistSettings() }
            .onChange(of: vm.runTimeoutSeconds) { vm.persistSettings() }
            .onChange(of: vm.executor) { vm.persistSettings() }
            .onChange(of: vm.responseMode) { vm.persistSettings() }
            .onChange(of: vm.developerMode) { vm.persistSettings() }
            .onOpenURL { url in
                vm.applyPairingURL(url)
            }
        }
    }

    private func shortRunID(_ runID: String) -> String {
        if runID.count <= 8 {
            return runID
        }
        return String(runID.prefix(8))
    }
}

private struct LogsView: View {
    let events: [ExecutionEvent]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(events.enumerated().reversed()), id: \.offset) { _, event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.type)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(event.message)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("Run Logs")
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

private struct ThreadsView: View {
    let threads: [ChatThread]
    let activeThreadID: UUID?
    let onSelect: (UUID) -> Void
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    let onNewChat: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renamingThreadID: UUID?
    @State private var renameTitle: String = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(threads) { thread in
                    Button {
                        onSelect(thread.id)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.title)
                                    .font(.body.weight(activeThreadID == thread.id ? .semibold : .regular))
                                    .lineLimit(1)
                                Text(thread.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if activeThreadID == thread.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            onDelete(thread.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            renamingThreadID = thread.id
                            renameTitle = thread.title
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.indigo)
                    }
                }
            }
            .navigationTitle("Threads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat") {
                        onNewChat()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .alert("Rename Thread", isPresented: Binding(
                get: { renamingThreadID != nil },
                set: { if !$0 { renamingThreadID = nil } }
            )) {
                TextField("Title", text: $renameTitle)
                Button("Cancel", role: .cancel) {
                    renamingThreadID = nil
                }
                Button("Save") {
                    if let threadID = renamingThreadID {
                        onRename(threadID, renameTitle)
                    }
                    renamingThreadID = nil
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

private struct MessageBubble: View {
    let message: ConversationMessage
    let serverURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .markdown:
                    MarkdownText(text: segment.content, isUser: isUser)
                case .code:
                    CodeBlock(text: segment.content)
                case let .image(url):
                    RemoteImageView(urlString: url)
                case let .section(title, body):
                    SectionCard(title: title, content: body, isUser: isUser)
                case let .artifact(item):
                    ArtifactCard(artifact: item, serverURL: serverURL)
                case let .agenda(items):
                    AgendaCard(items: items)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .foregroundStyle(isUser ? Color.white : Color.primary)
        .background(
            isUser
                ? Color.blue
                : Color(.secondarySystemBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var isUser: Bool {
        message.role == "user"
    }

    private var segments: [MessageSegment] {
        parseSegments(from: message.text, serverURL: serverURL, massageForDisplay: !isUser)
    }
}

private struct MarkdownText: View {
    let text: String
    let isUser: Bool

    var body: some View {
        if shouldRenderAsMarkdown(text),
           let rendered = try? AttributedString(
               markdown: text,
               options: AttributedString.MarkdownParsingOptions(
                   interpretedSyntax: .inlineOnlyPreservingWhitespace
               )
           ) {
            Text(rendered)
                .font(.body)
                .lineSpacing(1.5)
                .foregroundStyle(isUser ? Color.white : Color.primary)
        } else {
            Text(verbatim: text)
                .font(.body)
                .lineSpacing(1.5)
                .foregroundStyle(isUser ? Color.white : Color.primary)
        }
    }
}

private func shouldRenderAsMarkdown(_ text: String) -> Bool {
    if text.contains("```") || text.contains("](") || text.contains("![") {
        return true
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
            return true
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return true
        }
        if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
            return true
        }
    }
    return false
}

private struct CodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
        .foregroundStyle(Color(red: 0.86, green: 0.91, blue: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SectionCard: View {
    let title: String
    let content: String
    let isUser: Bool
    @State private var expanded = false

    var body: some View {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLong = trimmed.count > 280 || trimmed.contains("\n\n")
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isUser ? Color.white.opacity(0.9) : .secondary)
            if isLong {
                DisclosureGroup(expanded ? "Hide details" : "Show details", isExpanded: $expanded) {
                    MarkdownText(text: trimmed, isUser: isUser)
                }
                .font(.footnote)
            } else {
                MarkdownText(text: trimmed, isUser: isUser)
            }
        }
    }
}

private struct ArtifactCard: View {
    let artifact: ChatArtifact
    let serverURL: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = subtitleText, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let link = resolvedURL {
                Link(destination: link) {
                    Text("Open")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var iconName: String {
        switch artifact.type.lowercased() {
        case "image":
            return "photo"
        case "code":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc"
        }
    }

    private var subtitleText: String? {
        artifact.path ?? artifact.url ?? artifact.mime
    }

    private var resolvedURL: URL? {
        if let raw = artifact.url, let parsed = URL(string: raw) {
            return parsed
        }
        if let path = artifact.path,
           let resolved = resolveImageURL(from: path, serverURL: serverURL),
           let url = URL(string: resolved) {
            return url
        }
        return nil
    }
}

private struct MessageSegment: Identifiable {
    enum Kind {
        case markdown
        case code
        case image(url: String)
        case section(title: String, body: String)
        case artifact(item: ChatArtifact)
        case agenda(items: [ChatAgendaItem])
    }

    let id = UUID()
    let kind: Kind
    let content: String
}

private func parseSegments(from text: String, serverURL: String, massageForDisplay: Bool = true) -> [MessageSegment] {
    var segments: [MessageSegment] = []

    if let envelope = parseChatEnvelope(from: text) {
        if !envelope.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(MessageSegment(kind: .markdown, content: envelope.summary))
        }
        for section in envelope.sections {
            segments.append(MessageSegment(kind: .section(title: section.title, body: section.body), content: section.body))
        }
        for artifact in envelope.artifacts {
            if artifact.type.lowercased() == "image",
               let raw = artifact.url ?? artifact.path,
               let url = resolveImageURL(from: raw, serverURL: serverURL) {
                segments.append(MessageSegment(kind: .image(url: url), content: url))
                continue
            }
            segments.append(MessageSegment(kind: .artifact(item: artifact), content: artifact.title))
        }
        if !envelope.agendaItems.isEmpty {
            segments.append(MessageSegment(kind: .agenda(items: envelope.agendaItems), content: "agenda"))
        }
        return segments
    }

    var remaining = massageForDisplay ? massageAssistantTextForDisplay(text) : text

    if let imageURL = extractImageURL(from: remaining, serverURL: serverURL) {
        remaining = removeImageMarkdown(from: remaining)
        segments.append(MessageSegment(kind: .image(url: imageURL), content: imageURL))
    }

    if let agendaItems = parseAgendaItems(from: remaining), !agendaItems.isEmpty {
        let agendaLines = remaining
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.range(of: #"^\s*-?\s*\d{2}:\d{2}\s*[\-–]\s*\d{2}:\d{2}\s*\|"#, options: .regularExpression) != nil }
        let nonAgenda = remaining
            .split(separator: "\n")
            .map(String.init)
            .filter { line in !agendaLines.contains(line) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !nonAgenda.isEmpty {
            segments.append(MessageSegment(kind: .markdown, content: nonAgenda))
        }
        segments.append(MessageSegment(kind: .agenda(items: agendaItems), content: "agenda"))
        return segments
    }

    var remainingSlice = remaining[...]

    while let open = remainingSlice.range(of: "```") {
        let before = String(remainingSlice[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !before.isEmpty {
            segments.append(MessageSegment(kind: .markdown, content: before))
        }

        let afterOpen = remainingSlice[open.upperBound...]
        guard let close = afterOpen.range(of: "```") else {
            let tail = String(remainingSlice).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                segments.append(MessageSegment(kind: .markdown, content: tail))
            }
            return segments
        }

        var code = String(afterOpen[..<close.lowerBound])
        if let firstNewline = code.firstIndex(of: "\n") {
            let firstLine = code[..<firstNewline]
            if !firstLine.contains(" ") && firstLine.count <= 20 {
                code = String(code[code.index(after: firstNewline)...])
            }
        }
        code = code.trimmingCharacters(in: .newlines)
        if !code.isEmpty {
            segments.append(MessageSegment(kind: .code, content: code))
        }

        remainingSlice = afterOpen[close.upperBound...]
    }

    let tail = String(remainingSlice).trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty {
        segments.append(MessageSegment(kind: .markdown, content: tail))
    }
    return segments
}

private func massageAssistantTextForDisplay(_ text: String) -> String {
    var out = text.replacingOccurrences(of: "\r\n", with: "\n")
    out = out.replacingOccurrences(of: "\r", with: "\n")
    out = out.replacingOccurrences(of: "\t", with: "    ")

    // Add separation between concatenated words like "hello.pyRan".
    out = out.replacingRegex(
        pattern: #"([a-z0-9\)\]])([A-Z])"#,
        with: "$1 $2"
    )
    out = out.replacingRegex(
        pattern: #"(\.[A-Za-z0-9_-]+)(Ran|Created|Result|Output|Verified)\b"#,
        with: "$1\n$2"
    )
    out = out.replacingRegex(
        pattern: #"([.!?])\s*(What I Did|Result|Next Step|Output)\b"#,
        with: "$1\n\n$2"
    )
    out = out.replacingRegex(
        pattern: #"(What I Did|Result|Next Step|Output)(?=[A-Z])"#,
        with: "$1\n"
    )
    out = out.replacingRegex(
        pattern: #"(?m)^## (What I Did|Result|Next Step|Output)([A-Z])"#,
        with: "## $1\n$2"
    )
    out = out.replacingRegex(
        pattern: #"(?m)^(What I Did|Result|Next Step|Output)([A-Z])"#,
        with: "$1\n$2"
    )

    // Normalize common section labels into markdown headings.
    out = out.replacingRegex(pattern: #"(?<!#\s)(What I Did|Result|Next Step|Output)\s*:?"#, with: "\n\n## $1\n")
    out = out.replacingRegex(pattern: #"\n{3,}"#, with: "\n\n")

    // If output is inline, render it as a code block for readability.
    out = out.replacingRegex(
        pattern: #"(?m)^## Output\s*\n+(.+)$"#,
        with: "## Output\n```text\n$1\n```"
    )
    out = out.replacingRegex(
        pattern: #"(?m)^Output:\s*(.+)$"#,
        with: "Output:\n```text\n$1\n```"
    )
    out = out.replacingRegex(
        pattern: #"(?m)^## Result\s*\n+Output:\s*(.+)$"#,
        with: "## Result\nOutput:\n```text\n$1\n```"
    )
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func parseChatEnvelope(from text: String) -> ChatEnvelope? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let direct = decodeChatEnvelopeJSON(trimmed) {
        return direct
    }
    if let unescaped = decodeJSONStringLiteral(trimmed),
       let fromLiteral = decodeChatEnvelopeJSON(unescaped) {
        return fromLiteral
    }

    if let start = trimmed.firstIndex(of: "{"),
       let end = trimmed.lastIndex(of: "}"),
       start < end {
        let rangeSlice = String(trimmed[start...end])
        if let embedded = decodeChatEnvelopeJSON(rangeSlice) {
            return embedded
        }
        if let unescaped = decodeJSONStringLiteral(rangeSlice),
           let embeddedLiteral = decodeChatEnvelopeJSON(unescaped) {
            return embeddedLiteral
        }
    }
    return nil
}

private func parseAgendaItems(from text: String) -> [ChatAgendaItem]? {
    let lines = text.split(separator: "\n").map(String.init)
    var items: [ChatAgendaItem] = []
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^-?\s*\d{2}:\d{2}\s*[\-–]\s*\d{2}:\d{2}\s*\|"#, options: .regularExpression) != nil else {
            continue
        }
        let stripped = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
        let parts = stripped.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 3 {
            let times = parts[0].split(whereSeparator: { $0 == "-" || $0 == "–" }).map { $0.trimmingCharacters(in: .whitespaces) }
            let start = times.first ?? ""
            let end = times.count > 1 ? times[1] : ""
            items.append(
                ChatAgendaItem(
                    start: start,
                    end: end,
                    title: parts[1],
                    calendar: parts[2],
                    location: parts.count > 3 ? parts[3] : nil
                )
            )
        }
    }
    return items.isEmpty ? nil : items
}

private struct AgendaCard: View {
    let items: [ChatAgendaItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(.subheadline.weight(.semibold))
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.start + "-" + item.end)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.body.weight(.medium))
                    Text(item.calendar + (item.location.map { " • \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

private struct RemoteImageView: View {
    let urlString: String

    var body: some View {
        if let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .failure:
                    Text("Image failed to load")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    ProgressView()
                }
            }
            .frame(maxHeight: 260)
        } else {
            Text("Invalid image URL")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private func extractImageURL(from text: String, serverURL: String) -> String? {
    let pattern = #"\!\[[^\]]*\]\(([^)]+)\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsRange = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    let raw = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    return resolveImageURL(from: raw, serverURL: serverURL)
}

private func removeImageMarkdown(from text: String) -> String {
    let pattern = #"\!\[[^\]]*\]\([^)]+\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func resolveImageURL(from raw: String, serverURL: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower.contains("path/to/") || lower.contains("absolute/path") {
        return nil
    }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        return trimmed
    }
    let imagePath = extractImagePath(from: trimmed)
    guard let encoded = imagePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
        return nil
    }
    let normalizedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return "\(normalizedServer)/v1/files?path=\(encoded)"
}

private func extractImagePath(from text: String) -> String {
    let stripped = text
        .trimmingCharacters(in: CharacterSet(charactersIn: "`'\" "))
        .replacingOccurrences(of: "file://", with: "")
    let lower = stripped.lowercased()
    let extensions = [".png", ".jpg", ".jpeg", ".gif", ".webp"]
    guard let ext = extensions.first(where: { lower.contains($0) }),
          let end = lower.range(of: ext)?.upperBound else {
        return stripped
    }
    let originalEnd = stripped.index(stripped.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: end))
    let prefix = stripped[..<originalEnd]
    if let startSlash = prefix.lastIndex(of: "/") {
        let candidate = stripped[startSlash..<originalEnd]
        return String(candidate)
    }
    return String(prefix)
}

private func decodeChatEnvelopeJSON(_ value: String) -> ChatEnvelope? {
    guard let data = value.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ChatEnvelope.self, from: data)
}

private func decodeJSONStringLiteral(_ value: String) -> String? {
    guard value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
    guard let data = value.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(String.self, from: data) else {
        return nil
    }
    return decoded
}

private extension String {
    func replacingRegex(
        pattern: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return self
        }
        let range = NSRange(startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: template)
    }
}
