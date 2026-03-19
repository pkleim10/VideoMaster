import SwiftUI

struct FileExtSettingsView: View {
    @Bindable private var manager = VideoExtensionManager.shared
    @State private var newExt: String = ""

    var body: some View {
        Form {
            Section {
                ForEach(manager.entries) { entry in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { entry.enabled },
                            set: { manager.setEnabled(entry.ext, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()

                        Text(".\(entry.ext)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(entry.enabled ? .primary : .secondary)

                        Spacer()

                        Button {
                            manager.remove(entry.ext)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Extensions")
            } footer: {
                Text("Extensions recognized as video files when scanning folders. Uncheck to temporarily exclude an extension from scans.")
            }

            Section("Add extension") {
                HStack(spacing: 8) {
                    TextField("e.g. mp4", text: $newExt)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onSubmit { addNew() }

                    Button("Add") {
                        addNew()
                    }
                    .disabled(newExt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section {
                Button("Reset to defaults") {
                    manager.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func addNew() {
        let trimmed = newExt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.add(trimmed)
        newExt = ""
    }
}
