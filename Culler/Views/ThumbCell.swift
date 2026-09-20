import SwiftUI

/// One grid cell, Bridge-style: square image with a 1px hairline border,
/// monochrome file-type badge, tiny star row on a bottom gradient scrim,
/// pick/reject glyph, and a full-width 3pt color-label bar along the bottom
/// edge. All state changes render instantly — no animation.
struct ThumbCell: View {
    let item: CardItem
    let size: Double
    let showFilename: Bool
    let isSelected: Bool
    let selectionMode: Bool
    /// Fired once per distinct item shown, so the host can lazily check its
    /// RAW status only for cells actually scrolled into view (see
    /// Library.checkRawFlagIfNeeded) instead of scanning a whole album up
    /// front. No-op for file-based items and items already checked.
    var onNeedsRawCheck: ((String) -> Void)? = nil

    @State private var image: UIImage?
    /// Set once the load genuinely finishes with nothing — distinct from
    /// still-in-progress, so a dead file doesn't look identical to "loading".
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.cell)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loadFailed {
                VStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.footnote)
                    if size >= 90 {
                        Text("Unavailable")
                            .font(.system(size: 9))
                    }
                }
                .foregroundStyle(Theme.textTertiary)
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
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay(alignment: .bottom) { bottomScrim }
        .overlay(alignment: .bottomLeading) { ratingStars }
        .overlay(alignment: .bottom) { filenameStrip }
        .overlay(alignment: .bottom) { labelBar }
        .overlay(alignment: .topLeading) { typeBadge }
        .overlay(alignment: .topTrailing) { flagBadge }
        .overlay { videoPlayGlyph }
        .overlay { selectionOverlay }
        .overlay {
            Rectangle().strokeBorder(
                selectionMode && isSelected ? Theme.accent : Theme.hairline,
                lineWidth: selectionMode && isSelected ? 2 : 1
            )
        }
        .opacity(item.flag == .reject ? 0.35 : 1)
        .contentShape(Rectangle())
        .animation(nil, value: item.rating)
        .animation(nil, value: item.flag)
        .animation(nil, value: item.label)
        .animation(nil, value: isSelected)
        .task(id: taskKey) {
            loadFailed = false
            let result = await ThumbnailStore.shared.thumbnail(
                for: item,
                maxPixel: bucketedPixelSize
            )
            guard !Task.isCancelled else { return }
            image = result
            if result == nil, item.kind != .video {
                loadFailed = true
            }
        }
        .task(id: item.id) {
            onNeedsRawCheck?(item.id)
        }
    }

    /// Bucket the requested decode size so pinch-resizing doesn't re-decode
    /// every thumbnail at every intermediate size.
    private var bucketedPixelSize: CGFloat {
        let pixels = size * UIScreen.main.scale
        if pixels <= 240 { return 240 }
        if pixels <= 400 { return 400 }
        return 640
    }

    private var taskKey: String { "\(item.id)|\(Int(bucketedPixelSize))" }

    // MARK: Overlays

    /// Soft bottom gradient behind the star row (only when rated).
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
                    Image(systemName: "star.fill").font(.system(size: 7))
                }
            }
            .foregroundStyle(Theme.star)
            .padding(.leading, 4)
            .padding(.bottom, showFilename ? 18 : 6)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var filenameStrip: some View {
        if showFilename {
            Text(item.baseName)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 1.5)
                .background(Theme.scrim)
                .padding(.bottom, 3)
                .allowsHitTesting(false)
        }
    }

    /// Bridge/LR-style color label: a 3pt bar across the very bottom edge.
    @ViewBuilder
    private var labelBar: some View {
        if let label = item.label {
            Rectangle()
                .fill(label.color)
                .frame(maxWidth: .infinity)
                .frame(height: 3)
                .allowsHitTesting(false)
        }
    }

    /// Hidden for anything that isn't actually informative: a video is
    /// already distinguished by its own play glyph, and a plain gallery
    /// photo has nothing worth labeling — RAW/RAW+JPEG/JPEG-with-odd-
    /// extension etc. still show, since those are the ones a photographer
    /// actually needs to tell apart at a glance.
    private var showsTypeBadge: Bool {
        item.kind != .video && item.badge != "PHOTO"
    }

    @ViewBuilder
    private var typeBadge: some View {
        if showsTypeBadge {
            Text(item.badge)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(item.kind == .rawOnly ? Theme.rawBadge : Theme.textSecondary)
                .padding(.horizontal, 3)
                .padding(.vertical, 1.5)
                .background(Theme.scrim)
                .padding(3)
                .allowsHitTesting(false)
        }
    }

    /// A centered play glyph is the video/photo distinction now — the old
    /// "VIDEO" text badge is gone (see `showsTypeBadge`).
    @ViewBuilder
    private var videoPlayGlyph: some View {
        if item.kind == .video {
            Image(systemName: "play.circle.fill")
                .font(.system(size: min(size * 0.3, 32), weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.45), radius: 3)
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

    @ViewBuilder
    private var selectionOverlay: some View {
        if selectionMode {
            ZStack(alignment: .bottomTrailing) {
                if isSelected {
                    Theme.accent.opacity(0.15)
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .padding(5)
            }
            .allowsHitTesting(false)
        }
    }
}

extension ColorLabel {
    var color: Color {
        switch self {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}
