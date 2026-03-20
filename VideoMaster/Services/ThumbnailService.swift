import AppKit
import AVFoundation
import CryptoKit
import Foundation

private func withTimeout<T: Sendable>(seconds: Double, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}

/// Disk + memory cache for thumbnails/filmstrips. **Not** an `actor`: fast `load*` calls must not wait behind
/// `generate*` work from hundreds of grid cells (that was causing multi‑second stalls in the detail pane).
final class ThumbnailService: @unchecked Sendable {
    private let cacheDirectory: URL
    private let memoryCache = NSCache<NSString, NSImage>()
    /// Serializes cache directory mutations (migrate, bulk delete, clear).
    private let managementLock = NSLock()

    private static let filmstripCachePrefix = "_filmstrip"

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("VideoMaster/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheDirectory = dir
        memoryCache.countLimit = 5000
    }

    func thumbnailURL(for filePath: String) -> URL {
        let hash = SHA256.hash(data: Data(filePath.utf8))
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hashString).jpg")
    }

    func filmstripURL(for filePath: String) -> URL {
        let hash = SHA256.hash(data: Data(filePath.utf8))
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hashString)_filmstrip.jpg")
    }

    // MARK: - Fast path (memory + disk; never waits on AV / generation)

    /// Thread-safe: `NSCache` is thread-safe; disk read is local to this call.
    func loadThumbnail(for filePath: String) -> NSImage? {
        let key = filePath as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        let url = thumbnailURL(for: filePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url)
        else { return nil }
        memoryCache.setObject(image, forKey: key)
        return image
    }

    func loadFilmstrip(for filePath: String) -> NSImage? {
        let memKey = (filePath + Self.filmstripCachePrefix) as NSString
        if let cached = memoryCache.object(forKey: memKey) {
            return cached
        }
        let url = filmstripURL(for: filePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url)
        else { return nil }
        memoryCache.setObject(image, forKey: memKey)
        return image
    }

    // MARK: - Generation (async; can run concurrently for different files)

    func generateThumbnail(for video: Video) async throws -> URL {
        let cacheURL = thumbnailURL(for: video.filePath)

        if FileManager.default.fileExists(atPath: cacheURL.path) {
            if let image = NSImage(contentsOf: cacheURL) {
                memoryCache.setObject(image, forKey: video.filePath as NSString)
            }
            return cacheURL
        }

        let url = video.url
        let nsImage: NSImage = try await withTimeout(seconds: 10) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)

            var targetSeconds: Double = 5.0
            if let d = try? await asset.load(.duration) {
                let total = CMTimeGetSeconds(d)
                if total.isFinite && total > 0 {
                    targetSeconds = min(total * 0.1, 30)
                }
            }
            let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.75]
              )
        else {
            throw ThumbnailError.encodingFailed
        }

        try jpegData.write(to: cacheURL)
        memoryCache.setObject(nsImage, forKey: video.filePath as NSString)
        return cacheURL
    }

    func generateFilmstrip(for video: Video, rows: Int = 2, columns: Int = 4) async throws -> NSImage {
        let cacheURL = filmstripURL(for: video.filePath)
        let memKey = (video.filePath + Self.filmstripCachePrefix) as NSString

        if let cached = memoryCache.object(forKey: memKey) {
            return cached
        }
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let image = NSImage(contentsOf: cacheURL)
        {
            memoryCache.setObject(image, forKey: memKey)
            return image
        }

        return try await buildFilmstrip(for: video, rows: rows, columns: columns)
    }

    func regenerateFilmstrip(for video: Video, rows: Int, columns: Int) async throws -> NSImage {
        let cacheURL = filmstripURL(for: video.filePath)
        let memKey = (video.filePath + Self.filmstripCachePrefix) as NSString
        try? FileManager.default.removeItem(at: cacheURL)
        memoryCache.removeObject(forKey: memKey)
        return try await buildFilmstrip(for: video, rows: rows, columns: columns)
    }

    private func buildFilmstrip(for video: Video, rows: Int, columns: Int) async throws -> NSImage {
        let cacheURL = filmstripURL(for: video.filePath)
        let memKey = (video.filePath + Self.filmstripCachePrefix) as NSString
        let totalFrames = rows * columns
        let url = video.url

        let frames: [CGImage] = try await withTimeout(seconds: 30) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let totalSeconds = CMTimeGetSeconds(duration)

            guard totalSeconds.isFinite, totalSeconds > 2.0 else {
                throw ThumbnailError.generationFailed
            }

            let fractions = (1...totalFrames).map { Double($0) / Double(totalFrames + 1) }
            let times = fractions.map { CMTime(seconds: totalSeconds * $0, preferredTimescale: 600) }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

            var result: [CGImage] = []
            for time in times {
                try Task.checkCancellation()
                if let (cgImage, _) = try? await generator.image(at: time) {
                    result.append(cgImage)
                }
            }
            return result
        }

        guard frames.count == totalFrames else {
            throw ThumbnailError.generationFailed
        }

        let cellWidth: CGFloat = 400
        let cellHeight: CGFloat = 225
        let compositeWidth = cellWidth * CGFloat(columns)
        let compositeHeight = cellHeight * CGFloat(rows)

        let compositeImage = NSImage(size: NSSize(width: compositeWidth, height: compositeHeight))
        compositeImage.lockFocus()
        NSColor.black.setFill()
        for (index, cgImage) in frames.enumerated() {
            let col = index % columns
            let row = index / columns
            let cellX = CGFloat(col) * cellWidth
            let cellY = compositeHeight - CGFloat(row + 1) * cellHeight

            let frameW = CGFloat(cgImage.width)
            let frameH = CGFloat(cgImage.height)
            let scale = min(cellWidth / frameW, cellHeight / frameH)
            let drawW = frameW * scale
            let drawH = frameH * scale
            let drawX = cellX + (cellWidth - drawW) / 2
            let drawY = cellY + (cellHeight - drawH) / 2

            NSRect(x: cellX, y: cellY, width: cellWidth, height: cellHeight).fill()
            let frameImage = NSImage(cgImage: cgImage, size: NSSize(width: frameW, height: frameH))
            frameImage.draw(in: NSRect(x: drawX, y: drawY, width: drawW, height: drawH))
        }
        compositeImage.unlockFocus()

        guard let tiffData = compositeImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else {
            throw ThumbnailError.encodingFailed
        }

        try jpegData.write(to: cacheURL)
        memoryCache.setObject(compositeImage, forKey: memKey)
        return compositeImage
    }

    func deleteAllFilmstrips() {
        managementLock.lock()
        defer { managementLock.unlock() }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent.hasSuffix("_filmstrip.jpg") {
            try? fm.removeItem(at: url)
        }
        memoryCache.removeAllObjects()
    }

    func migrateCacheKey(from oldFilePath: String, to newFilePath: String) {
        managementLock.lock()
        defer { managementLock.unlock() }
        let oldDiskURL = thumbnailURL(for: oldFilePath)
        let newDiskURL = thumbnailURL(for: newFilePath)
        if FileManager.default.fileExists(atPath: oldDiskURL.path) {
            try? FileManager.default.moveItem(at: oldDiskURL, to: newDiskURL)
        }
        let oldFilmstripURL = filmstripURL(for: oldFilePath)
        let newFilmstripURL = filmstripURL(for: newFilePath)
        if FileManager.default.fileExists(atPath: oldFilmstripURL.path) {
            try? FileManager.default.moveItem(at: oldFilmstripURL, to: newFilmstripURL)
        }
        let oldKey = oldFilePath as NSString
        let newKey = newFilePath as NSString
        if let image = memoryCache.object(forKey: oldKey) {
            memoryCache.setObject(image, forKey: newKey)
            memoryCache.removeObject(forKey: oldKey)
        }
        let oldFsKey = (oldFilePath + Self.filmstripCachePrefix) as NSString
        let newFsKey = (newFilePath + Self.filmstripCachePrefix) as NSString
        if let image = memoryCache.object(forKey: oldFsKey) {
            memoryCache.setObject(image, forKey: newFsKey)
            memoryCache.removeObject(forKey: oldFsKey)
        }
    }

    func clearCache() throws {
        managementLock.lock()
        defer { managementLock.unlock() }
        memoryCache.removeAllObjects()
        let contents = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )
        for file in contents {
            try FileManager.default.removeItem(at: file)
        }
    }
}

enum ThumbnailError: Error, LocalizedError {
    case encodingFailed
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode thumbnail image"
        case .generationFailed: return "Failed to generate thumbnail"
        }
    }
}
