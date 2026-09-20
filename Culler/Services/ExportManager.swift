import Foundation
import Observation
import Photos

/// Copies originals byte-for-byte to a destination folder, optionally writes
/// XMP sidecars alongside, optionally adds to a Photos album.
/// Never re-encodes; never overwrites silently (collisions get " (1)" names).
@MainActor
@Observable
final class ExportManager {

    enum FileChoice: String, CaseIterable, Identifiable {
        case both = "RAW + JPEG"
        case rawOnly = "RAW only"
        case jpegOnly = "JPEG only"
        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case idle
        case running
        case done
        case failed(String)
    }

    var phase: Phase = .idle
    var completed = 0
    var total = 0
    var currentFile = ""
    var summary: ExportSummary?

    struct ExportSummary {
        var copied = 0
        var sidecars = 0
        var renamedCollisions = 0
        var addedToPhotos = 0
        /// Photos-library items skipped by "Also add to Photos album" —
        /// they already live in the Photos library.
        var alreadyInPhotos = 0
        var failures: [String] = []
        var destination: URL
    }

    var fractionComplete: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }

    /// The app's Files-visible export root: Documents/Exports.
    /// (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace make
    ///  Documents browsable in the Files app under "On My iPhone → Culler".)
    static func appExportsRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func reset() {
        phase = .idle
        completed = 0
        total = 0
        currentFile = ""
        summary = nil
    }

    // swiftlint:disable:next function_parameter_count
    func export(
        items: [CardItem],
        choice: FileChoice,
        destination: URL,
        destinationIsSecurityScoped: Bool,
        subfolderName: String?,
        writeSidecars: Bool,
        sidecarIncludesExtension: Bool,
        addToPhotos: Bool,
        albumName: String
    ) {
        guard phase != .running else { return }
        phase = .running
        summary = nil

        // Work out the flat copy list up front for accurate progress.
        // Photos-library assets have no source URLs; they export via
        // PHAssetResource and are pre-counted as one job each (the total is
        // corrected once we know how many files each asset actually wrote).
        var jobs: [(source: URL, item: CardItem)] = []
        var assetItems: [CardItem] = []
        for item in items {
            if item.assetLocalID != nil {
                assetItems.append(item)
                continue
            }
            switch choice {
            case .both:
                if let raw = item.rawURL { jobs.append((raw, item)) }
                if let jpeg = item.jpegURL { jobs.append((jpeg, item)) }
                if item.rawURL == nil && item.jpegURL == nil, let video = item.videoURL { jobs.append((video, item)) }
            case .rawOnly:
                // Videos have no RAW/JPEG variant — never drop them silently.
                if let url = item.rawURL ?? item.jpegURL ?? item.videoURL { jobs.append((url, item)) }
            case .jpegOnly:
                if let url = item.jpegURL ?? item.rawURL ?? item.videoURL { jobs.append((url, item)) }
            }
        }
        total = jobs.count + assetItems.count
        completed = 0

        Task {
            let accessing = destinationIsSecurityScoped && destination.startAccessingSecurityScopedResource()
            defer { if accessing { destination.stopAccessingSecurityScopedResource() } }

            // Resolve the actual target folder: optionally a subfolder created
            // inside the chosen destination. This must happen AFTER the
            // security scope is active so we can create it in a picked folder.
            let target: URL
            if let subfolderName, !subfolderName.isEmpty {
                let sub = destination.appendingPathComponent(subfolderName, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                } catch {
                    summary = ExportSummary(
                        failures: ["Couldn't create subfolder \"\(subfolderName)\": \(error.localizedDescription)"],
                        destination: destination
                    )
                    currentFile = ""
                    phase = .failed("Couldn't create the export subfolder.")
                    return
                }
                target = sub
            } else {
                target = destination
            }

            var result = ExportSummary(destination: target)

            // Track the primary exported file per item for sidecars & Photos.
            var exportedPrimary: [String: URL] = [:]

            for (source, item) in jobs {
                currentFile = source.lastPathComponent
                let copyResult = await Task.detached(priority: .userInitiated) { () -> Result<(URL, Bool), Error> in
                    do {
                        let dest = Self.uniqueDestination(for: source.lastPathComponent, in: target)
                        try FileManager.default.copyItem(at: source, to: dest.url)
                        return .success((dest.url, dest.renamed))
                    } catch {
                        return .failure(error)
                    }
                }.value

                switch copyResult {
                case .success(let (dest, renamed)):
                    result.copied += 1
                    if renamed { result.renamedCollisions += 1 }
                    // Prefer the RAW as the sidecar anchor (Adobe convention).
                    let ext = dest.pathExtension.lowercased()
                    if exportedPrimary[item.id] == nil || FileTypes.raw.contains(ext) {
                        exportedPrimary[item.id] = dest
                    }
                case .failure(let error):
                    result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
                completed += 1
            }

            // Photos-library assets: write the original resources straight
            // from PhotoKit into the target folder, sequentially.
            for item in assetItems {
                guard let assetID = item.assetLocalID else {
                    completed += 1
                    continue
                }
                currentFile = item.baseName
                var export = await PhotoLibrarySource.shared.exportResources(
                    assetID: assetID,
                    to: target,
                    includeRAW: choice != .jpegOnly,
                    includeNonRAW: choice != .rawOnly
                )
                if export.written.isEmpty && export.failures.isEmpty && choice == .rawOnly {
                    // Asset has no RAW resource — fall back to its non-RAW original.
                    export = await PhotoLibrarySource.shared.exportResources(
                        assetID: assetID,
                        to: target,
                        includeRAW: false,
                        includeNonRAW: true
                    )
                }
                // Real per-resource errors (iCloud/network, access) surface
                // as-is; "no exportable original" only when nothing failed.
                result.failures.append(contentsOf: export.failures)
                let written = export.written
                if written.isEmpty {
                    if export.failures.isEmpty {
                        result.failures.append("\(item.baseName): no exportable original in Photos.")
                    }
                } else {
                    result.copied += written.count
                    // The asset was pre-counted as one job; account for extras.
                    total += written.count - 1
                    completed += written.count - 1
                    // Prefer the RAW as the sidecar anchor (Adobe convention).
                    let anchor = written.first { FileTypes.raw.contains($0.pathExtension.lowercased()) } ?? written[0]
                    exportedPrimary[item.id] = anchor
                    currentFile = written.last?.lastPathComponent ?? currentFile
                }
                completed += 1
            }

            if writeSidecars {
                for item in items {
                    guard item.rating > 0 || item.label != nil, let anchor = exportedPrimary[item.id] else { continue }
                    if XMP.write(rating: item.rating, label: item.label, nextTo: anchor, includeExtension: sidecarIncludesExtension) {
                        result.sidecars += 1
                    }
                }
            }

            if addToPhotos {
                var urls: [URL] = []
                for item in items {
                    if item.assetLocalID != nil {
                        // Browsed in place — this shot already lives in Photos.
                        result.alreadyInPhotos += 1
                    } else if let url = photosCandidate(for: item) {
                        urls.append(url)
                    }
                }
                do {
                    let added = try await PhotosSaver.add(urls: urls, toAlbumNamed: albumName)
                    result.addedToPhotos = added
                } catch {
                    result.failures.append("Photos: \(error.localizedDescription)")
                }
            }

            currentFile = ""
            summary = result
            phase = result.failures.isEmpty ? .done : (result.copied > 0 ? .done : .failed(result.failures.first ?? "Export failed"))
        }
    }

    /// JPEG is the reliable Photos citizen; fall back to RAW (Photos accepts
    /// most common RAW formats, and PhotosSaver skips whatever it rejects).
    /// Videos go in as their movie file.
    private func photosCandidate(for item: CardItem) -> URL? {
        item.jpegURL ?? item.rawURL ?? item.videoURL
    }

    /// Never overwrite: `DSC01234.ARW` → `DSC01234 (1).ARW` etc.
    nonisolated static func uniqueDestination(for filename: String, in directory: URL) -> (url: URL, renamed: Bool) {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(filename)
        if !fm.fileExists(atPath: candidate.path) { return (candidate, false) }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 1
        repeat {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        } while fm.fileExists(atPath: candidate.path)
        return (candidate, true)
    }
}

// MARK: - Photos album

enum PhotosSaver {

    enum SaverError: LocalizedError {
        case notAuthorized
        case albumCreationFailed
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Photos access was not granted."
            case .albumCreationFailed: return "Couldn't create the album."
            }
        }
    }

    /// Adds files to a named album (created if needed). Returns how many were
    /// added; files Photos rejects (e.g. exotic RAW) are skipped one by one.
    static func add(urls: [URL], toAlbumNamed name: String) async throws -> Int {
        guard !urls.isEmpty else { return 0 }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaverError.notAuthorized }

        let album = try await fetchOrCreateAlbum(named: name)
        var added = 0
        for url in urls {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    let type: PHAssetResourceType = FileTypes.video.contains(url.pathExtension.lowercased())
                        ? .video : .photo
                    request.addResource(with: type, fileURL: url, options: options)
                    if let placeholder = request.placeholderForCreatedAsset,
                       let albumChange = PHAssetCollectionChangeRequest(for: album) {
                        albumChange.addAssets([placeholder] as NSArray)
                    }
                }
                added += 1
            } catch {
                continue // one bad file shouldn't sink the batch
            }
        }
        return added
    }

    private static func fetchOrCreateAlbum(named name: String) async throws -> PHAssetCollection {
        let fetch = PHFetchOptions()
        fetch.predicate = NSPredicate(format: "title = %@", name)
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetch).firstObject {
            return existing
        }
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = placeholderID,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw SaverError.albumCreationFailed
        }
        return album
    }

    /// Creates a brand-new REGULAR Photos album (never an iCloud Shared
    /// Album — Photos only ever creates those through its own explicit
    /// "New Shared Album" flow, so a plain `creationRequestForAssetCollection`
    /// like this is always a normal, local, non-shared album) directly from
    /// a selection — no intermediate folder export involved, unlike the
    /// Export flow's "Also add to Photos album" toggle. Items already in the
    /// Photos library are added by reference (no duplicate); file-based
    /// items (from a card/folder) are imported as new assets, with a
    /// RAW+JPEG pair combined into ONE asset (RAW as the alternate resource)
    /// exactly like a camera-captured RAW+JPEG shot.
    static func createAlbum(named name: String, from items: [CardItem]) async throws -> (added: Int, failed: Int) {
        guard !items.isEmpty else { return (0, 0) }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaverError.notAuthorized }

        var placeholderID: String?
        try? await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = placeholderID,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw SaverError.albumCreationFailed
        }

        var added = 0
        var failed = 0
        for item in items {
            if let assetID = item.assetLocalID {
                guard let asset = fetchAssetCaseInsensitive(assetID) else {
                    failed += 1
                    continue
                }
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        if let albumChange = PHAssetCollectionChangeRequest(for: album) {
                            albumChange.addAssets([asset] as NSArray)
                        }
                    }
                    added += 1
                } catch {
                    failed += 1
                }
                continue
            }
            guard item.jpegURL != nil || item.rawURL != nil || item.videoURL != nil else {
                failed += 1
                continue
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    if let jpegURL = item.jpegURL {
                        request.addResource(with: .photo, fileURL: jpegURL, options: options)
                    }
                    if let rawURL = item.rawURL {
                        request.addResource(with: item.jpegURL != nil ? .alternatePhoto : .photo, fileURL: rawURL, options: options)
                    }
                    if let videoURL = item.videoURL {
                        request.addResource(with: .video, fileURL: videoURL, options: options)
                    }
                    if let placeholder = request.placeholderForCreatedAsset,
                       let albumChange = PHAssetCollectionChangeRequest(for: album) {
                        albumChange.addAssets([placeholder] as NSArray)
                    }
                }
                added += 1
            } catch {
                failed += 1
            }
        }
        return (added, failed)
    }

    /// PHAsset local identifiers are case-sensitive; item ids store them
    /// lowercased (see PhotoLibrarySource.fetchAsset for the same fix).
    private static func fetchAssetCaseInsensitive(_ assetID: String) -> PHAsset? {
        if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject {
            return asset
        }
        let upper = assetID.uppercased()
        guard upper != assetID else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [upper], options: nil).firstObject
    }
}
