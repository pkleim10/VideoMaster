import SwiftUI

/// A custom segmented control styled for the Cinematic Blue design system.
/// Provides a sliding pill selection indicator with glass/surface treatment
/// instead of the stock segmented picker.
struct AppSegmentedControl<Selection: Hashable>: View {
    @Binding var selection: Selection
    let items: [Selection]
    private let makeLabel: (Selection) -> AnyView

    @Namespace private var namespace

    init<Label: View>(
        selection: Binding<Selection>,
        items: [Selection],
        @ViewBuilder label: @escaping (Selection) -> Label
    ) {
        self._selection = selection
        self.items = items
        self.makeLabel = { AnyView(label($0)) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isSelected = selection == item

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        selection = item
                    }
                } label: {
                    makeLabel(item)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                .fill(Color.appAccent.opacity(0.20))
                                .matchedGeometryEffect(id: "selectionPill", in: namespace)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                        .stroke(Color.appAccent.opacity(0.45), lineWidth: 1)
                                )
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Material.appSubtleGlass)
                .background(Color.appSurface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(Color.appAccent.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .frame(height: 28)
    }
}
