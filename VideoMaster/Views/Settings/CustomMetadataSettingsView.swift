import SwiftUI

/// Defines custom metadata **fields** (name + type). Per-video values are not implemented here yet.
struct CustomMetadataSettingsView: View {
    @Bindable var viewModel: LibraryViewModel
    @State private var selectedFieldIds: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Define fields for custom metadata. Per-video editing will use these types in a later update.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            List(selection: $selectedFieldIds) {
                ForEach(viewModel.customMetadataFieldDefinitions) { field in
                    HStack(alignment: .center, spacing: 12) {
                        TextField(
                            "Name",
                            text: Binding(
                                get: { field.name },
                                set: { viewModel.updateCustomMetadataFieldName(id: field.id, name: $0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160, maxWidth: .infinity)

                        Picker(
                            "Type",
                            selection: Binding(
                                get: { field.valueType },
                                set: { viewModel.updateCustomMetadataFieldType(id: field.id, valueType: $0) }
                            )
                        ) {
                            ForEach(CustomMetadataValueType.allCases) { t in
                                Text(t.displayName).tag(t)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 168)
                    }
                    .tag(field.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button {
                    viewModel.removeCustomMetadataFields(ids: selectedFieldIds)
                    selectedFieldIds.removeAll()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .disabled(selectedFieldIds.isEmpty)
                .help("Remove selected field(s)")

                Button {
                    viewModel.addCustomMetadataField()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .help("Add field")
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
