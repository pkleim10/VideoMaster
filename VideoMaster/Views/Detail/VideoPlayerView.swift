import AVKit
import SwiftUI

struct VideoPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading video...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Spacer()
                Button("Close") {
                    player?.pause()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .padding()
            }
        }
        .onAppear {
            player = AVPlayer(url: url)
            player?.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
