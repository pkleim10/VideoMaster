import GRDB
import SwiftUI

struct CollectionEditorView: View {
    let dbPool: DatabasePool
    let collection: VideoCollection?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var rules: [EditableRule] = []

    struct EditableRule: Identifiable {
        let id = UUID()
        var attribute: RuleAttribute = .name
        var comparison: RuleComparison = .equals
        var value: String = ""
    }

    private var repository: CollectionRepository {
        CollectionRepository(dbPool: dbPool)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !rules.isEmpty
            && rules.allSatisfy { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            rulesArea
            Divider()
            footer
        }
        .frame(width: 620, height: 400)
        .onAppear { loadExisting() }
    }

    private var header: some View {
        HStack {
            Text("Collection Name:")
                .fontWeight(.medium)
            TextField("e.g. Large Files", text: $name)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }

    private var rulesArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match videos where ALL of the following are true:")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        ruleRow(index: index, rule: rule)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Button(action: addRule) {
                Label("Add Condition", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }

    private func ruleRow(index: Int, rule: EditableRule) -> some View {
        HStack(spacing: 8) {
            Picker("Attribute", selection: $rules[index].attribute) {
                ForEach(RuleAttribute.allCases) { attr in
                    Text(attr.label).tag(attr)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .onChange(of: rules[index].attribute) { _, newAttr in
                let supported = newAttr.supportedComparisons
                if !supported.contains(rules[index].comparison) {
                    rules[index].comparison = supported.first ?? .equals
                }
            }

            Picker("Comparison", selection: $rules[index].comparison) {
                ForEach(rules[index].attribute.supportedComparisons) { comp in
                    Text(comp.label).tag(comp)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            TextField(rules[index].attribute.valuePlaceholder, text: $rules[index].value)
                .textFieldStyle(.roundedBorder)

            Button(action: { removeRule(at: index) }) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(rules.count <= 1)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(collection == nil ? "Create" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding()
    }

    // MARK: - Actions

    private func addRule() {
        rules.append(EditableRule())
    }

    private func removeRule(at index: Int) {
        guard rules.count > 1 else { return }
        rules.remove(at: index)
    }

    private func loadExisting() {
        guard let existing = collection else {
            rules = [EditableRule()]
            return
        }
        name = existing.name
        Task {
            guard let id = existing.id else { return }
            let dbRules = (try? await repository.fetchRules(for: id)) ?? []
            if dbRules.isEmpty {
                rules = [EditableRule()]
            } else {
                rules = dbRules.map { r in
                    EditableRule(attribute: r.attribute, comparison: r.comparison, value: r.value)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        Task {
            if var existing = collection {
                existing.name = trimmedName
                try? await repository.update(existing)
                if let id = existing.id {
                    let dbRules = rules.map { r in
                        CollectionRule(
                            collectionId: id,
                            attribute: r.attribute,
                            comparison: r.comparison,
                            value: r.value.trimmingCharacters(in: .whitespaces)
                        )
                    }
                    try? await repository.replaceRules(for: id, with: dbRules)
                }
            } else {
                let newCollection = VideoCollection(name: trimmedName, dateCreated: Date())
                let saved = try? await repository.insert(newCollection)
                if let id = saved?.id {
                    let dbRules = rules.map { r in
                        CollectionRule(
                            collectionId: id,
                            attribute: r.attribute,
                            comparison: r.comparison,
                            value: r.value.trimmingCharacters(in: .whitespaces)
                        )
                    }
                    try? await repository.replaceRules(for: id, with: dbRules)
                }
            }
            onSave()
            dismiss()
        }
    }
}
