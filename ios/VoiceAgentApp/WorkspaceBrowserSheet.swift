import SwiftUI

struct WorkspaceBrowserSheet: View {
    @ObservedObject var vm: VoiceAgentViewModel
    let runtimeDirectoryLabel: String
    let canUseBrowsedDirectory: Bool
    @Binding var newDirectoryName: String
    @Binding var isCreatingDirectory: Bool
    let onDismiss: () -> Void
    private let directoryBrowserPanelID = "workspace-directory-browser-panel"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        directoryBrowserPanel
                            .id(directoryBrowserPanelID)
                        workspaceSummaryPanel
                        if !recentWorkspacePaths.isEmpty {
                            recentWorkspacesPanel
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: vm.directoryBrowserPath) {
                    scrollToDirectoryBrowser(using: proxy)
                }
            }
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
            .task {
                if vm.directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   vm.directoryBrowserEntries.isEmpty,
                   !vm.isLoadingDirectoryBrowser {
                    await vm.refreshDirectoryBrowser()
                }
            }
        }
    }

    private func scrollToDirectoryBrowser(using proxy: ScrollViewProxy) {
        guard !vm.directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(directoryBrowserPanelID, anchor: .top)
        }
    }

    private var directoryBrowserPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Browsing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(browsedDirectoryLabel)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                if canUseBrowsedDirectory {
                    Button {
                        Task { await vm.useCurrentBrowserDirectoryAsWorkingDirectory() }
                    } label: {
                        Label("Use for Future Runs", systemImage: "checkmark.circle")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(vm.isLoadingDirectoryBrowser)
                    .accessibilityLabel("Use for Future Runs")
                } else {
                    selectedWorkspaceBadge
                }
            }

            Text(useFolderHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var selectedWorkspaceBadge: some View {
        Label("Selected for future runs", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.green.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.green.opacity(0.14), lineWidth: 1)
            )
            .accessibilityLabel("Selected for future runs")
    }

    private var workspaceSummaryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Future runs")
                        .font(.subheadline.weight(.semibold))
                    Text("New prompts in this session will run from the selected workspace unless you change it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            workspacePathRow(
                title: "Selected workspace",
                path: selectedWorkspacePath,
                systemImage: "checkmark.circle.fill",
                tint: .green,
                actionTitle: "Show"
            ) {
                Task { await vm.openDirectory(path: selectedWorkspacePath) }
            }

            if !backendRootPath.isEmpty, backendRootPath != selectedWorkspacePath {
                workspacePathRow(
                    title: "Current root",
                    path: backendRootPath,
                    systemImage: "externaldrive.fill",
                    tint: .secondary,
                    actionTitle: "Go"
                ) {
                    Task { await vm.openDirectory(path: backendRootPath) }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recentWorkspacesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recent workspaces", systemImage: "clock.arrow.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(recentWorkspacePaths, id: \.self) { path in
                workspacePathRow(
                    title: path == selectedWorkspacePath ? "Selected recently" : shortPathLabel(path),
                    path: path,
                    systemImage: path == selectedWorkspacePath ? "checkmark.circle.fill" : "folder.fill",
                    tint: path == selectedWorkspacePath ? .green : .blue,
                    actionTitle: "Open"
                ) {
                    Task { await vm.openDirectory(path: path) }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func workspacePathRow(
        title: String,
        path: String,
        systemImage: String,
        tint: Color,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: action) {
                    Image(systemName: "arrow.forward.circle")
                        .imageScale(.medium)
                        .frame(width: 34, height: 34)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(actionTitle)
            }
            Text(path)
                .font(.footnote.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
        }
        .padding(.vertical, 7)
    }

    private var browsedDirectoryLabel: String {
        let browsed = vm.directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return browsed.isEmpty ? runtimeDirectoryLabel : browsed
    }

    private var selectedWorkspacePath: String {
        let selected = runtimeDirectoryLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? "~" : selected
    }

    private var backendRootPath: String {
        vm.backendWorkdirRoot.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var useFolderHint: String {
        guard !vm.directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Open a folder to choose where future runs will work."
        }
        if canUseBrowsedDirectory {
            return "Tap Use for Future Runs to make this folder the workspace for new prompts in this session."
        }
        return "This folder is already the workspace for new prompts in this session."
    }

    private var recentWorkspacePaths: [String] {
        var seen = Set<String>()
        let paths = vm.threads
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { $0.resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return paths.compactMap { path in
            guard path != backendRootPath, !seen.contains(path) else { return nil }
            seen.insert(path)
            return path
        }
        .prefix(4)
        .map { $0 }
    }

    private func shortPathLabel(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Workspace" }
        if trimmed == "/" { return "/" }
        let url = URL(fileURLWithPath: trimmed)
        let last = url.lastPathComponent
        guard !last.isEmpty else { return trimmed }
        return last
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
}
