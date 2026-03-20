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

/// Caps concurrent `AVAssetImageGenerator` work so 10k+ libraries don’t spawn unbounded AV decode pressure.
private actor ThumbnailGenerationGate {
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    func release() {
        running -= 1
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        }
    }
}

/// Disk + memory cache for thumbnails/filmstrips. **Not** an `actor`: fast `load*` calls must not wait behind
/// `generate*` work from hundreds of grid cells (that was causing multi‑second stalls in the detail pane).
final class ThumbnailService: @unchecked Sendable {
    private let cacheDirectory: URL
    private let memoryCache = NSCache<NSString, NSImage>()
    /// Serializes cache directory mutations (migrate, bulk delete, clear).
    private let managementLock = NSLock()
    /// P0: bound concurrent AV thumbnail/filmstrip generation (grid + scanner + detail).
    private let generationGate = ThumbnailGenerationGate(maxConcurrent: 4)
    /// Coalesce multiple awaiters for the same path (grid scroll, scanner, detail).
    private let inflightLock = NSLock()
    private var inflightThumbnails: [String: Task<URL, Error>] = [:]
    private var inflightFilmstrips: [String: Task<NSImage, Error>] = [:]
    private var inflightDetailPreviews: [String: Task<URL, Error>] = [:]

    private static let filmstripCachePrefix = "_filmstrip"
    private static let detailPreviewCachePrefix = "_detailPreview"

    /// Presets for detail-pane JPEG long edge (Settings → Video; keep in sync with the picker there).
    static let detailPreviewLongEdgeChoices: [Int] = [480, 720, 1080, 1440, 2160]

    static func normalizedDetailLongEdge(_ value: Int) -> Int {
        if detailPreviewLongEdgeChoices.contains(value) { return value }
        return 1080
    }

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("VideoMaster/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheDirectory = dir
        memoryCache.countLimit = 5000
    }

    private func pathHashString(for filePath: String) -> String {
        let hash = SHA256.hash(data: Data(filePath.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    func thumbnailURL(for filePath: String) -> URL {
        cacheDirectory.appendingPathComponent("\(pathHashString(for: filePath)).jpg")
    }

    func filmstripURL(for filePath: String) -> URL {
        cacheDirectory.appendingPathComponent("\(pathHashString(for: filePath))_filmstrip.jpg")
    }

    /// Disk path for hi-res detail still: `<hash>_detail_<longEdge>.jpg`.
    func detailPreviewURL(for filePath: String, longEdge: Int) -> URL {
        let edge = Self.normalizedDetailLongEdge(longEdge)
        let h = pathHashString(for: filePath)
        return cacheDirectory.appendingPathComponent("\(h)_detail_\(edge).jpg")
    }

    /// Pre–width-suffix cache file (`<hash>_detail.jpg`, treated as 1080 long edge when reading).
    private func legacyDetailPreviewURL(for filePath: String) -> URL {
        let h = pathHashString(for: filePath)
        return cacheDirectory.appendingPathComponent("\(h)_detail.jpg")
    }

    private func detailPreviewMemoryKey(filePath: String, longEdge: Int) -> NSString {
        let edge = Self.normalizedDetailLongEdge(longEdge)
        return (filePath + Self.detailPreviewCachePrefix + "_\(edge)") as NSString
    }

    private func inflightDetailPreviewKey(filePath: String, longEdge: Int) -> String {
        "\(filePath)\u{1e}\(Self.normalizedDetailLongEdge(longEdge))"
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

    /// Hi-res detail preview on disk (`<hash>_detail_<longEdge>.jpg`) + `NSCache` keyed by path and long edge.
    func loadDetailPreview(for filePath: String, longEdge: Int) -> NSImage? {
        let edge = Self.normalizedDetailLongEdge(longEdge)
        let memKey = detailPreviewMemoryKey(filePath: filePath, longEdge: edge)
        if let cached = memoryCache.object(forKey: memKey) {
            return cached
        }
        var urls = [detailPreviewURL(for: filePath, longEdge: edge)]
        if edge == 1080 {
            let legacy = legacyDetailPreviewURL(for: filePath)
            if legacy.path != urls[0].path { urls.append(legacy) }
        }
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path),
                  let image = NSImage(contentsOf: url)
            else { continue }
            memoryCache.setObject(image, forKey: memKey)
            return image
        }
        return nil
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

        return try await coalescedThumbnailGeneration(for: video, filePath: video.filePath)
    }

    /// One in-flight generation per `filePath`; multiple awaiters share the same `Task`. AV work runs under a global concurrency cap.
    private func coalescedThumbnailGeneration(for video: Video, filePath: String) async throws -> URL {
        inflightLock.lock()
        if let existing = inflightThumbnails[filePath] {
            inflightLock.unlock()
            return try await existing.value
        }
        let task = Task<URL, Error> {
            await self.generationGate.acquire()
            do {
                let url = try await self.generateThumbnailWork(for: video)
                await self.generationGate.release()
                return url
            } catch {
                await self.generationGate.release()
                throw error
            }
        }
        inflightThumbnails[filePath] = task
        inflightLock.unlock()
        defer {
            inflightLock.lock()
            inflightThumbnails.removeValue(forKey: filePath)
            inflightLock.unlock()
        }
        return try await task.value
    }

    private func generateThumbnailWork(for video: Video) async throws -> URL {
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

    // MARK: - Detail preview (disk + memory; long edge from settings)

    /// Loads cached detail JPEG from disk/memory, or generates once and persists under `~/Library/Caches/.../VideoMaster/thumbnails/`.
    func detailPreviewImage(for video: Video, longEdge: Int) async -> NSImage? {
        let path = video.filePath
        let edge = Self.normalizedDetailLongEdge(longEdge)
        if let img = loadDetailPreview(for: path, longEdge: edge) { return img }
        guard (try? await generateDetailPreview(for: video, longEdge: edge)) != nil else { return nil }
        return loadDetailPreview(for: path, longEdge: edge)
    }

    func generateDetailPreview(for video: Video, longEdge: Int) async throws -> URL {
        let edge = Self.normalizedDetailLongEdge(longEdge)
        let cacheURL = detailPreviewURL(for: video.filePath, longEdge: edge)
        let memKey = detailPreviewMemoryKey(filePath: video.filePath, longEdge: edge)

        if FileManager.default.fileExists(atPath: cacheURL.path) {
            if let image = NSImage(contentsOf: cacheURL) {
                memoryCache.setObject(image, forKey: memKey)
            }
            return cacheURL
        }

        if edge == 1080 {
            let legacyURL = legacyDetailPreviewURL(for: video.filePath)
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                if let image = NSImage(contentsOf: legacyURL) {
                    memoryCache.setObject(image, forKey: memKey)
                }
                return legacyURL
            }
        }

        return try await coalescedDetailPreviewGeneration(for: video, filePath: video.filePath, longEdge: edge)
    }

    private func coalescedDetailPreviewGeneration(for video: Video, filePath: String, longEdge: Int) async throws -> URL {
        let coalesceKey = inflightDetailPreviewKey(filePath: filePath, longEdge: longEdge)
        inflightLock.lock()
        if let existing = inflightDetailPreviews[coalesceKey] {
            inflightLock.unlock()
            return try await existing.value
        }
        let task = Task<URL, Error> {
            await self.generationGate.acquire()
            do {
                let url = try await self.generateDetailPreviewWork(for: video, longEdge: longEdge)
                await self.generationGate.release()
                return url
            } catch {
                await self.generationGate.release()
                throw error
            }
        }
        inflightDetailPreviews[coalesceKey] = task
        inflightLock.unlock()
        defer {
            inflightLock.lock()
            inflightDetailPreviews.removeValue(forKey: coalesceKey)
            inflightLock.unlock()
        }
        return try await task.value
    }

    private func generateDetailPreviewWork(for video: Video, longEdge: Int) async throws -> URL {
        let edge = Self.normalizedDetailLongEdge(longEdge)
        let cacheURL = detailPreviewURL(for: video.filePath, longEdge: edge)
        let memKey = detailPreviewMemoryKey(filePath: video.filePath, longEdge: edge)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            if let image = NSImage(contentsOf: cacheURL) {
                memoryCache.setObject(image, forKey: memKey)
            }
            return cacheURL
        }

        if edge == 1080 {
            let legacyURL = legacyDetailPreviewURL(for: video.filePath)
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                if let image = NSImage(contentsOf: legacyURL) {
                    memoryCache.setObject(image, forKey: memKey)
                }
                return legacyURL
            }
        }

        let url = video.url
        let dim = CGFloat(edge)
        let nsImage: NSImage = try await withTimeout(seconds: 15) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: dim, height: dim)
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
                  properties: [.compressionFactor: 0.82]
              )
        else {
            throw ThumbnailError.encodingFailed
        }

        try jpegData.write(to: cacheURL)
        memoryCache.setObject(nsImage, forKey: memKey)
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

        return try await coalescedFilmstrip(for: video, rows: rows, columns: columns)
    }

    func regenerateFilmstrip(for video: Video, rows: Int, columns: Int) async throws -> NSImage {
        let cacheURL = filmstripURL(for: video.filePath)
        let memKey = (video.filePath + Self.filmstripCachePrefix) as NSString
        try? FileManager.default.removeItem(at: cacheURL)
        memoryCache.removeObject(forKey: memKey)
        return try await runFilmstripBuildWithGate(for: video, rows: rows, columns: columns)
    }

    private func filmstripInflightKey(filePath: String, rows: Int, columns: Int) -> String {
        "\(filePath)\u{1e}fs\u{1e}\(rows)x\(columns)"
    }

    private func coalescedFilmstrip(for video: Video, rows: Int, columns: Int) async throws -> NSImage {
        let key = filmstripInflightKey(filePath: video.filePath, rows: rows, columns: columns)
        inflightLock.lock()
        if let existing = inflightFilmstrips[key] {
            inflightLock.unlock()
            return try await existing.value
        }
        let task = Task<NSImage, Error> {
            await self.generationGate.acquire()
            do {
                let image = try await self.buildFilmstrip(for: video, rows: rows, columns: columns)
                await self.generationGate.release()
                return image
            } catch {
                await self.generationGate.release()
                throw error
            }
        }
        inflightFilmstrips[key] = task
        inflightLock.unlock()
        defer {
            inflightLock.lock()
            inflightFilmstrips.removeValue(forKey: key)
            inflightLock.unlock()
        }
        return try await task.value
    }

    private func runFilmstripBuildWithGate(for video: Video, rows: Int, columns: Int) async throws -> NSImage {
        await generationGate.acquire()
        do {
            let image = try await buildFilmstrip(for: video, rows: rows, columns: columns)
            await generationGate.release()
            return image
        } catch {
            await generationGate.release()
            throw error
        }
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
        let oldH = pathHashString(for: oldFilePath)
        let newH = pathHashString(for: newFilePath)
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for url in contents {
                let name = url.lastPathComponent
                guard name.hasPrefix(oldH) else { continue }
                if name == "\(oldH)_detail.jpg" {
                    let dest = cacheDirectory.appendingPathComponent("\(newH)_detail_1080.jpg")
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: url, to: dest)
                    }
                    continue
                }
                guard name.hasPrefix("\(oldH)_detail_"), name.hasSuffix(".jpg") else { continue }
                let rest = String(name.dropFirst(oldH.count))
                let newName = "\(newH)\(rest)"
                let newURL = cacheDirectory.appendingPathComponent(newName)
                try? fm.moveItem(at: url, to: newURL)
            }
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
        memoryCache.removeObject(forKey: (oldFilePath + Self.detailPreviewCachePrefix) as NSString)
        for edge in Self.detailPreviewLongEdgeChoices {
            let oldDetailKey = detailPreviewMemoryKey(filePath: oldFilePath, longEdge: edge)
            let newDetailKey = detailPreviewMemoryKey(filePath: newFilePath, longEdge: edge)
            if let image = memoryCache.object(forKey: oldDetailKey) {
                memoryCache.setObject(image, forKey: newDetailKey)
                memoryCache.removeObject(forKey: oldDetailKey)
            }
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
