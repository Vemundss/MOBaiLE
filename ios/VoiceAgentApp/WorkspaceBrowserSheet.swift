import ImageIO
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UIKit

struct WorkspaceBrowserSheet: View {
    @ObservedObject var vm: VoiceAgentViewModel
    let runtimeDirectoryLabel: String
    let canUseBrowsedDirectory: Bool
    @Binding var newDirectoryName: String
    @Binding var isCreatingDirectory: Bool
    let onDismiss: () -> Void
    private let directoryBrowserPanelID = "workspace-directory-browser-panel"
    private let directoryDefaultAutoRefreshKey = "__workspace_browser_default__"
    private let maxPreviewFileBytes: Int64 = AttachmentDraftPolicy.defaultMaxAttachmentBytes
    @State private var openingFilePath: String?
    @State private var fileOpenError: String = ""
    @State private var previewDocument: PreviewDocument?
    @State private var textPreviewDocument: TextPreviewDocument?
    @State private var directoryFilterText = ""
    @State private var directorySortOrder: WorkspaceDirectorySortOrder = .name
    @FocusState private var isDirectoryFilterFocused: Bool
    @State private var thumbnailImages: [DirectoryThumbnailCacheKey: UIImage] = [:]
    @State private var thumbnailCacheOrder: [DirectoryThumbnailCacheKey] = []
    @State private var thumbnailLoadingKeys: Set<DirectoryThumbnailCacheKey> = []
    private let directoryAutoRefreshIntervalNanoseconds: UInt64 = 5_000_000_000
    private let maxDirectoryThumbnailCacheCount = 80
    private let maxDirectoryThumbnailBytes: Int64 = 5 * 1024 * 1024

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
                    directoryFilterText = ""
                    isDirectoryFilterFocused = false
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
            .task(id: directoryAutoRefreshKey) {
                await autoRefreshDirectoryBrowser(path: directoryAutoRefreshKey)
            }
            .alert("Open failed", isPresented: Binding(
                get: { !fileOpenError.isEmpty },
                set: { if !$0 { fileOpenError = "" } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(fileOpenError)
            }
            .sheet(item: $previewDocument) { preview in
                FilePreviewSheet(
                    url: preview.url,
                    title: preview.title,
                    originalPath: preview.originalPath,
                    metadataText: preview.metadataText
                )
            }
            .sheet(item: $textPreviewDocument) { preview in
                TextFilePreviewSheet(document: preview)
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
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(browsedDirectoryTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let context = browsedDirectoryContext {
                            Text(context)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

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
                                    Task { await openDirectoryFromBrowserControls(path: crumb.path) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                Button {
                    Task { await navigateDirectoryUpFromBrowserControls() }
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

            directoryListControls

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

    private var directoryFilterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Filter files", text: $directoryFilterText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote)
                .submitLabel(.search)
                .focused($isDirectoryFilterFocused)
                .disabled(vm.isLoadingDirectoryBrowser)

            if hasDirectoryFilter {
                Button {
                    directoryFilterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear folder filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !vm.isLoadingDirectoryBrowser else { return }
            isDirectoryFilterFocused = true
        }
    }

    private var directoryListControls: some View {
        HStack(spacing: 8) {
            directoryFilterField

            Menu {
                Picker("Sort files", selection: $directorySortOrder) {
                    ForEach(WorkspaceDirectorySortOrder.allCases) { order in
                        Label(order.title, systemImage: order.systemImage).tag(order)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.callout.weight(.semibold))
                    .frame(width: 44, height: 36)
            }
            .buttonStyle(.bordered)
            .disabled(vm.isLoadingDirectoryBrowser)
            .accessibilityLabel("Sort files")
            .accessibilityValue(directorySortOrder.title)
        }
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
                Task { await openDirectoryFromBrowserControls(path: selectedWorkspacePath) }
            }

            if !backendRootPath.isEmpty, backendRootPath != selectedWorkspacePath {
                workspacePathRow(
                    title: "Current root",
                    path: backendRootPath,
                    systemImage: "externaldrive.fill",
                    tint: .secondary,
                    actionTitle: "Go"
                ) {
                    Task { await openDirectoryFromBrowserControls(path: backendRootPath) }
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
                    Task { await openDirectoryFromBrowserControls(path: path) }
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

    private var browsedDirectoryTitle: String {
        shortPathLabel(browsedDirectoryLabel)
    }

    private var browsedDirectoryContext: String? {
        parentPathLabel(for: browsedDirectoryLabel)
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

    private func parentPathLabel(for path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return nil }

        let parent = URL(fileURLWithPath: trimmed).deletingLastPathComponent().path
        guard !parent.isEmpty, parent != trimmed, parent != "." else { return nil }
        return parent
    }

    @ViewBuilder
    private var directoryEntriesContent: some View {
        if vm.filteredDirectoryBrowserEntries.isEmpty {
            Text("Only hidden folders in this directory. Disable filter in Settings to view them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if displayedDirectoryEntries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No files match this filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear Filter") {
                    directoryFilterText = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        } else {
            LazyVStack(spacing: 8) {
                ForEach(displayedDirectoryEntries) { entry in
                    Button {
                        Task { await openDirectoryEntryOrPreviewFile(entry) }
                    } label: {
                        directoryEntryRow(entry)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isLoadingDirectoryBrowser || openingFilePath == entry.path)
                    .contextMenu {
                        directoryEntryCopyActions(entry)
                    }
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

    private var displayedDirectoryEntries: [DirectoryEntry] {
        let entries = vm.filteredDirectoryBrowserEntries
        let query = directoryFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredEntries = query.isEmpty ? entries : entries.filter { entry in
            entry.name.localizedCaseInsensitiveContains(query) ||
            (entry.mime ?? "").localizedCaseInsensitiveContains(query)
        }
        return filteredEntries.sorted { lhs, rhs in
            directorySortOrder.areInIncreasingOrder(lhs, rhs)
        }
    }

    private var hasDirectoryFilter: Bool {
        !directoryFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func directoryEntryRow(_ entry: DirectoryEntry) -> some View {
        HStack(spacing: 10) {
            directoryEntryLeadingView(entry)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(directoryEntryDetailText(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if openingFilePath == entry.path {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: entry.isDirectory ? "chevron.right" : "doc.text.magnifyingglass")
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
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(directoryEntryAccessibilityLabel(entry))
        .accessibilityIdentifier(entry.isDirectory ? "workspace.folder.\(entry.name)" : "workspace.file.\(entry.name)")
    }

    @ViewBuilder
    private func directoryEntryLeadingView(_ entry: DirectoryEntry) -> some View {
        let thumbnailKey = DirectoryThumbnailCacheKey(entry)
        if let image = thumbnailImages[thumbnailKey] {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        } else if thumbnailLoadingKeys.contains(thumbnailKey) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: directoryEntryIconName(entry))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(directoryEntryTint(entry))
                .frame(width: 32, height: 32)
                .task(id: thumbnailKey) {
                    await loadDirectoryThumbnailIfNeeded(entry)
                }
        }
    }

    @MainActor
    private func loadDirectoryThumbnailIfNeeded(_ entry: DirectoryEntry) async {
        let thumbnailKey = DirectoryThumbnailCacheKey(entry)
        guard !entry.isDirectory,
              canRenderDirectoryThumbnail(entry),
              shouldLoadDirectoryThumbnail(entry),
              thumbnailImages[thumbnailKey] == nil,
              !thumbnailLoadingKeys.contains(thumbnailKey) else {
            return
        }
        thumbnailLoadingKeys.insert(thumbnailKey)
        defer { thumbnailLoadingKeys.remove(thumbnailKey) }
        do {
            let localURL = try await vm.downloadDirectoryFileForPreview(
                entry,
                cacheVersion: entry.previewCacheVersion
            )
            if let image = await DirectoryFileThumbnailRenderer.thumbnail(from: localURL, maxPointSize: 32) {
                storeDirectoryThumbnail(image, for: thumbnailKey)
            }
        } catch {
            return
        }
    }

    @MainActor
    private func storeDirectoryThumbnail(_ image: UIImage, for thumbnailKey: DirectoryThumbnailCacheKey) {
        thumbnailImages = thumbnailImages.filter { $0.key.path != thumbnailKey.path }
        thumbnailImages[thumbnailKey] = image
        thumbnailCacheOrder.removeAll { $0.path == thumbnailKey.path || $0 == thumbnailKey }
        thumbnailCacheOrder.append(thumbnailKey)

        while thumbnailCacheOrder.count > maxDirectoryThumbnailCacheCount {
            let evictedKey = thumbnailCacheOrder.removeFirst()
            thumbnailImages.removeValue(forKey: evictedKey)
        }
    }

    @ViewBuilder
    private func directoryEntryCopyActions(_ entry: DirectoryEntry) -> some View {
        Button {
            UIPasteboard.general.string = entry.path
        } label: {
            Label(entry.isDirectory ? "Copy Folder Path" : "Copy File Path", systemImage: "doc.on.doc")
        }

        Button {
            UIPasteboard.general.string = entry.name
        } label: {
            Label(entry.isDirectory ? "Copy Folder Name" : "Copy File Name", systemImage: "textformat")
        }
    }

    private var directoryAutoRefreshKey: String {
        let path = vm.directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? directoryDefaultAutoRefreshKey : path
    }

    @MainActor
    private func autoRefreshDirectoryBrowser(path: String) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: directoryAutoRefreshIntervalNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  shouldAutoRefreshDirectoryBrowser(path: path) else {
                continue
            }
            let refreshPath = path == directoryDefaultAutoRefreshKey ? nil : path
            await vm.refreshDirectoryBrowser(path: refreshPath, presentation: .background)
        }
    }

    @MainActor
    private func shouldAutoRefreshDirectoryBrowser(path: String) -> Bool {
        PreviewScenario.current == nil &&
        directoryAutoRefreshKey == path &&
        !vm.isLoadingDirectoryBrowser &&
        openingFilePath == nil &&
        previewDocument == nil &&
        textPreviewDocument == nil
    }

    @MainActor
    private func openDirectoryEntryOrPreviewFile(_ entry: DirectoryEntry) async {
        dismissCreateDirectoryEditor()
        if entry.isDirectory {
            await vm.openDirectoryEntry(entry)
            return
        }
        openingFilePath = entry.path
        defer { openingFilePath = nil }

        do {
            let inspection = try? await vm.inspectDirectoryFileForPreview(entry)
            if let blockedReason = inspection?.previewBlockedReason {
                fileOpenError = textPreviewBlockedMessage(for: blockedReason)
                return
            }
            let previewSource = textPreviewSource(for: entry)
            if let inspection, let text = inspection.textPreview {
                let previewURL = try await TextPreviewLoader.writePreviewTextToTemporaryFile(
                    title: entry.name,
                    text: text
                )
                textPreviewDocument = TextPreviewDocument(
                    url: previewURL,
                    title: entry.name,
                    text: text,
                    isTruncated: inspection.textPreviewTruncated,
                    sizeBytes: inspection.sizeBytes,
                    modifiedAt: inspection.modifiedAt,
                    previewOffset: inspection.textPreviewOffset,
                    nextOffset: inspection.textPreviewNextOffset,
                    previewBlockedReason: inspection.previewBlockedReason,
                    searchMatches: inspection.textSearchMatches,
                    searchMatchCount: inspection.textSearchMatchCount,
                    language: FilePreviewLanguage.infer(fileName: entry.name, mime: inspection.mime ?? entry.mime),
                    source: previewSource,
                    originalPath: inspection.path
                )
                return
            }

            let size = inspection?.sizeBytes ?? entry.sizeBytes
            if let size, size > maxPreviewFileBytes {
                fileOpenError = "\(entry.name) is \(humanReadableAttachmentSize(size)). Preview files must be \(humanReadableAttachmentSize(maxPreviewFileBytes)) or smaller."
                return
            }

            let cacheVersion = inspection?.previewCacheVersion ?? entry.previewCacheVersion
            let localURL = try await vm.downloadDirectoryFileForPreview(entry, cacheVersion: cacheVersion)
            if TextPreviewLoader.canPreview(fileName: localURL.lastPathComponent, mimeType: entry.mime) {
                do {
                    let text = try await TextPreviewLoader.loadText(from: localURL)
                    textPreviewDocument = TextPreviewDocument(
                        url: localURL,
                        title: entry.name,
                        text: text,
                        sizeBytes: size,
                        modifiedAt: inspection?.modifiedAt ?? entry.modifiedAt,
                        language: FilePreviewLanguage.infer(fileName: entry.name, mime: inspection?.mime ?? entry.mime),
                        source: previewSource,
                        originalPath: inspection?.path ?? entry.path
                    )
                    return
                } catch TextPreviewError.tooLarge {
                    // Let Quick Look handle larger text files when iOS supports the format.
                } catch {
                    if !QLPreviewController.canPreview(localURL as NSURL) {
                        throw error
                    }
                }
            }
            let resolvedMime = inspection?.mime ?? entry.mime
            if FilePreviewUnsupportedMessage.prefersInlineUnsupportedMessage(
                fileName: entry.name,
                mime: resolvedMime
            ) {
                fileOpenError = FilePreviewUnsupportedMessage.message(
                    fileName: entry.name,
                    mime: resolvedMime,
                    sizeBytes: inspection?.sizeBytes ?? entry.sizeBytes
                )
                return
            }
            if QLPreviewController.canPreview(localURL as NSURL) {
                previewDocument = PreviewDocument(
                    url: localURL,
                    title: entry.name,
                    originalPath: inspection?.path ?? entry.path,
                    metadataText: FileMetadataFormatter.previewMetadataText(
                        sizeBytes: inspection?.sizeBytes ?? entry.sizeBytes,
                        modifiedAt: inspection?.modifiedAt ?? entry.modifiedAt,
                        imageWidth: inspection?.imageWidth,
                        imageHeight: inspection?.imageHeight,
                        mime: inspection?.mime ?? entry.mime
                    )
                )
            } else {
                fileOpenError = FilePreviewUnsupportedMessage.message(
                    fileName: entry.name,
                    mime: inspection?.mime ?? entry.mime,
                    sizeBytes: inspection?.sizeBytes ?? entry.sizeBytes
                )
            }
        } catch {
            fileOpenError = FilePreviewOpenErrorMessage.message(error, fileName: entry.name)
        }
    }

    private func textPreviewSource(for entry: DirectoryEntry) -> TextPreviewSource? {
        guard !entry.isDirectory else { return nil }
        if PreviewScenario.current != nil, FileManager.default.fileExists(atPath: entry.path) {
            return nil
        }
        let serverURL = vm.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = vm.apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty, !token.isEmpty else { return nil }
        return TextPreviewSource(
            serverURL: serverURL,
            token: token,
            artifact: ChatArtifact(
                type: VoiceAgentDirectoryBrowser.artifactType(for: entry),
                title: entry.name,
                path: entry.path,
                mime: entry.mime,
                url: nil
            )
        )
    }

    private func textPreviewBlockedMessage(for reason: String) -> String {
        if reason == "sensitive_path" {
            return "Text preview is blocked for sensitive paths on the host."
        }
        return "Text preview is blocked for this file."
    }

    @MainActor
    private func openDirectoryFromBrowserControls(path: String) async {
        dismissCreateDirectoryEditor()
        await vm.openDirectory(path: path)
    }

    @MainActor
    private func navigateDirectoryUpFromBrowserControls() async {
        dismissCreateDirectoryEditor()
        await vm.navigateDirectoryUp()
    }

    @MainActor
    private func dismissCreateDirectoryEditor() {
        guard isCreatingDirectory || !newDirectoryName.isEmpty else { return }
        isCreatingDirectory = false
        newDirectoryName = ""
    }

    private func directoryEntryIconName(_ entry: DirectoryEntry) -> String {
        guard !entry.isDirectory else { return "folder.fill" }
        let lowerMime = (entry.mime ?? "").lowercased()
        if lowerMime.hasPrefix("image/") {
            return "photo"
        }
        if lowerMime.contains("pdf") {
            return "doc.richtext"
        }
        switch VoiceAgentDirectoryBrowser.artifactType(for: entry) {
        case "image":
            return "photo"
        case "code":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc.text"
        }
    }

    private func isImageEntry(_ entry: DirectoryEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        let lowerMime = (entry.mime ?? "").lowercased()
        return lowerMime.hasPrefix("image/") || VoiceAgentDirectoryBrowser.artifactType(for: entry) == "image"
    }

    private func isPDFEntry(_ entry: DirectoryEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        let lowerMime = (entry.mime ?? "").lowercased()
        return lowerMime.contains("pdf") || URL(fileURLWithPath: entry.name).pathExtension.lowercased() == "pdf"
    }

    private func canRenderDirectoryThumbnail(_ entry: DirectoryEntry) -> Bool {
        isImageEntry(entry) || isPDFEntry(entry)
    }

    private func shouldLoadDirectoryThumbnail(_ entry: DirectoryEntry) -> Bool {
        if let sizeBytes = entry.sizeBytes {
            return sizeBytes <= maxDirectoryThumbnailBytes
        }
        return PreviewScenario.current != nil
    }

    private func directoryEntryTint(_ entry: DirectoryEntry) -> Color {
        guard !entry.isDirectory else { return .blue }
        switch VoiceAgentDirectoryBrowser.artifactType(for: entry) {
        case "image":
            return .purple
        case "code":
            return .green
        default:
            return .secondary
        }
    }

    private func directoryEntryDetailText(_ entry: DirectoryEntry) -> String {
        guard !entry.isDirectory else { return "Folder" }
        var parts = [directoryEntryKindLabel(entry)]
        if let size = entry.sizeBytes {
            parts.append(humanReadableAttachmentSize(size))
        }
        if let modified = FileMetadataFormatter.modifiedShortLabel(entry.modifiedAt) {
            parts.append(modified)
        }
        if let mime = entry.mime?.trimmingCharacters(in: .whitespacesAndNewlines), !mime.isEmpty {
            parts.append(mime)
        }
        return parts.joined(separator: " · ")
    }

    private func directoryEntryKindLabel(_ entry: DirectoryEntry) -> String {
        let lowerMime = (entry.mime ?? "").lowercased()
        if lowerMime.hasPrefix("image/") {
            return "Image"
        }
        if lowerMime.contains("pdf") {
            return "PDF"
        }
        if lowerMime.contains("zip") {
            return "Archive"
        }
        switch VoiceAgentDirectoryBrowser.artifactType(for: entry) {
        case "image":
            return "Image"
        case "code":
            return "Text/code"
        default:
            return "File"
        }
    }

    private func directoryEntryAccessibilityLabel(_ entry: DirectoryEntry) -> String {
        if entry.isDirectory {
            return "Open folder \(entry.name)"
        }
        return "Preview file \(entry.name), \(directoryEntryDetailText(entry))"
    }
}

private enum WorkspaceDirectorySortOrder: String, CaseIterable, Identifiable {
    case name
    case modified
    case type
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:
            return "Name"
        case .modified:
            return "Modified"
        case .type:
            return "Type"
        case .size:
            return "Size"
        }
    }

    var systemImage: String {
        switch self {
        case .name:
            return "textformat"
        case .modified:
            return "calendar"
        case .type:
            return "doc.on.doc"
        case .size:
            return "arrow.up.left.and.arrow.down.right"
        }
    }

    func areInIncreasingOrder(_ lhs: DirectoryEntry, _ rhs: DirectoryEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory && !rhs.isDirectory
        }

        switch self {
        case .name:
            return nameCompare(lhs, rhs)
        case .modified:
            return compareOptionalStrings(lhs.modifiedAt, rhs.modifiedAt, descending: true) ?? nameCompare(lhs, rhs)
        case .type:
            let lhsType = directoryTypeKey(lhs)
            let rhsType = directoryTypeKey(rhs)
            if lhsType != rhsType {
                return lhsType.localizedCaseInsensitiveCompare(rhsType) == .orderedAscending
            }
            return nameCompare(lhs, rhs)
        case .size:
            return compareOptionalInts(lhs.sizeBytes, rhs.sizeBytes, descending: true) ?? nameCompare(lhs, rhs)
        }
    }

    private func nameCompare(_ lhs: DirectoryEntry, _ rhs: DirectoryEntry) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func directoryTypeKey(_ entry: DirectoryEntry) -> String {
        if entry.isDirectory {
            return "0-folder"
        }
        let mime = entry.mime?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mime, !mime.isEmpty {
            return mime
        }
        return URL(fileURLWithPath: entry.name).pathExtension.lowercased()
    }

    private func compareOptionalStrings(_ lhs: String?, _ rhs: String?, descending: Bool) -> Bool? {
        let lhsValue = lhs?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsValue = rhs?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (lhsValue?.isEmpty == false ? lhsValue : nil, rhsValue?.isEmpty == false ? rhsValue : nil) {
        case let (left?, right?) where left != right:
            return descending ? left > right : left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return nil
        }
    }

    private func compareOptionalInts(_ lhs: Int64?, _ rhs: Int64?, descending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case let (left?, right?) where left != right:
            return descending ? left > right : left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return nil
        }
    }
}

private struct DirectoryThumbnailCacheKey: Hashable {
    let path: String
    let version: String?

    init(_ entry: DirectoryEntry) {
        path = entry.path
        version = entry.previewCacheVersion
    }
}

private enum DirectoryFileThumbnailRenderer {
    static func thumbnail(from url: URL, maxPointSize: CGFloat) async -> UIImage? {
        let scale = await MainActor.run { UIScreen.main.scale }
        let pixelSize = max(1, Int(maxPointSize * scale))
        if url.pathExtension.lowercased() == "pdf",
           let thumbnail = await quickLookThumbnail(from: url, pointSize: CGSize(width: maxPointSize, height: maxPointSize), scale: scale) {
            return thumbnail
        }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else {
                return nil
            }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                return nil
            }
            return UIImage(cgImage: image)
        }.value
    }

    private static func quickLookThumbnail(from url: URL, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: pointSize,
                scale: scale,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.uiImage)
            }
        }
    }
}
