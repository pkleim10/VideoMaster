import SwiftUI

struct RatingView: View {
    let rating: Int
    let size: CGFloat
    let onRate: (Int) -> Void

    @State private var hoverRating: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= displayRating ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundColor(star <= displayRating ? .yellow : .secondary.opacity(0.4))
                    .onTapGesture {
                        onRate(star == rating ? 0 : star)
                    }
                    .onHover { hovering in
                        hoverRating = hovering ? star : nil
                    }
            }
        }
    }

    private var displayRating: Int {
        hoverRating ?? rating
    }
}
