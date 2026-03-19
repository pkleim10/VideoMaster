import GRDB
import SwiftUI

struct SettingsView: View {
    let dbPool: GRDB.DatabasePool
    @Bindable var viewModel: LibraryViewModel

    var body: some View {
        TabView {
            LibrarySettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }

            VideoSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Video", systemImage: "film")
                }

            DataSourcesSettingsView(dbPool: dbPool)
                .tabItem {
                    Label("Data Sources", systemImage: "folder")
                }

            FileExtSettingsView()
                .tabItem {
                    Label("File Ext", systemImage: "doc.badge.gearshape")
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
                        .foregroundStyle(viewModel.showRecentlyAdded ? .secondary : .tertiary)
                }

                filterRow(
                    title: "Recently Played",
                    isOn: $viewModel.showRecentlyPlayed
                ) {
                    daysField(value: $viewModel.recentlyPlayedDays)
                        .disabled(!viewModel.showRecentlyPlayed)
                    Text("days")
                        .foregroundStyle(viewModel.showRecentlyPlayed ? .secondary : .tertiary)
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
                        .foregroundStyle(.secondary)
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
                Text("When enabled, clicking Surprise Me! will immediately start playing the randomly selected video. When disabled, the video is selected and scrolled to but not played.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func compactStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
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
