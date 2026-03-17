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
        }
        .frame(minWidth: 500, minHeight: 350)
    }
}

struct LibrarySettingsView: View {
    @Bindable var viewModel: LibraryViewModel

    var body: some View {
        Form {
            Toggle("Exclude corrupt files from filters", isOn: $viewModel.excludeCorrupt)

            Text("Corrupt files (missing duration and resolution) will be hidden from Library, Collections, Rating, and Tag filters. They remain visible in the Corrupt filter and name search.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Divider()
                .padding(.vertical, 4)

            Toggle("Confirm deletions", isOn: $viewModel.confirmDeletions)

            Text("When enabled, a confirmation dialog will appear before permanently deleting files from disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct VideoSettingsView: View {
    @Bindable var viewModel: LibraryViewModel

    var body: some View {
        Form {
            Section("Default Filmstrip Size") {
                HStack(spacing: 24) {
                    compactStepper("Rows", value: $viewModel.defaultFilmstripRows, range: 1...6)
                    compactStepper("Columns", value: $viewModel.defaultFilmstripColumns, range: 1...8)
                }

                Text("\(viewModel.defaultFilmstripRows * viewModel.defaultFilmstripColumns) frames per filmstrip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("This sets the default grid size when generating new filmstrips. You can override it per video using Modify Filmstrip.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
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
