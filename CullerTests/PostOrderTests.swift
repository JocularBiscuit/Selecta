import XCTest
import SwiftData
@testable import Culler

/// Posting order: photos in a project get numbers (1 = post first). Taking a
/// number that's already used moves the older photo — and everything directly
/// after it — later; gaps stop the shifting; batch numbering follows tap order.
@MainActor
final class PostOrderTests: XCTestCase {

    private func makeLibrary(photos names: [String]) throws -> (Library, ProjectRecord) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AssetRecord.self, CardSession.self, ProjectRecord.self,
            configurations: config
        )
        let library = Library(context: ModelContext(container))
        library._setItemsForTesting(names.map(item))
        let project = library.createProject(named: "Post")
        library.add(ids: Set(names.map(id)), to: project)
        library._setOpenedProjectForTesting(project)
        return (library, project)
    }

    private func id(_ name: String) -> String { "test-card|\(name.lowercased())" }

    private func item(_ name: String) -> CardItem {
        CardItem(
            id: id(name), baseName: name, rawURL: nil, jpegURL: nil, videoURL: nil,
            rawSize: 0, jpegSize: 0, fileDate: Date(timeIntervalSince1970: 1_000_000),
            rating: 0, flag: .none, label: nil
        )
    }

    private func number(_ library: Library, _ name: String) -> Int? {
        library.item(id: id(name))?.postOrder
    }

    // MARK: Basics

    func testNumberingOnePhotoSetsItAndStoresItOnTheProject() throws {
        let (library, project) = try makeLibrary(photos: ["A", "B"])
        library.placePostOrder(ids: [id("A")], startingAt: 3)
        XCTAssertEqual(number(library, "A"), 3)
        XCTAssertNil(number(library, "B"))
        XCTAssertEqual(project.postOrder[id("A")], 3)
    }

    func testNumbersClampToAtLeastOne() throws {
        let (library, _) = try makeLibrary(photos: ["A"])
        library.placePostOrder(ids: [id("A")], startingAt: -4)
        XCTAssertEqual(number(library, "A"), 1)
    }

    // MARK: Collisions — older moves later, and everything directly after it

    func testCollisionPushesTheOlderPhotoLaterAndTheRunAfterIt() throws {
        let (library, _) = try makeLibrary(photos: ["A", "B", "C", "D", "NEW"])
        for (name, n) in [("A", 1), ("B", 2), ("C", 3), ("D", 4)] {
            library.placePostOrder(ids: [id(name)], startingAt: n)
        }
        library.placePostOrder(ids: [id("NEW")], startingAt: 2)

        XCTAssertEqual(number(library, "A"), 1)
        XCTAssertEqual(number(library, "NEW"), 2)
        XCTAssertEqual(number(library, "B"), 3)   // older holder of 2 moved later
        XCTAssertEqual(number(library, "C"), 4)   // and so did the ones after it
        XCTAssertEqual(number(library, "D"), 5)
    }

    func testAGapStopsTheShifting() throws {
        let (library, _) = try makeLibrary(photos: ["A", "B", "C", "NEW"])
        library.placePostOrder(ids: [id("A")], startingAt: 2)
        library.placePostOrder(ids: [id("B")], startingAt: 3)
        library.placePostOrder(ids: [id("C")], startingAt: 6)   // gap at 4–5
        library.placePostOrder(ids: [id("NEW")], startingAt: 2)

        XCTAssertEqual(number(library, "NEW"), 2)
        XCTAssertEqual(number(library, "A"), 3)
        XCTAssertEqual(number(library, "B"), 4)
        XCTAssertEqual(number(library, "C"), 6)   // beyond the gap: untouched
    }

    func testNoCollisionMeansNothingElseMoves() throws {
        let (library, _) = try makeLibrary(photos: ["A", "B"])
        library.placePostOrder(ids: [id("A")], startingAt: 5)
        library.placePostOrder(ids: [id("B")], startingAt: 2)
        XCTAssertEqual(number(library, "A"), 5)
        XCTAssertEqual(number(library, "B"), 2)
    }

    func testRenumberingAPhotoMovesItAndFreesItsOldNumber() throws {
        let (library, _) = try makeLibrary(photos: ["A", "B", "C"])
        for (name, n) in [("A", 1), ("B", 2), ("C", 3)] {
            library.placePostOrder(ids: [id(name)], startingAt: n)
        }
        // A: 1 -> 3. C (older holder of 3) moves to 4; B stays at 2.
        library.placePostOrder(ids: [id("A")], startingAt: 3)
        XCTAssertEqual(number(library, "A"), 3)
        XCTAssertEqual(number(library, "B"), 2)
        XCTAssertEqual(number(library, "C"), 4)
    }

    func testNumbersStayUnique() throws {
        let (library, project) = try makeLibrary(photos: ["A", "B", "C", "D", "E"])
        for (name, n) in [("A", 1), ("B", 2), ("C", 3), ("D", 1), ("E", 2), ("A", 2), ("C", 1)] {
            library.placePostOrder(ids: [id(name)], startingAt: n)
        }
        let values = Array(project.postOrder.values)
        XCTAssertEqual(Set(values).count, values.count, "two photos share a number: \(project.postOrder)")
    }

    // MARK: Batch

    func testBatchNumbersConsecutivelyInTheGivenOrder() throws {
        let (library, _) = try makeLibrary(photos: ["A", "B", "C"])
        library.placePostOrder(ids: [id("C"), id("A"), id("B")], startingAt: 4)
        XCTAssertEqual(number(library, "C"), 4)
        XCTAssertEqual(number(library, "A"), 5)
        XCTAssertEqual(number(library, "B"), 6)
    }

    func testBatchPushesCollidingPhotosPastTheWholeBlock() throws {
        let (library, _) = try makeLibrary(photos: ["X", "Y", "P", "Q", "R"])
        library.placePostOrder(ids: [id("X")], startingAt: 3)
        library.placePostOrder(ids: [id("Y")], startingAt: 4)
        library.placePostOrder(ids: [id("P"), id("Q"), id("R")], startingAt: 3)

        XCTAssertEqual(number(library, "P"), 3)
        XCTAssertEqual(number(library, "Q"), 4)
        XCTAssertEqual(number(library, "R"), 5)
        XCTAssertEqual(number(library, "X"), 6)
        XCTAssertEqual(number(library, "Y"), 7)
    }

    // MARK: Clear / close gaps

    func testClearRemovesOnlyTheGivenNumbers() throws {
        let (library, project) = try makeLibrary(photos: ["A", "B"])
        library.placePostOrder(ids: [id("A")], startingAt: 1)
        library.placePostOrder(ids: [id("B")], startingAt: 2)
        library.clearPostOrder(ids: [id("A")])
        XCTAssertNil(number(library, "A"))
        XCTAssertEqual(number(library, "B"), 2)
        XCTAssertNil(project.postOrder[id("A")])
    }

    func testCloseGapsRenumbersFromOneKeepingOrder() throws {
        let (library, _) = try makeLibrary(photos: ["A", "B", "C"])
        library.placePostOrder(ids: [id("A")], startingAt: 2)
        library.placePostOrder(ids: [id("B")], startingAt: 7)
        library.placePostOrder(ids: [id("C")], startingAt: 20)
        library.closePostOrderGaps()
        XCTAssertEqual(number(library, "A"), 1)
        XCTAssertEqual(number(library, "B"), 2)
        XCTAssertEqual(number(library, "C"), 3)
    }

    func testNextFreeContinuesAfterTheHighestNumber() throws {
        let (library, _) = try makeLibrary(photos: ["A", "B"])
        XCTAssertEqual(library.nextFreePostOrder, 1)
        library.placePostOrder(ids: [id("A")], startingAt: 4)
        XCTAssertEqual(library.nextFreePostOrder, 5)
    }

    // MARK: Persistence & sorting

    func testNumbersAreAppliedWhenTheProjectOpens() throws {
        let (library, project) = try makeLibrary(photos: ["A", "B"])
        project.postOrder = [id("B"): 1, id("A"): 2]
        library._setOpenedProjectForTesting(project)
        XCTAssertEqual(number(library, "B"), 1)
        XCTAssertEqual(number(library, "A"), 2)
    }

    func testSortByPostingOrderPutsUnnumberedLastInBothDirections() throws {
        let (library, _) = try makeLibrary(photos: ["A", "B", "C"])
        library.placePostOrder(ids: [id("C")], startingAt: 1)
        library.placePostOrder(ids: [id("A")], startingAt: 2)

        library.sortKey = .postingOrder
        XCTAssertTrue(library.sortAscending, "posting order starts ascending")
        XCTAssertEqual(library.filteredItems.map(\.baseName), ["C", "A", "B"])

        library.sortAscending = false
        XCTAssertEqual(library.filteredItems.map(\.baseName), ["A", "C", "B"])
    }

    // MARK: Selection order

    func testSelectionOrderFollowsTapOrder() throws {
        let (library, _) = try makeLibrary(photos: ["A", "B", "C"])
        library.selection.insert(id("C"))
        library.selection.insert(id("A"))
        library.selection.insert(id("B"))
        XCTAssertEqual(library.orderedSelection, [id("C"), id("A"), id("B")])

        library.selection.remove(id("A"))
        XCTAssertEqual(library.orderedSelection, [id("C"), id("B")])

        library.selection.insert(id("A"))
        XCTAssertEqual(library.orderedSelection, [id("C"), id("B"), id("A")])
    }

    func testSelectingManyAtOnceUsesGridOrder() throws {
        let (library, _) = try makeLibrary(photos: ["A", "B", "C"])
        library.sortKey = .filename
        library.sortAscending = true
        library.selection = Set([id("C"), id("A"), id("B")])
        XCTAssertEqual(library.orderedSelection, [id("A"), id("B"), id("C")])
    }
}
