import XCTest
import SwiftData
@testable import Culler

/// Unit tests for `Library` rating/flag/label/undo/keepers/filter logic and
/// `ExportManager.uniqueDestination` collision naming.
///
/// All `Library` state is injected via the DEBUG `_setItemsForTesting` hook,
/// backed by an in-memory SwiftData container so nothing touches disk.
@MainActor
final class LibraryAndExportTests: XCTestCase {

    // MARK: - Helpers

    /// Fresh Library on an in-memory store. One per test — no shared state.
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

    /// Hand-built fixture item. URLs default to nil; `kind` derives from them.
    private func makeItem(
        _ baseName: String,
        rating: Int = 0,
        flag: Flag = .none,
        label: ColorLabel? = nil,
        rawURL: URL? = nil,
        jpegURL: URL? = nil,
        videoURL: URL? = nil,
        date: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> CardItem {
        CardItem(
            id: itemID(baseName),
            baseName: baseName,
            rawURL: rawURL,
            jpegURL: jpegURL,
            videoURL: videoURL,
            rawSize: 0,
            jpegSize: 0,
            fileDate: date,
            rating: rating,
            flag: flag,
            label: label
        )
    }

    private func fakeURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/nonexistent/\(name)")
    }

    /// Unique temp directory, removed on teardown.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CullerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func touch(_ name: String, in dir: URL) throws {
        try Data("x".utf8).write(to: dir.appendingPathComponent(name))
    }

    // MARK: - setRating

    func testSetRatingUpdatesItemAndClampsToZeroThroughFive() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([makeItem("A")])
        let id = itemID("A")

        library.setRating(3, for: id)
        XCTAssertEqual(library.item(id: id)?.rating, 3)

        library.setRating(9, for: id)
        XCTAssertEqual(library.item(id: id)?.rating, 5, "ratings above 5 must clamp to 5")

        library.setRating(-3, for: id)
        XCTAssertEqual(library.item(id: id)?.rating, 0, "negative ratings must clamp to 0")
    }

    func testSetRatingUnknownIDIsNoOp() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([makeItem("A")])

        library.setRating(4, for: "test-card|does-not-exist")
        XCTAssertEqual(library.item(id: itemID("A"))?.rating, 0)
        XCTAssertFalse(library.canUndo)
    }

    // MARK: - setFlag toggling

    func testSetFlagTogglesBackToNoneWhenSetTwice() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([makeItem("A")])
        let id = itemID("A")

        library.setFlag(.pick, for: id)
        XCTAssertEqual(library.item(id: id)?.flag, .pick)

        library.setFlag(.pick, for: id)
        XCTAssertEqual(library.item(id: id)?.flag, Flag.none, "setting the same flag again must toggle back to .none")

        // Different flag replaces rather than toggles.
        library.setFlag(.pick, for: id)
        library.setFlag(.reject, for: id)
        XCTAssertEqual(library.item(id: id)?.flag, .reject)
    }

    // MARK: - setLabel toggling

    func testSetLabelTogglesBackToNilWhenSetTwice() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([makeItem("A")])
        let id = itemID("A")

        library.setLabel(.red, for: id)
        XCTAssertEqual(library.item(id: id)?.label, .red)

        library.setLabel(.red, for: id)
        XCTAssertNil(library.item(id: id)?.label, "setting the same label again must toggle back to nil")

        // Different label replaces rather than toggles.
        library.setLabel(.red, for: id)
        library.setLabel(.blue, for: id)
        XCTAssertEqual(library.item(id: id)?.label, .blue)
    }

    // MARK: - incrementRating

    func testIncrementRatingCapsAtFive() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([makeItem("A", rating: 4)])
        let id = itemID("A")

        library.incrementRating(for: id)
        XCTAssertEqual(library.item(id: id)?.rating, 5)

        library.incrementRating(for: id)
        XCTAssertEqual(library.item(id: id)?.rating, 5, "incrementing at 5 stars must stay at 5")
    }

    // MARK: - undo

    func testUndoRestoresPreviousValuesInLIFOOrder() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([makeItem("A")])
        let id = itemID("A")

        XCTAssertFalse(library.canUndo, "canUndo must be false with an empty undo stack")

        library.setRating(3, for: id)
        library.setFlag(.pick, for: id)
        library.setLabel(.green, for: id)
        XCTAssertTrue(library.canUndo)

        // Most recent change (label) undone first.
        library.undo()
        var current = try XCTUnwrap(library.item(id: id))
        XCTAssertEqual(current.rating, 3)
        XCTAssertEqual(current.flag, .pick)
        XCTAssertNil(current.label)

        // Then the flag.
        library.undo()
        current = try XCTUnwrap(library.item(id: id))
        XCTAssertEqual(current.rating, 3)
        XCTAssertEqual(current.flag, Flag.none)
        XCTAssertNil(current.label)

        // Then the rating.
        library.undo()
        current = try XCTUnwrap(library.item(id: id))
        XCTAssertEqual(current.rating, 0)
        XCTAssertEqual(current.flag, Flag.none)
        XCTAssertNil(current.label)
        XCTAssertFalse(library.canUndo)

        // Undo on an empty stack is a harmless no-op.
        library.undo()
        XCTAssertEqual(library.item(id: id)?.rating, 0)
    }

    func testUndoAcrossMultipleItemsPopsLIFO() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([makeItem("A"), makeItem("B")])

        library.setRating(2, for: itemID("A"))
        library.setRating(4, for: itemID("B"))

        library.undo() // undoes B first
        XCTAssertEqual(library.item(id: itemID("A"))?.rating, 2)
        XCTAssertEqual(library.item(id: itemID("B"))?.rating, 0)

        library.undo() // then A
        XCTAssertEqual(library.item(id: itemID("A"))?.rating, 0)
        XCTAssertFalse(library.canUndo)
    }

    // MARK: - keepers

    func testKeepersExcludesRejectsEvenWithFiveStars() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("Reject5", rating: 5, flag: .reject),
            makeItem("Plain5", rating: 5),
        ])

        let keepers = library.keepers(minStars: 0, includePicks: true)
        XCTAssertEqual(Set(keepers.map(\.baseName)), ["Plain5"],
                       "rejects must never be keepers, regardless of rating")
    }

    func testKeepersIncludesPicksRegardlessOfRatingWhenEnabled() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("Pick0", rating: 0, flag: .pick),
            makeItem("Plain0", rating: 0),
            makeItem("Plain3", rating: 3),
        ])

        let withPicks = library.keepers(minStars: 3, includePicks: true)
        XCTAssertEqual(Set(withPicks.map(\.baseName)), ["Pick0", "Plain3"],
                       "a 0-star pick must survive a 3-star threshold when picks are included")

        let withoutPicks = library.keepers(minStars: 3, includePicks: false)
        XCTAssertEqual(Set(withoutPicks.map(\.baseName)), ["Plain3"],
                       "with picks disabled, only the star threshold counts")
    }

    func testKeepersMinStarsZeroWithPicksReturnsEverythingNotRejected() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("Pick", flag: .pick),
            makeItem("Plain0"),
            makeItem("Plain2", rating: 2),
            makeItem("Reject", rating: 5, flag: .reject),
        ])

        let keepers = library.keepers(minStars: 0, includePicks: true)
        XCTAssertEqual(Set(keepers.map(\.baseName)), ["Pick", "Plain0", "Plain2"])
    }

    // MARK: - filteredItems: filtering

    func testFilteredItemsRespectsMinRating() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("R0", rating: 0),
            makeItem("R1", rating: 1),
            makeItem("R2", rating: 2),
            makeItem("R3", rating: 3),
        ])

        library.ratingFilter = .atLeast(2)
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["R2", "R3"])

        library.ratingFilter = .off
        XCTAssertEqual(library.filteredItems.count, 4)
    }

    func testFilteredItemsRespectsFlagFilter() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("Pick", flag: .pick),
            makeItem("Reject", flag: .reject),
            makeItem("Plain"),
        ])

        library.flagFilter = .pick
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["Pick"])

        library.flagFilter = .reject
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["Reject"])

        library.flagFilter = .unflagged
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["Plain"])

        library.flagFilter = .any
        XCTAssertEqual(library.filteredItems.count, 3)
    }

    func testFilteredItemsRespectsTypeFilter() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("Both", rawURL: fakeURL("Both.ARW"), jpegURL: fakeURL("Both.JPG")),
            makeItem("RawOnly", rawURL: fakeURL("RawOnly.NEF")),
            makeItem("JpegOnly", jpegURL: fakeURL("JpegOnly.JPG")),
            makeItem("Video", videoURL: fakeURL("Video.MP4")),
        ])

        library.typeFilter = .rawPlusJpeg
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["Both"])

        library.typeFilter = .rawOnly
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["RawOnly"])

        library.typeFilter = .jpegOnly
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["JpegOnly"])

        library.typeFilter = .video
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["Video"])

        library.typeFilter = .any
        XCTAssertEqual(library.filteredItems.count, 4)
    }

    func testFilteredItemsRespectsLabelFilterIncludingNilMeansUnlabeled() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("Red", label: .red),
            makeItem("Blue", label: .blue),
            makeItem("Unlabeled"),
        ])

        // Empty label filter set: label filtering is off entirely.
        library.labelFilter = []
        XCTAssertEqual(library.filteredItems.count, 3)

        // Specific label.
        library.labelFilter = [ColorLabel.red.rawValue]
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["Red"])

        // The unlabeled token means "unlabeled only".
        library.labelFilter = [Library.unlabeledFilterToken]
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["Unlabeled"])
    }

    // MARK: - filteredItems: sorting

    func testFilteredItemsSortsByCaptureTime() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        let t2 = Date(timeIntervalSince1970: 300)
        library._setItemsForTesting([
            makeItem("Middle", date: t1),
            makeItem("Newest", date: t2),
            makeItem("Oldest", date: t0),
        ])

        library.sortKey = .captureTime
        library.sortAscending = true
        XCTAssertEqual(library.filteredItems.map(\.baseName), ["Oldest", "Middle", "Newest"])

        library.sortAscending = false
        XCTAssertEqual(library.filteredItems.map(\.baseName), ["Newest", "Middle", "Oldest"])
    }

    func testFilteredItemsSortsByFilenameNaturally() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("DSC10"),
            makeItem("DSC2"),
            makeItem("DSC1"),
        ])

        library.sortKey = .filename
        library.sortAscending = true
        XCTAssertEqual(library.filteredItems.map(\.baseName), ["DSC1", "DSC2", "DSC10"],
                       "filename sort must be natural (DSC2 before DSC10)")

        library.sortAscending = false
        XCTAssertEqual(library.filteredItems.map(\.baseName), ["DSC10", "DSC2", "DSC1"])
    }

    func testFilteredItemsSortsByRating() throws {
        suppressSidecarWrites()
        let library = try makeLibrary()
        library._setItemsForTesting([
            makeItem("OneStar", rating: 1),
            makeItem("ThreeStars", rating: 3),
            makeItem("TwoStars", rating: 2),
        ])

        library.sortKey = .rating
        library.sortAscending = true
        XCTAssertEqual(library.filteredItems.map(\.baseName), ["OneStar", "TwoStars", "ThreeStars"])

        library.sortAscending = false
        XCTAssertEqual(library.filteredItems.map(\.baseName), ["ThreeStars", "TwoStars", "OneStar"])
    }

    // MARK: - ExportManager.uniqueDestination

    func testUniqueDestinationWithoutCollisionKeepsName() throws {
        let dir = try makeTempDir()

        let result = ExportManager.uniqueDestination(for: "DSC01234.ARW", in: dir)
        XCTAssertEqual(result.url.lastPathComponent, "DSC01234.ARW")
        XCTAssertFalse(result.renamed)
    }

    func testUniqueDestinationSingleCollisionAppendsOne() throws {
        let dir = try makeTempDir()
        try touch("DSC01234.ARW", in: dir)

        let result = ExportManager.uniqueDestination(for: "DSC01234.ARW", in: dir)
        XCTAssertEqual(result.url.lastPathComponent, "DSC01234 (1).ARW")
        XCTAssertTrue(result.renamed)
    }

    func testUniqueDestinationDoubleCollisionAppendsTwo() throws {
        let dir = try makeTempDir()
        try touch("DSC01234.ARW", in: dir)
        try touch("DSC01234 (1).ARW", in: dir)

        let result = ExportManager.uniqueDestination(for: "DSC01234.ARW", in: dir)
        XCTAssertEqual(result.url.lastPathComponent, "DSC01234 (2).ARW")
        XCTAssertTrue(result.renamed)
    }

    func testUniqueDestinationHandlesExtensionlessFiles() throws {
        let dir = try makeTempDir()

        // No collision: name passes through untouched.
        let fresh = ExportManager.uniqueDestination(for: "notes", in: dir)
        XCTAssertEqual(fresh.url.lastPathComponent, "notes")
        XCTAssertFalse(fresh.renamed)

        // Collision on an extensionless file: no trailing dot in the rename.
        try touch("README", in: dir)
        let renamed = ExportManager.uniqueDestination(for: "README", in: dir)
        XCTAssertEqual(renamed.url.lastPathComponent, "README (1)")
        XCTAssertTrue(renamed.renamed)
    }
}
