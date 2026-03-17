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
            CommandGroup(replacing: .appInfo) {
                Button("About VideoMaster") {
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .version: "build \(build)"
                    ])
                }
            }
            CommandGroup(after: .newItem) {
                Button("Add Folder...") {
                    appState.libraryViewModel?.showFolderPicker()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!appState.hasLibrary)
            }
            CommandGroup(replacing: .importExport) {
                if !DatabaseExportImport.defaultLibraryExists {
                    Button("Create library in default location") {
                        DatabaseExportImport.createLibraryInDefaultLocation()
                    }
                    .disabled(appState.hasLibrary)
                }
                Button("New Library...") {
                    DatabaseExportImport.createNewLibrary()
                }
                Button("Open Library...") {
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
                Button("Save Copy...") {
                    if let pool = appState.dbManager?.dbPool {
                        DatabaseExportImport.saveCopy(dbPool: pool)
                    }
                }
                .disabled(!appState.hasLibrary)
                Divider()
                Button("Close Library...") {
                    DatabaseExportImport.closeLibrary()
                }
                .disabled(!appState.hasLibrary)
                Button("Delete This Library...") {
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
            if let pool = appState.dbManager?.dbPool, let vm = appState.libraryViewModel {
                SettingsView(dbPool: pool, viewModel: vm)
            } else {
                Text("Open a library to access settings")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
