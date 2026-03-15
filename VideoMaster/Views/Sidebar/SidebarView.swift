import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: LibraryViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var showNewCollectionSheet = false
    @State private var editingCollection: VideoCollection?

    var body: some View {
        List(selection: $viewModel.sidebarFilter) {
            Section("LIBRARY") {
                sidebarRow("All Videos", icon: "film.stack", count: viewModel.libraryCounts.all)
                    .tag(SidebarFilter.all)
                sidebarRow("Recently Added", icon: "clock", count: viewModel.libraryCounts.recentlyAdded)
                    .tag(SidebarFilter.recentlyAdded)
                sidebarRow("Recently Played", icon: "play.circle", count: viewModel.libraryCounts.recentlyPlayed)
                    .tag(SidebarFilter.recentlyPlayed)
                sidebarRow("Top Rated", icon: "star.fill", count: viewModel.libraryCounts.topRated)
                    .tag(SidebarFilter.topRated)
            }

            Section("COLLECTIONS") {
                if viewModel.collections.isEmpty {
                    Text("No collections")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                } else {
                    ForEach(viewModel.collections) { collection in
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
                }

                Button(action: { showNewCollectionSheet = true }) {
                    Label("New Collection", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            Section("RATING") {
                ForEach((1...5).reversed(), id: \.self) { stars in
                    ratingRow(stars: stars, count: viewModel.libraryCounts.byRating[stars] ?? 0)
                        .tag(SidebarFilter.rating(stars))
                }
            }

            Section("TAGS") {
                if viewModel.tags.isEmpty {
                    Text("No tags yet")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                } else {
                    ForEach(viewModel.tags) { tag in
                        sidebarRow(tag.name, icon: "tag", count: viewModel.tagCounts[tag.id ?? -1] ?? 0)
                            .tag(SidebarFilter.tag(tag))
                    }
                }
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
