import AVFoundation
import Foundation

struct VideoMetadata {
    let duration: Double?
    let width: Int?
    let height: Int?
    let codec: String?
    let frameRate: Double?
    let fileSize: Int64
    let creationDate: Date?
}

struct MetadataExtractor {
    func extract(from url: URL) async -> VideoMetadata {
        let asset = AVURLAsset(url: url)

        let duration: Double? = await {
            guard let d = try? await asset.load(.duration) else { return nil }
            let seconds = CMTimeGetSeconds(d)
            return seconds.isFinite ? seconds : nil
        }()

        var width: Int?
        var height: Int?
        var codec: String?
        var frameRate: Double?

        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let track = tracks.first
        {
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform)
            {
                let transformed = size.applying(transform)
                width = Int(abs(transformed.width))
                height = Int(abs(transformed.height))
            }

            if let rate = try? await track.load(.nominalFrameRate) {
                frameRate = Double(rate)
            }

            if let descriptions = try? await track.load(.formatDescriptions),
               let desc = descriptions.first
            {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                codec = fourCharCode(subType)
            }
        }

        let fileSize: Int64 = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return attrs?[.size] as? Int64 ?? 0
        }()

        let creationDate: Date? = {
            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            return values?.creationDate
        }()

        return VideoMetadata(
            duration: duration,
            width: width,
            height: height,
            codec: codec,
            frameRate: frameRate,
            fileSize: fileSize,
            creationDate: creationDate
        )
    }

    private func fourCharCode(_ code: FourCharCode) -> String {
        let chars: [Character] = [
            Character(UnicodeScalar((code >> 24) & 0xFF)!),
            Character(UnicodeScalar((code >> 16) & 0xFF)!),
            Character(UnicodeScalar((code >> 8) & 0xFF)!),
            Character(UnicodeScalar(code & 0xFF)!),
        ]
        return String(chars).trimmingCharacters(in: .whitespaces)
    }
}
