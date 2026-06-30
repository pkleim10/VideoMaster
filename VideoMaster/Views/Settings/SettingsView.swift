import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        TabView {
            ApplicationSettingsView(appState: appState)
                .tabItem {
                    Label("Application", systemImage: "app")
                }

            if let pool = appState.dbManager?.dbPool, let vm = appState.libraryViewModel {
                LibrarySettingsView(viewModel: vm)
                    .tabItem {
                        Label("Library", systemImage: "books.vertical")
                    }

                VideoSettingsView(viewModel: vm)
                    .tabItem {
                        Label("Video", systemImage: "film")
                    }

                DataSourcesSettingsView(dbPool: pool)
                    .tabItem {
                        Label("Data Sources", systemImage: "folder")
                    }

                FileExtSettingsView()
                    .tabItem {
                        Label("File Ext", systemImage: "doc.badge.gearshape")
                    }

                ToolsSettingsView(viewModel: vm)
                    .tabItem {
                        Label("Tools", systemImage: "wrench.and.screwdriver")
                    }

                CustomMetadataSettingsView(viewModel: vm)
                    .tabItem {
                        Label("Custom Metadata", systemImage: "square.grid.3x3.square.badge.ellipsis")
                    }
            }
        }
        .frame(minWidth: 500, minHeight: 350)
    }
}

struct LibrarySettingsView: View {
    @Bindable var viewModel: LibraryViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Exclude corrupt files from filters", isOn: $viewModel.excludeCorrupt)
            } footer: {
                Text("Corrupt files (missing duration and resolution) will be hidden from Library, Collections, Rating, and Tag filters. They remain visible in the Corrupt filter and name search.")
            }

            Section {
                Toggle("Confirm deletions", isOn: $viewModel.confirmDeletions)
            } footer: {
                Text("When enabled, a confirmation dialog will appear before moving files to Trash.")
            }

            Section("Sidebar Filters") {
                filterRow(
                    title: "Recently Added",
                    isOn: $viewModel.showRecentlyAdded
                ) {
                    daysField(value: $viewModel.recentlyAddedDays)
                        .disabled(!viewModel.showRecentlyAdded)
                    Text("days")
                        .foregroundStyle(viewModel.showRecentlyAdded ? Color.appTextSecondary : Color.appTextTertiary)
                }

                filterRow(
                    title: "Recently Played",
                    isOn: $viewModel.showRecentlyPlayed
                ) {
                    daysField(value: $viewModel.recentlyPlayedDays)
                        .disabled(!viewModel.showRecentlyPlayed)
                    Text("days")
                        .foregroundStyle(viewModel.showRecentlyPlayed ? Color.appTextSecondary : Color.appTextTertiary)
                }

                filterRow(
                    title: "Top Rated",
                    isOn: $viewModel.showTopRated
                ) {
                    RatingView(rating: viewModel.topRatedMinRating, size: 14) { newRating in
                        viewModel.topRatedMinRating = max(newRating, 1)
                    }
                    .disabled(!viewModel.showTopRated)
                    .opacity(viewModel.showTopRated ? 1 : 0.4)
                }

                filterRow(title: "Duplicates", isOn: $viewModel.showDuplicates)

                filterRow(title: "Corrupt", isOn: $viewModel.showCorrupt)

                filterRow(title: "Missing", isOn: $viewModel.showMissing)

                filterRow(title: "Recently Converted", isOn: $viewModel.showRecentlyConverted)
            }

            Section {
                ListColumnsSettingsContent(viewModel: viewModel)
            } header: {
                Text("List view columns")
            } footer: {
                Text("Choose which metadata columns appear in list view. Name is always shown. Up to 16 custom columns can be shown at once (alphabetically). You can still reorder and resize visible columns using the table header.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func filterRow<C: View>(
        title: String,
        isOn: Binding<Bool>,
        @ViewBuilder config: () -> C
    ) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            Spacer()
            config()
        }
    }

    private func filterRow(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
    }

    private func daysField(value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number)
            .frame(width: 50)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .onChange(of: value.wrappedValue) { _, newVal in
                if newVal < 1 { value.wrappedValue = 1 }
                if newVal > 365 { value.wrappedValue = 365 }
            }
    }

}

struct VideoSettingsView: View {
    @Bindable var viewModel: LibraryViewModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 24) {
                    compactStepper("Rows", value: $viewModel.defaultFilmstripRows, range: 1...6)
                    compactStepper("Columns", value: $viewModel.defaultFilmstripColumns, range: 1...8)
                    Spacer()
                    Text("\(viewModel.defaultFilmstripRows * viewModel.defaultFilmstripColumns) frames per filmstrip")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }

                Button("Regenerate filmstrips") {
                    Task { await viewModel.clearFilmstripCacheAndMarkApplied() }
                }
                .disabled(!viewModel.filmstripLayoutChanged)
            } header: {
                Text("Default Filmstrip Size")
            } footer: {
                Text("This sets the default grid size when generating new filmstrips. You can override it per video using Modify Filmstrip. Regenerate clears cached filmstrips so they are recreated with the new layout when you view each video.")
            }

            Section {
                Toggle("Surprise Me! auto-plays selected video", isOn: $viewModel.surpriseMeAutoPlays)
            } footer: {
                Text("Surprise Me updates selection immediately, loads or generates the filmstrip for the detail pane, then starts auto-play if enabled, then scrolls the grid or list to the selection.")
            }

            Section {
                Picker("Player opens at", selection: $viewModel.playerStartPreference) {
                    ForEach(PlayerStartPreference.allCases) { pref in
                        Text(pref.label).tag(pref)
                    }
                }
            } footer: {
                Text("When you start inline playback, the resizable player opens at this size. Compact fits the inspector still/filmstrip area; Full screen opens borderless edge-to-edge; Last used size reopens the player at whatever size you last left it. You can always resize, snap, or go full-screen from the player's own controls.")
            }

            Section {
                Toggle("Fade resume banner after delay", isOn: $viewModel.fadeResumeBannerAutomatically)
                HStack(spacing: 24) {
                    compactStepper(
                        "Seconds before fade",
                        value: $viewModel.resumeBannerFadeDelaySeconds,
                        range: 1...120
                    )
                    Spacer()
                }
                .disabled(!viewModel.fadeResumeBannerAutomatically)
                .opacity(viewModel.fadeResumeBannerAutomatically ? 1 : 0.45)
            } header: {
                Text("Playback")
            } footer: {
                Text("After resuming inline playback from a remembered position, VideoMaster shows a banner with Start at beginning. When fade is enabled, that banner fades out after the delay; playback keeps going from the resumed time.")
            }

            Section {
                Picker("Maximum large preview thumbnail (long-edge)", selection: $viewModel.detailPreviewMaxLongEdge) {
                    ForEach(ThumbnailService.detailPreviewLongEdgeChoices, id: \.self) { w in
                        Text("\(w) px").tag(w)
                    }
                }
                Toggle("Auto adjust video pane", isOn: $viewModel.autoAdjustVideoPane)
            } header: {
                Text("Detail Pane Preview")
            } footer: {
                Text("Maximum width or height (long edge) for the disk-backed hi-res still when Thumbnail is selected. Larger values use more cache space. Grid and list thumbnails stay 400 px. When Auto adjust video pane is on, the horizontal splitter between the preview and the metadata area is adjusted so the thumbnail or filmstrip fits the media.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func compactStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
            HStack(spacing: 0) {
                Button {
                    if value.wrappedValue > range.lowerBound { value.wrappedValue -= 1 }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue <= range.lowerBound)

                Text("\(value.wrappedValue)")
                    .font(.title3)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(width: 30, alignment: .center)

                Button {
                    if value.wrappedValue < range.upperBound { value.wrappedValue += 1 }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue >= range.upperBound)
            }
        }
    }
}

struct ToolsSettingsView: View {
    @Bindable var viewModel: LibraryViewModel
    @State private var showingFilePicker = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    if let resolved = viewModel.resolvedFFmpegPath {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(resolved)
                            .font(.callout.monospaced())
                            .foregroundStyle(Color.appTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if viewModel.ffmpegUserPath.isEmpty {
                            Text("auto-discovered")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text(viewModel.ffmpegUserPath.isEmpty ? "Not found at standard paths" : "Not found at configured path")
                            .font(.callout)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }

                HStack {
                    TextField("Custom path to ffmpeg binary", text: $viewModel.ffmpegUserPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                    Button("Choose\u{2026}") { showingFilePicker = true }
                    if !viewModel.ffmpegUserPath.isEmpty {
                        Button("Clear") { viewModel.ffmpegUserPath = "" }
                    }
                }
            } header: {
                Text("FFmpeg")
            } footer: {
                Text("FFmpeg is used to repair videos that won\u{2019}t play in VideoMaster\u{2019}s built-in player (\u{201C}Fix for Built-in Player\u{201D} in the video context menu). VideoMaster auto-discovers ffmpeg at standard Homebrew and system paths. Set a custom path if your ffmpeg is installed elsewhere.")
            }
        }
        .formStyle(.grouped)
        .padding()
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.unixExecutable, .item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.ffmpegUserPath = url.path
            }
        }
    }
}
