import AppKit
import SwiftUI

/// Four filter columns (Library, Collections, Rating, Tags) below the list/grid, side by side.
/// Replaces the former left `SidebarView` while preserving the same `LibraryViewModel` bindings and behavior.
struct BottomFilterColumnsView: View {
    @Bindable var viewModel: LibraryViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var showNewCollectionSheet = false
    @State private var editingCollection: VideoCollection?
    @FocusState private var isTagRenameFocused: Bool
    @State private var showNewTag = false
    @State private var newTagName = ""

    private static let maxVisibleItems = 10
    private static let rowHeight: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            libraryColumn
                .frame(minWidth: 140, maxWidth: .infinity)
            Divider()
            collectionsColumn
                .frame(minWidth: 140, maxWidth: .infinity)
            Divider()
            ratingColumn
                .frame(minWidth: 120, maxWidth: .infinity)
            Divider()
            tagsColumn
                .frame(minWidth: 160, maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .contextMenu {
            Button(viewModel.showFilterStrip ? "Collapse Filter Strip" : "Expand Filter Strip") {
                viewModel.showFilterStrip.toggle()
            }
        }
        .sheet(isPresented: $showNewCollectionSheet) {
            CollectionEditorView(
                dbPool: viewModel.dbPool,
                collection: nil,
                onSave: { Task { await viewModel.loadCollections() } }
            )
        }
        .sheet(item: $editingCollection) { collection in
            CollectionEditorView(
                dbPool: viewModel.dbPool,
                collection: collection,
                onSave: { Task { await viewModel.loadCollections() } }
            )
        }
        .sheet(isPresented: $showNewTag) {
            VStack(spacing: 16) {
                Text("New Tag")
                    .font(.headline)
                TextField("Tag name", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task { await viewModel.createTag(trimmed) }
                        showNewTag = false
                    }
                HStack {
                    Button("Cancel") { showNewTag = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Create") {
                        let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task { await viewModel.createTag(trimmed) }
                        showNewTag = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 280)
        }
    }

    // MARK: - Columns

    private var libraryColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("LIBRARY")
            List(selection: $viewModel.sidebarFilter) {
                sidebarRow("All Videos", icon: "film.stack", count: viewModel.libraryCounts.all)
                    .tag(SidebarFilter.all)
                if viewModel.showRecentlyAdded {
                    sidebarRow("Recently Added", icon: "clock", count: viewModel.libraryCounts.recentlyAdded)
                        .tag(SidebarFilter.recentlyAdded)
                }
                if viewModel.showRecentlyPlayed {
                    sidebarRow("Recently Played", icon: "play.circle", count: viewModel.libraryCounts.recentlyPlayed)
                        .tag(SidebarFilter.recentlyPlayed)
                }
                if viewModel.showTopRated {
                    sidebarRow("Top Rated", icon: "star.fill", count: viewModel.libraryCounts.topRated)
                        .tag(SidebarFilter.topRated)
                }
                if viewModel.showDuplicates {
                    sidebarRow("Duplicates", icon: "doc.on.doc", count: viewModel.libraryCounts.duplicates)
                        .tag(SidebarFilter.duplicates)
                }
                if viewModel.showCorrupt {
                    sidebarRow("Corrupt", icon: "exclamationmark.triangle", count: viewModel.libraryCounts.corrupt)
                        .tag(SidebarFilter.corrupt)
                }
                if viewModel.showMissing {
                    sidebarRow("Missing", icon: "questionmark.circle", count: viewModel.libraryCounts.missing, unscanned: !viewModel.missingCountScanned)
                        .tag(SidebarFilter.missing)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120)
        }
        .padding(8)
    }

    private var collectionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("COLLECTIONS")
            if viewModel.collections.isEmpty {
                Text("No collections")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .padding(.vertical, 4)
            } else if viewModel.collections.count <= Self.maxVisibleItems {
                List(selection: $viewModel.sidebarFilter) {
                    ForEach(viewModel.collections, id: \.listId) { collection in
                        collectionRow(collection)
                            .tag(SidebarFilter.collection(collection))
                            .contextMenu {
                                Button("Edit Collection\u{2026}") {
                                    editingCollection = collection
                                }
                                Divider()
                                Button("Delete Collection", role: .destructive) {
                                    Task { await viewModel.deleteCollection(collection) }
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80)
            } else {
                scrollableCollections
            }

            Button(action: { showNewCollectionSheet = true }) {
                Label("New Collection", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.caption)
            .padding(.top, 4)
        }
        .padding(8)
    }

    private var ratingColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ratingSectionHeader
            List(selection: $viewModel.sidebarFilter) {
                ForEach((1...5).reversed(), id: \.self) { stars in
                    ratingRow(stars: stars, count: viewModel.libraryCounts.byRating[stars] ?? 0)
                        .tag(SidebarFilter.rating(stars))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120)
        }
        .padding(8)
    }

    private var tagsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            tagsSectionHeader
            if viewModel.tags.isEmpty {
                Text("No tags yet")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.tags, id: \.listId) { tag in
                            tagRow(tag)
                                .contextMenu { tagContextMenu(tag) }
                        }
                    }
                }
                .frame(minHeight: 80)
            }

            Button(action: {
                newTagName = ""
                showNewTag = true
            }) {
                Label("New Tag", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.caption)
            .padding(.top, 4)
        }
        .padding(8)
    }

    // MARK: - Shared (from former SidebarView)

    private var scrollableCollections: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(viewModel.collections, id: \.listId) { collection in
                    let isActive = {
                        if case .collection(let sel) = viewModel.sidebarFilter { return sel == collection }
                        return false
                    }()
                    HStack {
                        Label(collection.name, systemImage: "folder.fill")
                        Spacer()
                        Text("\(viewModel.collectionCounts[collection.id ?? -1] ?? 0)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .background(
                        isActive ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.3)) : nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.sidebarFilter = .collection(collection)
                    }
                    .contextMenu {
                        Button("Edit Collection\u{2026}") {
                            editingCollection = collection
                        }
                        Divider()
                        Button("Delete Collection", role: .destructive) {
                            Task { await viewModel.deleteCollection(collection) }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: Self.rowHeight * CGFloat(Self.maxVisibleItems))
    }

    private var ratingSectionHeader: some View {
        HStack(spacing: 4) {
            Text("RATING")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if case .rating = viewModel.sidebarFilter {
                Button("Remove Filter") {
                    viewModel.sidebarFilter = .all
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
                .help("Clear rating filter")
            }
        }
        .padding(.bottom, 4)
    }

    private var tagsSectionHeader: some View {
        HStack(spacing: 4) {
            Text("TAGS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if !viewModel.tags.isEmpty {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.tagFilterMode = viewModel.tagFilterMode == .all ? .any : .all
                    }
                }) {
                    Text(viewModel.tagFilterMode == .all ? "ALL" : "ANY")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(viewModel.tagFilterMode == .all ? Color.accentColor : Color.orange)
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                if !viewModel.selectedTagIds.isEmpty {
                    Button("Remove Filter") {
                        viewModel.clearTagFilters()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
                    .help("Clear tag filters")
                }
            }
        }
        .contextMenu {
            Button("Clear Filters") {
                viewModel.clearFilters()
            }
            .disabled(viewModel.selectedTagIds.isEmpty && !viewModel.isRatingFilterActive)
            .keyboardShortcut("c", modifiers: [.command, .option])
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
    }

    private func tagRow(_ tag: Tag) -> some View {
        let tagId = tag.id ?? -1
        let isSelected = viewModel.selectedTagIds.contains(tagId)
        let isEditing = viewModel.renamingTagId == tagId
        return HStack {
            if isEditing {
                TextField("Tag name", text: $viewModel.tagRenameText)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor, lineWidth: 2)
                    )
                    .focused($isTagRenameFocused)
                    .onSubmit { commitTagRename(tag) }
                    .onExitCommand { cancelTagRename() }
                    .onAppear {
                        viewModel.isEditingText = true
                        DispatchQueue.main.async {
                            isTagRenameFocused = true
                        }
                    }
                    .onDisappear {
                        viewModel.isEditingText = false
                    }
            } else {
                Label(tag.name, systemImage: "tag")
                    .foregroundStyle(isSelected ? .primary : .primary)
            }
            Spacer()
            Text("\(viewModel.tagCounts[tagId] ?? 0)")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            isSelected
                ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.3))
                : nil
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleTagTap(tag)
        }
        .onTapGesture(count: 2) {
            startTagRename(tag)
        }
    }

    private func startTagRename(_ tag: Tag) {
        guard let tagId = tag.id else { return }
        viewModel.renamingTagId = tagId
        viewModel.tagRenameText = tag.name
        viewModel.isEditingText = true
        DispatchQueue.main.async {
            isTagRenameFocused = true
        }
    }

    private func commitTagRename(_ tag: Tag) {
        let trimmed = viewModel.tagRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelTagRename()
            return
        }
        viewModel.renamingTagId = nil
        viewModel.tagRenameText = ""
        viewModel.isEditingText = false
        Task { await viewModel.renameTag(tag, to: trimmed) }
    }

    private func cancelTagRename() {
        viewModel.renamingTagId = nil
        viewModel.tagRenameText = ""
        viewModel.isEditingText = false
    }

    private func handleTagTap(_ tag: Tag) {
        guard let tagId = tag.id else { return }
        let cmdHeld = NSEvent.modifierFlags.contains(.command)

        if cmdHeld {
            if viewModel.selectedTagIds.contains(tagId) {
                viewModel.selectedTagIds.remove(tagId)
            } else {
                viewModel.selectedTagIds.insert(tagId)
            }
        } else {
            if viewModel.selectedTagIds == [tagId] {
                viewModel.selectedTagIds = []
            } else {
                viewModel.selectedTagIds = [tagId]
            }
        }
    }

    @ViewBuilder
    private func tagContextMenu(_ tag: Tag) -> some View {
        Button("Rename Tag") {
            startTagRename(tag)
        }
        Divider()
        Button("Delete Tag", role: .destructive) {
            Task { await viewModel.deleteTag(tag) }
        }
    }

    private func collectionRow(_ collection: VideoCollection) -> some View {
        sidebarRow(collection.name, icon: "folder.fill", count: viewModel.collectionCounts[collection.id ?? -1] ?? 0)
    }

    private func ratingRow(stars: Int, count: Int) -> some View {
        HStack {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: i <= stars ? "star.fill" : "star")
                        .font(.caption2)
                        .foregroundColor(i <= stars ? (colorScheme == .dark ? .yellow : .black) : .gray.opacity(0.3))
                }
            }
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
        }
    }

    private func sidebarRow(_ title: String, icon: String, count: Int, unscanned: Bool = false) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(unscanned ? "—" : "\(count)")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
        }
    }
}
