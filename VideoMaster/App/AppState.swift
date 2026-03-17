import Foundation
import GRDB

@MainActor
@Observable
final class AppState {
    let dbManager: DatabaseManager?
    let libraryViewModel: LibraryViewModel?
    let thumbnailService: ThumbnailService

    var hasLibrary: Bool { dbManager != nil }

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
    }
}
