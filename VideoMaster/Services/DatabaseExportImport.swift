import AppKit
import Foundation
import GRDB

struct RecentLibraryItem: Identifiable {
    let id: String
    let displayName: String
    let url: URL
}

enum DatabaseExportImport {
    private static let activeLibraryBookmarkKey = "VideoMaster.activeLibraryBookmark"
    private static let recentLibraryBookmarksKey = "VideoMaster.recentLibraryBookmarks"
    private static let userClosedLibraryKey = "VideoMaster.userClosedLibrary"
    private static let maxRecentLibraries = 10

    /// Stored reference to the active dbPool, set by AppState on init.
    nonisolated(unsafe) static var activeDbPool: DatabasePool?

    /// Checkpoints the current library and removes WAL files. Call before switching or closing.
    /// Only removes WAL/SHM files if the checkpoint succeeds — prevents data loss.
    static func checkpointAndCleanWAL() {
        guard let pool = activeDbPool, let url = activeLibraryURL() else { return }
        do {
            try pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
            let path = url.path
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        } catch {
            // Checkpoint failed — leave WAL/SHM intact to avoid data loss
        }
    }

    static var dbDirectoryURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("VideoMaster", isDirectory: true)
    }

    /// Default library path — always in App Support. Used when no active bookmark.
    static var defaultLibraryURL: URL {
        dbDirectoryURL.appendingPathComponent("VideoMaster.VideoMaster", isDirectory: false)
    }

    /// Whether the default library file exists on disk.
    static var defaultLibraryExists: Bool {
        FileManager.default.fileExists(atPath: defaultLibraryURL.path)
    }

    /// Whether the user explicitly closed the library. Checked once at launch, then cleared.
    static var userClosedLibrary: Bool {
        UserDefaults.standard.bool(forKey: userClosedLibraryKey)
    }

    static func clearUserClosedLibrary() {
        UserDefaults.standard.removeObject(forKey: userClosedLibraryKey)
    }

    /// Path to open for database. Resolves from active bookmark or default (if exists from migration). Nil = no library.
    static func databasePathForLaunch() -> String? {
        if let bookmark = UserDefaults.standard.data(forKey: activeLibraryBookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
            UserDefaults.standard.removeObject(forKey: activeLibraryBookmarkKey)
        }
        if FileManager.default.fileExists(atPath: defaultLibraryURL.path) {
            return defaultLibraryURL.path
        }
        return nil
    }

    /// Display name of the active library for window title (extension stripped). Empty when no library.
    static var activeLibraryDisplayName: String {
        if let path = databasePathForLaunch() {
            return displayName(for: URL(fileURLWithPath: path))
        }
        return ""
    }

    /// Returns display name for a library URL.
    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        for ext in [".videomaster", ".sqlite", ".db", ".sqlite3"] {
            if name.lowercased().hasSuffix(ext) {
                return String(name.dropLast(ext.count))
            }
        }
        return name
    }

    /// URL of the active library (for Save Copy, etc.). Nil when no library.
    static func activeLibraryURL() -> URL? {
        guard let path = databasePathForLaunch() else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func defaultExportFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMddyyyy"
        let datePart = formatter.string(from: Date())
        formatter.dateFormat = "HHmmss"
        let timePart = formatter.string(from: Date())
        let ms = Calendar.current.component(.nanosecond, from: Date()) / 1_000_000
        return "Library-\(datePart)-\(timePart)\(String(format: "%03d", ms)).VideoMaster"
    }

    /// Validates that the file is a valid VideoMaster database (has video table).
    static func validateImportFile(at url: URL) throws {
        let db = try DatabaseQueue(path: url.path)
        _ = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM video") }
    }

    // MARK: - Recent Libraries

    /// Returns recent library items from bookmarks. Prunes stale bookmarks.
    static func recentLibraryItems() -> [RecentLibraryItem] {
        var bookmarks = UserDefaults.standard.array(forKey: recentLibraryBookmarksKey) as? [Data] ?? []
        var result: [RecentLibraryItem] = []
        var kept: [Data] = []
        for bookmark in bookmarks {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            if result.contains(where: { $0.url.path == url.path }) { continue }
            kept.append(bookmark)
            result.append(RecentLibraryItem(
                id: url.path,
                displayName: displayName(for: url),
                url: url
            ))
        }
        if kept.count != bookmarks.count {
            UserDefaults.standard.set(kept, forKey: recentLibraryBookmarksKey)
        }
        return result
    }

    /// Adds a library URL to the recent list. Dedupes by path, trims to max.
    static func addToRecent(url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        let path = url.path
        var kept: [Data] = []
        for data in UserDefaults.standard.array(forKey: recentLibraryBookmarksKey) as? [Data] ?? [] {
            var isStale = false
            guard let u = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
                  u.path != path else { continue }
            kept.append(data)
        }
        kept.insert(bookmark, at: 0)
        kept = Array(kept.prefix(maxRecentLibraries))
        UserDefaults.standard.set(kept, forKey: recentLibraryBookmarksKey)
    }

    /// Switches to a library and restarts.
    static func switchToLibrary(_ item: RecentLibraryItem) {
        checkpointAndCleanWAL()
        let didStartAccess = item.url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { item.url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? item.url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(bookmark, forKey: activeLibraryBookmarkKey)
        addToRecent(url: item.url)
        relaunchAfterTerminate()
        NSApplication.shared.terminate(nil)
    }

    /// Clears all recent library bookmarks.
    static func clearRecentLibraries() {
        UserDefaults.standard.removeObject(forKey: recentLibraryBookmarksKey)
    }

    /// Schedules the app to relaunch after this process terminates. Uses launchctl so the relaunch survives our exit.
    private static func relaunchAfterTerminate() {
        let appPath = Bundle.main.bundlePath
        let script = """
        #!/bin/bash
        sleep 2
        open "\(appPath)"
        launchctl remove com.videomaster.relaunch 2>/dev/null || true
        """
        let scriptURL = dbDirectoryURL.appendingPathComponent("relaunch.sh", isDirectory: false)
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? (scriptURL as NSURL).setResourceValue(true, forKey: .isExecutableKey)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = [
                "submit", "-l", "com.videomaster.relaunch",
                "-o", dbDirectoryURL.appendingPathComponent("relaunch_out.log").path,
                "-e", dbDirectoryURL.appendingPathComponent("relaunch_err.log").path,
                "--", "/bin/bash", scriptURL.path
            ]
            try task.run()
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
        }
    }

    // MARK: - Save Copy

    /// Saves a copy of the current library to a user-chosen path. Does not switch.
    static func saveCopy(dbPool: DatabasePool) {
        guard let sourceURL = activeLibraryURL() else { return }
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["VideoMaster"]
        panel.nameFieldStringValue = defaultExportFileName()
        panel.title = "Save Copy"
        panel.message = "Save a copy of the current library to a file."

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        do {
            try dbPool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
            let fm = FileManager.default
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceURL, to: destURL)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Open Library

    /// Shows open panel and switches to the selected library.
    static func openLibraryFromUserSelection() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["VideoMaster", "sqlite", "db", "sqlite3"]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Library"
        panel.message = "Select a library file to open."

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            try validateImportFile(at: sourceURL)
        } catch {
            NSAlert(error: error).runModal()
            return
        }

        let item = RecentLibraryItem(
            id: sourceURL.path,
            displayName: sourceURL.lastPathComponent,
            url: sourceURL
        )
        switchToLibrary(item)
    }

    // MARK: - Create Library

    /// Creates a new empty library in App Support (default location) and relaunches. No bookmark needed — default path is used when no bookmark.
    /// If the file already exists, does nothing (avoids overwriting existing data).
    static func createLibraryInDefaultLocation() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dbDirectoryURL, withIntermediateDirectories: true)
        let destURL = defaultLibraryURL
        guard !fm.fileExists(atPath: destURL.path) else {
            let alert = NSAlert()
            alert.messageText = "Library Already Exists"
            alert.informativeText = "A library already exists at the default location. Use Open Library to open it, or choose a different location with Create library…"
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        do {
            try DatabaseMigration.createEmptyDatabase(at: destURL.path)
            relaunchAfterTerminate()
            NSApplication.shared.terminate(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Creates a new empty library at user-chosen path and switches to it.
    static func createNewLibrary() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["VideoMaster"]
        panel.nameFieldStringValue = "New Library.VideoMaster"
        panel.title = "New Library"
        panel.message = "Choose a location for the new library."

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        let didStartAccess = destURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { destURL.stopAccessingSecurityScopedResource() } }

        do {
            try DatabaseMigration.createEmptyDatabase(at: destURL.path)
            let item = RecentLibraryItem(
                id: destURL.path,
                displayName: destURL.lastPathComponent,
                url: destURL
            )
            switchToLibrary(item)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Close / Delete

    /// Closes the current library and relaunches to show landing. Keeps file on disk.
    static func closeLibrary() {
        checkpointAndCleanWAL()
        UserDefaults.standard.removeObject(forKey: activeLibraryBookmarkKey)
        UserDefaults.standard.set(true, forKey: userClosedLibraryKey)
        UserDefaults.standard.synchronize()
        relaunchAfterTerminate()
        NSApplication.shared.terminate(nil)
    }

    /// Deletes the library file from disk, removes from recent, and relaunches. Requires confirmation.
    static func deleteThisLibrary(at url: URL) {
        let fm = FileManager.default
        for ext in ["", "-wal", "-shm"] {
            let path = url.path + ext
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
        removeFromRecent(url: url)
        if databasePathForLaunch() == url.path {
            UserDefaults.standard.removeObject(forKey: activeLibraryBookmarkKey)
        }
        relaunchAfterTerminate()
        NSApplication.shared.terminate(nil)
    }

    /// Removes a library URL from the recent list.
    static func removeFromRecent(url: URL) {
        let path = url.path
        var kept: [Data] = []
        for data in UserDefaults.standard.array(forKey: recentLibraryBookmarksKey) as? [Data] ?? [] {
            var isStale = false
            guard let u = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
                  u.path != path else { continue }
            kept.append(data)
        }
        UserDefaults.standard.set(kept, forKey: recentLibraryBookmarksKey)
    }

    // MARK: - Launch

    /// Run at app launch. Migrates legacy library.sqlite if needed. Does not create default.
    static func prepareDatabaseForLaunch() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dbDirectoryURL, withIntermediateDirectories: true)

        let defaultPath = defaultLibraryURL.path

        // Migrate library.sqlite → VideoMaster.VideoMaster
        let legacyPath = dbDirectoryURL.appendingPathComponent("library.sqlite", isDirectory: false).path
        if !fm.fileExists(atPath: defaultPath), fm.fileExists(atPath: legacyPath) {
            try fm.moveItem(atPath: legacyPath, toPath: defaultPath)
            for ext in ["-wal", "-shm"] {
                let legacyExt = legacyPath + ext
                if fm.fileExists(atPath: legacyExt) {
                    try? fm.moveItem(atPath: legacyExt, toPath: defaultPath + ext)
                }
            }
        }

        // Migrate VideoMaster.sqlite → VideoMaster.VideoMaster
        let oldDefaultPath = dbDirectoryURL.appendingPathComponent("VideoMaster.sqlite", isDirectory: false).path
        if !fm.fileExists(atPath: defaultPath), fm.fileExists(atPath: oldDefaultPath) {
            try fm.moveItem(atPath: oldDefaultPath, toPath: defaultPath)
            for ext in ["-wal", "-shm"] {
                let oldExt = oldDefaultPath + ext
                if fm.fileExists(atPath: oldExt) {
                    try? fm.moveItem(atPath: oldExt, toPath: defaultPath + ext)
                }
            }
        }

        // Ensure default library is in recents if it exists
        if fm.fileExists(atPath: defaultPath) {
            addToRecent(url: defaultLibraryURL)
        }

        if UserDefaults.standard.data(forKey: activeLibraryBookmarkKey) == nil,
           let legacy = UserDefaults.standard.data(forKey: "VideoMaster.lastOpenedLibraryBookmark") {
            UserDefaults.standard.set(legacy, forKey: activeLibraryBookmarkKey)
            UserDefaults.standard.removeObject(forKey: "VideoMaster.lastOpenedLibraryBookmark")
        }

        try? fm.removeItem(at: dbDirectoryURL.appendingPathComponent("relaunch.sh", isDirectory: false))
        try? fm.removeItem(at: dbDirectoryURL.appendingPathComponent("relaunch_out.log", isDirectory: false))
        try? fm.removeItem(at: dbDirectoryURL.appendingPathComponent("relaunch_err.log", isDirectory: false))
    }
}
