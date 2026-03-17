import SwiftUI

struct LandingView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            Text("VideoMaster")
                .font(.title)
                .fontWeight(.medium)

            Text("Create or open a library to get started")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                if !DatabaseExportImport.defaultLibraryExists {
                    Button(action: { DatabaseExportImport.createLibraryInDefaultLocation() }) {
                        Label("Create library in default location", systemImage: "plus.circle.fill")
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Button(action: { DatabaseExportImport.createNewLibrary() }) {
                    Label("Create library…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: { DatabaseExportImport.openLibraryFromUserSelection() }) {
                    Label("Open library…", systemImage: "folder")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if !DatabaseExportImport.recentLibraryItems().isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    Text("Open recent")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    ForEach(DatabaseExportImport.recentLibraryItems()) { item in
                        Button(action: { DatabaseExportImport.switchToLibrary(item) }) {
                            Label(item.displayName, systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: 200)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
