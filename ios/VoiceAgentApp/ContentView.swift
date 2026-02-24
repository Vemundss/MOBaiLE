import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var vm = VoiceAgentViewModel()
    @State private var showConnectionSettings = false

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
                    Button("New Chat") {
                        vm.startNewChat()
                    }
                    .font(.subheadline.weight(.semibold))
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
                            Picker("Executor", selection: $vm.executor) {
                                Text("Local").tag("local")
                                Text("Codex").tag("codex")
                            }
                            .pickerStyle(.segmented)
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
            .onChange(of: vm.didCompleteRun) {
                if vm.didCompleteRun {
                    showConnectionSettings = false
                }
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
        parseSegments(from: message.text, serverURL: serverURL)
    }
}

private struct MarkdownText: View {
    let text: String
    let isUser: Bool

    var body: some View {
        if let rendered = try? AttributedString(markdown: text) {
            Text(rendered)
                .font(.body)
                .lineSpacing(1.5)
                .foregroundStyle(isUser ? Color.white : Color.primary)
        } else {
            Text(text)
                .font(.body)
                .lineSpacing(1.5)
                .foregroundStyle(isUser ? Color.white : Color.primary)
        }
    }
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
        .background(Color.black.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MessageSegment: Identifiable {
    enum Kind {
        case markdown
        case code
        case image(url: String)
    }

    let id = UUID()
    let kind: Kind
    let content: String
}

private func parseSegments(from text: String, serverURL: String) -> [MessageSegment] {
    var segments: [MessageSegment] = []
    var remaining = text

    if let imageURL = extractImageURL(from: remaining, serverURL: serverURL) {
        remaining = removeImageMarkdown(from: remaining)
        segments.append(MessageSegment(kind: .image(url: imageURL), content: imageURL))
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
    let lower = text.lowercased()
    let extensions = [".png", ".jpg", ".jpeg", ".gif", ".webp"]
    guard let ext = extensions.first(where: { lower.contains($0) }),
          let end = lower.range(of: ext)?.upperBound else {
        return text
    }
    let originalEnd = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: end))
    let prefix = text[..<originalEnd]
    if let startSlash = prefix.lastIndex(of: "/") {
        let candidate = text[startSlash..<originalEnd]
        return String(candidate)
    }
    return String(prefix)
}
