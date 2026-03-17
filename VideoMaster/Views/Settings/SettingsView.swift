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
