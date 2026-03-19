import Foundation

extension URL {
    var isVideoFile: Bool {
        VideoExtensionManager.shared.enabledExtensions.contains(pathExtension.lowercased())
    }
}
