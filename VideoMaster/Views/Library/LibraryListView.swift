import SwiftUI
import AppKit

struct TableScrollHelper: NSViewRepresentable {
    let scrollToRow: Int?

    final class Coordinator: NSObject {
        /// Bumped whenever a new scroll is scheduled so stale delayed work (e.g. after deletes / table rebuild)
        /// cannot run — avoids EXC_BAD_ACCESS in SwiftUI’s AppKitOutlineTableCoordinator during scroll/layout races.
        var generation: UInt64 = 0
        var pending: [DispatchWorkItem] = []

        func cancelPending() {
            pending.forEach { $0.cancel() }
            pending.removeAll()
            generation &+= 1
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        return view
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.cancelPending()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.cancelPending()
        guard let row = scrollToRow, row >= 0 else { return }
        guard let window = nsView.window, window.contentView != nil else { return }

        let gen = context.coordinator.generation
        let coord = context.coordinator

        // Fewer, cancellable retries — the old 5× fire-and-forget pattern could still scroll after the
        // filtered list shrank, fighting SwiftUI Table updates and crashing in objc_retain (see crash .ips).
        let delays: [TimeInterval] = [0.06, 0.22, 0.45]
        for delay in delays {
            let work = DispatchWorkItem { [weak window, weak coord] in
                guard let window, let coord else { return }
                guard gen == coord.generation else { return }
                guard let content = window.contentView,
                      let tableView = Self.findTableView(in: content)
                else { return }
                Self.scrollRowSafely(row, in: tableView)
            }
            coord.pending.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        let focusWork = DispatchWorkItem { [weak window, weak coord] in
            guard let window, let coord else { return }
            guard gen == coord.generation else { return }
            guard let content = window.contentView,
                  let tableView = Self.findTableView(in: content),
                  row < tableView.numberOfRows
            else { return }
            window.makeFirstResponder(tableView)
        }
        coord.pending.append(focusWork)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: focusWork)
    }

    /// Scroll so the selected row sits near the **vertical center** of the scroll viewport.
    /// `scrollRowToVisible` only minimizes scroll and often pins the row to an edge.
    private static func scrollRowSafely(_ row: Int, in tableView: NSTableView) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.layoutSubtreeIfNeeded()

        guard let scrollView = tableView.enclosingScrollView else {
            tableView.scrollRowToVisible(row)
            return
        }
        scrollView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        clipView.layoutSubtreeIfNeeded()

        let rowRect = tableView.rect(ofRow: row)
        guard !rowRect.isEmpty else {
            tableView.scrollRowToVisible(row)
            return
        }

        let viewportH = clipView.bounds.height
        guard viewportH > 0 else {
            tableView.scrollRowToVisible(row)
            return
        }

        // Rectangle in table coordinates spanning one viewport tall, vertically centered on the row.
        // scrollToVisible on the table scrolls the enclosing NSScrollView to place this rect appropriately.
        let tableExtent = max(tableView.bounds.height, rowRect.maxY)
        let maxOriginY = max(0, tableExtent - viewportH)
        let rowMid = rowRect.midY
        let desiredOriginY = rowMid - viewportH / 2
        let originY = min(maxOriginY, max(0, desiredOriginY.rounded()))

        let targetRect = NSRect(
            x: tableView.bounds.minX,
            y: originY,
            width: tableView.bounds.width,
            height: viewportH
        )
        tableView.scrollToVisible(targetRect)

        tableView.layoutSubtreeIfNeeded()
        guard tableView.rect(ofRow: row).intersects(tableView.visibleRect) else {
            tableView.scrollRowToVisible(row)
            return
        }
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
            listTableColumns()
        }
        .tint(Color.appAccent)
        .id("\(viewModel.filteredVideosVersion)-\(viewModel.listColumnConfigurationSignature)")
        .background(TableScrollHelper(scrollToRow: scrollToRow))
        .background(ScrollCommandHandler(command: viewModel.scrollCommand, mode: .list))
        // Backup: didSet on `isPlayingInline` restores columns before persisting; one delayed pass catches
        // a late SwiftUI table layout pass after unfreeze.
        .onChange(of: viewModel.isPlayingInline) { _, playing in
            guard !playing else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                viewModel.reapplyListColumnCustomizationAfterPlaybackExit()
            }
        }
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
                    // If the right-clicked row is part of a multi-selection,
                    // send the whole selection; otherwise just this one video.
                    let urlsToSend: [URL] = {
                        if ids.count > 1, ids.contains(video.id) {
                            return ids.compactMap { id in
                                viewModel.filteredVideos.first(where: { $0.id == id })?.url
                            }
                        }
                        return [video.url]
                    }()
                    if ExternalApps.isSubmarineInstalled {
                        Button("Submarine") {
                            ExternalApps.openInSubmarine(urlsToSend)
                        }
                        Divider()
                    }
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
                Button("Re-encode to MP4\u{2026}") {
                    if let ffmpeg = ffmpegPath {
                        let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                        for v in selected {
                            viewModel.reencodeVideo(v, ffmpegPath: ffmpeg)
                        }
                    }
                }
                .disabled(ffmpegPath == nil)
                .help(ffmpegPath == nil ? "Requires ffmpeg — configure the path in Settings \u{2192} Tools" : "")
                Button("Move Files\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Move Here"
                    panel.message = "Choose a destination folder"
                    if panel.runModal() == .OK, let dest = panel.url {
                        let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                        Task { await viewModel.moveVideos(selected, to: dest) }
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

    @TableColumnBuilder<Video, KeyPathComparator<Video>>
    private func listTableColumns() -> some TableColumnContent<Video, KeyPathComparator<Video>> {
        TableColumn("Name", value: \.fileName) { video in
            nameRowView(for: video)
        }
        .width(min: 200, ideal: 350)
        .customizationID("name")

        // Grouped so the outer `Table` column builder stays within SwiftUI’s sibling limit.
        listStandardOptionalColumns()

        // `ForEach` is not supported inside `TableColumnBuilder`; emit up to 16 custom columns by index.
        // Split across two helpers: SwiftUI’s column builder limits sibling column count per block.
        listCustomTableColumnsSlots0to7()
        listCustomTableColumnsSlots8to15()
    }

    @TableColumnBuilder<Video, KeyPathComparator<Video>>
    private func listStandardOptionalColumns() -> some TableColumnContent<Video, KeyPathComparator<Video>> {
        if viewModel.isStandardListColumnVisible("duration") {
            TableColumn("Duration", value: \.sortableDuration) { video in
                Text(video.formattedDuration ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(Color.appTextSecondary)
            }
            .width(min: 60, ideal: 80)
            .alignment(.trailing)
            .customizationID("duration")
        }

        if viewModel.isStandardListColumnVisible("resolution") {
            TableColumn("Resolution", value: \.sortableResolutionHeight) { video in
                if let label = video.resolutionLabel {
                    Text(label)
                        .font(Font.appCaption2)
                        .padding(.horizontal, AppSpacing.xxs)
                        .padding(.vertical, 1)
                        .background(Color.appSurface)
                        .foregroundStyle(Color.appAccent)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous))
                } else {
                    Text("—")
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .width(min: 60, ideal: 80)
            .alignment(.center)
            .customizationID("resolution")
        }

        if viewModel.isStandardListColumnVisible("size") {
            TableColumn("Size", value: \.fileSize) { video in
                Text(video.formattedFileSize)
                    .monospacedDigit()
                    .foregroundStyle(Color.appTextSecondary)
            }
            .width(min: 60, ideal: 80)
            .alignment(.trailing)
            .customizationID("size")
        }

        if viewModel.isStandardListColumnVisible("rating") {
            TableColumn("Rating", value: \.rating) { video in
                RatingView(rating: video.rating, size: 10) { newRating in
                    viewModel.applyRating(to: [video.id], rating: newRating)
                    Task { await viewModel.persistRating(for: [video.id], rating: newRating) }
                }
            }
            .width(min: 70, ideal: 90)
            .customizationID("rating")
        }

        if viewModel.isStandardListColumnVisible("dateAdded") {
            TableColumn("Date Added", value: \.dateAdded) { video in
                Text(video.dateAdded, format: .dateTime.month(.twoDigits).day(.twoDigits).year())
                    .foregroundStyle(Color.appTextSecondary)
                    .help(video.dateAdded.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 80, ideal: 100)
            .customizationID("dateAdded")
        }

        if viewModel.isStandardListColumnVisible("playCount") {
            TableColumn("Plays", value: \.sortablePlayCount) { video in
                Text("\(video.playCount)")
                    .monospacedDigit()
                    .foregroundStyle(Color.appTextSecondary)
            }
            .width(min: 56, ideal: 72)
            .alignment(.trailing)
            .customizationID("playCount")
        }

        if viewModel.isStandardListColumnVisible("created") {
            TableColumn("Created", value: \.sortableCreationDate) { video in
                if let created = video.creationDate {
                    Text(created, format: .dateTime.month(.twoDigits).day(.twoDigits).year())
                        .foregroundStyle(Color.appTextSecondary)
                        .help(created.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("—")
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .width(min: 80, ideal: 100)
            .customizationID("created")
        }

        if viewModel.isStandardListColumnVisible("lastPlayed") {
            TableColumn("Last Played", value: \.sortableLastPlayed) { video in
                if let last = video.lastPlayed {
                    Text(last, format: .dateTime.month(.twoDigits).day(.twoDigits).year())
                        .foregroundStyle(Color.appTextSecondary)
                        .help(last.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("—")
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .width(min: 80, ideal: 100)
            .customizationID("lastPlayed")
        }
    }

    @TableColumnBuilder<Video, KeyPathComparator<Video>>
    private func listCustomTableColumnsSlots0to7() -> some TableColumnContent<Video, KeyPathComparator<Video>> {
        let fields = viewModel.visibleCustomFieldsForList
        if fields.indices.contains(0) { listCustomColumn(for: fields[0]) }
        if fields.indices.contains(1) { listCustomColumn(for: fields[1]) }
        if fields.indices.contains(2) { listCustomColumn(for: fields[2]) }
        if fields.indices.contains(3) { listCustomColumn(for: fields[3]) }
        if fields.indices.contains(4) { listCustomColumn(for: fields[4]) }
        if fields.indices.contains(5) { listCustomColumn(for: fields[5]) }
        if fields.indices.contains(6) { listCustomColumn(for: fields[6]) }
        if fields.indices.contains(7) { listCustomColumn(for: fields[7]) }
    }

    @TableColumnBuilder<Video, KeyPathComparator<Video>>
    private func listCustomTableColumnsSlots8to15() -> some TableColumnContent<Video, KeyPathComparator<Video>> {
        let fields = viewModel.visibleCustomFieldsForList
        if fields.indices.contains(8) { listCustomColumn(for: fields[8]) }
        if fields.indices.contains(9) { listCustomColumn(for: fields[9]) }
        if fields.indices.contains(10) { listCustomColumn(for: fields[10]) }
        if fields.indices.contains(11) { listCustomColumn(for: fields[11]) }
        if fields.indices.contains(12) { listCustomColumn(for: fields[12]) }
        if fields.indices.contains(13) { listCustomColumn(for: fields[13]) }
        if fields.indices.contains(14) { listCustomColumn(for: fields[14]) }
        if fields.indices.contains(15) { listCustomColumn(for: fields[15]) }
    }

    @TableColumnBuilder<Video, KeyPathComparator<Video>>
    private func listCustomColumn(for field: CustomMetadataFieldDefinition) -> some TableColumnContent<
        Video,
        KeyPathComparator<Video>
    > {
        TableColumn(field.name, value: \.fileName) { video in
            Text(viewModel.listCustomFieldDisplay(for: video, field: field))
                .lineLimit(2)
                .foregroundStyle(Color.appTextSecondary)
        }
        .width(min: 80, ideal: 120)
        .customizationID("custom-\(field.id.uuidString)")
    }

    @ViewBuilder
    private func nameRowView(for video: Video) -> some View {
        HStack(spacing: AppSpacing.sm) {
            AsyncThumbnailView(
                filePath: video.filePath,
                thumbnailService: thumbnailService,
                cacheVersion: video.thumbnailPath
            )
            .frame(width: 56, height: 36)
            .appMediaFrame(cornerRadius: AppRadius.sm)
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
                .appMediaFrame(cornerRadius: AppRadius.md)
            }

            if viewModel.renamingVideoId == video.id {
                TextField("", text: $viewModel.renameText)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .padding(.horizontal, AppSpacing.xs)
                    .padding(.vertical, AppSpacing.xxs)
                    .background(Color.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous)
                            .stroke(Color.appAccent, lineWidth: 1.5)
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
                    .foregroundStyle(Color.appTextPrimary)
                if video.hasSubtitles {
                    // Blue-accented subtitles indicator, consistent with Cinematic Blue theme.
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.appAccent, in: RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous))
                        .help("Subtitles available")
                        .accessibilityLabel("Subtitles available")
                }
            }
        }
    }

    private var ffmpegPath: String? { viewModel.resolvedFFmpegPath }

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
