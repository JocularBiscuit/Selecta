import XCTest
@testable import Culler

/// Tests for `Library.scanFolder(root:cardKey:)` — the recursive enumeration,
/// case-insensitive RAW+JPEG pairing, and XMP sidecar pickup logic.
///
/// `scanFolder` is a nonisolated static synchronous function, so it is called
/// directly against a temp fixture tree that mimics an SD card layout.
final class PairingTests: XCTestCase {

    private var root: URL!
    private let cardKey = "TESTCARD"
    private var items: [CardItem] = []
    /// Scanned items keyed by lowercased base name for convenient lookup.
    private var byBase: [String: CardItem] = [:]

    // MARK: - Fixture

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairingTests-\(UUID().uuidString)", isDirectory: true)

        // Sony-style folder
        // (1) RAW+JPEG pair, same dir
        try touch("DCIM/100MSDCF/DSC00001.ARW")
        try touch("DCIM/100MSDCF/DSC00001.JPG")
        // (7) valid sidecar for DSC00001: rating 3, label Red
        try write(XMP.packet(rating: 3, label: .red), to: "DCIM/100MSDCF/DSC00001.xmp")

        // (2) case-insensitive pairing across differing filename case
        try touch("DCIM/100MSDCF/DSC00002.arw")
        try touch("DCIM/100MSDCF/dsc00002.JPG")

        // (3) RAW-only, JPEG-only, video
        try touch("DCIM/100MSDCF/DSC00003.ARW")
        try touch("DCIM/100MSDCF/DSC00004.JPG")
        try touch("DCIM/100MSDCF/C0001.MP4")

        // (8) sidecar carrying the inner original extension: DSC00003.ARW.xmp
        try write(XMP.packet(rating: 5, label: .green), to: "DCIM/100MSDCF/DSC00003.ARW.xmp")

        // (6) hidden files and unknown extensions must be ignored
        try touch("DCIM/100MSDCF/.hidden.ARW")
        try touch("DCIM/100MSDCF/NOTES.txt")
        try touch("DCIM/100MSDCF/CANON.CTG")

        // (4)+(5) Nikon-style names in a second subdirectory (recursion)
        try touch("DCIM/101MSDCF/DSC_0001.NEF")
        try touch("DCIM/101MSDCF/DSC_0001.JPG")
        try touch("DCIM/101MSDCF/_DSC0005.NEF")

        items = Library.scanFolder(root: root, cardKey: cardKey)
        byBase = Dictionary(
            uniqueKeysWithValues: items.map { ($0.baseName.lowercased(), $0) }
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        items = []
        byBase = [:]
    }

    /// Creates a fake file (content is irrelevant; scanning only inspects
    /// names and extensions) at `relativePath` under the fixture root.
    private func touch(_ relativePath: String) throws {
        try write("x", to: relativePath)
    }

    private func write(_ content: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }

    // MARK: - (1) RAW+JPEG in the same directory pairs into one item

    func testRawPlusJpegPairsIntoSingleItem() throws {
        let matches = items.filter { $0.baseName.lowercased() == "dsc00001" }
        XCTAssertEqual(matches.count, 1, "DSC00001.ARW + DSC00001.JPG must produce exactly one CardItem")

        let item = try XCTUnwrap(matches.first)
        XCTAssertEqual(item.kind, .rawPlusJpeg)
        XCTAssertNotNil(item.rawURL)
        XCTAssertNotNil(item.jpegURL)
        XCTAssertNil(item.videoURL)
        XCTAssertEqual(item.rawURL?.lastPathComponent, "DSC00001.ARW")
        XCTAssertEqual(item.jpegURL?.lastPathComponent, "DSC00001.JPG")
        XCTAssertEqual(item.id, "TESTCARD|dsc00001", "id must be cardKey|baseNameLower")
    }

    // MARK: - (2) Pairing is case-insensitive on base name and extension

    func testCaseInsensitivePairing() throws {
        let matches = items.filter { $0.baseName.lowercased() == "dsc00002" }
        XCTAssertEqual(matches.count, 1, "DSC00002.arw + dsc00002.JPG must pair into one item despite case differences")

        let item = try XCTUnwrap(matches.first)
        XCTAssertEqual(item.kind, .rawPlusJpeg)
        XCTAssertNotNil(item.rawURL)
        XCTAssertNotNil(item.jpegURL)
        XCTAssertEqual(item.id, "TESTCARD|dsc00002")
    }

    // MARK: - (3) Lone files get the right kind

    func testRawOnlyKind() throws {
        let item = try XCTUnwrap(byBase["dsc00003"], "DSC00003.ARW should be scanned")
        XCTAssertEqual(item.kind, .rawOnly)
        XCTAssertNotNil(item.rawURL)
        XCTAssertNil(item.jpegURL)
        XCTAssertNil(item.videoURL)
    }

    func testJpegOnlyKind() throws {
        let item = try XCTUnwrap(byBase["dsc00004"], "DSC00004.JPG should be scanned")
        XCTAssertEqual(item.kind, .jpegOnly)
        XCTAssertNil(item.rawURL)
        XCTAssertNotNil(item.jpegURL)
        XCTAssertNil(item.videoURL)
    }

    func testVideoKind() throws {
        let item = try XCTUnwrap(byBase["c0001"], "C0001.MP4 should be scanned")
        XCTAssertEqual(item.kind, .video)
        XCTAssertNil(item.rawURL)
        XCTAssertNil(item.jpegURL)
        XCTAssertNotNil(item.videoURL)
        XCTAssertEqual(item.videoURL?.lastPathComponent, "C0001.MP4")
    }

    // MARK: - (4) Nikon-style base names

    func testNikonUnderscoreNamesPair() throws {
        let matches = items.filter { $0.baseName.lowercased() == "dsc_0001" }
        XCTAssertEqual(matches.count, 1, "DSC_0001.NEF + DSC_0001.JPG must pair into one item")

        let item = try XCTUnwrap(matches.first)
        XCTAssertEqual(item.kind, .rawPlusJpeg)
        XCTAssertEqual(item.id, "TESTCARD|dsc_0001")
    }

    func testNikonLeadingUnderscoreName() throws {
        let item = try XCTUnwrap(byBase["_dsc0005"], "_DSC0005.NEF should be scanned")
        XCTAssertEqual(item.kind, .rawOnly)
        XCTAssertEqual(item.id, "TESTCARD|_dsc0005")
        XCTAssertEqual(item.baseName, "_DSC0005", "baseName should keep original casing")
    }

    // MARK: - (5) Recursion into subdirectories

    func testRecursesIntoAllSubdirectories() {
        // Items live in DCIM/100MSDCF and DCIM/101MSDCF, never at the root —
        // finding all of them proves recursive enumeration.
        let bases = Set(items.map { $0.baseName.lowercased() })
        XCTAssertTrue(bases.contains("dsc00001"), "should find items in DCIM/100MSDCF")
        XCTAssertTrue(bases.contains("dsc_0001"), "should find items in DCIM/101MSDCF")
        XCTAssertTrue(bases.contains("_dsc0005"), "should find items in DCIM/101MSDCF")
        XCTAssertEqual(items.count, 7, "expected exactly 7 items: 00001, 00002, 00003, 00004, C0001, DSC_0001, _DSC0005")
    }

    // MARK: - (6) Hidden files and unknown extensions are ignored

    func testHiddenAndUnknownFilesIgnored() {
        let bases = Set(items.map { $0.baseName.lowercased() })
        XCTAssertFalse(bases.contains(".hidden"), "hidden files must be skipped")
        XCTAssertFalse(bases.contains("notes"), ".txt files must be ignored")
        XCTAssertFalse(bases.contains("canon"), ".CTG files must be ignored")
        for item in items {
            for url in [item.rawURL, item.jpegURL, item.videoURL].compactMap({ $0 }) {
                XCTAssertFalse(url.lastPathComponent.hasPrefix("."),
                               "no scanned URL should point at a hidden file: \(url.lastPathComponent)")
            }
        }
    }

    // MARK: - (7) Sidecar pickup: base-name sidecar seeds rating and label

    func testSidecarRatingAndLabelPickedUp() throws {
        let item = try XCTUnwrap(byBase["dsc00001"])
        XCTAssertEqual(item.rating, 3, "rating from DSC00001.xmp should be applied")
        XCTAssertEqual(item.label, .red, "label from DSC00001.xmp should be applied")
    }

    // MARK: - (8) Sidecar with inner extension (DSC00003.ARW.xmp) maps correctly

    func testSidecarWithInnerExtensionMapsToBaseName() throws {
        let item = try XCTUnwrap(byBase["dsc00003"])
        XCTAssertEqual(item.rating, 5, "DSC00003.ARW.xmp must map to base dsc00003")
        XCTAssertEqual(item.label, .green)
        // And the sidecar itself must not have become an item.
        XCTAssertFalse(items.contains { $0.baseName.lowercased() == "dsc00003.arw" },
                       "the .xmp file itself must not appear as a scanned item")
    }

    // MARK: - (9) previewURL prefers the JPEG over the RAW

    func testPreviewURLPrefersJpeg() throws {
        let pair = try XCTUnwrap(byBase["dsc00001"])
        XCTAssertEqual(pair.previewURL, pair.jpegURL, "RAW+JPEG pair should preview from the JPEG")
        XCTAssertNotEqual(pair.previewURL, pair.rawURL)

        let rawOnly = try XCTUnwrap(byBase["dsc00003"])
        XCTAssertEqual(rawOnly.previewURL, rawOnly.rawURL, "RAW-only item falls back to the RAW")

        let video = try XCTUnwrap(byBase["c0001"])
        XCTAssertEqual(video.previewURL, video.videoURL, "video item falls back to the video URL")
    }
}
