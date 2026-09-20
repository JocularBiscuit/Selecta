import Foundation

import ImageIO
import CoreImage
import CryptoKit
import AVFoundation

/// Lightweight image metadata read via ImageIO without decoding pixels.
/// Everything is optional — missing EXIF fields simply stay nil.
struct ImageMeta: Equatable, Sendable {
    var pixelSize: CGSize?
    var captureDate: Date?
    var fNumber: Double?
    var exposureSeconds: Double?
    var iso: Int?
    var focalLength35mm: Int?   // 35mm-equivalent; falls back to FocalLength
    var cameraModel: String?    // TIFF "Model"
    var durationSeconds: Double?    // videos only; nil for stills
    // Extra fields for the full "all metadata" Details sheet — nil whenever
    // the source file doesn't carry them (common for stripped/edited exports).
    var cameraMake: String?         // TIFF "Make", e.g. "SONY"
    var lensModel: String?          // Exif "LensModel"
    var exposureBias: Double?       // EV compensation
    var gpsCoordinateText: String?  // "37.3349° N, 122.0090° W", if present
    var colorSpace: String?         // "sRGB", "Adobe RGB", …
    var orientation: Int?           // Exif/TIFF orientation tag (1–8)
}

/// Thumbnail / preview pipeline.
///
/// Strategy (in order):
///  1. JPEG sibling → decode downsampled with ImageIO (fast, always works).
///  2. RAW → embedded JPEG preview via CGImageSourceCreateThumbnailAtIndex.
///  3. RAW → CIRAWFilter reduced-size render (slow fallback).
///  4. nil → caller shows a placeholder. Never blocks the UI.
///
/// Every generated thumbnail is disk-cached keyed by (path, mtime, size, maxPixel),
/// decodes run off the main thread with bounded concurrency, and queued work
/// honors Task cancellation so scrolled-past cells don't burn CPU.
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()

    private let memory = NSCache<NSString, PlatformImage>()
    private let gate = AsyncLimiter(limit: 4)
    private let cacheDir: URL

    /// Thumbnail decode buckets (device pixels). Requests are rounded up to
    /// one of these so pinch-resizing never triggers a re-decode per step.
    static let thumbBuckets: [CGFloat] = [240, 400, 640]

    /// Synthetic bucket for loupe/full-size cache keys.
    private static let loupeBucket: CGFloat = 8192

    private init() {
        // Cost-based eviction: ~320 MB of decoded pixels, biggest wins first out.
        memory.totalCostLimit = 320 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: Public API

    /// Grid/filmstrip thumbnail. `maxPixel` is in device pixels.
    func thumbnail(for item: CardItem, maxPixel: CGFloat) async -> PlatformImage? {
        if let assetID = item.assetLocalID {
            let bucket = Self.thumbBuckets.first { $0 >= maxPixel } ?? Self.thumbBuckets[Self.thumbBuckets.count - 1]
            return await assetImage(assetID: assetID, bucket: bucket)
        }
        guard let url = item.previewURL else { return nil }
        return await image(for: url, maxPixel: maxPixel, diskCache: true)
    }

    /// Loupe-size image: big enough for 100% focus checks. Not disk-cached
    /// (too large); memory-cached only.
    func loupeImage(for item: CardItem) async -> PlatformImage? {
        if let assetID = item.assetLocalID {
            return await assetImage(assetID: assetID, bucket: Self.loupeBucket)
        }
        guard let url = item.previewURL else { return nil }
        return await image(for: url, maxPixel: 8192, diskCache: false)
    }

    /// Best already-available image for an item, largest first — checked
    /// synchronously against the memory cache, then the thumbnail disk cache.
    /// Lets the loupe show *something* instantly while full-res decodes
    /// (progressive loading; never blocks).
    func cachedPreview(for item: CardItem) -> PlatformImage? {
        if let assetID = item.assetLocalID {
            // Photos-library assets are memory-only (PhotoKit has its own
            // disk caches); scan every bucket, largest first.
            for px in [Self.loupeBucket] + Self.thumbBuckets.reversed() {
                if let hit = memory.object(forKey: assetKey(assetID, bucket: px) as NSString) {
                    return hit
                }
            }
            return nil
        }
        guard let url = item.previewURL else { return nil }
        for px in [8192] + Self.thumbBuckets.reversed() {
            if let hit = memory.object(forKey: cacheKey(url: url, maxPixel: px) as NSString) {
                return hit
            }
        }
        for px in Self.thumbBuckets.reversed() {
            if let disk = loadFromDisk(key: cacheKey(url: url, maxPixel: px)) {
                return disk
            }
        }
        return nil
    }

    func cacheSizeBytes() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func clearCache() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: Photos-library assets

    /// Memory-cache key for a Photos-library asset at a given bucket size.
    private func assetKey(_ assetID: String, bucket: CGFloat) -> String {
        "ph|\(assetID)|\(Int(bucket))"
    }

    /// Fetch (or return the cached) image for a Photos-library asset.
    /// Memory-cached only — PhotoKit maintains its own disk caches, so a
    /// second cache layer on disk would just double the footprint.
    private func assetImage(assetID: String, bucket: CGFloat) async -> PlatformImage? {
        let key = assetKey(assetID, bucket: bucket)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if Task.isCancelled { return nil }

        // Same bounded-concurrency gate as file decodes: fast scrolling over
        // a huge album must not fire unbounded PhotoKit requests (each one a
        // potential iCloud download). Cancelled cells give the slot back.
        guard await gate.acquire() else { return nil }
        defer { gate.release() }
        if Task.isCancelled { return nil }
        if let hit = memory.object(forKey: key as NSString) { return hit }

        let fetched: PlatformImage?
        if bucket >= Self.loupeBucket {
            fetched = await PhotoLibrarySource.shared.fullImage(assetID: assetID)
        } else {
            fetched = await PhotoLibrarySource.shared.thumbnail(assetID: assetID, maxPixel: bucket)
        }
        if let fetched {
            memory.setObject(fetched, forKey: key as NSString, cost: Self.pixelCost(of: fetched))
        }
        return fetched
    }

    // MARK: Core pipeline

    private func image(for url: URL, maxPixel: CGFloat, diskCache: Bool) async -> PlatformImage? {
        let key = cacheKey(url: url, maxPixel: maxPixel)

        if let hit = memory.object(forKey: key as NSString) { return hit }

        if diskCache, let disk = loadFromDisk(key: key) {
            memory.setObject(disk, forKey: key as NSString, cost: Self.pixelCost(of: disk))
            return disk
        }

        if Task.isCancelled { return nil }

        // Bounded concurrency; give up the slot immediately if cancelled while queued.
        guard await gate.acquire() else { return nil }
        defer { gate.release() }
        if Task.isCancelled { return nil }

        let decoded: PlatformImage? = await Task.detached(priority: .userInitiated) { [cacheDir] in
            guard let img = Self.decode(url: url, maxPixel: maxPixel) else { return nil }
            if diskCache, let data = img.jpegDataCompat(compressionQuality: 0.8) {
                let dest = cacheDir.appendingPathComponent(key).appendingPathExtension("jpg")
                try? data.write(to: dest, options: .atomic)
            }
            return img
        }.value

        if let decoded {
            memory.setObject(decoded, forKey: key as NSString, cost: Self.pixelCost(of: decoded))
        }
        return decoded
    }

    private static func pixelCost(of image: PlatformImage) -> Int {
        guard let cg = image.cgImageCompat else { return 1 }
        return cg.width * cg.height * 4
    }

    private static func decode(url: URL, maxPixel: CGFloat) -> PlatformImage? {
        let ext = url.pathExtension.lowercased()
        if FileTypes.video.contains(ext) { return videoPosterFrame(url: url, maxPixel: maxPixel) }

        if let img = imageIOThumbnail(url: url, maxPixel: maxPixel) { return img }

        // Last-ditch RAW render at reduced size.
        if FileTypes.raw.contains(ext) { return ciRawRender(url: url, maxPixel: maxPixel) }
        return nil
    }

    /// ImageIO decode. For RAW files this pulls the embedded JPEG preview;
    /// for JPEGs it downsample-decodes without loading the full bitmap.
    private static func imageIOThumbnail(url: URL, maxPixel: CGFloat) -> PlatformImage? {
        let srcOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOptions as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        return PlatformImage.fromCGImage(cg)
    }

    /// Poster frame for a video: a frame near the 1-second mark (clamped to the
    /// clip's duration by the generator's loose tolerances), oriented and sized
    /// like any other thumbnail. Runs synchronously inside the detached decode
    /// task, and the result flows through the same memory/disk caches as stills.
    private static func videoPosterFrame(url: URL, maxPixel: CGFloat) -> PlatformImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // ~1s in gives a representative frame (skips black lead-ins); the loose
        // tolerances snap it back inside shorter clips. Fall back to the first
        // frame if the seek still fails.
        let target = CMTime(seconds: 1, preferredTimescale: 600)
        if let cg = try? generator.copyCGImage(at: target, actualTime: nil) {
            return PlatformImage.fromCGImage(cg)
        }
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return PlatformImage.fromCGImage(cg)
    }

    private static func ciRawRender(url: URL, maxPixel: CGFloat) -> PlatformImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        filter.isDraftModeEnabled = true
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1.0, maxPixel / max(extent.width, extent.height))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return PlatformImage.fromCGImage(cg)
    }

    /// Load metadata (dimensions, capture date, exposure) without decoding pixels.
    /// Stills go through ImageIO; videos load duration/track info via AVFoundation.
    static func metadata(for url: URL) async -> ImageMeta {
        if FileTypes.video.contains(url.pathExtension.lowercased()) {
            return await videoMetadata(for: url)
        }
        return imageMetadata(for: url)
    }

    private static func videoMetadata(for url: URL) async -> ImageMeta {
        var meta = ImageMeta()
        let asset = AVURLAsset(url: url)

        if let (duration, tracks) = try? await asset.load(.duration, .tracks) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { meta.durationSeconds = seconds }

            if let track = tracks.first(where: { $0.mediaType == .video }),
               let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let transformed = naturalSize.applying(transform)
                let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                if size.width > 0, size.height > 0 { meta.pixelSize = size }
            }
        }

        // Capture date: asset creationDate when trivially available, else file date.
        if let creationItem = try? await asset.load(.creationDate),
           let date = try? await creationItem.load(.dateValue) {
            meta.captureDate = date
        } else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            meta.captureDate = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
        }
        return meta
    }

    private static func imageMetadata(for url: URL) -> ImageMeta {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ImageMeta()
        }
        return parseProperties(props)
    }

    /// EXIF/TIFF/GPS parsing shared by file-based reads (ImageIO on a URL)
    /// and Photos-library reads (ImageIO on downloaded original `Data`, see
    /// `assetMeta(from:)`) — one source of truth for "all metadata".
    private static func parseProperties(_ props: [CFString: Any]) -> ImageMeta {
        var meta = ImageMeta()
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            meta.pixelSize = CGSize(width: w, height: h)
        }
        if let orientation = props[kCGImagePropertyOrientation] as? Int {
            meta.orientation = orientation
        }
        if let colorModel = props[kCGImagePropertyColorModel] as? String {
            meta.colorSpace = colorModel
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
                meta.captureDate = fmt.date(from: raw)
            }
            if let f = exif[kCGImagePropertyExifFNumber] as? Double, f > 0 {
                meta.fNumber = f
            }
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
                meta.exposureSeconds = t
            }
            if let speeds = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any],
               let iso = speeds.first as? Int, iso > 0 {
                meta.iso = iso
            }
            if let f35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, f35 > 0 {
                meta.focalLength35mm = f35
            } else if let focal = exif[kCGImagePropertyExifFocalLength] as? Double, focal > 0 {
                meta.focalLength35mm = Int(focal.rounded())
            }
            if let lens = (exif[kCGImagePropertyExifLensModel] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !lens.isEmpty {
                meta.lensModel = lens
            }
            if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double {
                meta.exposureBias = bias
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let model = (tiff[kCGImagePropertyTIFFModel] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                meta.cameraModel = model
            }
            if let make = (tiff[kCGImagePropertyTIFFMake] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !make.isEmpty {
                meta.cameraMake = make
            }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            meta.gpsCoordinateText = String(format: "%.4f° %@, %.4f° %@", lat, latRef, lon, lonRef)
        }
        return meta
    }

    /// EXIF for a Photos-library asset, parsed from its original image data
    /// (fetched separately since it can be a large iCloud download — callers
    /// decide when that's worth it). Mirrors the file-based read above so
    /// both sources feed the same "all metadata" formatting.
    static func assetMeta(from data: Data) -> ImageMeta {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return ImageMeta()
        }
        return parseProperties(props)
    }

    // MARK: Helpers

    private func cacheKey(url: URL, maxPixel: CGFloat) -> String {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int64) ?? 0
        let raw = "\(url.path)|\(mtime)|\(size)|\(Int(maxPixel))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadFromDisk(key: String) -> PlatformImage? {
        let url = cacheDir.appendingPathComponent(key).appendingPathExtension("jpg")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return PlatformImage(data: data)
    }
}

/// Simple async semaphore: bounds concurrent decodes, returns false if the
/// waiting task was cancelled before a slot opened.
final class AsyncLimiter: @unchecked Sendable {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private let lock = NSLock()

    init(limit: Int) { self.limit = limit }

    func acquire() async -> Bool {
        lock.lock()
        if active < limit {
            active += 1
            lock.unlock()
            return true
        }
        lock.unlock()
        return await withCheckedContinuation { cont in
            lock.lock()
            if active < limit {
                active += 1
                lock.unlock()
                cont.resume(returning: true)
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        if let next = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            next.resume(returning: true)
        } else {
            active = max(0, active - 1)
            lock.unlock()
        }
    }
}
