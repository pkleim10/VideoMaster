import SwiftUI

struct ApplicationSettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appState.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows macOS light or dark mode. Light and Dark lock VideoMaster to that style regardless of system setting.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
