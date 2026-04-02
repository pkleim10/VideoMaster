import AppKit
import SwiftUI

@main
struct VideoMasterApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    DatabaseExportImport.checkpointAndCleanWAL()
                }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Surprise Me!") {
                    appState.libraryViewModel?.surpriseMePickRandom()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(appState.libraryViewModel?.filteredVideos.isEmpty ?? true)

                Button("Clear Filters") {
                    appState.libraryViewModel?.clearFilters()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!appState.hasLibrary
                    || ((appState.libraryViewModel?.selectedTagIds.isEmpty ?? true)
                        && !(appState.libraryViewModel?.isRatingFilterActive ?? false)))

                Button("Toggle Thumbnail / Filmstrip") {
                    appState.libraryViewModel?.showThumbnailInDetail.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!appState.hasLibrary)

                Button {
                    appState.libraryViewModel?.showFilterStrip.toggle()
                } label: {
                    Text((appState.libraryViewModel?.showFilterStrip ?? true) ? "Collapse Filter Strip" : "Expand Filter Strip")
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!appState.hasLibrary)
            }
            CommandGroup(after: .pasteboard) {
                Button("Delete\u{2026}") {
                    guard let vm = appState.libraryViewModel,
                          !vm.selectedVideoIds.isEmpty
                    else { return }
                    if vm.confirmDeletions {
                        vm.pendingDeleteIds = vm.selectedVideoIds
                        vm.showDeleteConfirmation = true
                    } else {
                        let ids = vm.selectedVideoIds
                        Task { await vm.deleteVideos(ids) }
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(appState.libraryViewModel?.selectedVideoIds.isEmpty != false)

                Button("Remove from Library") {
                    guard let vm = appState.libraryViewModel,
                          !vm.selectedVideoIds.isEmpty
                    else { return }
                    let ids = vm.selectedVideoIds
                    Task { await vm.removeVideosFromLibrary(ids) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(appState.libraryViewModel?.selectedVideoIds.isEmpty != false)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About VideoMaster") {
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .version: "build \(build)"
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Folder\u{2026}") {
                    appState.libraryViewModel?.showFolderPicker()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!appState.hasLibrary)
            }
            CommandGroup(replacing: .importExport) {
                Button("Play in External Player") {
                    guard let vm = appState.libraryViewModel,
                          let videoId = vm.selectedVideoIds.first,
                          let video = vm.filteredVideos.first(where: { $0.id == videoId })
                    else { return }
                    NSWorkspace.shared.open(video.url)
                    Task { await vm.recordPlay(for: video) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(appState.libraryViewModel?.selectedVideoIds.first == nil)

                Button("Show in Finder") {
                    guard let vm = appState.libraryViewModel,
                          let videoId = vm.selectedVideoIds.first,
                          let video = vm.filteredVideos.first(where: { $0.id == videoId })
                    else { return }
                    NSWorkspace.shared.selectFile(video.filePath, inFileViewerRootedAtPath: "")
                }
                .disabled(appState.libraryViewModel?.selectedVideoIds.first == nil)

                if let vm = appState.libraryViewModel,
                   let videoId = vm.selectedVideoIds.first,
                   let video = vm.filteredVideos.first(where: { $0.id == videoId })
                {
                    Menu("Open With") {
                        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: video.url)
                        ForEach(appURLs, id: \.self) { appURL in
                            Button(appURL.deletingPathExtension().lastPathComponent) {
                                NSWorkspace.shared.open(
                                    [video.url],
                                    withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()
                                )
                                Task { await vm.recordPlay(for: video) }
                            }
                        }
                    }
                }

                Divider()

                if !DatabaseExportImport.defaultLibraryExists {
                    Button("Create library in default location") {
                        DatabaseExportImport.createLibraryInDefaultLocation()
                    }
                    .disabled(appState.hasLibrary)
                }
                Button("New Library\u{2026}") {
                    DatabaseExportImport.createNewLibrary()
                }
                Button("Open Library\u{2026}") {
                    DatabaseExportImport.openLibraryFromUserSelection()
                }
                Menu("Open Recent") {
                    ForEach(DatabaseExportImport.recentLibraryItems()) { item in
                        Button(item.displayName) {
                            DatabaseExportImport.switchToLibrary(item)
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        DatabaseExportImport.clearRecentLibraries()
                    }
                    .disabled(DatabaseExportImport.recentLibraryItems().isEmpty)
                }
                .disabled(DatabaseExportImport.recentLibraryItems().isEmpty)
                Divider()
                Button("Save Copy\u{2026}") {
                    if let pool = appState.dbManager?.dbPool {
                        DatabaseExportImport.saveCopy(dbPool: pool)
                    }
                }
                .disabled(!appState.hasLibrary)
                Divider()
                Button("Close Library\u{2026}") {
                    DatabaseExportImport.closeLibrary()
                }
                .disabled(!appState.hasLibrary)
                Button("Delete This Library\u{2026}") {
                    guard let url = DatabaseExportImport.activeLibraryURL() else { return }
                    let alert = NSAlert()
                    alert.messageText = "Delete This Library?"
                    alert.informativeText = "This will permanently delete the library file from disk. This action cannot be undone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        DatabaseExportImport.deleteThisLibrary(at: url)
                    }
                }
                .disabled(!appState.hasLibrary)
            }
        }

        Settings {
            SettingsView(appState: appState)
        }
    }
}
