import XCTest
import SwiftData
@testable import Culler

/// Focused tests for the new filter model (RatingFilterMode, multi-label
/// filter, activeProject) and the expanded format/pairing rules
/// (HEIC siblings, new RAW formats, MKV video, CardItem.badge).
@MainActor
final class FilterAndFormatTests: XCTestCase {

    // MARK: - Helpers

    /// Fresh Library on an in-memory store (includes ProjectRecord).
    private func makeLibrary() throws -> Library {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AssetRecord.self, CardSession.self, ProjectRecord.self,
            configurations: config
        )
        return Library(context: ModelContext(container))
    }

    /// Turn off the debounced XMP sidecar write so mutations never spawn
    /// background file writes during tests. Restored on teardown.
    private func suppressSidecarWrites() {
        let defaults = UserDefaults.standard
        let key = SettingsKeys.writeSidecarsToCard
        let previous = defaults.object(forKey: key) as? Bool
        defaults.set(false, forKey: key)
        addTeardownBlock {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func itemID(_ baseName: String) -> String {
        "test-card|\(baseName.lowercased())"
    }

    private func makeItem(
        _ baseName: String,
        rating: Int = 0,
        flag: Flag = .none,
        label: ColorLabel? = nil,
        date: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> CardItem {
        CardItem(
            id: itemID(baseName),
            baseName: baseName,
            rawURL: nil,
            jpegURL: nil,
            videoURL: nil,
            rawSize: 0,
            jpegSize: 0,
            fileDate: date,
            rating: rating,
            flag: flag,
            label: label
        )
    }

    /// Unique temp fixture directory, removed on teardown.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterAndFormatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func touch(_ name: String, in dir: URL) throws {
        try Data("x".utf8).write(to: dir.appendingPathComponent(name))
    }

    private func scan(_ dir: URL) -> [String: CardItem] {
        let items = Library.scanFolder(root: dir, cardKey: "TESTCARD")
        return Dictionary(
            uniqueKeysWithValues: items.map { ($0.baseName.lowercased(), $0) }
        )
    }

    // MARK: - (a) RatingFilterMode.exactly(0): unrated only

    func testExactlyZeroShowsOnlyUnratedItems() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("Unrated0", rating: 0),
            makeItem("Unrated1", rating: 0),
            makeItem("OneStar", rating: 1),
            makeItem("FiveStars", rating: 5),
        ])

        library.ratingFilter = .exactly(0)
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)),
                       ["Unrated0", "Unrated1"],
                       ".exactly(0) must show only unrated items")
    }

    // MARK: - (b) RatingFilterMode.exactly(3): only ★3

    func testExactlyThreeMatchesOnlyThreeStars() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("R0", rating: 0),
            makeItem("R2", rating: 2),
            makeItem("R3", rating: 3),
            makeItem("R4", rating: 4),
        ])

        library.ratingFilter = .exactly(3)
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["R3"],
                       ".exactly(3) must match only exactly-3-star items, not 4+")
    }

    // MARK: - (c) Multi-label filter: {Red, unlabeled} = red OR unlabeled

    func testMultiLabelFilterRedPlusUnlabeled() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("Red", label: .red),
            makeItem("Blue", label: .blue),
            makeItem("Green", label: .green),
            makeItem("Unlabeled"),
        ])

        library.labelFilter = [ColorLabel.red.rawValue, Library.unlabeledFilterToken]
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)),
                       ["Red", "Unlabeled"],
                       "multi-label filter must union red-labeled and unlabeled items")
    }

    // MARK: - (d) Pairing priority: JPG beats HEIC; HEIC pairs when no JPG

    func testJpegWinsOverHeicAsPairSibling() throws {
        let dir = try makeTempDir()
        try touch("DSC00010.ARW", in: dir)
        try touch("DSC00010.JPG", in: dir)
        try touch("DSC00010.HEIC", in: dir)

        let byBase = scan(dir)
        let item = try XCTUnwrap(byBase["dsc00010"], "ARW+JPG+HEIC must scan as one item")
        XCTAssertEqual(item.kind, .rawPlusJpeg)
        XCTAssertEqual(item.jpegURL?.lastPathComponent, "DSC00010.JPG",
                       "with JPG and HEIC siblings, the classic JPG must win as jpegURL")
        XCTAssertEqual(item.badge, "RAW+J")
    }

    func testHeicPairsWithRawWhenNoJpegPresent() throws {
        let dir = try makeTempDir()
        try touch("DSC00011.ARW", in: dir)
        try touch("DSC00011.HEIC", in: dir)

        let byBase = scan(dir)
        let item = try XCTUnwrap(byBase["dsc00011"], "ARW+HEIC must scan as one item")
        XCTAssertEqual(item.kind, .rawPlusJpeg, "HEIC sibling must still count as a RAW+image pair")
        XCTAssertEqual(item.jpegURL?.lastPathComponent, "DSC00011.HEIC")
        XCTAssertEqual(item.badge, "RAW+HEIC")
    }

    // MARK: - (e) New formats recognized

    func testPefAndSrwScanAsRawOnly() throws {
        let dir = try makeTempDir()
        try touch("IMGP0001.PEF", in: dir)
        try touch("SAM_0001.SRW", in: dir)

        let byBase = scan(dir)
        let pentax = try XCTUnwrap(byBase["imgp0001"], ".PEF must be scanned")
        XCTAssertEqual(pentax.kind, .rawOnly)
        XCTAssertEqual(pentax.badge, "RAW")

        let samsung = try XCTUnwrap(byBase["sam_0001"], ".SRW must be scanned")
        XCTAssertEqual(samsung.kind, .rawOnly)
        XCTAssertEqual(samsung.badge, "RAW")
    }

    func testLoneHeicScansAsJpegOnlyWithHeicBadge() throws {
        let dir = try makeTempDir()
        try touch("IMG_0001.HEIC", in: dir)

        let byBase = scan(dir)
        let item = try XCTUnwrap(byBase["img_0001"], ".HEIC must be scanned")
        XCTAssertEqual(item.kind, .jpegOnly)
        XCTAssertEqual(item.badge, "HEIC")
    }

    func testMkvScansAsVideo() throws {
        let dir = try makeTempDir()
        try touch("CLIP0001.MKV", in: dir)

        let byBase = scan(dir)
        let item = try XCTUnwrap(byBase["clip0001"], ".MKV must be scanned")
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.badge, "MKV")
    }

    // MARK: - (f) activeProject filter

    func testActiveProjectShowsOnlyProjectMembers() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("InProject1"),
            makeItem("InProject2"),
            makeItem("Outsider"),
        ])

        let project = library.createProject(named: "Keepers")
        library.add(ids: [itemID("InProject1"), itemID("InProject2")], to: project)

        library.activeProject = project
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)),
                       ["InProject1", "InProject2"],
                       "active project must show its members and hide everything else")

        library.activeProject = nil
        XCTAssertEqual(library.filteredItems.count, 3,
                       "clearing the active project must show all items again")
    }
}
