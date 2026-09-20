import SwiftUI
import UIKit
import Photos
import PhotosUI

// MARK: - Album browser sheet

/// Native-feeling album picker, styled like the Photos app's Albums tab in
/// Culler's dark chrome: a hierarchical grid of folders and album cards
/// (square cover via PhotoLibrarySource, title, count). Tapping an album
/// opens it IN PLACE through `onOpenAlbum` — nothing is copied.
struct AlbumBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Host opens the album in place (PhotoLibrarySource) — no copying.
    var onOpenAlbum: (String) -> Void

    private enum Phase {
        case loading, denied, browsing
    }
    @State private var phase: Phase = .loading
    /// Limited photo access: most albums are invisible; say so and offer
    /// the system picker to expand the selection.
    @State private var isLimitedAccess = false
    /// Bumped after the limited-library picker expands the selection, to
    /// force the browse level to reload its entries.
    @State private var reloadToken = 0

    init(onOpenAlbum: @escaping (String) -> Void = { _ in }) {
        self.onOpenAlbum = onOpenAlbum
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView()
                        .tint(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .denied:
                    deniedView
                case .browsing:
                    albumGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadAlbums() }
    }

    private func loadAlbums() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized, .limited:
            isLimitedAccess = status == .limited
            phase = .browsing   // BrowseLevelView loads its own entries
        default:
            phase = .denied
        }
    }

    /// Present the system's limited-library picker so the user can expand
    /// which photos Culler may see, then reload the browse level so newly
    /// permitted albums appear without closing the sheet.
    private func presentLimitedLibraryPicker() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { _ in
            Task { @MainActor in
                reloadToken += 1   // forces BrowseLevelView to re-fetch entries
            }
        }
    }

    private func openInPlace(_ entry: PhotosImportCoordinator.AlbumEntry) {
        Haptics.tap()
        dismiss()
        onOpenAlbum(entry.id)
    }

    // MARK: Album grid

    private var albumGrid: some View {
        BrowseLevelView(
            title: "Albums",
            loader: { PhotosImportCoordinator.fetchTopLevel() },
            isLimited: isLimitedAccess,
            limitedBanner: { AnyView(limitedAccessBanner) },
            onOpenAlbum: { entry in openInPlace(entry) }
        )
        .id(reloadToken)
    }

    /// One level of the album hierarchy (top level, or inside a folder).
    /// Folders push another BrowseLevelView; albums render as cards.
    private struct BrowseLevelView: View {
        let title: String
        let loader: () -> [PhotosImportCoordinator.BrowseEntry]
        var isLimited: Bool = false
        var limitedBanner: () -> AnyView = { AnyView(EmptyView()) }
        let onOpenAlbum: (PhotosImportCoordinator.AlbumEntry) -> Void

        @State private var entries: [PhotosImportCoordinator.BrowseEntry] = []
        @State private var loaded = false

        var body: some View {
            ScrollView {
                if isLimited { limitedBanner() }
                if loaded && entries.isEmpty {
                    Text("Nothing here.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 16
                ) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .folder(let fid, let ftitle, let list, let subCount):
                            NavigationLink {
                                BrowseLevelView(
                                    title: ftitle,
                                    loader: { PhotosImportCoordinator.fetchFolder(list) },
                                    onOpenAlbum: onOpenAlbum
                                )
                            } label: {
                                FolderCard(id: fid, title: ftitle, subCount: subCount, list: list)
                            }
                            .buttonStyle(.plain)
                        case .album(let a):
                            AlbumCard(
                                entry: a,
                                onOpen: { onOpenAlbum(a) }
                            )
                        }
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if !loaded {
                    entries = await Task.detached(priority: .userInitiated) { loader() }.value
                    loaded = true
                }
            }
        }
    }

    private struct FolderCard: View {
        let id: String
        let title: String
        let subCount: Int
        let list: PHCollectionList

        /// A handful of covers pulled from the albums inside this folder
        /// (recursing into sub-folders if it has no albums directly) — a
        /// preview of what's inside instead of a plain folder glyph.
        @State private var covers: [UIImage] = []

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.cell)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if covers.isEmpty {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 38, weight: .light))
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            MiniCollage(images: covers)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(subCount) item\(subCount == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .task(id: id) {
                let assetIDs = await Task.detached(priority: .userInitiated) {
                    PhotosImportCoordinator.folderCoverAssetIDs(list, limit: 6)
                }.value
                guard !assetIDs.isEmpty else { return }
                covers = await withTaskGroup(of: (Int, UIImage?).self) { group in
                    for (offset, assetID) in assetIDs.enumerated() {
                        group.addTask {
                            (offset, await PhotoLibrarySource.shared.thumbnail(assetID: assetID, maxPixel: 240))
                        }
                    }
                    var ordered = [UIImage?](repeating: nil, count: assetIDs.count)
                    for await (offset, image) in group { ordered[offset] = image }
                    return ordered.compactMap { $0 }
                }
            }
        }
    }

    private var limitedAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
            Text("Selecta can only see the photos you've selected.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            Button("Manage…") { presentLimitedLibraryPicker() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.surface)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private struct AlbumCard: View {
        let entry: PhotosImportCoordinator.AlbumEntry
        let onOpen: () -> Void

        /// The album's most recent photos, newest first — a mini contact
        /// sheet instead of a single cover shot.
        @State private var covers: [UIImage] = []

        var body: some View {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    coverView
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text("\(entry.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .task(id: entry.id) {
                // coverImages does a direct sorted fetch + per-asset
                // thumbnail request — the same reliable path used
                // everywhere else — rather than PHAsset.fetchKeyAssets,
                // which routinely comes back empty for a plain user album
                // (that mismatch was why every album row showed no cover).
                covers = await PhotoLibrarySource.shared.coverImages(albumID: entry.id, count: 6, maxPixel: 240)
            }
        }

        private var coverView: some View {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.cell)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if covers.isEmpty {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        MiniCollage(images: covers)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
        }
    }

    /// Up to 6 tiles, most recent first — 1 full tile, a 2-row, an L-shaped
    /// 3-split, a 2×2, or two rows of 3 depending on how many photos
    /// actually loaded. Shared by AlbumCard and FolderCard cover previews.
    private struct MiniCollage: View {
        let images: [UIImage]

        var body: some View {
            GeometryReader { geo in
                collage(in: geo.size)
            }
        }

        @ViewBuilder
        private func collage(in size: CGSize) -> some View {
            let hair: CGFloat = 1.5
            switch images.count {
            case 1:
                tile(images[0], width: size.width, height: size.height)
            case 2:
                row([images[0], images[1]], height: size.width, hair: hair)
            case 3:
                HStack(spacing: hair) {
                    tile(images[0], width: (size.width - hair) / 2, height: size.height)
                    VStack(spacing: hair) {
                        tile(images[1], width: (size.width - hair) / 2, height: (size.height - hair) / 2)
                        tile(images[2], width: (size.width - hair) / 2, height: (size.height - hair) / 2)
                    }
                }
            case 4:
                VStack(spacing: hair) {
                    row(Array(images[0..<2]), height: (size.height - hair) / 2, hair: hair)
                    row(Array(images[2..<4]), height: (size.height - hair) / 2, hair: hair)
                }
            default:
                // 5 or 6.
                VStack(spacing: hair) {
                    row(Array(images[0..<3]), height: (size.height - hair) / 2, hair: hair)
                    row(Array(images[3...]), height: (size.height - hair) / 2, hair: hair)
                }
            }
        }

        private func row(_ images: [UIImage], height: CGFloat, hair: CGFloat) -> some View {
            HStack(spacing: hair) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    tile(image, width: .infinity, height: height)
                }
            }
        }

        private func tile(_ image: UIImage, width: CGFloat, height: CGFloat) -> some View {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width == .infinity ? nil : max(width, 0), height: max(height, 0))
                .frame(maxWidth: width == .infinity ? .infinity : nil)
                .clipped()
        }
    }

    private var deniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Photos access is off")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Selecta needs read access to your photo library to list albums. You can grant it in Settings.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 140, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
