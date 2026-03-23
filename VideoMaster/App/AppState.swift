import AppKit
import Foundation
import GRDB

@MainActor
@Observable
final class AppState {
    private static let appearanceKey = "VideoMaster.appearanceMode"

    let dbManager: DatabaseManager?
    let libraryViewModel: LibraryViewModel?
    let thumbnailService: ThumbnailService

    var hasLibrary: Bool { dbManager != nil }

    /// Light / Dark / System — persisted and applied to `NSApp.appearance`.
    var appearance: AppAppearance = .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
            Self.applyAppearance(appearance)
        }
    }

    init() {
        thumbnailService = ThumbnailService()
        var db: DatabaseManager?
        var vm: LibraryViewModel?
        do {
            _ = try DatabaseExportImport.prepareDatabaseForLaunch()
            let userClosed = DatabaseExportImport.userClosedLibrary
            DatabaseExportImport.clearUserClosedLibrary()
            if !userClosed, let path = DatabaseExportImport.databasePathForLaunch() {
                let manager = try DatabaseManager(path: path)
                db = manager
                vm = LibraryViewModel(
                    dbPool: manager.dbPool,
                    thumbnailService: thumbnailService
                )
            }
        } catch {
            // File deleted, corrupted, or no library — show landing
        }
        dbManager = db
        libraryViewModel = vm
        DatabaseExportImport.activeDbPool = db?.dbPool

        if let raw = UserDefaults.standard.string(forKey: Self.appearanceKey),
           let mode = AppAppearance(rawValue: raw)
        {
            appearance = mode
        }
        // `NSApp` / shared application is not ready during `App.init` — applying here crashes (IUO nil).
        let mode = appearance
        DispatchQueue.main.async {
            Self.applyAppearance(mode)
        }
    }

    static func applyAppearance(_ mode: AppAppearance) {
        // Prefer `shared` over `NSApp` — safer if anything queries before full activation.
        let app = NSApplication.shared
        switch mode {
        case .system:
            app.appearance = nil
        case .light:
            app.appearance = NSAppearance(named: .aqua)
        case .dark:
            app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
