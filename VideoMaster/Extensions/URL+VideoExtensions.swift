import Foundation

extension URL {
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv",
        "webm", "mpg", "mpeg", "3gp", "ts", "mts", "vob", "ogv",
    ]

    var isVideoFile: Bool {
        Self.videoExtensions.contains(pathExtension.lowercased())
    }
}
