import SwiftUI

struct ContentView: View {
    @StateObject private var vm = VoiceAgentViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connection")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Server URL", text: $vm.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline.monospaced())
                    SecureField("API Token", text: $vm.apiToken)
                        .font(.subheadline.monospaced())
                    TextField("Session ID", text: $vm.sessionID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline.monospaced())
                    TextField("Working directory (e.g. ~ or /Users/...)", text: $vm.workingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline.monospaced())
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(spacing: 8) {
                    HStack {
                        Picker("Executor", selection: $vm.executor) {
                            Text("Local").tag("local")
                            Text("Codex").tag("codex")
                        }
                        .pickerStyle(.segmented)
                    }

                    TextEditor(text: $vm.promptText)
                        .frame(minHeight: 72, maxHeight: 120)
                        .padding(6)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 8) {
                        Button(vm.isLoading ? "Running..." : "Send") {
                            Task { await vm.sendPrompt() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isLoading || vm.apiToken.isEmpty || vm.serverURL.isEmpty || vm.promptText.isEmpty)

                        Button(vm.isRecording ? "Recording..." : "Record") {
                            Task { await vm.startRecording() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.isLoading || vm.isRecording || vm.apiToken.isEmpty || vm.serverURL.isEmpty)

                        Button("Stop + Send") {
                            Task { await vm.stopRecordingAndSend() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.isLoading || !vm.isRecording || vm.apiToken.isEmpty || vm.serverURL.isEmpty)
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    if !vm.runID.isEmpty {
                        Text("Run ID: \(vm.runID)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Text(vm.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !vm.resolvedWorkingDirectory.isEmpty {
                        Text("Working dir: \(vm.resolvedWorkingDirectory)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if !vm.summaryText.isEmpty {
                        Text(vm.summaryText)
                            .font(.subheadline.weight(.semibold))
                    }
                    if !vm.transcriptText.isEmpty {
                        Text("Transcript: \(vm.transcriptText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !vm.errorText.isEmpty {
                        Text(vm.errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        if vm.events.isEmpty {
                            Text("No events yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(vm.events.indices, id: \.self) { idx in
                                let event = vm.events[idx]
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.type)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(event.message)
                                        .font(.body)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .padding()
            .navigationTitle("Voice Agent MVP")
        }
    }
}

#Preview {
    ContentView()
}
