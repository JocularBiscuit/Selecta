import Foundation
import Photos
import UIKit
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
    func coverImages(albumID: String, count: Int, maxPixel: CGFloat) async -> [UIImage] {
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

        return await withTaskGroup(of: (Int, UIImage?).self) { group in
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
            var ordered = [UIImage?](repeating: nil, count: assets.count)
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
    func thumbnail(assetID: String, maxPixel: CGFloat) async -> UIImage? {
        guard let asset = fetchAsset(assetID) else { return nil }
        return await requestImage(
            asset: asset,
            targetSize: CGSize(width: maxPixel, height: maxPixel),
            contentMode: .aspectFill
        )
    }

    /// Full-resolution image for the loupe.
    func fullImage(assetID: String) async -> UIImage? {
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
        if let cached = cachedRaw(assetID) { return cached }
        guard let asset = fetchAsset(assetID) else { return false }
        let isRaw = Self.hasRawResource(asset)
        storeRaw([assetID: isRaw])
        return isRaw
    }

    /// RAW answers for many assets at once — the efficient path for a whole
    /// album (Recents can hold tens of thousands). One PHAsset fetch per
    /// batch of identifiers instead of one per asset, and answers are
    /// remembered for the session (an asset's resources don't change), so
    /// re-filtering or reopening the album is instant. Synchronous: call it
    /// off the main actor. Unknown identifiers come back as not-RAW.
    func rawFlags(for assetIDs: [String]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        var missing: [String] = []
        rawCacheLock.lock()
        for id in assetIDs {
            if let cached = rawCache[id] { result[id] = cached } else { missing.append(id) }
        }
        rawCacheLock.unlock()
        guard !missing.isEmpty else { return result }

        // Stored ids may be lowercased (see fetchAsset); fetch by the
        // uppercased form and map answers back to whatever was asked.
        var askedByUpper: [String: [String]] = [:]
        for id in missing { askedByUpper[id.uppercased(), default: []].append(id) }
        var found: [String: Bool] = [:]
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(askedByUpper.keys), options: nil)
        assets.enumerateObjects { asset, _, _ in
            let isRaw = Self.hasRawResource(asset)
            for asked in askedByUpper[asset.localIdentifier.uppercased()] ?? [] { found[asked] = isRaw }
        }
        for id in missing where found[id] == nil { found[id] = false }
        storeRaw(found)
        result.merge(found) { _, new in new }
        return result
    }

    /// Capture locations for many assets at once, straight off PHAsset (the
    /// library's own index — no image download). Assets without a location
    /// are simply absent. Synchronous: call it off the main actor.
    func coordinates(for assetIDs: [String]) -> [String: GeoPoint] {
        var askedByUpper: [String: [String]] = [:]
        for id in assetIDs { askedByUpper[id.uppercased(), default: []].append(id) }
        var result: [String: GeoPoint] = [:]
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(askedByUpper.keys), options: nil)
        assets.enumerateObjects { asset, _, _ in
            guard let c = asset.location?.coordinate, c.latitude != 0 || c.longitude != 0 else { return }
            let point = GeoPoint(latitude: c.latitude, longitude: c.longitude)
            for asked in askedByUpper[asset.localIdentifier.uppercased()] ?? [] { result[asked] = point }
        }
        return result
    }

    private static func hasRawResource(_ asset: PHAsset) -> Bool {
        guard asset.mediaType == .image else { return false }
        return PHAssetResource.assetResources(for: asset).contains { resource in
            resource.type == .alternatePhoto || isRawType(resource.uniformTypeIdentifier)
        }
    }

    private let rawCacheLock = NSLock()
    private var rawCache: [String: Bool] = [:]

    private func cachedRaw(_ assetID: String) -> Bool? {
        rawCacheLock.lock(); defer { rawCacheLock.unlock() }
        return rawCache[assetID]
    }

    private func storeRaw(_ flags: [String: Bool]) {
        rawCacheLock.lock(); defer { rawCacheLock.unlock() }
        rawCache.merge(flags) { _, new in new }
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
    private func requestImage(asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode) async -> UIImage? {
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
