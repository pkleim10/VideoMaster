import SwiftUI

struct LandingView: View {
    var body: some View {
        VStack(spacing: AppSpacing.xxxl) {
            // App icon
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)

            // Title + subtitle
            VStack(spacing: AppSpacing.sm) {
                Text("VideoMaster")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)

                Text("Create or open a library to get started")
                    .font(.title3)
                    .foregroundStyle(Color.appTextSecondary)
            }

            // Main action card
            VStack(spacing: AppSpacing.lg) {
                // Primary create actions
                VStack(spacing: AppSpacing.md) {
                    if !DatabaseExportImport.defaultLibraryExists {
                        Button(action: { DatabaseExportImport.createLibraryInDefaultLocation() }) {
                            Label("Create library in default location", systemImage: "plus.circle.fill")
                                .frame(maxWidth: 260)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appAccent)
                        .controlSize(.large)
                    }

                    Button(action: { DatabaseExportImport.createNewLibrary() }) {
                        Label("Create library…", systemImage: "folder.badge.plus")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.appAccent)
                    .controlSize(.large)

                    Button(action: { DatabaseExportImport.openLibraryFromUserSelection() }) {
                        Label("Open library…", systemImage: "folder")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.appAccent)
                    .controlSize(.large)
                }

                // Recents
                if !DatabaseExportImport.recentLibraryItems().isEmpty {
                    Rectangle()
                        .fill(Color.appDivider)
                        .frame(height: 1)
                        .padding(.vertical, AppSpacing.xs)

                    Text("Open recent")
                        .font(.headline)
                        .foregroundStyle(Color.appTextSecondary)

                    VStack(spacing: AppSpacing.xs) {
                        ForEach(DatabaseExportImport.recentLibraryItems()) { item in
                            Button(action: { DatabaseExportImport.switchToLibrary(item) }) {
                                HStack {
                                    Label(item.displayName, systemImage: "clock.arrow.circlepath")
                                    Spacer()
                                }
                                .frame(maxWidth: 260)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.appTextPrimary)
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                    .fill(Color.appHover)
                            )
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .padding(.vertical, AppSpacing.xl)
            .padding(.horizontal, AppSpacing.xxl)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .fill(Material.appSubtleGlass)
                    .background(Color.appSurface.opacity(0.75))
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.15), lineWidth: 1)
            )
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}
