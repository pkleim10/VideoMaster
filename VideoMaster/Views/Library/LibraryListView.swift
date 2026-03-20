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
        for delay in [0.05, 0.2, 0.5, 0.9, 1.5] {
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

    /// Prefer the table with the most rows (video list) over sidebar/collections.
    private static func findTableView(in view: NSView) -> NSTableView? {
        var best: NSTableView?
        var bestRows = 0
        func search(_ v: NSView) {
            if let tv = v as? NSTableView, tv.numberOfRows > bestRows {
                best = tv
                bestRows = tv.numberOfRows
            }
            for sub in v.subviews { search(sub) }
        }
        search(view)
        return best
    }
}

struct LibraryListView: View {
    @Bindable var viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService
    @Binding var scrollPositionRow: Int?

    @State private var filmstripVideo: Video?
    @FocusState private var isRenameFocused: Bool
    @State private var scrollToRow: Int?
    @State private var thumbnailPopoverVideoId: String?

    var body: some View {
        Table(
            viewModel.filteredVideos,
            selection: $viewModel.selectedVideoIds,
            sortOrder: $viewModel.tableSortOrder,
            columnCustomization: $viewModel.columnCustomization
        ) {
            TableColumn("Name", value: \.fileName) { video in
                HStack(spacing: 8) {
                    AsyncThumbnailView(
                        filePath: video.filePath, thumbnailService: thumbnailService
                    )
                    .frame(width: 56, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onHover { hovering in
                        thumbnailPopoverVideoId = hovering ? video.id : nil
                    }
                    .popover(
                        isPresented: Binding(
                            get: { thumbnailPopoverVideoId == video.id },
                            set: { if !$0 { thumbnailPopoverVideoId = nil } }
                        ),
                        arrowEdge: .trailing
                    ) {
                        AsyncThumbnailView(
                            filePath: video.filePath, thumbnailService: thumbnailService
                        )
                        .frame(width: 224, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

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
            } else if let row = scrollPositionRow, row >= 0, row < viewModel.filteredVideos.count {
                scrollToRow(withId: viewModel.filteredVideos[row].id, delay: 0.2)
            }
        }
        .onChange(of: viewModel.scrollToVideoId, initial: true) { _, targetId in
            guard let id = targetId else { return }
            viewModel.scrollToVideoId = nil
            // Table may not have laid out yet after version bump; retry with increasing delays
            for delay in [0.05, 0.15, 0.35] as [Double] {
                scrollToRow(withId: id, delay: delay)
            }
        }
        .contextMenu(forSelectionType: Video.ID.self) { ids in
            if let filePath = ids.first,
               let video = viewModel.filteredVideos.first(where: { $0.id == filePath })
            {
                Button("Play in External Player") {
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
                if ids.count == 1 {
                    Button("Rename") {
                        viewModel.renameText = video.fileName
                        viewModel.renamingVideoId = video.id
                    }
                }
                Divider()
                Button("Modify Filmstrip\u{2026}") {
                    filmstripVideo = video
                }
                Divider()
                Button("Remove from Library") {
                    Task { await viewModel.removeVideosFromLibrary(ids) }
                }
                Button("Delete Video…", role: .destructive) {
                    if viewModel.confirmDeletions {
                        viewModel.pendingDeleteIds = ids
                        viewModel.showDeleteConfirmation = true
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
                thumbnailService: thumbnailService,
                defaultRows: viewModel.defaultFilmstripRows,
                defaultColumns: viewModel.defaultFilmstripColumns
            ) { _ in
                viewModel.filmstripRefreshId &+= 1
            }
        }
        .confirmationDialog(
            "Delete \(viewModel.pendingDeleteIds.count == 1 ? "Video" : "\(viewModel.pendingDeleteIds.count) Videos")",
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = viewModel.pendingDeleteIds
                viewModel.pendingDeleteIds = []
                Task { await viewModel.deleteVideos(ids) }
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteIds = []
            }
        } message: {
            if viewModel.pendingDeleteIds.count == 1 {
                Text("The file will be moved to Trash.")
            } else {
                Text("\(viewModel.pendingDeleteIds.count) files will be moved to Trash.")
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
            _ = await viewModel.renameVideo(video, to: newName)
            viewModel.renameText = ""
        }
    }

    private func cancelRename() {
        viewModel.renamingVideoId = nil
        viewModel.renameText = ""
    }

    private func scrollToSelectedRow(delay: Double) {
        guard let selectedId = viewModel.selectedVideoIds.first,
              let row = viewModel.filteredVideos.firstIndex(where: { $0.id == selectedId })
        else { return }
        scrollPositionRow = row
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
