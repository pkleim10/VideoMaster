import AVKit
import AppKit
import SwiftUI

struct VideoDetailView: View {
    let video: Video
    @Bindable var viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService
    @State private var tags: [Tag] = []
    /// Stored values for custom metadata fields (UUID → string); empty string is valid.
    @State private var customFieldValues: [UUID: String] = [:]
    /// Fields where the current selection has differing values (“Various”).
    @State private var customFieldVarious: Set<UUID> = []
    @State private var newTagName: String = ""
    @State private var isCreatingTag = false
    @FocusState private var isTagFieldFocused: Bool
    /// Grid/list-sized preview (400); shown immediately in detail.
    @State private var detailThumbnailLo: NSImage?
    /// Session-only hi-res detail still (long edge from settings); replaces lo when ready.
    @State private var detailThumbnailHi: NSImage?
    @State private var filmstrip: NSImage?
    @State private var filmstripRows: Int = 2
    @State private var filmstripColumns: Int = 4
    @State private var isEditingName = false
    @State private var editedName: String = ""
    @State private var inlinePlayer: AVPlayer?
    /// Tracks detail column size for auto-adjust splitter (thumbnail/filmstrip vs metadata).
    @State private var detailPaneSize: CGSize = .zero
    private var effectiveHeight: CGFloat { viewModel.effectiveDetailHeight }

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let handleHeight: CGFloat = 8
            let clampedDetailHeight = min(max(100, effectiveHeight), totalHeight - 100 - handleHeight)
            let thumbnailHeight = max(100, totalHeight - clampedDetailHeight - handleHeight)

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !viewModel.isPlayingInline, (detailThumbnailLo != nil || detailThumbnailHi != nil || filmstrip != nil) {
                        Picker("", selection: $viewModel.showThumbnailInDetail) {
                            Text("Thumbnail").tag(true)
                            Text("Filmstrip").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                        .help("Switch preview type (⌥⌘F)")
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                        if !viewModel.showThumbnailInDetail, filmstrip != nil {
                            Text("Click any frame to start playback from that point")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 4)
                        }
                    }

                    thumbnailSection(maxHeight: thumbnailHeight)
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }
                .frame(height: thumbnailHeight)

                resizeHandle(totalHeight: totalHeight)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        titleSection
                        Divider()
                        detailsAndAttributesRow
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
                .frame(height: clampedDetailHeight)
            }
            .onAppear {
                detailPaneSize = geo.size
                scheduleAutoAdjustVideoPane()
            }
            .onChange(of: geo.size.width) { _, _ in
                detailPaneSize = geo.size
                scheduleAutoAdjustVideoPane(debounce: true)
            }
            .onChange(of: geo.size.height) { _, _ in
                detailPaneSize = geo.size
                scheduleAutoAdjustVideoPane(debounce: true)
            }
        }
        .task(id: video.id) {
            stopInlinePlayback()
            viewModel.isPlayingInline = false
            viewModel.pendingFilmstripSeekSeconds = nil
            isEditingName = false
            viewModel.isEditingText = false
            let path = video.filePath
            detailThumbnailLo = nil
            detailThumbnailHi = nil
            // Filmstrip mode: load cached strip before any `await` so SwiftUI never paints a frame with
            // `filmstrip == nil` while the strip exists on disk (that frame read as thumbnail/placeholder flash).
            if viewModel.showThumbnailInDetail {
                filmstrip = nil
            } else {
                let fs = thumbnailService.loadFilmstrip(for: path)
                filmstrip = fs
                if let f = fs {
                    inferFilmstripGrid(from: f)
                    if viewModel.autoAdjustVideoPane {
                        applyAutoAdjustVideoPaneIfNeeded(filmstripSizingImage: f)
                    }
                }
            }
            await loadData()
        }
        .onChange(of: viewModel.filmstripRefreshId) { _, _ in
            Task { @MainActor in
                filmstrip = thumbnailService.loadFilmstrip(for: video.filePath)
                if let fs = filmstrip {
                    inferFilmstripGrid(from: fs)
                }
                scheduleAutoAdjustVideoPane()
            }
        }
        .onChange(of: viewModel.detailPreviewMaxLongEdge) { _, _ in
            Task { @MainActor in
                detailThumbnailHi = nil
                scheduleDetailPreviewLoad(for: resolvedVideo)
            }
        }
        .onChange(of: viewModel.showThumbnailInDetail) { _, showThumb in
            if showThumb {
                scheduleDetailPreviewLoad(for: resolvedVideo)
            }
            scheduleAutoAdjustVideoPane()
        }
        .onChange(of: viewModel.isPlayingInline) { _, _ in
            // Defer until after layout so `detailPaneSize` reflects chrome (picker, hints) after exit play mode.
            DispatchQueue.main.async {
                scheduleAutoAdjustVideoPane()
            }
        }
        .onChange(of: viewModel.autoAdjustVideoPane) { _, _ in
            scheduleAutoAdjustVideoPane()
        }
        .onChange(of: viewModel.selectedVideoIds) { _, _ in
            Task { @MainActor in
                tags = viewModel.tagsForVideos(selectedIds)
                await reloadCustomMetadata()
            }
        }
        .onChange(of: viewModel.customMetadataFieldDefinitions) { _, _ in
            Task { await reloadCustomMetadata() }
        }
    }

    @ViewBuilder
    private func filmstripImage(_ filmstrip: NSImage) -> some View {
        Image(nsImage: filmstrip)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .overlay {
                GeometryReader { imgGeo in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            handleFilmstripClick(at: location, in: imgGeo.size)
                        }
                }
            }
    }

    private func resizeHandle(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = viewModel.effectiveDetailHeight
                        // Match clamp logic in body: avoid negative max when GeometryReader is transiently tiny
                        // (e.g. list thrash / crash recovery), which previously corrupted persisted detail height.
                        let minThumb: CGFloat = 100
                        let handleH: CGFloat = 8
                        let maxDetail = max(100, totalHeight - minThumb - handleH)
                        let newHeight = min(maxDetail, max(100, base - value.translation.height))
                        viewModel.updateCurrentLayoutWithSizes(detailVideoHeight: newHeight)
                    }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 40, height: 4)
            }
    }

    // MARK: - Thumbnail + Inline Player

    private func thumbnailSection(maxHeight: CGFloat) -> some View {
        let preferThumbnail = viewModel.showThumbnailInDetail
        let detailStill = detailThumbnailHi ?? detailThumbnailLo

        return ZStack {
                if viewModel.isPlayingInline, let player = inlinePlayer {
                    FloatingPlayerView(player: player)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if preferThumbnail, let detailStill {
                    Image(nsImage: detailStill)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if let filmstrip {
                    filmstripImage(filmstrip)
                } else if let detailStill {
                    // Filmstrip mode, no strip yet: show grid/hi-res still while generating on demand (cached strips are
                    // applied synchronously in `.task`, so this does not flash before an existing filmstrip).
                    Image(nsImage: detailStill)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            Image(systemName: "film")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                        }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .onChange(of: viewModel.isPlayingInline) { _, isPlaying in
            if isPlaying {
                if inlinePlayer == nil {
                    let seek = viewModel.pendingFilmstripSeekSeconds ?? 0
                    viewModel.pendingFilmstripSeekSeconds = nil
                    startInlinePlayback(at: seek)
                }
            } else {
                viewModel.pendingFilmstripSeekSeconds = nil
                stopInlinePlayback()
            }
        }
        .onChange(of: viewModel.inlinePlayPauseToggle) { _, _ in
            guard let player = inlinePlayer else { return }
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
        }
    }

    private func startInlinePlayback() {
        startInlinePlayback(at: 0)
    }

    private func startInlinePlayback(at seconds: Double) {
        let player = AVPlayer(url: video.url)
        inlinePlayer = player
        if seconds > 0 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { _ in
                player.play()
            }
        } else {
            player.play()
        }
        Task { await viewModel.recordPlay(for: video) }
    }

    private func stopInlinePlayback() {
        inlinePlayer?.pause()
        inlinePlayer = nil
    }

    private func handleFilmstripClick(at location: CGPoint, in size: CGSize) {
        let seekTime: Double
        if let duration = video.duration, duration > 0, size.width > 0, size.height > 0,
           filmstripColumns > 0, filmstripRows > 0
        {
            let cellWidth = size.width / CGFloat(filmstripColumns)
            let cellHeight = size.height / CGFloat(filmstripRows)
            let col = min(Int(location.x / cellWidth), filmstripColumns - 1)
            let row = min(Int(location.y / cellHeight), filmstripRows - 1)
            let frameIndex = row * filmstripColumns + col
            let totalFrames = filmstripRows * filmstripColumns
            seekTime = duration * Double(frameIndex + 1) / Double(totalFrames + 1)
        } else {
            // Duration often missing on first open until metadata loads; still start playback from the beginning.
            seekTime = 0
        }

        stopInlinePlayback()
        viewModel.pendingFilmstripSeekSeconds = seekTime
        viewModel.isPlayingInline = true
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isMultiSelect {
                Text("\(selectedIds.count) Videos Selected")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            } else {
                if isEditingName {
                    TextField("File name", text: $editedName)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelRename() }
                } else {
                    Text(video.fileName)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .onTapGesture {
                            editedName = video.fileName
                            isEditingName = true
                            viewModel.isEditingText = true
                        }
                }

                Text(video.filePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    Button("Play Video") { playVideo() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(video.filePath, inFileViewerRootedAtPath: "")
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Details (left 2/3) + Rating & Tags (right 1/3)

    private var detailsAndAttributesRow: some View {
        HStack(alignment: .top, spacing: 20) {
            metadataSection
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ratingAndTagsSection
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(idealWidth: 180)
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)

            if isMultiSelect {
                let vids = selectedVideos
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading, spacing: 10
                ) {
                    MetadataRow(label: "Resolution", value: {
                        if let outer = commonOptionalValue(\.resolution), let res = outer { return res }
                        return "--"
                    }())
                    MetadataRow(label: "Duration", value: {
                        if let outer = commonOptionalValue(\.duration), let d = outer {
                            return d.formattedDuration
                        }
                        return "--"
                    }())
                    MetadataRow(label: "File Size", value: commonValue(\.fileSize).map { $0.formattedFileSize } ?? "--")
                    MetadataRow(label: "Codec", value: {
                        if let outer = commonOptionalValue(\.codec), let c = outer { return c }
                        return "--"
                    }())
                    MetadataRow(label: "Frame Rate", value: {
                        if let outer = commonOptionalValue(\.frameRate), let fr = outer {
                            return String(format: "%.2f fps", fr)
                        }
                        return "--"
                    }())
                    MetadataRow(label: "Date Added", value: commonValue(\.dateAdded)?.formatted(date: .abbreviated, time: .shortened) ?? "--")
                    MetadataRow(label: "Created", value: {
                        if let outer = commonOptionalValue(\.creationDate), let date = outer {
                            return date.formatted(date: .abbreviated, time: .shortened)
                        }
                        return "--"
                    }())
                    MetadataRow(label: "Last Played", value: {
                        if let outer = commonOptionalValue(\.lastPlayed), let date = outer {
                            return date.formatted(date: .abbreviated, time: .shortened)
                        }
                        return "--"
                    }())
                    MetadataRow(label: "Plays", value: {
                        if let pc = commonValue(\.playCount) { return "\(pc)" }
                        return "--"
                    }())
                    MetadataRow(label: "Videos", value: "\(vids.count)")
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading, spacing: 10
                ) {
                    MetadataRow(label: "Resolution", value: video.resolution ?? "Unknown")
                    MetadataRow(
                        label: "Duration", value: video.formattedDuration ?? "Unknown"
                    )
                    MetadataRow(label: "File Size", value: video.formattedFileSize)
                    MetadataRow(label: "Codec", value: video.codec ?? "Unknown")
                    MetadataRow(
                        label: "Frame Rate",
                        value: video.frameRate.map { String(format: "%.2f fps", $0) } ?? "Unknown"
                    )
                    MetadataRow(
                        label: "Date Added",
                        value: video.dateAdded.formatted(date: .abbreviated, time: .shortened)
                    )
                    if let created = video.creationDate {
                        MetadataRow(
                            label: "Created",
                            value: created.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    if let lastPlayed = video.lastPlayed {
                        MetadataRow(
                            label: "Last Played",
                            value: lastPlayed.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    MetadataRow(label: "Plays", value: "\(video.playCount)")
                }
            }

            if !sortedCustomDefinitionFields.isEmpty {
                Divider()
                customMetadataFieldsSection
            }
        }
    }

    private var sortedCustomDefinitionFields: [CustomMetadataFieldDefinition] {
        viewModel.customMetadataFieldDefinitions.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var customMetadataFieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom")
                .font(.headline)
            ForEach(sortedCustomDefinitionFields) { field in
                customMetadataFieldEditor(for: field)
            }
        }
    }

    @ViewBuilder
    private func customMetadataFieldEditor(for field: CustomMetadataFieldDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            switch field.valueType {
            case .string:
                customStringField(for: field)
            case .text:
                customTextEditorField(for: field)
            case .number:
                customNumberField(for: field)
            case .date:
                customDateField(for: field, includeTime: false)
            case .dateTime:
                customDateField(for: field, includeTime: true)
            }
        }
    }

    private func customStringField(for field: CustomMetadataFieldDefinition) -> some View {
        Group {
            if customFieldVarious.contains(field.id) {
                TextField("", text: customBinding(for: field), prompt: Text("Various").foregroundStyle(.tertiary))
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("", text: customBinding(for: field))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func customTextEditorField(for field: CustomMetadataFieldDefinition) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: customBinding(for: field))
                .font(.body)
                .frame(minHeight: 56, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                }
            if customFieldVarious.contains(field.id), (customFieldValues[field.id] ?? "").isEmpty {
                Text("Various")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
                    .padding(.leading, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    private func customNumberField(for field: CustomMetadataFieldDefinition) -> some View {
        Group {
            if customFieldVarious.contains(field.id) {
                TextField("", text: customNumberBinding(for: field), prompt: Text("Various").foregroundStyle(.tertiary))
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("", text: customNumberBinding(for: field))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func customDateField(for field: CustomMetadataFieldDefinition, includeTime: Bool) -> some View {
        Group {
            if customFieldVarious.contains(field.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Various")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(includeTime ? "Set date & time…" : "Set date…") {
                        let now = Date()
                        let encoded = CustomMetadataDetailCodec.encodeDate(now, as: field.valueType)
                        customFieldValues[field.id] = encoded
                        customFieldVarious.remove(field.id)
                        Task {
                            await viewModel.persistCustomMetadata(
                                fieldId: field.id,
                                value: encoded,
                                forVideoPaths: selectedIds
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if includeTime {
                DatePicker(
                    "",
                    selection: customDateBinding(for: field),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
            } else {
                DatePicker(
                    "",
                    selection: customDateBinding(for: field),
                    displayedComponents: .date
                )
                .labelsHidden()
            }
        }
    }

    private func customBinding(for field: CustomMetadataFieldDefinition) -> Binding<String> {
        Binding(
            get: { customFieldValues[field.id] ?? "" },
            set: { new in
                customFieldValues[field.id] = new
                customFieldVarious.remove(field.id)
                Task {
                    await viewModel.persistCustomMetadata(
                        fieldId: field.id,
                        value: new,
                        forVideoPaths: selectedIds
                    )
                }
            }
        )
    }

    private func customNumberBinding(for field: CustomMetadataFieldDefinition) -> Binding<String> {
        Binding(
            get: { customFieldValues[field.id] ?? "" },
            set: { new in
                customFieldValues[field.id] = new
                customFieldVarious.remove(field.id)
                let trimmed = new.trimmingCharacters(in: .whitespaces)
                guard trimmed.isEmpty || Double(trimmed) != nil else { return }
                Task {
                    await viewModel.persistCustomMetadata(
                        fieldId: field.id,
                        value: trimmed,
                        forVideoPaths: selectedIds
                    )
                }
            }
        )
    }

    private func customDateBinding(for field: CustomMetadataFieldDefinition) -> Binding<Date> {
        Binding(
            get: {
                let s = customFieldValues[field.id] ?? ""
                return CustomMetadataDetailCodec.decodeDateLike(s, as: field.valueType) ?? Date()
            },
            set: { newDate in
                let s = CustomMetadataDetailCodec.encodeDate(newDate, as: field.valueType)
                customFieldValues[field.id] = s
                customFieldVarious.remove(field.id)
                Task {
                    await viewModel.persistCustomMetadata(
                        fieldId: field.id,
                        value: s,
                        forVideoPaths: selectedIds
                    )
                }
            }
        )
    }

    /// Tags in alphabetical order for the tag picker (inline flow).
    private var sortedAlphaTags: [Tag] {
        viewModel.tags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private func tagToggleChip(for tag: Tag) -> some View {
        TagToggleChip(
            tag: tag,
            isActive: tags.contains(where: { $0.id == tag.id })
        ) { isAdding in
            if isAdding {
                if !tags.contains(where: { $0.id == tag.id }) {
                    tags.append(tag)
                }
            } else {
                tags.removeAll { $0.id == tag.id }
            }
            Task {
                let selected = selectedIds
                if isAdding {
                    await viewModel.addTag(tag.name, toVideos: selected)
                } else {
                    await viewModel.removeTag(tag, fromVideos: selected)
                }
                tags = viewModel.tagsForVideos(selected)
            }
        }
    }

    // MARK: - Rating + Tags (combined right column)

    private var ratingAndTagsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rating")
                    .font(.headline)
                RatingView(rating: isMultiSelect ? (commonValue(\.rating) ?? 0) : resolvedVideo.rating, size: 20) { newRating in
                    let ids = selectedIds
                    viewModel.applyRating(to: ids, rating: newRating)
                    Task { await viewModel.persistRating(for: ids, rating: newRating) }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Tags")
                    .font(.headline)

                if viewModel.tags.isEmpty {
                    Text("No tags yet — create one below")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(sortedAlphaTags) { tag in
                            tagToggleChip(for: tag)
                        }
                    }
                }

                Divider()

                if isCreatingTag {
                    HStack(spacing: 4) {
                        TextField("Tag name", text: $newTagName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .focused($isTagFieldFocused)
                            .onSubmit { addTag() }
                            .onAppear {
                                isTagFieldFocused = true
                                viewModel.isEditingText = true
                            }
                            .onDisappear {
                                viewModel.isEditingText = false
                            }
                        Button(action: addTag) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button(action: { isCreatingTag = false; newTagName = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button(action: { isCreatingTag = true }) {
                        Label("New Tag", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func commitRename() {
        let newName = editedName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != video.fileName else {
            cancelRename()
            return
        }
        Task {
            if await viewModel.renameVideo(video, to: newName) != nil {
                isEditingName = false
                viewModel.isEditingText = false
            }
        }
    }

    private func cancelRename() {
        isEditingName = false
        viewModel.isEditingText = false
        editedName = ""
    }

    private func playVideo() {
        NSWorkspace.shared.open(video.url)
        Task {
            await viewModel.recordPlay(for: video)
        }
    }

    private func loadData() async {
        let path = video.filePath
        let service = thumbnailService
        let stableId = video.id

        // Metadata / detail pane first — do not wait for filmstrip load or generation.
        tags = viewModel.tagsForVideos(selectedIds)
        await reloadCustomMetadata()
        if viewModel.showThumbnailInDetail {
            scheduleDetailPreviewLoad(for: resolvedVideo)
        }
        // Do not schedule auto-adjust here: preview/filmstrip are not loaded yet; early runs used the
        // 16:9 placeholder and caused flicker and wrong shrink-wrap when filmstrip appeared later.

        if viewModel.pendingAutoPlay {
            viewModel.pendingAutoPlay = false
            viewModel.isPlayingInline = true
        }

        await Task.yield()

        // Cached filmstrip is applied synchronously in `.task(id:)` before this runs when Filmstrip is selected.

        // Disk cache: 400px thumbnail loads off-thread; filmstrip generation continues in the background Task below.
        let thumbnailLoaded = await Task.detached(priority: .userInitiated) {
            service.loadThumbnail(for: path)
        }.value
        detailThumbnailLo = thumbnailLoaded
        if viewModel.showThumbnailInDetail {
            scheduleAutoAdjustVideoPane(debounce: true)
        }

        await Task.yield()

        Task { @MainActor in
            if filmstrip == nil {
                let filmstripLoaded = await Task.detached(priority: .userInitiated) {
                    service.loadFilmstrip(for: path)
                }.value
                if let fs = filmstripLoaded {
                    inferFilmstripGrid(from: fs)
                }
                // Resize splitter using the loaded image *before* assigning @State so the first paint matches filmstrip aspect (no jump).
                if !viewModel.showThumbnailInDetail, viewModel.autoAdjustVideoPane, let img = filmstripLoaded {
                    applyAutoAdjustVideoPaneIfNeeded(filmstripSizingImage: img)
                }
                filmstrip = filmstripLoaded
            }
            if viewModel.pendingSurpriseScrollVideoId == stableId, filmstrip != nil {
                viewModel.showThumbnailInDetail = false
            }
            await generateFilmstripIfNeeded()
            if viewModel.pendingSurpriseScrollVideoId == stableId, filmstrip != nil {
                viewModel.showThumbnailInDetail = false
            }
            // After on-demand generation, filmstrip @State is set — sync adjust (no debounced Task) to match strip immediately.
            if !viewModel.showThumbnailInDetail, viewModel.autoAdjustVideoPane {
                applyAutoAdjustVideoPaneIfNeeded()
            }
            await Task.yield()
            await Task.yield()
            viewModel.finishSurpriseScrollIfNeeded(for: stableId)
        }
        Task { @MainActor in
            await generateThumbnailIfNeeded()
        }
    }

    /// Disk-backed hi-res still (long edge from settings); 400px shows first, then swaps when JPEG is ready.
    private func scheduleDetailPreviewLoad(for videoForPreview: Video) {
        let stableId = videoForPreview.id
        let longEdge = viewModel.detailPreviewMaxLongEdge
        Task(priority: .userInitiated) {
            guard let large = await thumbnailService.detailPreviewImage(for: videoForPreview, longEdge: longEdge) else { return }
            await MainActor.run {
                let primary = viewModel.lastSelectedVideoId ?? viewModel.selectedVideoIds.first
                let stillSelected = primary == stableId || viewModel.selectedVideoIds.contains(stableId)
                guard stillSelected else { return }
                detailThumbnailHi = large
                scheduleAutoAdjustVideoPane()
            }
        }
    }

    private func generateThumbnailIfNeeded() async {
        guard detailThumbnailLo == nil else { return }
        let v = resolvedVideo
        if let url = try? await thumbnailService.generateThumbnail(for: v) {
            detailThumbnailLo = NSImage(contentsOf: url)
        }
    }

    private func generateFilmstripIfNeeded() async {
        guard filmstrip == nil else { return }
        if let generated = try? await thumbnailService.generateFilmstrip(
            for: video,
            rows: viewModel.defaultFilmstripRows,
            columns: viewModel.defaultFilmstripColumns
        ) {
            filmstrip = generated
            inferFilmstripGrid(from: generated)
        }
    }

    private func inferFilmstripGrid(from image: NSImage) {
        let cellWidth: CGFloat = 400
        let cellHeight: CGFloat = 225
        let cols = max(1, Int(round(image.size.width / cellWidth)))
        let rows = max(1, Int(round(image.size.height / cellHeight)))
        filmstripColumns = cols
        filmstripRows = rows
    }

    // MARK: - Auto-adjust preview / metadata split

    private func scheduleAutoAdjustVideoPane(debounce: Bool = false) {
        guard viewModel.autoAdjustVideoPane else { return }
        if debounce {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                applyAutoAdjustVideoPaneIfNeeded()
            }
        } else {
            applyAutoAdjustVideoPaneIfNeeded()
        }
    }

    /// - Parameter filmstripSizingImage: When set, used for height math **before** `filmstrip` @State is assigned so the splitter can update in the same frame as the filmstrip first appears (avoids jump/flicker).
    private func applyAutoAdjustVideoPaneIfNeeded(filmstripSizingImage: NSImage? = nil) {
        guard viewModel.autoAdjustVideoPane else { return }
        let totalHeight = detailPaneSize.height
        let fullWidth = detailPaneSize.width
        guard totalHeight > 200, fullWidth > 80 else { return }

        let horizontalPadding: CGFloat = 32
        let contentW = max(40, fullWidth - horizontalPadding)
        let handleH: CGFloat = 8
        let minDetail: CGFloat = 100
        let minThumb: CGFloat = 100

        let filmstripEffective = filmstripSizingImage ?? filmstrip
        let hasMediaChrome = !viewModel.isPlayingInline
            && (detailThumbnailLo != nil || detailThumbnailHi != nil || filmstripEffective != nil)
        let showHint = !viewModel.showThumbnailInDetail && filmstripEffective != nil
        let chrome = previewColumnChromeHeight(
            isPlayingInline: viewModel.isPlayingInline,
            hasMediaChrome: hasMediaChrome,
            showFilmstripHint: showHint
        )
        let fitted = fittedMediaHeight(contentWidth: contentW, filmstripOverride: filmstripSizingImage)
        let idealThumbTotal = chrome + fitted

        let maxThumb = totalHeight - minDetail - handleH
        let thumbUsed = min(maxThumb, max(minThumb, idealThumbTotal))
        let newDetailRaw = totalHeight - thumbUsed - handleH
        let maxDetailAllowed = max(100, totalHeight - minThumb - handleH)
        let newDetail = min(maxDetailAllowed, max(minDetail, newDetailRaw))
        viewModel.updateCurrentLayoutWithSizes(detailVideoHeight: newDetail)
    }

    private func previewColumnChromeHeight(
        isPlayingInline: Bool,
        hasMediaChrome: Bool,
        showFilmstripHint: Bool
    ) -> CGFloat {
        if isPlayingInline { return 4 }
        var h: CGFloat = 4
        if hasMediaChrome {
            h += 8 + 30 + 4
            if showFilmstripHint { h += 4 + 18 }
        }
        return h
    }

    private func fittedMediaHeight(contentWidth: CGFloat, filmstripOverride: NSImage? = nil) -> CGFloat {
        let w = max(1, contentWidth)
        if viewModel.isPlayingInline {
            return w * 9 / 16
        }
        let img: NSImage?
        if viewModel.showThumbnailInDetail {
            img = detailThumbnailHi ?? detailThumbnailLo
        } else {
            // Prefer filmstrip dimensions when present (cached strips are set in `.task` before thumbnails load).
            // When the strip is still generating, size to the visible interim still so auto-adjust matches the preview.
            if let fs = filmstripOverride ?? filmstrip {
                img = fs
            } else {
                img = detailThumbnailHi ?? detailThumbnailLo
            }
        }
        guard let img, img.size.width > 0, img.size.height > 0 else {
            return w * 9 / 16
        }
        return w * (img.size.height / img.size.width)
    }

    private var selectedIds: Set<String> {
        let ids = viewModel.selectedVideoIds
        return ids.isEmpty ? [video.id] : ids
    }

    /// Latest row from the view model. The `video` parameter can go stale because the detail
    /// `NSHostingView` often keeps the same SwiftUI root when the selection id is unchanged.
    private var resolvedVideo: Video {
        viewModel.videos.first(where: { $0.id == video.id }) ?? video
    }

    private var isMultiSelect: Bool {
        viewModel.selectedVideoIds.count > 1
    }

    private var selectedVideos: [Video] {
        let ids = selectedIds
        // Use `videos` (not `filteredVideos`) so rating and other fields update immediately after
        // `applyRating`; filtered list is refreshed asynchronously.
        return ids.compactMap { id in viewModel.videos.first(where: { $0.id == id }) }
    }

    private func commonValue<T: Equatable>(_ keyPath: KeyPath<Video, T>) -> T? {
        let vids = selectedVideos
        guard let first = vids.first else { return nil }
        let val = first[keyPath: keyPath]
        return vids.allSatisfy({ $0[keyPath: keyPath] == val }) ? val : nil
    }

    private func commonOptionalValue<T: Equatable>(_ keyPath: KeyPath<Video, T?>) -> T?? {
        let vids = selectedVideos
        guard let first = vids.first else { return nil }
        let val = first[keyPath: keyPath]
        return vids.allSatisfy({ $0[keyPath: keyPath] == val }) ? .some(val) : nil
    }

    private func addTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            let selected = selectedIds
            await viewModel.addTag(name, toVideos: selected)
            newTagName = ""
            isCreatingTag = false
            tags = viewModel.tagsForVideos(selected)
        }
    }

    private func reloadCustomMetadata() async {
        let merged = await viewModel.mergedCustomMetadata(forVideoPaths: Array(selectedIds))
        let validIds = Set(sortedCustomDefinitionFields.map(\.id))
        customFieldValues = customFieldValues.filter { validIds.contains($0.key) }
        customFieldVarious = customFieldVarious.filter { validIds.contains($0) }
        for def in sortedCustomDefinitionFields {
            if let common = merged[def.id] {
                customFieldVarious.remove(def.id)
                customFieldValues[def.id] = common
            } else {
                customFieldVarious.insert(def.id)
                customFieldValues[def.id] = ""
            }
        }
    }

}

/// Encode/decode custom date fields in the detail pane (stored as strings in SQLite).
private enum CustomMetadataDetailCodec {
    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let iso8601DateTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601DateTimeNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func encodeDate(_ date: Date, as type: CustomMetadataValueType) -> String {
        switch type {
        case .date:
            return dateOnlyFormatter.string(from: date)
        case .dateTime:
            return iso8601DateTime.string(from: date)
        default:
            return ""
        }
    }

    static func decodeDateLike(_ s: String, as type: CustomMetadataValueType) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        switch type {
        case .date:
            if let d = dateOnlyFormatter.date(from: trimmed) { return d }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withFullDate]
            return iso.date(from: trimmed)
        case .dateTime:
            if let d = iso8601DateTime.date(from: trimmed) { return d }
            if let d = iso8601DateTimeNoFraction.date(from: trimmed) { return d }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: trimmed)
        default:
            return nil
        }
    }
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
        }
    }
}

struct FloatingPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
