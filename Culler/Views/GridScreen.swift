import SwiftUI
import SwiftData

/// The main browse/cull grid: filter bar on top, LazyVGrid of thumbnails,
/// Bridge-style status bar at the bottom, batch-action panel when selecting.
struct GridScreen: View {
    @Bindable var library: Library
    @Binding var showFolderPicker: Bool

    @AppStorage(SettingsKeys.thumbSize) private var thumbSize = 110.0
    @AppStorage(SettingsKeys.showFilenames) private var showFilenames = false

    @State private var loupeItemID: String?
    @State private var showExport = false
    @State private var showSettings = false
    @State private var showSwitchProject = false
    @State private var showAlbumBrowser = false
    @State private var showAddPhotosChooser = false
    @State private var pinchBaseSize: Double?
    @State private var peekItemID: String?
    /// Magnification applied to the peek preview image while it's held and
    /// pinched — distinct from `pinchBaseSize`/`thumbSize`, which resize the
    /// grid itself and only apply when nothing is being peeked.
    @State private var peekZoomScale: CGFloat = 1
    @State private var peekZoomBase: CGFloat?
    @State private var shareCoordinator = ShareCoordinator()
    @State private var albumCreationCoordinator = AlbumCreationCoordinator()
    @State private var isOpeningAlbum = false

    // MARK: Drag-to-select (paint selection across cells by dragging)

    /// Frames of the currently-visible cells, in the grid's own coordinate
    /// space, used to resolve a live drag location to the item under it.
    @State private var cellFrames: [String: CGRect] = [:]
    /// The cell currently held by an active long press, if any — set the
    /// instant a cell's long press fires, cleared on release. The grid-level
    /// drag gesture only does anything while this is non-nil.
    @State private var holdOriginID: String?
    @State private var isDragSelecting = false
    /// Whether a drag-select paints cells IN or OUT, decided from the first
    /// cell's own state the moment the drag starts.
    @State private var dragSelectTargetState = false
    @State private var dragSelectTouchedIDs: Set<String> = []
    /// True when this same continuous gesture is the one that just entered
    /// selection mode (a fresh long press outside any selection context). A
    /// drag continuing straight out of that same touch must keep painting
    /// SELECT, never flip to deselect — the origin cell's "already selected"
    /// state at that instant is an artifact of just having been added, not a
    /// prior selection worth toggling off.
    @State private var freshSelectionEntry = false
    private let gridSpace = "galleryGrid"

    private var filtered: [CardItem] { library.filteredItems }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg.ignoresSafeArea())
                .navigationTitle(library.cardName ?? "Selecta")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .toolbarBackground(Theme.surface, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        // Picks/Rejects smart folders — only meaningful inside
                        // an open project (they read each item's own flag).
                        if library.openedProject != nil {
                            ProjectFolderTabs(library: library)
                        }
                        // Picking photos gets its own light filter bar
                        // (photo/video, RAW/normal) instead of the full
                        // culling FilterSortBar, which doesn't apply here.
                        if library.isSelectingFromGallery {
                            GallerySelectFilterBar(library: library)
                        } else {
                            FilterSortBar(library: library, showFilenames: $showFilenames, thumbSize: $thumbSize)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if library.isSelectingFromGallery {
                        // Switching source (another album/folder) lives in the
                        // top "Source" menu — the bar itself stays focused on
                        // the one job: confirm the selection into a project.
                        SourceSelectBar(
                            library: library,
                            onOpenProject: { project in library.openProject(project) }
                        )
                    } else if library.selectionMode {
                        BatchBar(library: library, showExport: $showExport, onShare: {
                            let picked = library.items.filter { library.selection.contains($0.id) }
                            shareCoordinator.begin(picked)
                        }, onCreateAlbum: {
                            let picked = library.items.filter { library.selection.contains($0.id) }
                            albumCreationCoordinator.begin(picked)
                        })
                    } else {
                        statusBar
                    }
                }
        }
        .fullScreenCover(item: Binding(
            get: { loupeItemID.map { LoupeTarget(id: $0) } },
            set: { loupeItemID = $0?.id }
        )) { target in
            LoupeScreen(library: library, startID: target.id, itemIDs: filtered.map(\.id))
        }
        .sheet(isPresented: $showExport) {
            // From the BatchBar (selection mode) the user means "export the
            // selected shots" — preselect that scope instead of the keepers rule.
            ExportSheet(
                library: library,
                initialScope: library.selectionMode && !library.selection.isEmpty ? .selection : nil
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showSwitchProject) {
            ProjectsSheet(library: library)
        }
        .sheet(isPresented: $showAlbumBrowser) {
            AlbumBrowserSheet(onOpenAlbum: { albumID in openAlbum(albumID) })
        }
        .sheet(isPresented: $showAddPhotosChooser) {
            if let project = library.openedProject {
                AddPhotosChooserView(
                    projectName: project.name,
                    onChooseGallery: {
                        showAddPhotosChooser = false
                        library.beginAddingPhotos(to: project)
                        presentAfterDismiss { showAlbumBrowser = true }
                    },
                    onChooseFiles: {
                        showAddPhotosChooser = false
                        library.beginAddingPhotos(to: project)
                        presentAfterDismiss { showFolderPicker = true }
                    }
                )
            }
        }
        // Defensive peek clears that don't depend on the originating cell
        // delivering pressing(false): a new scan, or leaving/entering
        // selection, tears down the cell that set peekItemID.
        .onChange(of: library.scanGeneration) { _, _ in peekItemID = nil }
        .onChange(of: library.selectionMode) { _, _ in peekItemID = nil }
        .overlay {
            if isOpeningAlbum {
                LoadingOverlay(label: "Opening album…")
            }
        }
        .overlay {
            // Resolve from the visible `filtered` set (not the unfiltered
            // index): if the peeked item scrolled or filtered out, the overlay
            // clears instead of hanging as a non-interactive full-screen dim.
            if let peekItemID, let item = filtered.first(where: { $0.id == peekItemID }) {
                PeekOverlay(item: item, zoom: peekZoomScale)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if library.infoNote != nil {
                infoBanner
            }
        }
        .alert(
            "Couldn't open",
            isPresented: Binding(
                get: { library.loadError != nil },
                set: { if !$0 { library.loadError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(library.loadError ?? "")
        }
        .shareFlow(shareCoordinator)
        .albumCreationFlow(albumCreationCoordinator)
        .overlay {
            if albumCreationCoordinator.isWorking {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Creating album…").font(.footnote).foregroundStyle(.white)
                    }
                    .padding(20)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                }
            }
        }
        .overlay {
            if shareCoordinator.isPreparing {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Preparing…").font(.footnote).foregroundStyle(.white)
                    }
                    .padding(20)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                }
            }
        }
        #if DEBUG
        .onChange(of: library.items.count) { _, newCount in
            guard ProcessInfo.processInfo.environment["CULLER_AUTO_LOUPE"] != nil,
                  newCount > 0,
                  loupeItemID == nil,
                  let first = library.filteredItems.first else { return }
            loupeItemID = first.id
        }
        #endif
    }

    /// Load the album's assets in place (nothing copied) and open them as
    /// the current "card". Shows a blocking overlay while loading and keeps
    /// the current card when the album is empty or fails to load.
    private func openAlbum(_ albumID: String) {
        showAlbumBrowser = false
        guard !isOpeningAlbum else { return }
        isOpeningAlbum = true
        Task {
            let result = await PhotoLibrarySource.shared.loadItems(albumID: albumID)
            await MainActor.run {
                isOpeningAlbum = false
                guard !result.items.isEmpty else {
                    library.loadError = "That album is empty or couldn't be loaded from your Photos library."
                    return
                }
                library.openPhotoAlbum(albumID: albumID, title: result.title, items: result.items)
            }
        }
    }

    /// SwiftUI can drop a sheet presentation requested in the same tick a
    /// previous sheet dismisses; a short delay lets the dismiss animation
    /// finish first so the next sheet reliably appears.
    private func presentAfterDismiss(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }

    /// Transient, non-error banner for `library.infoNote` (e.g. "N photos live
    /// on a card/folder"). Distinct from the "Couldn't open" alert, which is
    /// reserved for real open failures. Tap to dismiss; auto-clears after a
    /// few seconds.
    private var infoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Text(library.infoNote ?? "")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .contentShape(Rectangle())
        .onTapGesture { library.infoNote = nil }
        .task(id: library.infoNote) {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { library.infoNote = nil }
        }
    }

    private struct LoupeTarget: Identifiable { let id: String }

    // MARK: Grid body

    @ViewBuilder
    private var content: some View {
        if library.isLoading && library.items.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Theme.textSecondary)
                Text("Scanning card…")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if library.cardUnavailable {
            unavailableView
        } else if library.items.isEmpty {
            emptyView
        } else if filtered.isEmpty {
            noMatchesView
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize * 1.6), spacing: 2)],
                spacing: 2
            ) {
                ForEach(filtered) { item in
                    ThumbCell(
                        item: item,
                        size: thumbSize,
                        showFilename: showFilenames,
                        isSelected: library.selection.contains(item.id),
                        selectionMode: library.selectionMode || library.isSelectingFromGallery,
                        onNeedsRawCheck: { library.checkRawFlagIfNeeded(itemID: $0) }
                    )
                    // Frame tracking for drag-select ONLY while a drag-select
                    // is actually in progress — mounting a GeometryReader on
                    // every visible cell unconditionally re-published a
                    // preference (and re-rendered this whole screen) on every
                    // single scroll pixel, which is what made scrolling a big
                    // album like "Recents" feel completely stuck. Cell frames
                    // don't change while a drag-select is held (nothing else
                    // scrolls at the same time), so reading them only for
                    // that brief window is enough and costs nothing at rest.
                    .background {
                        if isDragSelecting {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: CellFrameKey.self,
                                    value: [item.id: proxy.frame(in: .named(gridSpace))]
                                )
                            }
                        }
                    }
                    .onTapGesture {
                        // Gallery selection or multi-select → toggle; otherwise
                        // (culling a project/card) → open the loupe.
                        if library.isSelectingFromGallery || library.selectionMode {
                            toggleSelection(item.id)
                        } else {
                            loupeItemID = item.id
                        }
                    }
                    // Plain onLongPressGesture (not a custom Gesture composed
                    // with DragGesture): this is the one form that reliably
                    // coexists with the ScrollView's own pan — a scroll flick
                    // moves the finger past maximumDistance and cancels the
                    // press before it fires, so scrolling stays untouched.
                    // A drag-to-paint-select experiment that instead attached
                    // an exclusive `.gesture()` per cell (a LongPressGesture
                    // sequenced with a DragGesture) broke scrolling outright
                    // even though its long-press phase used these exact same
                    // parameters — an exclusive `.gesture()`, unlike this
                    // convenience modifier, appears to delay the ScrollView's
                    // own pan recognition regardless of how quickly the long
                    // press itself fails. Do not reintroduce that form —
                    // drag-select below is driven by a SEPARATE
                    // `.simultaneousGesture` at the grid level instead, which
                    // by definition can never block scrolling.
                    // Shorter hold (0.2s, was 0.35s) while in a selecting
                    // context — once you're already selecting, the hold is
                    // just there to disambiguate from a scroll flick, not to
                    // trigger a peek first, so it can be quick. Outside a
                    // selecting context the fuller-feeling 0.35s stays,
                    // since a long press there does something more final
                    // (enters selection mode outright).
                    .onLongPressGesture(
                        minimumDuration: (library.selectionMode || library.isSelectingFromGallery) ? 0.2 : 0.35,
                        maximumDistance: 12,
                        pressing: { pressing in
                            if !pressing && holdOriginID == item.id { endDragSelectSession() }
                        }, perform: {
                        holdOriginID = item.id
                        if library.selectionMode || library.isSelectingFromGallery {
                            peekItemID = item.id
                            peekZoomScale = 1
                            Haptics.tap()
                        } else {
                            library.selectionMode = true
                            library.selection = [item.id]
                            freshSelectionEntry = true
                            Haptics.tap()
                        }
                    })
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
        .coordinateSpace(name: gridSpace)
        .onPreferenceChange(CellFrameKey.self) { cellFrames = $0 }
        // A second single-finger gesture on top of the ScrollView's own pan,
        // recognized SIMULTANEOUSLY (never exclusively) — the defining
        // property of `.simultaneousGesture` is that it cannot block or
        // delay an ancestor/sibling gesture, so this can never be the thing
        // that breaks scrolling, unlike an exclusive `.gesture()`. It fires
        // on every plain scroll drag too, but `onChanged` bails immediately
        // when no cell is being held (the overwhelming majority of drags),
        // so that cost is a single nil-check, not a real one.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(gridSpace))
                .onChanged { value in handleGridDrag(value) }
                .onEnded { _ in endDragSelectSession() }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    // While peeking, the same pinch zooms into the peek
                    // preview instead of resizing the grid — previously this
                    // branch just dismissed the peek outright, "losing" it
                    // the moment a second finger touched down to zoom.
                    if peekItemID != nil {
                        if peekZoomBase == nil { peekZoomBase = peekZoomScale }
                        if let base = peekZoomBase {
                            peekZoomScale = min(5, max(1, base * value.magnification))
                        }
                        return
                    }
                    if pinchBaseSize == nil { pinchBaseSize = thumbSize }
                    if let base = pinchBaseSize {
                        thumbSize = min(240, max(70, base * value.magnification))
                    }
                }
                .onEnded { _ in
                    pinchBaseSize = nil
                    peekZoomBase = nil
                }
        )
    }

    /// Frames of visible cells in the grid's coordinate space, collected so
    /// a live drag location can be resolved to the item under it.
    private struct CellFrameKey: PreferenceKey {
        static var defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    /// Only acts once a cell's long press has already fired (`holdOriginID`
    /// set) — for every ordinary scroll/pan touch this is a single nil-check
    /// and nothing more.
    private func handleGridDrag(_ value: DragGesture.Value) {
        guard let originID = holdOriginID else { return }
        guard library.selectionMode || library.isSelectingFromGallery else { return }
        let moved = hypot(value.translation.width, value.translation.height)
        guard moved >= 5 else { return }
        if !isDragSelecting {
            peekItemID = nil
            isDragSelecting = true
            dragSelectTouchedIDs = []
            dragSelectTargetState = freshSelectionEntry || !library.selection.contains(originID)
            paintDragSelect(originID)
        }
        if let hitID = cellID(at: value.location) {
            paintDragSelect(hitID)
        }
    }

    private func endDragSelectSession() {
        peekItemID = nil
        peekZoomScale = 1
        isDragSelecting = false
        dragSelectTouchedIDs = []
        holdOriginID = nil
        freshSelectionEntry = false
        cellFrames = [:]
    }

    private func paintDragSelect(_ itemID: String) {
        guard !dragSelectTouchedIDs.contains(itemID) else { return }
        dragSelectTouchedIDs.insert(itemID)
        if dragSelectTargetState {
            library.selection.insert(itemID)
        } else {
            library.selection.remove(itemID)
        }
        Haptics.tap()
    }

    private func cellID(at point: CGPoint) -> String? {
        for (id, frame) in cellFrames where frame.contains(point) {
            return id
        }
        return nil
    }

    private func toggleSelection(_ id: String) {
        if library.selection.contains(id) {
            library.selection.remove(id)
        } else {
            library.selection.insert(id)
        }
    }

    // MARK: Status bar (Bridge-style, bottom)

    private var pickCount: Int { library.items.filter { $0.flag == .pick }.count }
    private var rejectCount: Int { library.items.filter { $0.flag == .reject }.count }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Theme.hairline.frame(height: 1)
            HStack(spacing: 8) {
                Text("\(library.items.count) shots · \(filtered.count) shown · \(pickCount) picks · \(rejectCount) rejects")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Image(systemName: "square.grid.4x3.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.textTertiary)
                    Slider(value: $thumbSize, in: 70...240)
                        .frame(width: 104)
                        .tint(Theme.textTertiary)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
        }
        .background(Theme.surface)
    }

    // MARK: Empty / error states

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textTertiary)
            if library.sourceKind == .photoAlbum {
                Text("This album is empty")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("The album has no photos or videos Culler can show.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Browse Photo Library") { showAlbumBrowser = true }
                    .buttonStyle(.bordered)
                    .tint(Theme.textSecondary)
            } else {
                Text("No photos found")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("This folder has no RAW or JPEG files. Try picking the card's DCIM folder.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Pick another folder") { showFolderPicker = true }
                    .buttonStyle(.bordered)
                    .tint(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "sdcard")
                .font(.system(size: 44))
                .foregroundStyle(Theme.rawBadge)
            Text("Card disconnected")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Your ratings are safe. Reconnect the card and reopen it to continue culling.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            HStack {
                Button("Try again") { library.rescan(); library.checkCardStillPresent() }
                    .buttonStyle(.bordered)
                    .tint(Theme.textSecondary)
                Button("Open Card") { showFolderPicker = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesView: some View {
        VStack(spacing: 12) {
            Text("No shots match the filter")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("\(library.items.count) shots on the card")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Button("Clear filters") {
                library.clearFilters()
                library.projectFolder = .all
            }
            .buttonStyle(.bordered)
            .tint(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        Group {
            if library.isSelectingFromGallery {
                // Picking photos (from a gallery album or a folder): switch
                // source, close, or select/clear all.
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showAlbumBrowser = true } label: {
                            Label("Browse Photo Library…", systemImage: "photo.stack")
                        }
                        Button { showFolderPicker = true } label: {
                            Label("Open Another Folder…", systemImage: "sdcard")
                        }
                    } label: {
                        Text("Source")
                    }
                    .tint(Theme.textPrimary)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { library.cancelPicking() }
                        .tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    let allSelected = !library.items.isEmpty && library.selection.count == library.filteredItems.count
                    Button(allSelected ? "Clear" : "Select all") {
                        library.selection = allSelected ? [] : Set(library.filteredItems.map(\.id))
                    }
                    .tint(Theme.textPrimary)
                }
            } else {
                // Culling — always inside a project under the new flow.
                ToolbarItem(placement: .topBarLeading) {
                    Button { library.closeCard() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .tint(Theme.textPrimary)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showAddPhotosChooser = true } label: {
                            Label("Add Photos…", systemImage: "plus.rectangle.on.folder")
                        }
                        Button { showSwitchProject = true } label: {
                            Label("Switch Project…", systemImage: "folder")
                        }
                        if library.openedProject != nil {
                            Button { library.rescan() } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(Theme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(library.selectionMode ? "Done" : "Select") {
                        library.selectionMode.toggle()
                        if !library.selectionMode { library.selection.removeAll() }
                    }
                    .tint(Theme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            let picked = library.items.filter { library.selection.contains($0.id) }
                            shareCoordinator.begin(picked)
                        } label: {
                            Label("Share selected…", systemImage: "square.and.arrow.up")
                        }
                        .disabled(library.selection.isEmpty)
                        Button {
                            let picked = library.items.filter { library.selection.contains($0.id) }
                            albumCreationCoordinator.begin(picked)
                        } label: {
                            Label("Create Album…", systemImage: "rectangle.stack.badge.plus")
                        }
                        .disabled(library.selection.isEmpty)
                        Button { showExport = true } label: {
                            Label("Export to folder…", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(Theme.textPrimary)
                    .disabled(library.items.isEmpty)
                }
            }
        }
    }
}

// MARK: - Source selection bar (pick photos → add to a project)

/// Bottom bar shown while picking photos from a Photos-gallery album OR a
/// folder/card — both are purely for choosing which photos to work on. When
/// `library.targetProject` is set (the normal case: arrived here via
/// "Add Photos…" for a specific project) the primary button adds straight to
/// it with no extra tap; otherwise a menu of all projects is offered.
struct SourceSelectBar: View {
    @Bindable var library: Library
    var onOpenProject: (ProjectRecord) -> Void

    @State private var showNewProject = false
    @State private var newName = ""

    private var count: Int { library.selection.count }

    var body: some View {
        VStack(spacing: 0) {
            Theme.hairline.frame(height: 1)
            HStack(spacing: 12) {
                Text(count == 0 ? "Tap photos to select" : "\(count) selected")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(count == 0 ? Theme.textSecondary : Theme.textPrimary)

                Spacer(minLength: 8)

                // Nothing picked yet → a clear way back out. Once at least
                // one photo is selected, that same slot becomes the primary
                // "add" action instead of a disabled placeholder.
                if count == 0 {
                    Button {
                        library.cancelPicking()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Theme.surfaceElevated, in: Capsule())
                    }
                } else if let target = library.targetProject {
                    Button {
                        add(to: target)
                    } label: {
                        Text("Add \(count) to “\(target.name)”")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Theme.accent, in: Capsule())
                    }
                } else {
                    Menu {
                        ForEach(library.projects(), id: \.persistentModelID) { project in
                            Button {
                                add(to: project)
                            } label: {
                                Text("\(project.name) (\(library.memberCount(of: project)))")
                            }
                        }
                        Divider()
                        Button {
                            newName = ""
                            showNewProject = true
                        } label: {
                            Label("New Project…", systemImage: "plus")
                        }
                    } label: {
                        Label("Add to Project", systemImage: "folder.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Theme.accent, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Theme.surface)
        .alert("New Project", isPresented: $showNewProject) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                add(to: library.createProject(named: name))
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Gather the \(count) selected photo\(count == 1 ? "" : "s") into a new project, then rate them there.")
        }
    }

    private func add(to project: ProjectRecord) {
        library.addSelectionToProject(project)
        Haptics.tap()
        onOpenProject(project)   // jump straight into the project to rate
    }
}

// MARK: - Project folder tabs (All Photos / Picks / Rejects)

/// Automatic smart folders inside a project, derived from each item's own
/// flag — no separate assignment step. Shown just under the nav bar while a
/// project is open.
struct ProjectFolderTabs: View {
    @Bindable var library: Library

    var body: some View {
        HStack(spacing: 6) {
            tab("All Photos", folder: .all)
            tab("Picks", folder: .picks)
            tab("Rejects", folder: .rejects)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }

    private func tab(_ title: String, folder: Library.ProjectFolder) -> some View {
        let active = library.projectFolder == folder
        return Button {
            library.projectFolder = folder
            Haptics.tap()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? Color.black : Theme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(active ? Theme.accent : Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Gallery select filter bar (photo/video, RAW/normal)

/// Light filter row shown only while picking photos from a source: narrow a
/// big album down before adding to a project. RAW-ness is checked lazily,
/// per item, as each thumbnail scrolls into view (see
/// Library.checkRawFlagIfNeeded) rather than scanned for the whole album up
/// front — items still being checked are simply excluded from the RAW/Normal
/// split until known, rather than flashing into the wrong bucket.
struct GallerySelectFilterBar: View {
    @Bindable var library: Library

    var body: some View {
        HStack(spacing: 6) {
            mediaChip("All", filter: .all)
            mediaChip("Photos", filter: .photosOnly)
            mediaChip("Videos", filter: .videosOnly)
            Theme.hairline.frame(width: 1, height: 18).padding(.horizontal, 2)
            rawChip("All", filter: .all)
            rawChip("RAW", filter: .rawOnly)
            rawChip("Normal", filter: .normalOnly)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }

    private func mediaChip(_ title: String, filter: Library.GalleryMediaFilter) -> some View {
        let active = library.galleryMediaFilter == filter
        return Button {
            library.galleryMediaFilter = filter
            Haptics.tap()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? Color.black : Theme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(active ? Theme.accent : Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func rawChip(_ title: String, filter: Library.GalleryRawFilter) -> some View {
        let active = library.galleryRawFilter == filter
        return Button {
            library.galleryRawFilter = filter
            Haptics.tap()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? Color.black : Theme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(active ? Theme.rawBadge : Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Batch action panel (multi-select)

/// Full-width pro-toolbar panel pinned to the bottom edge while selecting:
/// count, direct 5-star batch rating, pick/reject, label dots, select-all,
/// export. Every action applies instantly — no animation.
struct BatchBar: View {
    @Bindable var library: Library
    @Binding var showExport: Bool
    var onShare: () -> Void = {}
    var onCreateAlbum: () -> Void = {}

    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""

    var body: some View {
        VStack(spacing: 0) {
            Theme.hairline.frame(height: 1)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text("\(library.selection.count)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minWidth: 28, alignment: .leading)

                    starButton(0, icon: "star.slash")
                    ForEach(1...5, id: \.self) { n in
                        starButton(n, icon: "star.fill")
                    }

                    Spacer(minLength: 0)

                    flagButton(.pick, icon: "flag.fill", color: Theme.pick)
                    flagButton(.reject, icon: "xmark", color: Theme.reject)
                }
                HStack(spacing: 4) {
                    Spacer(minLength: 0)

                    addToProjectMenu

                    Button {
                        library.selection = Set(library.filteredItems.map(\.id))
                    } label: {
                        Text("Select All")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button { onShare() } label: {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        Button { onCreateAlbum() } label: {
                            Label("Create Album…", systemImage: "rectangle.stack.badge.plus")
                        }
                        Button { showExport = true } label: {
                            Label("Export to folder…", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(library.selection.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(library.selection.isEmpty)
                }
            }
            .padding(.horizontal, 10)
        }
        .background(Theme.surface)
        .alert("New Project", isPresented: $showNewProjectAlert) {
            TextField("Name", text: $newProjectName)
            Button("Create") { createProjectWithSelection() }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        } message: {
            Text("The \(library.selection.count) selected shots will be added.")
        }
    }

    // MARK: Add to project

    private var addToProjectMenu: some View {
        Menu {
            ForEach(library.projects(), id: \.persistentModelID) { project in
                Button {
                    library.add(ids: library.selection, to: project)
                    Haptics.tap()
                } label: {
                    Label(project.name, systemImage: "folder")
                }
            }
            Divider()
            Button {
                newProjectName = ""
                showNewProjectAlert = true
            } label: {
                Label("New Project…", systemImage: "plus")
            }
        } label: {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(library.selection.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(library.selection.isEmpty)
    }

    private func createProjectWithSelection() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        newProjectName = ""
        guard !name.isEmpty else { return }
        let project = library.createProject(named: name)
        library.add(ids: library.selection, to: project)
        Haptics.tap()
    }

    // MARK: Batch controls

    private func starButton(_ stars: Int, icon: String) -> some View {
        Button {
            library.batchSetRating(stars, ids: library.selection)
            Haptics.tap()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(stars == 0 ? Theme.textTertiary : Theme.star)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func flagButton(_ flag: Flag, icon: String, color: Color) -> some View {
        Button {
            library.batchSetFlag(flag, ids: library.selection)
            Haptics.tap()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Peek overlay (press-and-hold preview)

/// Large preview of the long-pressed shot, shown while the finger is held.
/// Non-interactive; the host clears it on release. `zoom` lets a second-finger
/// pinch while holding magnify into the image without dismissing the peek.
struct PeekOverlay: View {
    let item: CardItem
    var zoom: CGFloat = 1
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .padding(20)
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Text(item.baseName)
                        .font(.footnote.weight(.semibold).monospaced())
                    if item.rating > 0 {
                        Text(String(repeating: "★", count: item.rating))
                            .foregroundStyle(Theme.star)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(.bottom, 40)
            }
        }
        .task(id: item.id) {
            image = await ThumbnailStore.shared.thumbnail(for: item, maxPixel: 1200)
        }
    }
}
