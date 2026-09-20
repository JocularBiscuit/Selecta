import Foundation
import SwiftUI
import SwiftData
import Observation

/// Central view model: owns the open card, the item list, ratings, undo,
/// and filter/sort state.
@MainActor
@Observable
final class Library {

    // MARK: State

    /// Where the open "card" comes from: a folder on disk (SD card, Files),
    /// a Photos-library album browsed in place, or a project (which can mix
    /// members gathered from either — re-resolved live, nothing copied).
    enum SourceKind: Equatable { case folder, photoAlbum, project }

    /// What the open grid is *for*: culling (rate/flag/loupe — projects) or
    /// selecting (a Photos-gallery album or a folder/card; pick photos → add
    /// to a project → rate there). No rating happens in `.select` mode.
    enum BrowseMode: Equatable { case cull, select }
    private(set) var browseMode: BrowseMode = .cull
    var isSelectingFromGallery: Bool { browseMode == .select }

    /// Sub-view within an open project: everything, or the automatic
    /// Picks/Rejects smart folders (derived from each item's flag — no
    /// separate assignment step).
    enum ProjectFolder: Equatable { case all, picks, rejects }
    var projectFolder: ProjectFolder = .all { didSet { pruneSelectionToFiltered() } }

    /// Filters shown only while picking photos from a source (`.select`
    /// mode) — narrowing a big album down before adding to a project.
    enum GalleryMediaFilter: Equatable { case all, photosOnly, videosOnly }
    enum GalleryRawFilter: Equatable { case all, rawOnly, normalOnly }
    var galleryMediaFilter: GalleryMediaFilter = .all { didSet { pruneSelectionToFiltered() } }
    var galleryRawFilter: GalleryRawFilter = .all { didSet { pruneSelectionToFiltered() } }

    private(set) var items: [CardItem] = []
    private(set) var cardName: String?
    private(set) var cardRootURL: URL?
    private(set) var cardKey: String = ""
    private(set) var sourceKind: SourceKind?
    /// Photos-library album backing the open card (nil for folder cards).
    private(set) var albumLocalID: String?
    /// The project currently open for culling (nil outside a project). Set by
    /// `openProject`, distinct from `activeProject` (a filter that can scope
    /// any already-open card down to one project's members).
    private(set) var openedProject: ProjectRecord?
    /// The project being gathered INTO by the current "add photos" flow
    /// (browsing a source in `.select` mode to add to a specific project).
    var targetProject: ProjectRecord?
    /// Bumped every time a card open/scan finishes delivering items (folder
    /// scan or album load). Lets views react to "the scan for the current
    /// card completed" instead of guessing from item counts.
    private(set) var scanGeneration = 0
    var isLoading = false
    var cardUnavailable = false
    var loadError: String?
    /// Non-error, informational note about the just-opened source (e.g. "N of
    /// this project's photos live on a card/folder and aren't shown here").
    /// Surfaced as a transient banner — never as the "Couldn't open" alert,
    /// which is reserved for genuine open failures (`loadError`).
    var infoNote: String?

    // Filter & sort. Changing any filter prunes the selection so batch
    // actions can never silently hit shots the user can no longer see.
    var ratingFilter: RatingFilterMode = .off { didSet { pruneSelectionToFiltered() } }
    var flagFilter: FlagFilter = .any { didSet { pruneSelectionToFiltered() } }
    /// Multi-select label filter: ColorLabel raw values, plus "none" for
    /// unlabeled. Empty set = label filter off.
    var labelFilter: Set<String> = [] { didSet { pruneSelectionToFiltered() } }
    var typeFilter: TypeFilter = .any { didSet { pruneSelectionToFiltered() } }
    var activeProject: ProjectRecord? { didSet { pruneSelectionToFiltered() } }
    var sortKey: SortKey = .captureTime
    var sortAscending = false   // newest first by default

    static let unlabeledFilterToken = "none"

    // Selection (grid multi-select)
    var selectionMode = false
    var selection: Set<String> = []

    private var indexByID: [String: Int] = [:]
    private var undoStack: [UndoEntry] = []
    private var sidecarTasks: [String: Task<Void, Never>] = [:]
    /// Guards openProject's async multi-source load: if the user opens a
    /// different source before it finishes, its result is discarded instead
    /// of stomping whatever loaded after it.
    private var openRequestToken = UUID()
    private let context: ModelContext

    @ObservationIgnored @AppStorage(SettingsKeys.writeSidecarsToCard) private var writeSidecarsToCard = true
    @ObservationIgnored @AppStorage(SettingsKeys.sidecarIncludesExtension) private var sidecarIncludesExtension = false

    struct UndoEntry {
        let itemID: String
        let rating: Int
        let flag: Flag
        let label: ColorLabel?
    }

    init(context: ModelContext) {
        self.context = context
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var hasCard: Bool { sourceKind != nil }

    func item(id: String) -> CardItem? {
        guard let idx = indexByID[id] else { return nil }
        return items[idx]
    }

    // MARK: Filtered & sorted view

    /// Bumped whenever `items` is reassigned OR any single item's fields
    /// change in place (rating/flag/label edits, undo, the camera/RAW
    /// background backfills). Used INSTEAD of comparing the whole `items`
    /// array by value in the cache check below.
    ///
    /// That used to rely on Array's copy-on-write "same buffer" fast path
    /// staying intact — but a single in-place edit like `items[idx].x = y`
    /// forces Swift to COPY THE WHOLE ARRAY before mutating one element
    /// (since the cached fingerprint still held a reference to the old
    /// buffer), which breaks the fast path for every comparison afterward:
    /// every subsequent `filteredItems` read fell back to a full O(n)
    /// element-by-element comparison, found it changed, and did a full
    /// O(n log n) recompute — on EVERY single item mutation. For a
    /// background backfill touching thousands of items in small batches,
    /// that compounded into exactly the severe scroll lag reported ("super
    /// super laggy" picking from a real Photos library). A revision counter
    /// makes the cache check a single Int comparison regardless of library
    /// size, no matter how items were mutated.
    @ObservationIgnored private var itemsRevision = 0

    /// Everything the filtered/sorted view depends on. Compared on each
    /// access so one change recomputes at most once, no matter how many
    /// times a render pass reads `filteredItems`.
    private struct FilterFingerprint: Equatable {
        var itemsRevision: Int
        var ratingFilter: RatingFilterMode
        var flagFilter: FlagFilter
        var labelFilter: Set<String>
        var typeFilter: TypeFilter
        var projectItemIDs: [String]?
        var projectFolder: ProjectFolder
        var galleryMediaFilter: GalleryMediaFilter
        var galleryRawFilter: GalleryRawFilter
        var sortKey: SortKey
        var sortAscending: Bool
    }

    @ObservationIgnored private var filterCacheKey: FilterFingerprint?
    @ObservationIgnored private var filterCacheResult: [CardItem] = []

    /// Memoized: re-filters and re-sorts only when items or any filter/sort
    /// input actually changed; repeated reads within a render are free.
    var filteredItems: [CardItem] {
        let fingerprint = FilterFingerprint(
            itemsRevision: itemsRevision,
            ratingFilter: ratingFilter,
            flagFilter: flagFilter,
            labelFilter: labelFilter,
            typeFilter: typeFilter,
            projectItemIDs: activeProject?.itemIDs,
            projectFolder: projectFolder,
            galleryMediaFilter: galleryMediaFilter,
            galleryRawFilter: galleryRawFilter,
            sortKey: sortKey,
            sortAscending: sortAscending
        )
        if fingerprint == filterCacheKey { return filterCacheResult }
        let result = computeFilteredItems()
        filterCacheKey = fingerprint
        filterCacheResult = result
        return result
    }

    private func computeFilteredItems() -> [CardItem] {
        let projectIDs: Set<String>? = activeProject.map { Set($0.itemIDs) }
        var result = items.filter { item in
            if !ratingFilter.matches(item.rating) { return false }
            switch flagFilter {
            case .any: break
            case .pick: if item.flag != .pick { return false }
            case .reject: if item.flag != .reject { return false }
            case .unflagged: if item.flag != .none { return false }
            }
            if !labelFilter.isEmpty {
                let token = item.label?.rawValue ?? Self.unlabeledFilterToken
                if !labelFilter.contains(token) { return false }
            }
            switch typeFilter {
            case .any: break
            case .rawPlusJpeg: if item.kind != .rawPlusJpeg { return false }
            case .rawOnly: if item.kind != .rawOnly { return false }
            case .jpegOnly: if item.kind != .jpegOnly { return false }
            case .video: if item.kind != .video { return false }
            }
            if let projectIDs, !projectIDs.contains(item.id) { return false }
            switch projectFolder {
            case .all: break
            case .picks: if item.flag != .pick { return false }
            case .rejects: if item.flag != .reject { return false }
            }
            if browseMode == .select {
                switch galleryMediaFilter {
                case .all: break
                case .photosOnly: if item.kind == .video { return false }
                case .videosOnly: if item.kind != .video { return false }
                }
                switch galleryRawFilter {
                case .all: break
                // Not-yet-determined items (assetIsRaw == nil, still being
                // backfilled) are excluded from BOTH specific filters rather
                // than guessed at — they'll appear as soon as the check
                // completes, instead of briefly showing in the wrong bucket.
                case .rawOnly: if item.assetIsRaw != true { return false }
                case .normalOnly: if item.assetIsRaw != false { return false }
                }
            }
            return true
        }
        result.sort { a, b in
            let ordered: Bool
            switch sortKey {
            case .captureTime: ordered = a.fileDate == b.fileDate ? a.baseName < b.baseName : a.fileDate < b.fileDate
            case .filename: ordered = a.baseName.localizedStandardCompare(b.baseName) == .orderedAscending
            case .rating: ordered = a.rating == b.rating ? a.baseName < b.baseName : a.rating < b.rating
            case .fileType:
                let oa = Self.typeOrder(a.kind), ob = Self.typeOrder(b.kind)
                ordered = oa == ob ? a.baseName < b.baseName : oa < ob
            case .camera:
                switch (a.camera, b.camera) {
                case (nil, _?): return false   // unknown camera sorts last, both directions
                case (_?, nil): return true
                case (nil, nil):
                    ordered = a.baseName < b.baseName
                case let (ca?, cb?):
                    ordered = ca == cb
                        ? a.baseName < b.baseName
                        : ca.localizedStandardCompare(cb) == .orderedAscending
                }
            }
            return sortAscending ? ordered : !ordered
        }
        return result
    }

    /// Fixed ordering for the "File type" sort: RAW+JPEG < RAW < JPEG < video.
    private static func typeOrder(_ kind: FileKind) -> Int {
        switch kind {
        case .rawPlusJpeg: return 0
        case .rawOnly: return 1
        case .jpegOnly: return 2
        case .video: return 3
        }
    }

    var hasActiveFilter: Bool {
        ratingFilter != .off || flagFilter != .any || !labelFilter.isEmpty
            || typeFilter != .any || activeProject != nil
    }

    func clearFilters() {
        ratingFilter = .off
        flagFilter = .any
        labelFilter = []
        typeFilter = .any
        activeProject = nil
        galleryMediaFilter = .all
        galleryRawFilter = .all
    }

    /// Drop selected ids that the current filters hide, so BatchBar counts
    /// and batch actions always refer to visible shots only.
    private func pruneSelectionToFiltered() {
        guard !selection.isEmpty else { return }
        selection.formIntersection(filteredItems.map(\.id))
    }

    // MARK: Projects (app-internal collections)

    func projects() -> [ProjectRecord] {
        let descriptor = FetchDescriptor<ProjectRecord>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func createProject(named name: String) -> ProjectRecord {
        let project = ProjectRecord(name: name)
        context.insert(project)
        try? context.save()
        return project
    }

    func add(ids: Set<String>, to project: ProjectRecord) {
        let merged = Set(project.itemIDs).union(ids)
        project.itemIDs = Array(merged)
        try? context.save()
    }

    func remove(ids: Set<String>, from project: ProjectRecord) {
        project.itemIDs.removeAll { ids.contains($0) }
        try? context.save()
    }

    func deleteProject(_ project: ProjectRecord) {
        if activeProject === project { activeProject = nil }
        if targetProject === project { targetProject = nil }
        if openedProject === project { closeCard() }
        context.delete(project)
        try? context.save()
    }

    func memberCount(of project: ProjectRecord) -> Int { project.itemIDs.count }

    func pickCount(of project: ProjectRecord) -> Int {
        project.itemIDs.reduce(0) { count, id in
            count + (fetchRecordFlag(for: id) == .pick ? 1 : 0)
        }
    }

    /// Reads one item's persisted flag directly (for project-card counts,
    /// without needing that item's source open).
    private func fetchRecordFlag(for itemID: String) -> Flag? {
        let parts = itemID.components(separatedBy: "|")
        guard parts.count > 1 else { return nil }
        let key = parts[0], baseLower = parts[1]
        let predicate = #Predicate<AssetRecord> { $0.cardKey == key && $0.baseNameLower == baseLower }
        var descriptor = FetchDescriptor<AssetRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.flag
    }

    /// The project whose culling grid was open when the current "add photos"
    /// flow began, if any. Lets cancelling out of picking (see
    /// `cancelPicking()`) return to that grid instead of always dropping all
    /// the way out to the projects list — set only when `beginAddingPhotos`
    /// is called from inside an already-open project (via its own "Add
    /// Photos…" menu item), nil when it's called from the projects list
    /// itself (nothing to return to there).
    private(set) var returnToProject: ProjectRecord?

    /// Start an "add photos" flow: whichever source is opened next (a Photos
    /// album or a folder/card) will be for SELECTING photos to add to this
    /// project — the bottom bar reads `targetProject` to skip straight to it.
    func beginAddingPhotos(to project: ProjectRecord) {
        targetProject = project
        returnToProject = openedProject
    }

    /// Add the current multi-selection to a project (the bridge from gallery/
    /// folder selection → project, where the user then rates).
    func addSelectionToProject(_ project: ProjectRecord) {
        add(ids: selection, to: project)
        if targetProject === project { targetProject = nil }
        returnToProject = nil
    }

    /// Cancel out of picking photos before anything's been selected: back to
    /// the project's own culling grid if that's where this flow started
    /// (tapped "Add Photos…" from inside an open project), otherwise out to
    /// the projects list — never "a screen to pick a different album", which
    /// is what dropping straight to closeCard() always did before.
    func cancelPicking() {
        if let project = returnToProject {
            returnToProject = nil
            openProject(project)
        } else {
            closeCard()
        }
    }

    /// Reset to the no-card state (shows the projects home screen).
    func closeCard() {
        clearItems()
        cardName = nil
        cardRootURL = nil
        sourceKind = nil
        browseMode = .cull
        albumLocalID = nil
        openedProject = nil
        targetProject = nil
        returnToProject = nil
        projectFolder = .all
        selection.removeAll()
        selectionMode = false
        cardKey = ""
        loadError = nil
        infoNote = nil
        cardUnavailable = false
        isLoading = false
        // A filter/project set for the old source must not leak into the next
        // one (FilterSortBar is hidden in .select, so it can't be cleared there).
        clearFilters()
    }

    /// Items matching the export "keepers" rule: never rejects; picks (if
    /// enabled) or anything at/above the star threshold. minStars == 0 means
    /// "everything that isn't rejected".
    func keepers(minStars: Int, includePicks: Bool) -> [CardItem] {
        items.filter { item in
            if item.flag == .reject { return false }
            if includePicks && item.flag == .pick { return true }
            return item.rating >= minStars
        }
    }

    // MARK: Opening a card

    /// Called with the URL from the folder picker. Persists a security-scoped
    /// bookmark and scans the folder.
    func openCard(pickedURL: URL) {
        let accessing = pickedURL.startAccessingSecurityScopedResource()
        do {
            let bookmark = try pickedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let session = findOrCreateSession(for: pickedURL, bookmark: bookmark)
            session.lastOpened = Date()
            session.bookmarkData = bookmark
            try? context.save()
            startSession(url: pickedURL, key: session.cardKey, name: session.displayName)
        } catch {
            if accessing { pickedURL.stopAccessingSecurityScopedResource() }
            loadError = "Couldn't bookmark that folder: \(error.localizedDescription)"
        }
    }

    /// Open a Photos-library album for SELECTION (not culling). Tapping picks
    /// photos; the user then adds the selection to a project and rates there.
    func openPhotoAlbum(albumID: String, title: String, items newItems: [CardItem]) {
        cardKey = "photoslib"
        sourceKind = .photoAlbum
        browseMode = .select
        albumLocalID = albumID
        cardRootURL = nil
        cardName = title
        cardUnavailable = false
        loadError = nil
        infoNote = nil
        openedProject = nil   // browsing to select, not inside a project
        projectFolder = .all
        undoStack.removeAll()
        selection.removeAll()
        selectionMode = false
        // Filters belong to culling; a leaked filter/project from a previous
        // card would silently hide gallery items (no FilterSortBar in .select).
        clearFilters()

        items = mergeRecords(into: newItems, cardKey: cardKey)
        rebuildIndex()
        scanGeneration += 1
        // No eager RAW scan here: for a huge album (e.g. "Recents", often
        // thousands of assets) that whole-album PHAssetResource sweep is
        // itself the real cost, not just a caching issue — see
        // checkRawFlagIfNeeded, which paces the same check to visible cells.

        // Save/refresh the session so "Reopen last card" works, matched by album.
        let all = (try? context.fetch(FetchDescriptor<CardSession>())) ?? []
        let session: CardSession
        if let existing = all.first(where: { $0.albumLocalID == albumID }) {
            session = existing
        } else {
            session = CardSession(cardKey: cardKey, bookmarkData: Data(), displayName: title)
            session.albumLocalID = albumID
            context.insert(session)
        }
        session.displayName = title
        session.lastOpened = Date()
        try? context.save()
    }

    /// Open a project as its own view: loads every member LIVE from wherever
    /// it actually lives — Photos-library assets in place, and folder/card
    /// members by re-resolving that source's bookmark and re-scanning it.
    /// Nothing is ever copied. A member whose source can't be reached right
    /// now (a card unplugged, a photo deleted) is skipped and counted for a
    /// non-blocking info banner rather than failing the whole open.
    func openProject(_ project: ProjectRecord) {
        let allIDs = project.itemIDs
        infoNote = nil
        guard !allIDs.isEmpty else {
            loadError = "This project is empty. Add photos from your Photos library or a card/folder."
            return
        }

        let token = UUID()
        openRequestToken = token
        isLoading = true

        Task {
            // Group members by their originating source: each item's id is
            // "<originCardKey>|<baseNameLower>", the same key ratings for it
            // are stored under, whatever the Library's OWN current cardKey
            // happens to be while this loads.
            var byOrigin: [String: [String]] = [:]
            for id in allIDs {
                let key = id.components(separatedBy: "|").first ?? ""
                byOrigin[key, default: []].append(id)
            }

            var resolved: [CardItem] = []
            var unresolvedCount = 0

            if let photoIDs = byOrigin.removeValue(forKey: "photoslib") {
                if await PhotoLibrarySource.shared.requestAccess() {
                    let assetIDs = photoIDs.map { String($0.dropFirst("photoslib|".count)) }
                    let loaded = await PhotoLibrarySource.shared.loadAssets(lowercasedLocalIDs: assetIDs)
                    resolved += loaded
                    unresolvedCount += photoIDs.count - loaded.count
                } else {
                    unresolvedCount += photoIDs.count
                }
            }

            if !byOrigin.isEmpty {
                let sessions = (try? context.fetch(FetchDescriptor<CardSession>())) ?? []
                let sessionByKey = Dictionary(sessions.map { ($0.cardKey, $0) }, uniquingKeysWith: { a, _ in a })
                for (originKey, ids) in byOrigin {
                    let wantedBaseNames = Set(ids.compactMap { id -> String? in
                        let parts = id.components(separatedBy: "|")
                        return parts.count > 1 ? parts[1] : nil
                    })
                    guard let session = sessionByKey[originKey] else {
                        unresolvedCount += ids.count
                        continue
                    }
                    var stale = false
                    guard let url = try? URL(resolvingBookmarkData: session.bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                          url.startAccessingSecurityScopedResource() else {
                        unresolvedCount += ids.count
                        continue
                    }
                    let scanned = await Task.detached(priority: .userInitiated) {
                        Self.scanFolder(root: url, cardKey: originKey)
                    }.value
                    let matched = scanned.filter { wantedBaseNames.contains($0.baseName.lowercased()) }
                    resolved += matched
                    unresolvedCount += ids.count - matched.count
                }
            }

            guard openRequestToken == token else { return }   // a newer open superseded this one
            isLoading = false

            guard !resolved.isEmpty else {
                loadError = unresolvedCount > 0
                    ? "None of this project's photos could be reached right now. Their source (Photos library or a card) may be unavailable."
                    : "This project is empty. Add photos from your Photos library or a card/folder."
                return
            }

            cardKey = "project:\(project.persistentModelID.hashValue)"
            sourceKind = .project
            browseMode = .cull   // a project is where you rate
            openedProject = project
            projectFolder = .all
            albumLocalID = nil
            cardRootURL = nil
            cardName = project.name
            cardUnavailable = false
            loadError = nil
            // A successful open must not raise the "Couldn't open" alert; an
            // unresolved-member count is informational, so it goes through
            // infoNote instead.
            infoNote = unresolvedCount > 0
                ? "\(unresolvedCount) photo\(unresolvedCount == 1 ? "" : "s") in this project couldn't be reached right now."
                : nil
            undoStack.removeAll()
            selection.removeAll()
            selectionMode = false
            targetProject = nil
            // Reset any leaked filter before scoping to the project (which the
            // view IS — so no activeProject and no stray star/flag filter).
            clearFilters()   // also sets activeProject = nil
            items = mergeRecordsMixedOrigin(into: resolved)
            rebuildIndex()
            scanGeneration += 1
            backfillRawFlags()
        }
    }

    /// Reopen the most recently used card from its persisted bookmark
    /// (folder cards) or by reloading its album (Photos-library cards).
    func reopenLastCard() {
        guard let session = lastSession() else { return }
        if let albumID = session.albumLocalID {
            isLoading = true
            Task {
                // Without authorization the PhotoKit fetches silently come
                // back empty — ask first so the user gets a real prompt or
                // a real "access is off" message instead of a bogus one.
                guard await PhotoLibrarySource.shared.requestAccess() else {
                    isLoading = false
                    loadError = "Photos access is off. Allow access in Settings, then reopen the album."
                    return
                }
                let result = await PhotoLibrarySource.shared.loadItems(albumID: albumID)
                isLoading = false
                guard !result.items.isEmpty else {
                    loadError = "The last album couldn't be loaded. Pick it again from your Photos library."
                    return
                }
                openPhotoAlbum(albumID: albumID, title: result.title, items: result.items)
            }
            return
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: session.bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            loadError = "The last card couldn't be found. Plug it in and pick its folder again."
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            loadError = "Access to the last card expired. Pick its folder again."
            return
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            session.bookmarkData = fresh
        }
        session.lastOpened = Date()
        try? context.save()
        startSession(url: url, key: session.cardKey, name: session.displayName)
    }

    func lastSession() -> CardSession? {
        var descriptor = FetchDescriptor<CardSession>(sortBy: [SortDescriptor(\.lastOpened, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func findOrCreateSession(for url: URL, bookmark: Data) -> CardSession {
        let all = (try? context.fetch(FetchDescriptor<CardSession>())) ?? []
        // Match an existing session by resolving its bookmark to the same path,
        // so the same physical card keeps the same cardKey (and its ratings).
        for session in all {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: session.bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               resolved.standardizedFileURL.path == url.standardizedFileURL.path {
                return session
            }
        }
        let session = CardSession(cardKey: UUID().uuidString, bookmarkData: bookmark, displayName: url.lastPathComponent)
        context.insert(session)
        return session
    }

    private func startSession(url: URL, key: String, name: String) {
        cardRootURL = url
        cardKey = key
        cardName = name
        sourceKind = .folder
        // Folders/cards are opened to pick photos to gather into a project —
        // the same select-then-add flow as a Photos-library album.
        browseMode = .select
        albumLocalID = nil
        cardUnavailable = false
        loadError = nil
        infoNote = nil
        openedProject = nil
        projectFolder = .all
        undoStack.removeAll()
        selection.removeAll()
        selectionMode = false
        // A filter/project from the previous source must not carry into this
        // one and silently hide shots.
        clearFilters()
        // Clear the previous card's items immediately: nothing from the old
        // card may stay tappable under the new cardKey while the scan runs
        // (that window used to let ratings land on the wrong card's records).
        clearItems()
        isLoading = true
        Task { await scan() }
    }

    /// Re-check that the card is still reachable (call on foreground).
    /// Photos-library albums and projects don't go "unavailable" the way an
    /// unplugged folder card does — a project's unreachable members are
    /// already surfaced individually via `infoNote` when it opens.
    func checkCardStillPresent() {
        if sourceKind == .photoAlbum || sourceKind == .project {
            cardUnavailable = false
            return
        }
        guard let root = cardRootURL else { return }
        cardUnavailable = !FileManager.default.fileExists(atPath: root.path)
    }

    func rescan() {
        if sourceKind == .project {
            guard let project = openedProject, !isLoading else { return }
            openProject(project)
            return
        }
        if sourceKind == .photoAlbum {
            // Album cards have no folder to re-enumerate: reload the album
            // from PhotoKit instead of silently doing nothing.
            guard let albumID = albumLocalID, !isLoading else { return }
            isLoading = true
            Task {
                let result = await PhotoLibrarySource.shared.loadItems(albumID: albumID)
                isLoading = false
                guard sourceKind == .photoAlbum, albumLocalID == albumID else { return }
                guard !result.items.isEmpty else {
                    loadError = "The album couldn't be reloaded from your Photos library."
                    return
                }
                cardName = result.title
                items = mergeRecords(into: result.items, cardKey: cardKey)
                rebuildIndex()
                scanGeneration += 1
            }
            return
        }
        Task { await scan() }
    }

    // MARK: Scanning & pairing

    private func scan() async {
        guard sourceKind == .folder, let root = cardRootURL else { return }
        isLoading = true
        defer { isLoading = false }

        let key = cardKey
        let scanned = await Task.detached(priority: .userInitiated) {
            Self.scanFolder(root: root, cardKey: key)
        }.value

        guard cardKey == key else { return } // user opened a different card meanwhile

        if scanned.isEmpty {
            clearItems()
            cardUnavailable = !FileManager.default.fileExists(atPath: root.path)
            scanGeneration += 1
            return
        }

        items = mergeRecords(into: scanned, cardKey: key)
        rebuildIndex()
        scanGeneration += 1
        backfillCameras()
    }

    /// Merge persisted ratings into freshly loaded items (DB wins over
    /// sidecar; sidecar values seed new records). Shared by folder scans
    /// and Photos-album loads — everything here shares one origin cardKey.
    private func mergeRecords(into loaded: [CardItem], cardKey key: String) -> [CardItem] {
        var merged = loaded
        let records = fetchRecords(cardKey: key)
        for i in merged.indices {
            let baseLower = merged[i].baseName.lowercased()
            if let record = records[baseLower] {
                merged[i].rating = record.rating
                merged[i].flag = record.flag
                merged[i].label = record.label
            } else if merged[i].rating > 0 || merged[i].label != nil {
                // Came from an XMP sidecar on the card — seed a DB record.
                let record = AssetRecord(cardKey: key, baseNameLower: baseLower)
                record.rating = merged[i].rating
                record.label = merged[i].label
                context.insert(record)
            }
        }
        try? context.save()
        return merged
    }

    /// Same as `mergeRecords`, but for a project's items, which can span
    /// several different origins at once. Each item's own id encodes its
    /// true origin cardKey — the same key `upsertRecord` writes ratings
    /// under — so records are looked up per-origin group rather than under
    /// one shared key (which would silently disconnect ratings).
    private func mergeRecordsMixedOrigin(into loaded: [CardItem]) -> [CardItem] {
        var merged = loaded
        let groups = Dictionary(grouping: merged.indices) { idx in
            merged[idx].id.components(separatedBy: "|").first ?? ""
        }
        for (originKey, indices) in groups {
            let records = fetchRecords(cardKey: originKey)
            for i in indices {
                let baseLower = merged[i].baseName.lowercased()
                if let record = records[baseLower] {
                    merged[i].rating = record.rating
                    merged[i].flag = record.flag
                    merged[i].label = record.label
                } else if merged[i].rating > 0 || merged[i].label != nil {
                    let record = AssetRecord(cardKey: originKey, baseNameLower: baseLower)
                    record.rating = merged[i].rating
                    record.label = merged[i].label
                    context.insert(record)
                }
            }
        }
        try? context.save()
        return merged
    }

    /// Fill in `camera` for file-based items by reading EXIF in the
    /// background (Photos assets carry their camera from PhotoKit). Aborts
    /// quietly if the user opens a different card meanwhile.
    func backfillCameras() {
        let key = cardKey
        let targets: [(id: String, url: URL)] = items.compactMap { item in
            guard item.assetLocalID == nil, item.camera == nil, let url = item.previewURL else { return nil }
            return (item.id, url)
        }
        guard !targets.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            var index = 0
            while index < targets.count {
                // Batches of ~4 concurrent metadata reads.
                let chunk = Array(targets[index..<min(index + 4, targets.count)])
                index += chunk.count
                let found = await withTaskGroup(of: (String, String)?.self) { group -> [(String, String)] in
                    for target in chunk {
                        group.addTask {
                            guard let model = await ThumbnailStore.metadata(for: target.url).cameraModel else { return nil }
                            return (target.id, model)
                        }
                    }
                    var out: [(String, String)] = []
                    for await pair in group {
                        if let pair { out.append(pair) }
                    }
                    return out
                }
                let aborted = await MainActor.run { () -> Bool in
                    guard let self, self.cardKey == key else { return true }
                    self.applyCameras(found)
                    return false
                }
                if aborted { return }
            }
        }
    }

    private func applyCameras(_ pairs: [(String, String)]) {
        guard !pairs.isEmpty else { return }
        for (id, camera) in pairs {
            if let idx = indexByID[id] { items[idx].camera = camera }
        }
        itemsRevision += 1   // one cache invalidation per batch, not per item
    }

    /// Fill in `assetIsRaw` for Photos-library items by checking each
    /// asset's resources in the background (a per-asset PHAssetResource
    /// lookup — too slow to do inline for a whole album, so it happens
    /// progressively after the grid is already showing). Powers the RAW
    /// filter and the RAW badge in gallery `.select` mode. Aborts quietly if
    /// the user opens a different card/album meanwhile.
    func backfillRawFlags() {
        let key = cardKey
        let targets: [(id: String, assetID: String)] = items.compactMap { item in
            guard let assetID = item.assetLocalID, item.assetIsRaw == nil else { return nil }
            return (item.id, assetID)
        }
        guard !targets.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            // 8-way concurrent PHAssetResource lookups, but the `items`
            // mutation (and the cache-invalidating revision bump it
            // triggers) is applied only every ~32 results, not every 8 —
            // for a large album this is the difference between a handful of
            // cheap cache invalidations and hundreds of them.
            var pending: [(String, Bool)] = []
            var index = 0
            while index < targets.count {
                let chunk = Array(targets[index..<min(index + 8, targets.count)])
                index += chunk.count
                let found = await withTaskGroup(of: (String, Bool).self) { group -> [(String, Bool)] in
                    for target in chunk {
                        group.addTask {
                            let isRaw = await PhotoLibrarySource.shared.assetHasRaw(target.assetID)
                            return (target.id, isRaw)
                        }
                    }
                    var out: [(String, Bool)] = []
                    for await pair in group { out.append(pair) }
                    return out
                }
                pending += found
                guard pending.count >= 32 || index >= targets.count else { continue }
                let toApply = pending
                pending = []
                let aborted = await MainActor.run { () -> Bool in
                    guard let self, self.cardKey == key else { return true }
                    self.applyRawFlags(toApply)
                    return false
                }
                if aborted { return }
            }
        }
    }

    private func applyRawFlags(_ pairs: [(String, Bool)]) {
        guard !pairs.isEmpty else { return }
        for (id, isRaw) in pairs {
            guard let idx = indexByID[id] else { continue }
            items[idx].assetIsRaw = isRaw
            if isRaw { items[idx].assetFormat = "RAW" }
        }
        itemsRevision += 1   // one cache invalidation per batch, not per item
    }

    /// In-flight guard for `checkRawFlagIfNeeded`, so a cell that appears
    /// more than once (LazyVGrid recycling during a fast scroll) doesn't
    /// fire a duplicate PHAssetResource lookup for the same asset.
    @ObservationIgnored private var rawCheckInFlight: Set<String> = []

    /// Progressive, on-demand RAW check for a single item — fired as its
    /// thumbnail scrolls into view (see ThumbCell), instead of scanning a
    /// whole album up front. A big album like "Recents" can hold thousands
    /// of assets; checking every one of them the moment the album opens is
    /// real, unavoidable per-asset work that stalls scrolling no matter how
    /// cheaply it's cached. Pacing the same check to only the handful of
    /// cells actually on screen keeps it invisible, the same way thumbnail
    /// decoding already is.
    func checkRawFlagIfNeeded(itemID: String) {
        guard let idx = indexByID[itemID],
              items[idx].assetIsRaw == nil,
              let assetID = items[idx].assetLocalID,
              !rawCheckInFlight.contains(itemID) else { return }
        rawCheckInFlight.insert(itemID)
        let key = cardKey
        Task.detached(priority: .utility) { [weak self] in
            let isRaw = await PhotoLibrarySource.shared.assetHasRaw(assetID)
            await MainActor.run {
                guard let self else { return }
                self.rawCheckInFlight.remove(itemID)
                guard self.cardKey == key else { return }
                self.applyRawFlags([(itemID, isRaw)])
            }
        }
    }

    /// Runs off the main actor. Enumerates recursively, groups by
    /// case-insensitive base name, pairs RAW+JPEG, and reads XMP sidecars.
    /// Internal (not private) so unit tests can exercise pairing directly.
    nonisolated static func scanFolder(root: URL, cardKey: String) -> [CardItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }

        struct Group {
            var baseName: String = ""
            var rawURL: URL?
            var jpegURL: URL?
            var videoURL: URL?
            var rawSize: Int64 = 0
            var jpegSize: Int64 = 0
            var jpegPriority: Int = .max   // lower = preferred sibling format
            var date: Date = .distantFuture
        }
        var groups: [String: Group] = [:]
        var sidecars: [String: URL] = [:]

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let base = url.deletingPathExtension().lastPathComponent
            let baseLower = base.lowercased()

            if ext == "xmp" {
                // Both DSC01234.xmp and DSC01234.ARW.xmp map to their base name.
                let inner = (base as NSString).pathExtension.lowercased()
                let sidecarBase = FileTypes.raw.contains(inner) || FileTypes.image.contains(inner)
                    ? (base as NSString).deletingPathExtension.lowercased()
                    : baseLower
                sidecars[sidecarBase] = url
                continue
            }

            let isRaw = FileTypes.raw.contains(ext)
            let isImage = FileTypes.image.contains(ext)
            let isVideo = FileTypes.video.contains(ext)
            guard isRaw || isImage || isVideo else { continue }

            var group = groups[baseLower] ?? Group()
            if group.baseName.isEmpty { group.baseName = base }
            let size = Int64(values.fileSize ?? 0)
            if isRaw {
                group.rawURL = url
                group.rawSize = size
            } else if isImage {
                // Several stills can share a base name (JPG + HEIC + PNG);
                // the classic JPEG wins as the pair sibling.
                let priority = FileTypes.imagePriority.firstIndex(of: ext) ?? 98
                if priority < group.jpegPriority {
                    group.jpegURL = url
                    group.jpegSize = size
                    group.jpegPriority = priority
                }
            } else {
                group.videoURL = url
                if group.rawSize == 0 && group.jpegSize == 0 { group.rawSize = size }
            }
            if let date = values.creationDate ?? values.contentModificationDate, date < group.date {
                group.date = date
            }
            groups[baseLower] = group
        }

        return groups.map { baseLower, group in
            var item = CardItem(
                id: "\(cardKey)|\(baseLower)",
                baseName: group.baseName,
                rawURL: group.rawURL,
                jpegURL: group.jpegURL,
                videoURL: group.videoURL,
                rawSize: group.rawSize,
                jpegSize: group.jpegSize,
                fileDate: group.date == .distantFuture ? Date() : group.date
            )
            if let sidecar = sidecars[baseLower], let values = XMP.read(from: sidecar) {
                item.rating = values.rating
                item.label = values.label
            }
            return item
        }
    }

    private func rebuildIndex() {
        indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        itemsRevision += 1
    }

    /// Reset to no items (card close / empty scan result) — the direct-
    /// assignment counterpart to rebuildIndex(), so itemsRevision is bumped
    /// here too instead of only after a non-empty scan.
    private func clearItems() {
        items = []
        indexByID = [:]
        itemsRevision += 1
    }

    #if DEBUG
    /// Test hook: inject items directly so rating/undo/keepers logic can be
    /// unit-tested without a real card scan.
    func _setItemsForTesting(_ newItems: [CardItem], cardKey key: String = "test-card") {
        cardKey = key
        cardRootURL = URL(fileURLWithPath: NSTemporaryDirectory())
        sourceKind = .folder
        items = newItems
        rebuildIndex()
    }

    /// Test hook: run `openProject` and await its completion by polling
    /// `isLoading` (set synchronously true at the top of `openProject`, and
    /// false exactly once at the end of its internal Task, on every path).
    func _openProjectForTesting(_ project: ProjectRecord, timeout: TimeInterval = 5) async {
        openProject(project)
        let deadline = Date().addingTimeInterval(timeout)
        while isLoading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    #endif

    // MARK: Rating / flag / label (optimistic, undoable, debounced persistence)

    func setRating(_ rating: Int, for id: String) {
        mutate(id: id) { $0.rating = max(0, min(5, rating)) }
    }

    func setFlag(_ flag: Flag, for id: String) {
        mutate(id: id) { $0.flag = ($0.flag == flag ? .none : flag) }
    }

    func setLabel(_ label: ColorLabel?, for id: String) {
        mutate(id: id) { $0.label = ($0.label == label ? nil : label) }
    }

    func incrementRating(for id: String) {
        guard let item = item(id: id) else { return }
        setRating(min(5, item.rating + 1), for: id)
    }

    /// Batch versions for multi-select. One undo entry per item.
    func batchSetRating(_ rating: Int, ids: Set<String>) { for id in ids { setRating(rating, for: id) } }
    func batchSetFlag(_ flag: Flag, ids: Set<String>) {
        for id in ids { mutate(id: id) { $0.flag = flag } }
    }
    func batchSetLabel(_ label: ColorLabel?, ids: Set<String>) {
        for id in ids { mutate(id: id) { $0.label = label } }
    }

    func undo() {
        guard let entry = undoStack.popLast(), let idx = indexByID[entry.itemID] else { return }
        items[idx].rating = entry.rating
        items[idx].flag = entry.flag
        items[idx].label = entry.label
        itemsRevision += 1
        persist(items[idx])
    }

    private func mutate(id: String, _ change: (inout CardItem) -> Void) {
        guard let idx = indexByID[id] else { return }
        let old = items[idx]
        change(&items[idx])
        guard items[idx].rating != old.rating || items[idx].flag != old.flag || items[idx].label != old.label else { return }
        itemsRevision += 1
        undoStack.append(UndoEntry(itemID: id, rating: old.rating, flag: old.flag, label: old.label))
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
        persist(items[idx])
    }

    /// DB write is immediate (cheap); the sidecar write to the card is
    /// debounced per item so a swipe-up burst produces one file write.
    private func persist(_ item: CardItem) {
        upsertRecord(for: item)
        // Photos-library assets have no folder to drop a sidecar into.
        guard writeSidecarsToCard, !cardUnavailable, item.assetLocalID == nil else { return }
        let includeExt = sidecarIncludesExtension
        sidecarTasks[item.id]?.cancel()
        sidecarTasks[item.id] = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            XMP.write(for: item, includeExtension: includeExt)
        }
    }

    private func upsertRecord(for item: CardItem) {
        // Derive the card key from the item's own id ("cardKey|…") rather
        // than the Library's current cardKey, so a rating applied in any
        // transient window can never be stamped onto a different card.
        let key = item.id.components(separatedBy: "|").first ?? cardKey
        let baseLower = item.baseName.lowercased()
        let predicate = #Predicate<AssetRecord> { $0.cardKey == key && $0.baseNameLower == baseLower }
        var descriptor = FetchDescriptor<AssetRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        let record: AssetRecord
        if let existing = (try? context.fetch(descriptor))?.first {
            record = existing
        } else {
            record = AssetRecord(cardKey: key, baseNameLower: baseLower)
            context.insert(record)
        }
        record.rating = item.rating
        record.flag = item.flag
        record.label = item.label
        record.updatedAt = Date()
        try? context.save()
    }

    private func fetchRecords(cardKey key: String) -> [String: AssetRecord] {
        let predicate = #Predicate<AssetRecord> { $0.cardKey == key }
        let records = (try? context.fetch(FetchDescriptor<AssetRecord>(predicate: predicate))) ?? []
        return Dictionary(records.map { ($0.baseNameLower, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

enum SettingsKeys {
    static let writeSidecarsToCard = "writeSidecarsToCard"
    static let sidecarIncludesExtension = "sidecarIncludesExtension"
    static let exportMinStars = "exportMinStars"
    static let exportIncludePicks = "exportIncludePicks"
    static let showFilenames = "showFilenames"
    static let thumbSize = "thumbSize"
    static let hapticsEnabled = "hapticsEnabled"
    static let followSystemAppearance = "followSystemAppearance"
    static let histogramVisible = "histogramVisible"
    static let loupeBlackBackground = "loupeBlackBackground"
    static let exportDestBookmark = "exportDestBookmark"
    static let exportAlbumName = "exportAlbumName"
}
