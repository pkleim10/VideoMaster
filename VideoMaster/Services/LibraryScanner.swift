import Foundation
import GRDB

enum ScanUpdate: Sendable {
    case started(total: Int)
    case progress(current: Int, total: Int, fileName: String)
    case completed
    case error(String)
}

actor LibraryScanner {
    private let dbPool: DatabasePool
    private let metadataExtractor = MetadataExtractor()
    private let thumbnailService: ThumbnailService
    private let videoRepo: VideoRepository

    init(dbPool: DatabasePool, thumbnailService: ThumbnailService) {
        self.dbPool = dbPool
        self.thumbnailService = thumbnailService
        self.videoRepo = VideoRepository(dbPool: dbPool)
    }

    func scan(folder: URL) -> AsyncStream<ScanUpdate> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.performScan(folder: folder, continuation: continuation)
            }
        }
    }

    private func performScan(folder: URL, continuation: AsyncStream<ScanUpdate>.Continuation) async {
        let videoFiles = discoverVideoFiles(in: folder)
        continuation.yield(.started(total: videoFiles.count))

        let concurrencyLimit = 4
        var processed = 0

        await withTaskGroup(of: Void.self) { group in
            for (index, fileURL) in videoFiles.enumerated() {
                if index >= concurrencyLimit {
                    await group.next()
                }

                group.addTask { [self] in
                    await self.processFile(fileURL)
                }

                processed += 1
                continuation.yield(
                    .progress(
                        current: processed,
                        total: videoFiles.count,
                        fileName: fileURL.lastPathComponent
                    )
                )
            }

            await group.waitForAll()
        }

        continuation.yield(.completed)
        continuation.finish()
    }

    private func processFile(_ fileURL: URL) async {
        do {
            let exists = try await videoRepo.videoExists(filePath: fileURL.path)
            guard !exists else { return }

            let metadata = await metadataExtractor.extract(from: fileURL)

            let videoInput = Video(
                filePath: fileURL.path,
                fileName: fileURL.lastPathComponent,
                fileSize: metadata.fileSize,
                duration: metadata.duration,
                width: metadata.width,
                height: metadata.height,
                codec: metadata.codec,
                frameRate: metadata.frameRate,
                creationDate: metadata.creationDate,
                dateAdded: Date(),
                rating: 0,
                playCount: 0
            )

            let video = try await videoRepo.insert(videoInput)

            Task.detached { [thumbnailService, videoRepo] in
                if let url = try? await thumbnailService.generateThumbnail(for: video),
                   let dbId = video.databaseId
                {
                    try? await videoRepo.updateThumbnailPath(videoId: dbId, path: url.path)
                }
            }
        } catch {
            print("Failed to process \(fileURL.lastPathComponent): \(error)")
        }
    }

    private func discoverVideoFiles(in folder: URL) -> [URL] {
        var results: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return results }

        while let url = enumerator.nextObject() as? URL {
            if url.isVideoFile {
                results.append(url)
            }
        }
        return results
    }
}
