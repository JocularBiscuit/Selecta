import SwiftUI

/// One grid cell — the Mac equivalent of iOS' ThumbCell, minus the
/// touch-only affordances (selection checkmark circle, long-press peek).
/// A blue focus ring shows keyboard focus instead.
struct MacThumbCell: View {
    let item: CardItem
    let isFocused: Bool

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.cell)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if item.kind == .video {
                Image(systemName: "video.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay(alignment: .bottom) { bottomScrim }
        .overlay(alignment: .bottomLeading) { ratingStars }
        .overlay(alignment: .topTrailing) { flagBadge }
        .overlay {
            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 3)
            }
        }
        .overlay {
            Rectangle().strokeBorder(isFocused ? Theme.accent : Theme.hairline, lineWidth: isFocused ? 2 : 1)
        }
        .opacity(item.flag == .reject ? 0.35 : 1)
        .contentShape(Rectangle())
        .task(id: item.id) {
            image = await ThumbnailStore.shared.thumbnail(for: item, maxPixel: 400)
        }
    }

    @ViewBuilder
    private var bottomScrim: some View {
        if item.rating > 0 {
            LinearGradient(colors: [.clear, Theme.scrim], startPoint: .top, endPoint: .bottom)
                .frame(height: 26)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var ratingStars: some View {
        if item.rating > 0 {
            HStack(spacing: 1) {
                ForEach(0..<item.rating, id: \.self) { _ in
                    Image(systemName: "star.fill").font(.system(size: 8))
                }
            }
            .foregroundStyle(Theme.star)
            .padding(.leading, 4)
            .padding(.bottom, 4)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var flagBadge: some View {
        switch item.flag {
        case .pick:
            Image(systemName: "flag.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.pick)
                .padding(3)
                .background(Theme.scrim)
                .padding(3)
                .allowsHitTesting(false)
        case .reject:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.reject)
                .padding(3)
                .background(Theme.scrim)
                .padding(3)
                .allowsHitTesting(false)
        case .none:
            EmptyView()
        }
    }
}
