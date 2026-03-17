import SwiftUI

@main
struct VideoMasterApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder...") {
                    appState.libraryViewModel.showFolderPicker()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(dbPool: appState.dbManager.dbPool, viewModel: appState.libraryViewModel)
        }
    }
}
