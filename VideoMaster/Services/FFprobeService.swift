import Foundation

actor FFprobeService {
    static let shared = FFprobeService()

    private var cachedPath: String?

    var isAvailable: Bool {
        ffprobePath != nil
    }

    private var ffprobePath: String? {
        if let cached = cachedPath { return cached }
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe",
        ]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        cachedPath = found
        return found
    }

    struct ProbeResult: Sendable {
        let duration: Double?
        let width: Int?
        let height: Int?
        let codec: String?
        let frameRate: Double?
        let bitRate: Int?
    }

    func probe(url: URL) throws -> ProbeResult {
        guard let path = ffprobePath else {
            throw FFprobeError.notInstalled
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FFprobeError.parseFailed
        }

        guard let streams = json["streams"] as? [[String: Any]],
              let videoStream = streams.first(where: { ($0["codec_type"] as? String) == "video" })
        else {
            throw FFprobeError.noVideoStream
        }

        let width = videoStream["width"] as? Int
        let height = videoStream["height"] as? Int
        let codec = videoStream["codec_name"] as? String

        var frameRate: Double?
        if let rFrameRate = videoStream["r_frame_rate"] as? String {
            let parts = rFrameRate.split(separator: "/")
            if parts.count == 2,
               let num = Double(parts[0]),
               let den = Double(parts[1]),
               den > 0
            {
                frameRate = num / den
            }
        }

        var duration: Double?
        if let d = videoStream["duration"] as? String {
            duration = Double(d)
        } else if let format = json["format"] as? [String: Any],
                  let d = format["duration"] as? String
        {
            duration = Double(d)
        }

        var bitRate: Int?
        if let br = videoStream["bit_rate"] as? String {
            bitRate = Int(br)
        }

        return ProbeResult(
            duration: duration,
            width: width,
            height: height,
            codec: codec,
            frameRate: frameRate,
            bitRate: bitRate
        )
    }
}

enum FFprobeError: Error, LocalizedError {
    case notInstalled
    case noVideoStream
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "ffprobe is not installed. Install via: brew install ffmpeg"
        case .noVideoStream: return "No video stream found in file"
        case .parseFailed: return "Failed to parse ffprobe output"
        }
    }
}
