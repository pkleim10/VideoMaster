import AppKit
import GRDB
import SwiftUI

struct DataSourcesSettingsView: View {
    let dbPool: DatabasePool

    @State private var dataSources: [DataSource] = []
    @State private var selectedId: Int64?
    @State private var isLoading = false

    private var repository: DataSourceRepository {
        DataSourceRepository(dbPool: dbPool)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Folders that VideoMaster watches for video files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            List(dataSources, selection: $selectedId) { source in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                            .fontWeight(.medium)
                        Text(source.folderPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(source.dateAdded, style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)
            .overlay {
                if dataSources.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No data sources")
                            .foregroundStyle(.secondary)
                        Text("Add folders to watch for video files")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: addFolder) {
                    Image(systemName: "plus")
                }
                .help("Add a folder")

                Button(action: removeSelected) {
                    Image(systemName: "minus")
                }
                .disabled(selectedId == nil)
                .help("Remove selected folder")

                Spacer()

                Button("Reveal in Finder") {
                    if let id = selectedId,
                       let source = dataSources.first(where: { $0.id == id })
                    {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: source.folderPath)
                    }
                }
                .disabled(selectedId == nil)
                .controlSize(.small)
            }
            .padding(10)
        }
        .task {
            await loadDataSources()
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select folders to watch for video files"
        panel.prompt = "Add"

        if panel.runModal() == .OK {
            Task {
                for url in panel.urls {
                    let path = url.path
                    let exists = (try? await repository.exists(folderPath: path)) ?? false
                    if !exists {
                        let source = DataSource(
                            folderPath: path,
                            name: url.lastPathComponent,
                            dateAdded: Date()
                        )
                        try? await repository.insert(source)
                    }
                }
                await loadDataSources()
            }
        }
    }

    private func removeSelected() {
        guard let id = selectedId,
              let source = dataSources.first(where: { $0.id == id })
        else { return }

        Task {
            try? await repository.delete(source)
            selectedId = nil
            await loadDataSources()
        }
    }

    private func loadDataSources() async {
        isLoading = true
        dataSources = (try? await repository.fetchAll()) ?? []
        isLoading = false
    }
}
