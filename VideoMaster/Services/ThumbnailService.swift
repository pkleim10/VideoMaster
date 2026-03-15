import AppKit
import AVFoundation
import CryptoKit
import Foundation

actor ThumbnailService {
    private let cacheDirectory: URL
    private let memoryCache = NSCache<NSString, NSImage>()

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

    func generateThumbnail(for video: Video) async throws -> URL {
        let cacheURL = thumbnailURL(for: video.filePath)

        if FileManager.default.fileExists(atPath: cacheURL.path) {
            if let image = NSImage(contentsOf: cacheURL) {
                memoryCache.setObject(image, forKey: video.filePath as NSString)
            }
            return cacheURL
        }

        let asset = AVURLAsset(url: video.url)
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
        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )

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

    func clearCache() throws {
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
