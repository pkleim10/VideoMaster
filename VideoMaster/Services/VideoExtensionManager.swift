import Foundation
import SwiftUI

struct VideoExtensionEntry: Identifiable {
    let id: String
    var enabled: Bool

    var ext: String { id }
}

@Observable
final class VideoExtensionManager {
    static let shared = VideoExtensionManager()

    private static let userDefaultsKey = "VideoMaster.videoExtensions"
    private static let defaultExtensions: [(String, Bool)] = [
        ("mp4", true), ("mov", true), ("m4v", true), ("avi", true), ("mkv", true),
        ("wmv", true), ("flv", true), ("webm", true), ("mpg", true), ("mpeg", true),
        ("3gp", true), ("ts", true), ("mts", true), ("vob", true), ("ogv", true),
        ("divx", true), ("dv", true), ("m2ts", true), ("mxf", true),
    ]

    var entries: [VideoExtensionEntry] {
        didSet { persist() }
    }

    var enabledExtensions: Set<String> {
        Set(entries.filter(\.enabled).map(\.ext))
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let raw = try? JSONDecoder().decode([[String: String]].self, from: data)
        {
            entries = raw.compactMap { dict in
                guard let ext = dict["ext"], let enabledStr = dict["enabled"] else { return nil }
                return VideoExtensionEntry(id: ext, enabled: enabledStr == "1")
            }
            if entries.isEmpty {
                entries = Self.defaultExtensions.map { VideoExtensionEntry(id: $0.0, enabled: $0.1) }
            }
        } else {
            entries = Self.defaultExtensions.map { VideoExtensionEntry(id: $0.0, enabled: $0.1) }
        }
    }

    private func persist() {
        let raw = entries.map { ["ext": $0.ext, "enabled": $0.enabled ? "1" : "0"] }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    func setEnabled(_ ext: String, _ enabled: Bool) {
        let normalized = ext.lowercased()
        if let idx = entries.firstIndex(where: { $0.ext == normalized }) {
            entries[idx].enabled = enabled
        }
    }

    func add(_ ext: String) {
        let normalized = ext.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("."), normalized.allSatisfy({ $0.isLetter || $0.isNumber }) else { return }
        guard !entries.contains(where: { $0.ext == normalized }) else { return }
        entries.append(VideoExtensionEntry(id: normalized, enabled: true))
        entries.sort { $0.ext.localizedCaseInsensitiveCompare($1.ext) == .orderedAscending }
    }

    func remove(_ ext: String) {
        entries.removeAll { $0.ext == ext }
    }

    func resetToDefaults() {
        entries = Self.defaultExtensions.map { VideoExtensionEntry(id: $0.0, enabled: $0.1) }
    }
}
