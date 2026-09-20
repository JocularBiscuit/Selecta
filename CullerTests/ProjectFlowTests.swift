import XCTest
import SwiftData
@testable import Culler

/// Tests for the project-first flow added in this round: the automatic
/// Picks/Rejects project folders, and `openProject`'s ability to resolve a
/// project's members from MULTIPLE origins at once (Photos-library assets
/// and folder/card files re-scanned live from their bookmark) — with each
/// item's rating correctly attributed to its own true origin, and members
/// whose source can't be reached degrading gracefully instead of failing
/// the whole open.
@MainActor
final class ProjectFlowTests: XCTestCase {

    // MARK: - Helpers (mirrors LibraryAndExportTests)

    private func makeLibrary() throws -> (Library, ModelContext) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AssetRecord.self, CardSession.self, ProjectRecord.self,
            configurations: config
        )
        let context = ModelContext(container)
        return (Library(context: context), context)
    }

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

    private func makeItem(_ baseName: String, rating: Int = 0, flag: Flag = .none) -> CardItem {
        CardItem(
            id: itemID(baseName),
            baseName: baseName,
            rawURL: nil,
            jpegURL: nil,
            videoURL: nil,
            rawSize: 0,
            jpegSize: 0,
            fileDate: Date(timeIntervalSince1970: 1_000_000),
            rating: rating,
            flag: flag,
            label: nil
        )
    }

    /// A real temp folder with a couple of plain image files, for exercising
    /// the actual `scanFolder` + bookmark-resolution path `openProject` uses.
    private func makeTempFolder(files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CullerProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - ProjectFolder (Picks / Rejects smart folders)

    func testProjectFolderFiltersByFlag() throws {
        suppressSidecarWrites()
        let (library, _) = try makeLibrary()
        library._setItemsForTesting([
            makeItem("Pick", flag: .pick),
            makeItem("Reject", flag: .reject),
            makeItem("Plain"),
        ])

        library.projectFolder = .all
        XCTAssertEqual(library.filteredItems.count, 3)

        library.projectFolder = .picks
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["Pick"])

        library.projectFolder = .rejects
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["Reject"])
    }

    func testProjectFolderCombinesWithOtherFilters() throws {
        suppressSidecarWrites()
        let (library, _) = try makeLibrary()
        library._setItemsForTesting([
            makeItem("HighPick", rating: 5, flag: .pick),
            makeItem("LowPick", rating: 1, flag: .pick),
        ])
        library.projectFolder = .picks
        library.ratingFilter = .atLeast(3)
        XCTAssertEqual(Set(library.filteredItems.map(\.baseName)), ["HighPick"])
    }

    // MARK: - openProject: multi-source resolution

    /// A project whose members live entirely on a folder card: openProject
    /// must re-resolve the folder's bookmark, re-scan it, and reattach each
    /// item's own previously-persisted rating (not the Library's ambient
    /// cardKey — each item encodes its own true origin).
    func testOpenProjectResolvesFolderMembersAndReattachesRatings() async throws {
        suppressSidecarWrites()
        let (library, context) = try makeLibrary()
        let folder = try makeTempFolder(files: ["IMG_0001.JPG", "IMG_0002.JPG"])
        let cardKey = "folder-\(UUID().uuidString)"

        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let session = CardSession(cardKey: cardKey, bookmarkData: bookmark, displayName: "Test Card")
        context.insert(session)

        // A rating already on record for img_0001 under its TRUE origin key —
        // openProject must find this via the item's own id, not the
        // project-view's ambient cardKey.
        let record = AssetRecord(cardKey: cardKey, baseNameLower: "img_0001")
        record.rating = 4
        context.insert(record)
        try context.save()

        let project = ProjectRecord(name: "Mixed")
        project.itemIDs = ["\(cardKey)|img_0001", "\(cardKey)|img_0002"]
        context.insert(project)
        try context.save()

        await library._openProjectForTesting(project)

        XCTAssertNil(library.loadError)
        XCTAssertEqual(library.sourceKind, .project)
        XCTAssertEqual(library.browseMode, .cull)
        XCTAssertTrue(library.openedProject === project)
        XCTAssertEqual(library.items.count, 2)
        XCTAssertEqual(library.item(id: "\(cardKey)|img_0001")?.rating, 4)
        XCTAssertEqual(library.item(id: "\(cardKey)|img_0002")?.rating, 0)
    }

    /// A project mixing a resolvable folder member with a member whose
    /// origin session no longer exists (e.g. a card that was never
    /// re-opened, or one this device has no record of) must still open
    /// successfully with the reachable member, and surface the unreachable
    /// count via `infoNote` rather than failing outright. (Deliberately
    /// avoids a real "photoslib|…" id here: that path calls the real
    /// PHPhotoLibrary permission API, which can hang on a system prompt in a
    /// headless test runner — the missing-session path below exercises the
    /// same graceful-degradation logic synchronously, with no system call.)
    func testOpenProjectDegradesGracefullyWhenSomeMembersAreUnreachable() async throws {
        suppressSidecarWrites()
        let (library, context) = try makeLibrary()
        let folder = try makeTempFolder(files: ["A.JPG"])
        let cardKey = "folder-\(UUID().uuidString)"
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        context.insert(CardSession(cardKey: cardKey, bookmarkData: bookmark, displayName: "Card"))
        try context.save()

        let project = ProjectRecord(name: "Mixed Sources")
        project.itemIDs = ["\(cardKey)|a", "unknown-card-key|missing"]
        context.insert(project)
        try context.save()

        await library._openProjectForTesting(project)

        XCTAssertNil(library.loadError, "one reachable member is enough for a successful open")
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.items.first?.baseName.lowercased(), "a")
        XCTAssertNotNil(library.infoNote, "the unreachable member should be surfaced, not silently dropped")
    }

    /// Every member unreachable (bookmark gone) → the open fails with a
    /// clear `loadError` instead of silently showing an empty project.
    func testOpenProjectFailsWhenNoMembersCanBeResolved() async throws {
        suppressSidecarWrites()
        let (library, context) = try makeLibrary()
        let project = ProjectRecord(name: "Orphaned")
        project.itemIDs = ["missing-card-key|somefile"]
        context.insert(project)
        try context.save()

        await library._openProjectForTesting(project)

        XCTAssertNotNil(library.loadError)
        XCTAssertNil(library.openedProject)
    }

    func testOpenProjectOnEmptyProjectSetsLoadError() async throws {
        suppressSidecarWrites()
        let (library, context) = try makeLibrary()
        let project = ProjectRecord(name: "Empty")
        context.insert(project)
        try context.save()

        await library._openProjectForTesting(project)

        XCTAssertNotNil(library.loadError)
        XCTAssertTrue(library.items.isEmpty)
    }

    // MARK: - closeCard resets project-scoped state

    func testCloseCardResetsProjectState() throws {
        suppressSidecarWrites()
        let (library, _) = try makeLibrary()
        library._setItemsForTesting([makeItem("A")])
        library.projectFolder = .picks

        library.closeCard()

        XCTAssertFalse(library.hasCard)
        XCTAssertEqual(library.projectFolder, .all)
        XCTAssertNil(library.openedProject)
        XCTAssertNil(library.targetProject)
    }
}
