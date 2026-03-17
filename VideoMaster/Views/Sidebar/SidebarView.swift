import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: LibraryViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var showNewCollectionSheet = false
    @State private var editingCollection: VideoCollection?
    @State private var renamingTag: Tag = Tag(name: "")
    @State private var showRenameTag = false
    @State private var renameText = ""
    @State private var showNewTag = false
    @State private var newTagName = ""

    private static let maxVisibleItems = 10
    private static let rowHeight: CGFloat = 24

    var body: some View {
        List(selection: $viewModel.sidebarFilter) {
            sectionHeader("LIBRARY", isExpanded: $viewModel.isLibraryExpanded)
                .selectionDisabled()
                .listRowSeparator(.hidden)
            if viewModel.isLibraryExpanded {
                sidebarRow("All Videos", icon: "film.stack", count: viewModel.libraryCounts.all)
                    .tag(SidebarFilter.all)
                sidebarRow("Recently Added", icon: "clock", count: viewModel.libraryCounts.recentlyAdded)
                    .tag(SidebarFilter.recentlyAdded)
                sidebarRow("Recently Played", icon: "play.circle", count: viewModel.libraryCounts.recentlyPlayed)
                    .tag(SidebarFilter.recentlyPlayed)
                sidebarRow("Top Rated", icon: "star.fill", count: viewModel.libraryCounts.topRated)
                    .tag(SidebarFilter.topRated)
                sidebarRow("Corrupt", icon: "exclamationmark.triangle", count: viewModel.libraryCounts.corrupt)
                    .tag(SidebarFilter.corrupt)
            }

            sectionHeader("COLLECTIONS", isExpanded: $viewModel.isCollectionsExpanded)
                .padding(.top, 12)
                .selectionDisabled()
                .listRowSeparator(.hidden)
            if viewModel.isCollectionsExpanded {
                if viewModel.collections.isEmpty {
                    Text("No collections")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                } else if viewModel.collections.count <= Self.maxVisibleItems {
                    ForEach(viewModel.collections, id: \.listId) { collection in
                        collectionRow(collection)
                            .tag(SidebarFilter.collection(collection))
                            .contextMenu {
                                Button("Edit Collection...") {
                                    editingCollection = collection
                                }
                                Divider()
                                Button("Delete Collection", role: .destructive) {
                                    Task { await viewModel.deleteCollection(collection) }
                                }
                            }
                    }
                } else {
                    scrollableCollections
                        .selectionDisabled()
                }

                Button(action: { showNewCollectionSheet = true }) {
                    Label("New Collection", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            sectionHeader("RATING", isExpanded: $viewModel.isRatingExpanded)
                .padding(.top, 12)
                .selectionDisabled()
                .listRowSeparator(.hidden)
            if viewModel.isRatingExpanded {
                ForEach((1...5).reversed(), id: \.self) { stars in
                    ratingRow(stars: stars, count: viewModel.libraryCounts.byRating[stars] ?? 0)
                        .tag(SidebarFilter.rating(stars))
                }
            }

            tagsSectionHeader
                .padding(.top, 12)
                .selectionDisabled()
                .listRowSeparator(.hidden)
            if viewModel.isTagsExpanded {
                if viewModel.tags.isEmpty {
                    Text("No tags yet")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                } else {
                    ForEach(viewModel.tags, id: \.listId) { tag in
                        tagRow(tag)
                            .contextMenu { tagContextMenu(tag) }
                    }
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
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
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
        .sheet(isPresented: $showRenameTag) {
            VStack(spacing: 16) {
                Text("Rename Tag")
                    .font(.headline)
                TextField("Tag name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let tag = renamingTag
                        Task { await viewModel.renameTag(tag, to: trimmed) }
                        showRenameTag = false
                    }
                HStack {
                    Button("Cancel") { showRenameTag = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Rename") {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let tag = renamingTag
                        Task { await viewModel.renameTag(tag, to: trimmed) }
                        showRenameTag = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 280)
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
                        Button("Edit Collection...") {
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
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }

    private var tagsSectionHeader: some View {
        HStack(spacing: 4) {
            Button(action: { withAnimation { viewModel.isTagsExpanded.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.isTagsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text("TAGS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
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
            }
        }
    }

    private func sectionHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button(action: { withAnimation { isExpanded.wrappedValue.toggle() } }) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func tagRow(_ tag: Tag) -> some View {
        let tagId = tag.id ?? -1
        let isSelected = viewModel.selectedTagIds.contains(tagId)
        return HStack {
            Label(tag.name, systemImage: "tag")
                .foregroundStyle(isSelected ? .primary : .primary)
            Spacer()
            Text("\(viewModel.tagCounts[tagId] ?? 0)")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
        }
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.3))
                : nil
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .contentShape(Rectangle())
        .onTapGesture {
            handleTagTap(tag)
        }
        .selectionDisabled()
    }

    private func handleTagTap(_ tag: Tag) {
        guard let tagId = tag.id else { return }
        let cmdHeld = NSEvent.modifierFlags.contains(.command)

        if cmdHeld {
            if viewModel.selectedTagIds.contains(tagId) {
                viewModel.selectedTagIds.remove(tagId)
                if viewModel.selectedTagIds.isEmpty {
                    viewModel.sidebarFilter = .all
                }
            } else {
                viewModel.selectedTagIds.insert(tagId)
                viewModel.sidebarFilter = .tags
            }
        } else {
            if viewModel.selectedTagIds == [tagId] {
                viewModel.selectedTagIds = []
                viewModel.sidebarFilter = .all
            } else {
                viewModel.selectedTagIds = [tagId]
                viewModel.sidebarFilter = .tags
            }
        }
    }

    @ViewBuilder
    private func tagContextMenu(_ tag: Tag) -> some View {
        Button("Rename Tag...") {
            renamingTag = tag
            renameText = tag.name
            DispatchQueue.main.async {
                showRenameTag = true
            }
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

    private func sidebarRow(_ title: String, icon: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
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
}
