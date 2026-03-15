import Foundation
import GRDB

@MainActor
@Observable
final class AppState {
    let dbManager: DatabaseManager
    let libraryViewModel: LibraryViewModel
    let thumbnailService: ThumbnailService

    init() {
        do {
            let db = try DatabaseManager()
            let thumbService = ThumbnailService()
            self.dbManager = db
            self.thumbnailService = thumbService
            self.libraryViewModel = LibraryViewModel(
                dbPool: db.dbPool,
                thumbnailService: thumbService
            )
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }
}
