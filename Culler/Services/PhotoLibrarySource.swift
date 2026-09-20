import Foundation
import Photos
import AVFoundation
import UniformTypeIdentifiers

/// Live, in-place access to the user's Photos library: albums are browsed
/// where they are, nothing is copied into the app. Thread-safe by design
/// (plain final class, all entry points async) — deliberately NOT @MainActor.
final class PhotoLibrarySource {
    static let shared = PhotoLibrarySource()

    /// Images + videos only (no audio); used everywhere we count or fetch.
    private static func mediaPredicate() -> NSPredicate {
        NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
    }

    /// PHAsset local identifiers are case-sensitive (uppercase UUID + a
    /// suffix like "/L0/001"). Several call sites reconstruct an assetID by
    /// stripping the "photoslib|" prefix off a stored item id — which is
    /// LOWERCASED for consistent Set/Dictionary lookups — so a raw
    /// case-sensitive fetch silently returns nothing for those. Retrying
    /// uppercased here fixes every caller at once instead of requiring each
    /// one to remember to correct the case itself.
    private func fetchAsset(_ assetID: String) -> PHAsset? {
        if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject {
            return asset
        }
        let upper = assetID.uppercased()
        guard upper != assetID else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [upper], options: nil).firstObject
    }

    private func fetchCollection(_ albumID: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
    }

    /// Ask for (read) access to the Photos library.
    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Up to `count` most-recent thumbnails for an album/folder cover
    /// collage — a direct sorted fetch + per-asset thumbnail request, the
    /// same reliable path used for grid cells and project covers, rather
    /// than `PHAsset.fetchKeyAssets` (an album-summary API meant for
    /// "Moments"-style smart groupings; for a plain user-created album it
    /// routinely returns nil or an empty result, which is why album rows
    /// were showing no cover at all).
    func coverImages(albumID: String, count: Int, maxPixel: CGFloat) async -> [PlatformImage] {
        guard let collection = fetchCollection(albumID) else { return [] }
        let options = PHFetchOptions()
        options.predicate = Self.mediaPredicate()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = count
        let fetched = PHAsset.fetchAssets(in: collection, options: options)
        guard fetched.count > 0 else { return [] }
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }

        return await withTaskGroup(of: (Int, PlatformImage?).self) { group in
            for (offset, asset) in assets.enumerated() {
                group.addTask {
                    let image = await self.requestImage(
                        asset: asset,
                        targetSize: CGSize(width: maxPixel, height: maxPixel),
                        contentMode: .aspectFill
                    )
                    return (offset, image)
                }
            }
            var ordered = [PlatformImage?](repeating: nil, count: assets.count)
            for await (offset, image) in group { ordered[offset] = image }
            return ordered.compactMap { $0 }
        }
    }

    /// Fetch the album's assets as CardItems (assetLocalID set, URLs nil).
    /// Deliberately avoids per-asset PHAssetResource lookups — far too slow
    /// for big albums; format details stay generic ("PHOTO"/"VIDEO").
    func loadItems(albumID: String) async -> (title: String, items: [CardItem]) {
        guard let collection = fetchCollection(albumID) else { return ("", []) }

        let options = PHFetchOptions()
        options.predicate = Self.mediaPredicate()
        // Newest first — matches the app-wide default order.
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetched = PHAsset.fetchAssets(in: collection, options: options)

        var items: [CardItem] = []
        items.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            items.append(Self.makeItem(from: asset))
        }
        return (collection.localizedTitle ?? "Album", items)
    }

    /// Map one PHAsset to a CardItem (shared by album and project loading).
    static func makeItem(from asset: PHAsset) -> CardItem {
        let localID = asset.localIdentifier
        var item = CardItem(
            id: "photoslib|" + localID.lowercased(),
            baseName: String(localID.prefix(8)),
            fileDate: asset.creationDate ?? asset.modificationDate ?? Date()
        )
        item.assetLocalID = localID
        item.assetKind = asset.mediaType == .video ? .video : .jpegOnly
        item.assetFormat = asset.mediaType == .video ? "VIDEO" : "PHOTO"
        return item
    }

    /// Fetch specific assets by the lowercased ids stored in project
    /// membership ("photoslib|<lowercased local id>" without the prefix).
    /// PHAsset local identifiers are case-sensitive (uppercase UUID + "/L0/00x"),
    /// so try the uppercased form first and fall back to the raw strings.
    func loadAssets(lowercasedLocalIDs: [String]) async -> [CardItem] {
        guard !lowercasedLocalIDs.isEmpty else { return [] }
        var found: [String: PHAsset] = [:]   // keyed lowercased
        for candidates in [lowercasedLocalIDs.map { $0.uppercased() }, lowercasedLocalIDs] {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: candidates, options: nil)
            fetched.enumerateObjects { asset, _, _ in
                found[asset.localIdentifier.lowercased()] = asset
            }
            if found.count == lowercasedLocalIDs.count { break }
        }
        return found.values
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            .map { Self.makeItem(from: $0) }
    }

    /// Grid thumbnail for one asset.
    func thumbnail(assetID: String, maxPixel: CGFloat) async -> PlatformImage? {
        guard let asset = fetchAsset(assetID) else { return nil }
        return await requestImage(
            asset: asset,
            targetSize: CGSize(width: maxPixel, height: maxPixel),
            contentMode: .aspectFill
        )
    }

    /// Full-resolution image for the loupe.
    func fullImage(assetID: String) async -> PlatformImage? {
        guard let asset = fetchAsset(assetID) else { return nil }
        return await requestImage(
            asset: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit
        )
    }

    /// Cheap per-asset facts straight off PHAsset — no image data is
    /// downloaded. Used for info lines so browsing never forces an iCloud
    /// original download.
    struct AssetBasicInfo: Sendable {
        let pixelSize: CGSize?
        let creationDate: Date?
        let durationSeconds: Double?
    }

    func basicInfo(assetID: String) async -> AssetBasicInfo? {
        guard let asset = fetchAsset(assetID) else { return nil }
        let size: CGSize? = (asset.pixelWidth > 0 && asset.pixelHeight > 0)
            ? CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
            : nil
        return AssetBasicInfo(
            pixelSize: size,
            creationDate: asset.creationDate,
            durationSeconds: asset.mediaType == .video && asset.duration > 0 ? asset.duration : nil
        )
    }

    /// Original image data (for histogram/metadata reads).
    func imageData(assetID: String) async -> Data? {
        guard let asset = fetchAsset(assetID) else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard once.claim() else { return }
                continuation.resume(returning: data)
            }
        }
    }

    /// Streaming-capable player item for video assets.
    func playerItem(assetID: String) async -> AVPlayerItem? {
        guard let asset = fetchAsset(assetID) else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                guard once.claim() else { return }
                continuation.resume(returning: item)
            }
        }
    }

    /// Export the asset's original resources (RAW and/or non-RAW) into
    /// `directory`; returns the written file URLs plus one human-readable
    /// line per resource that failed (iCloud download errors, denied access
    /// and the like are surfaced, never swallowed). Only untouched originals
    /// are considered (.photo/.alternatePhoto/.video) — adjusted/derived
    /// renditions are skipped so exports stay byte-for-byte faithful.
    func exportResources(
        assetID: String,
        to directory: URL,
        includeRAW: Bool,
        includeNonRAW: Bool
    ) async -> (written: [URL], failures: [String]) {
        guard let asset = fetchAsset(assetID) else { return ([], []) }

        let originals = PHAssetResource.assetResources(for: asset).filter { resource in
            switch resource.type {
            case .photo, .alternatePhoto, .video: return true
            default: return false
            }
        }

        var written: [URL] = []
        var failures: [String] = []
        for resource in originals {
            let isRAW = resource.type == .alternatePhoto || Self.isRawType(resource.uniformTypeIdentifier)
            guard isRAW ? includeRAW : includeNonRAW else { continue }

            let destination = ExportManager.uniqueDestination(for: resource.originalFilename, in: directory).url
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            do {
                try await PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options)
                written.append(destination)
            } catch {
                try? FileManager.default.removeItem(at: destination) // no partial files
                failures.append("\(resource.originalFilename): \(error.localizedDescription)")
            }
        }
        return (written, failures)
    }

    private static func isRawType(_ identifier: String) -> Bool {
        UTType(identifier)?.conforms(to: .rawImage) == true
    }

    /// Whether an asset has a RAW resource (a RAW+JPEG pair or a RAW-only
    /// shot) — used to decide whether to offer the RAW/JPEG/Both share chooser.
    func assetHasRaw(_ assetID: String) async -> Bool {
        guard let asset = fetchAsset(assetID) else { return false }
        return PHAssetResource.assetResources(for: asset).contains { resource in
            resource.type == .alternatePhoto || Self.isRawType(resource.uniformTypeIdentifier)
        }
    }

    /// The asset's real original filename (e.g. "IMG_1234.HEIC"), straight
    /// off its PHAssetResource — cheap local metadata, no download. Used
    /// only for the single item the loupe currently shows (never the whole
    /// grid — see the note on `loadItems` about why a per-asset
    /// PHAssetResource lookup doesn't belong in a bulk path).
    func originalFilename(assetID: String) async -> String? {
        guard let asset = fetchAsset(assetID) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
        return primary?.originalFilename
    }

    // MARK: Image requests

    /// Wraps the callback-style PHImageManager API. Degraded interim results
    /// (PHImageResultIsDegradedKey) are ignored so the continuation resumes
    /// exactly once, with the final image (or nil on failure/cancel). Task
    /// cancellation cancels the underlying PhotoKit request (stopping any
    /// in-flight iCloud download) and resumes with nil immediately.
    private func requestImage(asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode) async -> PlatformImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let once = ResumeOnce()
        let canceller = RequestCanceller()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let requestID = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                    if degraded && image != nil { return } // wait for the final callback
                    guard once.claim() else { return }
                    continuation.resume(returning: image)
                }
                canceller.arm {
                    PHImageManager.default().cancelImageRequest(requestID)
                    if once.claim() { continuation.resume(returning: nil) }
                }
            }
        } onCancel: {
            canceller.cancel()
        }
    }
}

/// Bridges Swift Task cancellation to a callback-API cancel action. `arm`
/// registers the action once the request exists; if the task was already
/// cancelled by then, the action runs immediately. Thread-safe; the action
/// runs at most once.
private final class RequestCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var cancelled = false

    func arm(_ action: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            action()
            return
        }
        self.action = action
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = action
        self.action = nil
        lock.unlock()
        action?()
    }
}

/// Guards a checked continuation against double-resume from callback APIs
/// that may fire more than once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    /// Returns true exactly once.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
