import SwiftUI

/// Shared content for Library settings and the list-view “Columns…” sheet.
struct ListColumnsSettingsContent: View {
    @Bindable var viewModel: LibraryViewModel

    /// Multiline “text” custom fields are omitted from list columns (use string or other types).
    private var listableCustomDefinitions: [CustomMetadataFieldDefinition] {
        viewModel.customMetadataFieldDefinitions
            .filter { $0.valueType != .text }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            HStack {
                Label("Name", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Always visible")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Duration", isOn: bindingStandard("duration"))
            Toggle("Resolution", isOn: bindingStandard("resolution"))
            Toggle("File size", isOn: bindingStandard("size"))
            Toggle("Rating", isOn: bindingStandard("rating"))
            Toggle("Date added", isOn: bindingStandard("dateAdded"))
            Toggle("Plays", isOn: bindingStandard("playCount"))
            Toggle("Created", isOn: bindingStandard("created"))
            Toggle("Last played", isOn: bindingStandard("lastPlayed"))

            if listableCustomDefinitions.isEmpty {
                Text("No listable custom metadata fields (multiline “Text” fields are excluded). Add fields in the Custom Metadata settings tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ForEach(listableCustomDefinitions) { field in
                    Toggle(field.name, isOn: bindingCustom(field.id))
                }
            }
        }
    }

    private func bindingStandard(_ id: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.isStandardListColumnVisible(id) },
            set: { viewModel.setStandardListColumnVisible(id, visible: $0) }
        )
    }

    private func bindingCustom(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { viewModel.isCustomListFieldVisible(id) },
            set: { viewModel.setCustomListFieldVisible(fieldId: id, visible: $0) }
        )
    }
}
