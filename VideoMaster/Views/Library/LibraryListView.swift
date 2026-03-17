import SwiftUI
import AppKit

struct TableScrollHelper: NSViewRepresentable {
    let scrollToRow: Int?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let row = scrollToRow, row >= 0 else { return }
        guard let window = nsView.window,
              let tableView = Self.findTableView(in: window.contentView!) else { return }
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.centerRow(row, in: tableView)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            window.makeFirstResponder(tableView)
        }
    }

    private static func centerRow(_ row: Int, in tableView: NSTableView) {
        guard row >= 0, row < tableView.numberOfRows,
              let scrollView = tableView.enclosingScrollView else { return }
        tableView.layoutSubtreeIfNeeded()
        let rowRect = tableView.rect(ofRow: row)
        let visibleHeight = scrollView.documentVisibleRect.height
        let targetY = rowRect.midY - visibleHeight / 2
        let maxY = max(0, tableView.frame.height - visibleHeight)
        let clampedY = max(0, min(targetY, maxY))
        scrollView.documentView?.scroll(NSPoint(x: 0, y: clampedY))
    }

    private static func findTableView(in view: NSView) -> NSTableView? {
        if let tv = view as? NSTableView {
            return tv
        }
        for subview in view.subviews {
            if let tv = findTableView(in: subview) {
                return tv
            }
        }
        return nil
    }
}

struct LibraryListView: View {
    @Bindable var viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService

    @State private var filmstripVideo: Video?
    @State private var pendingDeleteIds: Set<String> = []
    @State private var showDeleteConfirmation = false
    @FocusState private var isRenameFocused: Bool
    @State private var scrollToRow: Int?

    var body: some View {
        Table(
            viewModel.filteredVideos,
            selection: $viewModel.selectedVideoIds,
            sortOrder: Binding<[KeyPathComparator<Video>]>(
                get: { viewModel.tableSortOrder },
                set: { newValue in
                    let oldSort = VideoSort.from(keyPath: viewModel.tableSortOrder.first?.keyPath ?? \Video.dateAdded)
                    let newSort = VideoSort.from(keyPath: newValue.first?.keyPath ?? \Video.dateAdded)
                    let resolved: [KeyPathComparator<Video>]
                    if oldSort != newSort {
                        resolved = newSort.comparators(ascending: true)
                    } else {
                        resolved = newValue
                    }
                    withAnimation(nil) {
                        viewModel.tableSortOrder = resolved
                    }
                    viewModel.savePreferences()
                }
            ),
            columnCustomization: $viewModel.columnCustomization
        ) {
            TableColumn("Name", value: \.fileName) { video in
                HStack(spacing: 8) {
                    AsyncThumbnailView(
                        filePath: video.filePath, thumbnailService: thumbnailService
                    )
                    .frame(width: 56, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    if viewModel.renamingVideoId == video.id {
                        TextField("", text: $viewModel.renameText)
                            .textFieldStyle(.plain)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.accentColor, lineWidth: 2)
                            )
                            .focused($isRenameFocused)
                            .onSubmit { commitRename(video) }
                            .onExitCommand { cancelRename() }
                            .onAppear {
                                viewModel.isEditingText = true
                                DispatchQueue.main.async {
                                    isRenameFocused = true
                                }
                            }
                            .onDisappear {
                                viewModel.isEditingText = false
                            }
                    } else {
                        Text(video.fileName)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 200, ideal: 350)
            .customizationID("name")

            TableColumn("Duration", value: \.sortableDuration) { video in
                Text(video.formattedDuration ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            .customizationID("duration")

            TableColumn("Resolution", value: \.sortablePixelCount) { video in
                if let label = video.resolutionLabel {
                    Text(label)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 60, ideal: 80)
            .customizationID("resolution")

            TableColumn("Size", value: \.fileSize) { video in
                Text(video.formattedFileSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            .customizationID("size")

            TableColumn("Rating", value: \.rating) { video in
                RatingView(rating: video.rating, size: 10) { newRating in
                    viewModel.applyRating(to: [video.id], rating: newRating)
                    Task { await viewModel.persistRating(for: [video.id], rating: newRating) }
                }
            }
            .width(min: 70, ideal: 90)
            .customizationID("rating")

            TableColumn("Date Added", value: \.dateAdded) { video in
                Text(video.dateAdded, format: .dateTime.month(.twoDigits).day(.twoDigits).year())
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
            .customizationID("dateAdded")
        }
        .id(viewModel.filteredVideosVersion)
        .background(TableScrollHelper(scrollToRow: scrollToRow))
        .onAppear {
            if viewModel.scrollToSelectedOnViewSwitch {
                viewModel.scrollToSelectedOnViewSwitch = false
                scrollToSelectedRow(delay: 0.3)
            }
        }
        .onChange(of: viewModel.scrollToVideoId) { _, targetId in
            guard let id = targetId else { return }
            viewModel.scrollToVideoId = nil
            scrollToRow(withId: id, delay: 0.2)
        }
        .contextMenu(forSelectionType: Video.ID.self) { ids in
            if let filePath = ids.first,
               let video = viewModel.filteredVideos.first(where: { $0.id == filePath })
            {
                Button("Play") {
                    NSWorkspace.shared.open(video.url)
                    Task { await viewModel.recordPlay(for: video) }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(
                        video.filePath, inFileViewerRootedAtPath: ""
                    )
                }
                Menu("Open With") {
                    let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: video.url)
                    ForEach(appURLs, id: \.self) { appURL in
                        Button(appURL.deletingPathExtension().lastPathComponent) {
                            NSWorkspace.shared.open(
                                [video.url],
                                withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()
                            )
                            Task { await viewModel.recordPlay(for: video) }
                        }
                    }
                }
                Divider()
                Button("Modify Filmstrip...") {
                    filmstripVideo = video
                }
                Divider()
                Button("Delete File", role: .destructive) {
                    if viewModel.confirmDeletions {
                        pendingDeleteIds = ids
                        showDeleteConfirmation = true
                    } else {
                        Task { await viewModel.deleteVideos(ids) }
                    }
                }
            }
        } primaryAction: { ids in
            if let filePath = ids.first,
               let video = viewModel.filteredVideos.first(where: { $0.id == filePath })
            {
                NSWorkspace.shared.open(video.url)
                Task { await viewModel.recordPlay(for: video) }
            }
        }
        .sheet(item: $filmstripVideo) { video in
            FilmstripConfigView(
                video: video,
                thumbnailService: thumbnailService
            ) { _ in
                viewModel.filmstripRefreshId &+= 1
            }
        }
        .confirmationDialog(
            "Delete \(pendingDeleteIds.count == 1 ? "File" : "\(pendingDeleteIds.count) Files")",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = pendingDeleteIds
                pendingDeleteIds = []
                Task { await viewModel.deleteVideos(ids) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteIds = []
            }
        } message: {
            if pendingDeleteIds.count == 1 {
                Text("This will permanently delete the file from disk. This action cannot be undone.")
            } else {
                Text("This will permanently delete \(pendingDeleteIds.count) files from disk. This action cannot be undone.")
            }
        }
    }

    private func commitRename(_ video: Video) {
        let newName = viewModel.renameText.trimmingCharacters(in: .whitespaces)
        viewModel.renamingVideoId = nil
        guard !newName.isEmpty, newName != video.fileName else {
            viewModel.renameText = ""
            return
        }
        Task {
            if let newPath = await viewModel.renameVideo(video, to: newName),
               viewModel.isSortedByName
            {
                scrollToRow(withId: newPath, delay: 0.3)
            }
            viewModel.renameText = ""
        }
    }

    private func cancelRename() {
        viewModel.renamingVideoId = nil
        viewModel.renameText = ""
    }

    private func scrollToSelectedRow(delay: Double) {
        guard let selectedId = viewModel.selectedVideoIds.first else { return }
        scrollToRow(withId: selectedId, delay: delay)
    }

    private func scrollToRow(withId id: String, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let row = viewModel.filteredVideos.firstIndex(where: { $0.id == id }) {
                scrollToRow = nil
                DispatchQueue.main.async {
                    scrollToRow = row
                }
            }
        }
    }
}
