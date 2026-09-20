import Foundation
import SwiftData

// MARK: - Flags & labels

enum Flag: Int, Codable, CaseIterable {
    case none = 0
    case pick = 1
    case reject = 2
}

/// Color labels. Raw values match Lightroom's default label names exactly,
/// so `xmp:Label` round-trips into Lightroom Classic / Bridge.
enum ColorLabel: String, Codable, CaseIterable, Identifiable {
    case red = "Red"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    var id: String { rawValue }
}

// MARK: - SwiftData models

/// One rating record per (card, base name). This is deliberately keyed by
/// card + base filename — not by full path — so ratings survive card
/// unplug/replug and app restarts.
@Model
final class AssetRecord {
    var cardKey: String = ""
    var baseNameLower: String = ""
    var rating: Int = 0
    var flagRaw: Int = 0
    var labelRaw: String?
    var updatedAt: Date = Date()

    init(cardKey: String, baseNameLower: String) {
        self.cardKey = cardKey
        self.baseNameLower = baseNameLower
    }

    var flag: Flag {
        get { Flag(rawValue: flagRaw) ?? .none }
        set { flagRaw = newValue.rawValue }
    }
    var label: ColorLabel? {
        get { labelRaw.flatMap(ColorLabel.init(rawValue:)) }
        set { labelRaw = newValue?.rawValue }
    }
}

/// A previously-opened card, so "Reopen last card" works across launches.
@Model
final class CardSession {
    var cardKey: String = ""
    var bookmarkData: Data = Data()
    var displayName: String = ""
    var lastOpened: Date = Date()
    /// Photos-library album this session refers to (nil for folder cards).
    /// Optional with a default so the SwiftData migration stays lightweight.
    var albumLocalID: String? = nil

    init(cardKey: String, bookmarkData: Data, displayName: String) {
        self.cardKey = cardKey
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.lastOpened = Date()
    }
}

// MARK: - In-memory item (one card = one RAW+JPEG pair)

enum FileKind {
    case rawPlusJpeg, rawOnly, jpegOnly, video

    var badge: String {
        switch self {
        case .rawPlusJpeg: return "RAW+J"
        case .rawOnly: return "RAW"
        case .jpegOnly: return "JPEG"
        case .video: return "VIDEO"
        }
    }
}

/// The in-memory representation of one shot (a RAW+JPEG pair, or a lone file).
/// File-system truth lives here; ratings are mirrored from AssetRecord/XMP.
struct CardItem: Identifiable, Hashable {
    let id: String              // cardKey|baseNameLower
    let baseName: String        // original-case base filename, e.g. DSC01234
    var rawURL: URL?
    var jpegURL: URL?
    var videoURL: URL?
    var rawSize: Int64 = 0
    var jpegSize: Int64 = 0
    var fileDate: Date          // creation date from the file system (capture-time proxy)

    var rating: Int = 0
    var flag: Flag = .none
    var label: ColorLabel?

    // Photos-library assets (browsed in place, nothing copied). When
    // assetLocalID is set, the URL-based fields above stay nil.
    var assetLocalID: String? = nil   // PHAsset.localIdentifier
    var camera: String? = nil         // TIFF "Model", also backfilled for files
    var assetKind: FileKind? = nil    // kind override for library assets
    var assetFormat: String? = nil    // badge override, e.g. "HEIC", "RAW+J"
    /// Whether a Photos-library asset has a RAW resource. nil = not checked
    /// yet — filled in lazily per item as it scrolls into view (see
    /// Library.checkRawFlagIfNeeded) or eagerly for a small curated set (see
    /// Library.backfillRawFlags); file-based items never use this, their
    /// RAW-ness is already known from rawURL at scan time.
    var assetIsRaw: Bool? = nil

    var kind: FileKind {
        if let assetKind { return assetKind }
        if rawURL != nil && jpegURL != nil { return .rawPlusJpeg }
        if rawURL != nil { return .rawOnly }
        if jpegURL != nil { return .jpegOnly }
        return .video
    }

    /// Badge text showing the actual formats, e.g. "RAW+J", "RAW+HEIC",
    /// "HEIC", "PNG", "MOV". Views should prefer this over kind.badge.
    var badge: String {
        if let assetFormat { return assetFormat }
        switch kind {
        case .rawPlusJpeg:
            let ext = jpegURL?.pathExtension.lowercased() ?? ""
            return FileTypes.jpeg.contains(ext) ? "RAW+J" : "RAW+\(ext.uppercased())"
        case .rawOnly:
            return "RAW"
        case .jpegOnly:
            let ext = jpegURL?.pathExtension.lowercased() ?? "jpeg"
            return FileTypes.jpeg.contains(ext) ? "JPEG" : ext.uppercased()
        case .video:
            let ext = videoURL?.pathExtension.uppercased() ?? "VIDEO"
            return ext
        }
    }

    /// Best URL to decode previews from: JPEG sibling first (fast, always
    /// decodable), otherwise the RAW (embedded preview), otherwise the video.
    var previewURL: URL? { jpegURL ?? rawURL ?? videoURL }

    /// Directory the shot lives in (for sidecar writes).
    var directoryURL: URL? { (rawURL ?? jpegURL ?? videoURL)?.deletingLastPathComponent() }

    var totalSize: Int64 { rawSize + jpegSize }
}

// MARK: - File-type sets

enum FileTypes {
    /// RAW formats. Sony (.arw/.sr2/.srf) and Nikon (.nef/.nrw) first-class,
    /// plus every other common mirrorless/DSLR/medium-format vendor.
    static let raw: Set<String> = [
        "arw", "sr2", "srf",                // Sony
        "nef", "nrw",                       // Nikon
        "cr3", "cr2", "crw",                // Canon
        "raf",                              // Fujifilm
        "rw2", "raw",                       // Panasonic/Leica
        "dng",                              // Adobe/Leica/phones
        "orf", "ori",                       // Olympus/OM System
        "pef", "srw", "x3f", "mrw", "rwl",  // Pentax, Samsung, Sigma, Minolta, Leica
        "3fr", "fff", "iiq", "mef", "mos",  // Hasselblad, Phase One, Mamiya, Leaf
        "dcr", "kdc", "erf", "gpr"          // Kodak, Epson, GoPro
    ]
    /// Preferred sibling subset (classic RAW+JPEG pairing).
    static let jpeg: Set<String> = ["jpg", "jpeg", "jfif"]
    /// All non-RAW stills ImageIO can decode.
    static let image: Set<String> = [
        "jpg", "jpeg", "jfif", "heic", "heif", "png",
        "tif", "tiff", "webp", "bmp", "gif", "avif", "jxl"
    ]
    /// When several non-RAW images share a base name, lower index wins as
    /// the pair sibling (JPEG stays the classic companion).
    static let imagePriority: [String] = [
        "jpg", "jpeg", "jfif", "heic", "heif", "png",
        "tif", "tiff", "webp", "avif", "jxl", "bmp", "gif"
    ]
    static let video: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mts", "m2ts",
        "mkv", "webm", "3gp", "3g2", "mpg", "mpeg", "wmv", "mxf"
    ]
}

// MARK: - Projects (app-internal collections, like Lightroom collections)

@Model
final class ProjectRecord {
    var name: String = ""
    var createdAt: Date = Date()
    /// Member item ids ("cardKey|baseNameLower") — spans cards; items only
    /// render while their card is open.
    var itemIDs: [String] = []

    init(name: String) {
        self.name = name
        self.createdAt = Date()
    }
}

// MARK: - Filtering & sorting

enum RatingFilterMode: Equatable, Hashable {
    case off
    case atLeast(Int)   // ★n+
    case exactly(Int)   // exactly ★n (0 = unrated only)

    func matches(_ rating: Int) -> Bool {
        switch self {
        case .off: return true
        case .atLeast(let n): return rating >= n
        case .exactly(let n): return rating == n
        }
    }
}

enum FlagFilter: String, CaseIterable, Identifiable {
    case any = "Any flag"
    case pick = "Picks"
    case reject = "Rejects"
    case unflagged = "Unflagged"
    var id: String { rawValue }
}

enum TypeFilter: String, CaseIterable, Identifiable {
    case any = "All types"
    case rawPlusJpeg = "RAW+Image"
    case rawOnly = "RAW only"
    case jpegOnly = "Image only"
    case video = "Video"
    var id: String { rawValue }
}

enum SortKey: String, CaseIterable, Identifiable {
    case captureTime = "Capture time"
    case filename = "Filename"
    case rating = "Rating"
    case fileType = "File type"
    case camera = "Camera"
    var id: String { rawValue }
}
