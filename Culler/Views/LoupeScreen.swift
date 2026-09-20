import SwiftUI
import UIKit
import AVKit

/// Fullscreen single-image culling view, styled like a professional
/// desktop loupe (Lightroom / Photo Mechanic): neutral dark chrome, one
/// compact toolbar strip, filmstrip, optional RGB histogram overlay.
///
/// Gestures (Photo Mechanic-style, only when not zoomed in):
///   swipe left/right — previous/next shot
///   swipe up         — +1 star
///   swipe down       — toggle reject
///   double-tap       — 100% zoom (pinch also works)
///   single tap       — show/hide chrome
struct LoupeScreen: View {
    @Bindable var library: Library
    let startID: String
    let itemIDs: [String]   // snapshot of the filtered order at open time

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.histogramVisible) private var histogramVisible = false
    @AppStorage(SettingsKeys.loupeBlackBackground) private var loupeBlackBackground = true
    @AppStorage("loupeInfoOverlay") private var infoOverlayVisible = false

    @State private var index: Int = 0
    @State private var image: UIImage?
    @State private var imageItemID: String?   // which item `image` belongs to
    @State private var isZoomed = false
    @State private var chromeVisible = true
    @State private var showInfo = false
    @State private var histogram: HistogramData?
    @State private var metaCache: [String: ImageMeta] = [:]
    @State private var sizeCache: [String: Int64] = [:]   // video file sizes
    /// Real original filename for a Photos-library asset (e.g. "IMG_1234.HEIC"),
    /// fetched lazily per item so the title can show a distinguishing name
    /// instead of just its capture date.
    @State private var filenameCache: [String: String] = [:]
    /// Asset items whose full EXIF has been parsed (metaCache alone can't
    /// tell: it is pre-seeded with cheap PHAsset facts).
    @State private var exifLoaded: Set<String> = []
    /// Asset items whose EXIF fetch failed — never retried automatically,
    /// so a flaky network can't trigger a re-download loop per revisit.
    @State private var exifFailed: Set<String> = []
    @State private var player: AVPlayer?
    @State private var isPlayingVideo = false
    @State private var videoLoading = false
    @State private var videoLoadFailed = false
    @State private var imageLoadFailed = false
    @State private var showExport = false
    @State private var shareCoordinator = ShareCoordinator()
    @State private var albumCreationCoordinator = AlbumCreationCoordinator()
    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""

    // Pinch guard: ignore the culling drag while a pinch is active and for a
    // short grace period after it ends, so two-finger zooms never trigger
    // accidental photo switches or ratings.
    @State private var isPinching = false
    @State private var pinchEndedAt = Date.distantPast

    private var currentID: String? {
        itemIDs.indices.contains(index) ? itemIDs[index] : nil
    }
    private var currentItem: CardItem? {
        currentID.flatMap { library.item(id: $0) }
    }
    private var isVideo: Bool { currentItem?.kind == .video }
    private var isCurrentSelected: Bool {
        currentID.map { library.selection.contains($0) } ?? false
    }

    var body: some View {
        ZStack {
            (loupeBlackBackground ? Color.black : Theme.bg).ignoresSafeArea()

            if isVideo {
                if isPlayingVideo, let player {
                    // Native transport controls (play/pause/scrub). The top
                    // bar stays visible above it so exit is always possible.
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                } else {
                    // Poster frame + centered play button. Swipes and
                    // tap-to-toggle-chrome behave exactly like photos here.
                    Group {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { chromeVisible.toggle() } }
                    .simultaneousGesture(cullingGesture)
                    .ignoresSafeArea()

                    if videoLoadFailed {
                        loadFailureOverlay(message: "Couldn't load this video from iCloud.") {
                            startVideoPlayback()
                        }
                    } else if videoLoading {
                        loadingOverlay(label: "Loading video…")
                    } else {
                        Button {
                            startVideoPlayback()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 76, height: 76)
                                .background(.black.opacity(0.55), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ZoomableImageView(
                    itemID: currentID ?? "",
                    image: image,
                    isZoomed: $isZoomed,
                    onInteractionChanged: { pinching in
                        if pinching {
                            isPinching = true
                        } else {
                            isPinching = false
                            pinchEndedAt = Date()
                        }
                    }
                )
                .ignoresSafeArea()
                .onTapGesture(count: 2) { } // handled inside the scroll view
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { chromeVisible.toggle() } }
                .simultaneousGesture(cullingGesture)
                if image == nil {
                    if imageLoadFailed {
                        loadFailureOverlay(message: "Couldn't load this photo.") {
                            imageLoadFailed = false
                            Task { await loadImage() }
                        }
                    } else {
                        loadingOverlay(label: nil)
                    }
                }
            }

            // Edge tap zones for one-handed prev/next.
            if !isZoomed {
                HStack {
                    navZone(systemImage: "chevron.left") { step(-1) }
                    Spacer()
                    navZone(systemImage: "chevron.right") { step(1) }
                }
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
            }

            VStack(spacing: 0) {
                topBar

                if chromeVisible, infoOverlayVisible || (histogramVisible && histogram != nil) {
                    HStack(alignment: .top, spacing: 8) {
                        if infoOverlayVisible, let item = currentItem {
                            infoOverlay(for: item)
                        }
                        Spacer(minLength: 0)
                        if histogramVisible, let histogram {
                            HistogramView(data: histogram)
                                .frame(width: 150, height: 84)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                }

                Spacer(minLength: 0)

                // While a video is playing, hide the rating bar + filmstrip so
                // the native scrubber underneath is fully reachable. Tap "Done"
                // (top-left) to stop and rate.
                if chromeVisible, !isPlayingVideo, let item = currentItem {
                    toolbar(for: item)
                    FilmstripView(library: library, itemIDs: itemIDs, index: $index)
                }
            }

            // Always-visible Done while a video plays, so exiting playback (to
            // rate) never depends on the native controls being on screen.
            if isPlayingVideo {
                VStack {
                    HStack {
                        Button { stopPlayback() } label: {
                            Text("Done")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    Spacer()
                }
            }
        }
        .statusBarHidden(!chromeVisible)
        .task(id: currentID) { await loadImage() }
        .task(id: currentID) { await loadMetadata() }
        .task(id: currentID) { resetVideoPlayback() }
        .task(id: image) { await recomputeHistogram() }
        .onChange(of: infoOverlayVisible) { _, visible in
            // EXIF for Photos-library assets is fetched lazily — only while
            // the info overlay is actually showing.
            if visible { Task { await loadMetadata() } }
        }
        .onDisappear { player?.pause(); player = nil }
        .onChange(of: histogramVisible) { _, visible in
            if visible {
                Task { await recomputeHistogram() }
            } else {
                histogram = nil
            }
        }
        .onAppear {
            index = itemIDs.firstIndex(of: startID) ?? 0
        }
        .sheet(isPresented: $showInfo) {
            if let item = currentItem {
                InfoSheet(item: item)
                    .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(
                library: library,
                fixedItems: currentItem.map { [$0] }
            )
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
        .alert("New Project", isPresented: $showNewProjectAlert) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let project = library.createProject(named: name)
                addCurrentToProject(project)
            }
        } message: {
            Text("Add this photo to a new project.")
        }
    }

    // MARK: Navigation & loading

    private func step(_ delta: Int) {
        let next = index + delta
        guard itemIDs.indices.contains(next) else {
            Haptics.tap()
            return
        }
        index = next
        // Progressive loading: show whatever is already cached instantly
        // instead of a blank frame; the full-res decode swaps in silently.
        if let item = library.item(id: itemIDs[next]) {
            image = ThumbnailStore.shared.cachedPreview(for: item)
            imageItemID = item.id
        } else {
            image = nil
            imageItemID = nil
        }
    }

    private func loadImage() async {
        guard let item = currentItem else { return }
        let id = item.id
        // Filmstrip taps / first appearance land here without going through
        // step(): make sure a stale photo is replaced by the cached preview.
        if imageItemID != id {
            image = ThumbnailStore.shared.cachedPreview(for: item)
            imageItemID = id
        }
        imageLoadFailed = false
        if let full = await ThumbnailStore.shared.loupeImage(for: item), currentID == id {
            image = full
        } else if currentID == id, image == nil, !Task.isCancelled {
            // Nothing cached and the full decode/download failed: show an
            // explicit error with retry instead of an indefinite black canvas.
            imageLoadFailed = true
        }
        // Prefetch neighbors into the pipeline's caches.
        for delta in [1, -1, 2, -2] {
            let n = index + delta
            if itemIDs.indices.contains(n), let neighbor = library.item(id: itemIDs[n]) {
                Task.detached(priority: .background) {
                    _ = await ThumbnailStore.shared.loupeImage(for: neighbor)
                }
            }
        }
    }

    private func loadMetadata() async {
        guard let item = currentItem else { return }
        let id = item.id
        // Photos-library assets: cheap PHAsset facts (dimensions, capture
        // date, duration) always; full EXIF needs the ORIGINAL bytes — a
        // potentially huge iCloud download — so it is fetched only while
        // the info overlay is actually visible, at most once per item.
        if let assetID = item.assetLocalID {
            if metaCache[id] == nil {
                var meta = ImageMeta()
                if let info = await PhotoLibrarySource.shared.basicInfo(assetID: assetID) {
                    meta.pixelSize = info.pixelSize
                    meta.captureDate = info.creationDate
                    meta.durationSeconds = info.durationSeconds
                }
                meta.cameraModel = item.camera
                metaCache[id] = meta
            }
            // Cheap local metadata (no download) — fetched once per item so
            // the title bar can show a real distinguishing name instead of
            // just the capture date.
            if filenameCache[id] == nil, let name = await PhotoLibrarySource.shared.originalFilename(assetID: assetID) {
                filenameCache[id] = name
            }
            guard infoOverlayVisible, item.kind != .video,
                  !exifLoaded.contains(id), !exifFailed.contains(id) else { return }
            guard let data = await PhotoLibrarySource.shared.imageData(assetID: assetID) else {
                exifFailed.insert(id) // don't re-download on every revisit
                return
            }
            var meta = ThumbnailStore.assetMeta(from: data)
            if meta.cameraModel == nil { meta.cameraModel = item.camera }
            if meta.pixelSize == nil { meta.pixelSize = metaCache[id]?.pixelSize }
            if meta.captureDate == nil { meta.captureDate = metaCache[id]?.captureDate }
            metaCache[id] = meta
            exifLoaded.insert(id)
            return
        }
        // Video size for the info line (cheap file-system read).
        if item.kind == .video, sizeCache[id] == nil, let url = item.videoURL {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            sizeCache[id] = bytes ?? 0
        }
        guard metaCache[id] == nil, let url = item.videoURL ?? item.previewURL else { return }
        let meta = await ThumbnailStore.metadata(for: url)
        metaCache[id] = meta
    }

    private func recomputeHistogram() async {
        guard histogramVisible, !isVideo, let image else {
            histogram = nil
            return
        }
        histogram = await HistogramEngine.compute(from: image)
    }

    /// Reset playback whenever the shot changes: back to the poster view,
    /// never carry a playing video across items.
    private func resetVideoPlayback() {
        player?.pause()
        player = nil
        isPlayingVideo = false
        videoLoadFailed = false
        videoLoading = false
    }

    /// Stop playback but keep the shot: returns to the poster + rating chrome
    /// so the user can rate after watching. Player is kept for quick resume.
    private func stopPlayback() {
        player?.pause()
        isPlayingVideo = false
        chromeVisible = true
    }

    /// Lazily load and start the video only when the user taps play —
    /// browsing past videos never streams anything from iCloud.
    private func startVideoPlayback() {
        guard let item = currentItem, item.kind == .video else { return }
        chromeVisible = true   // the exit button must be reachable while playing
        videoLoadFailed = false
        if let url = item.videoURL {
            player = AVPlayer(url: url)
            isPlayingVideo = true
            player?.play()
            return
        }
        guard let assetID = item.assetLocalID else { return }
        let id = item.id
        videoLoading = true
        Task {
            let playerItem = await PhotoLibrarySource.shared.playerItem(assetID: assetID)
            guard currentID == id else { return }
            videoLoading = false
            if let playerItem {
                player = AVPlayer(playerItem: playerItem)
                isPlayingVideo = true
                player?.play()
            } else {
                // iCloud-only video that couldn't stream (offline, slow
                // network): explicit error with retry, not a black screen.
                videoLoadFailed = true
            }
        }
    }

    // MARK: Loading / failure overlays (loupe canvas)

    private func loadingOverlay(label: String?) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(Theme.textSecondary)
            if let label {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(20)
        .background(Theme.scrim, in: RoundedRectangle(cornerRadius: Theme.radius))
        .allowsHitTesting(false)
    }

    private func loadFailureOverlay(message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .tint(Theme.textSecondary)
        }
        .padding(20)
        .background(Theme.scrim, in: RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: Selection & projects (from the loupe)

    private func toggleSelection() {
        guard let id = currentID else { return }
        if library.selection.contains(id) {
            library.selection.remove(id)
        } else {
            library.selection.insert(id)
            library.selectionMode = true   // grid shows checkmarks on return
        }
        Haptics.tap()
    }

    private func addCurrentToProject(_ project: ProjectRecord) {
        guard let id = currentID else { return }
        library.add(ids: [id], to: project)
        Haptics.tap()
    }

    private var cullingGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard !isZoomed, !isPinching,
                      Date().timeIntervalSince(pinchEndedAt) > 0.35 else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy) {
                    step(dx < 0 ? 1 : -1)
                } else if let id = currentID {
                    if dy < 0 {
                        library.incrementRating(for: id)
                        Haptics.rate()
                    } else {
                        library.setFlag(.reject, for: id)
                        Haptics.rate()
                    }
                }
            }
    }

    private func navZone(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 44, height: 180)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            ghostButton("chevron.down") { dismiss() }

            ghostButton(
                isCurrentSelected ? "checkmark.circle.fill" : "checkmark.circle",
                active: isCurrentSelected
            ) {
                toggleSelection()
            }
            .overlay(alignment: .topTrailing) {
                if !library.selection.isEmpty {
                    Text("\(library.selection.count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: 4, y: -2)
                }
            }

            Spacer(minLength: 4)

            if let item = currentItem {
                VStack(spacing: 2) {
                    // Minimal by default — just the name + a short date. Tap
                    // ⓘ for the index/type/dimensions/date line plus the info
                    // overlay.
                    titleText(for: item)
                        .font(.caption.weight(.semibold).monospaced())
                        .lineLimit(1)
                    if infoOverlayVisible {
                        HStack(spacing: 5) {
                            Text(verbatim: "\(index + 1) of \(itemIDs.count)")
                                .foregroundStyle(Theme.textSecondary)
                            typeBadge(for: item)
                            if let meta = metaCache[item.id] {
                                if let size = meta.pixelSize {
                                    // String(Int(...)) on purpose: no locale
                                    // grouping separators ("1616", not "1.616").
                                    Text(String(Int(size.width)) + "×" + String(Int(size.height)))
                                        .foregroundStyle(Theme.textTertiary)
                                        .layoutPriority(1)
                                }
                                // For Photos-library assets the title already IS
                                // the capture date; don't show it twice.
                                if item.assetLocalID == nil, let date = meta.captureDate {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                        .font(.caption2)
                        .lineLimit(1)
                    }
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                ghostButton("arrow.uturn.backward", disabled: !library.canUndo) {
                    library.undo()
                    Haptics.tap()
                }
                if !isVideo {
                    ghostButton("chart.bar.xaxis", active: histogramVisible) {
                        histogramVisible.toggle()
                        Haptics.tap()
                    }
                }
                ghostButton("info.circle", active: infoOverlayVisible) {
                    infoOverlayVisible.toggle()
                    Haptics.tap()
                }
                Menu {
                    Button {
                        if let item = currentItem { shareCoordinator.begin([item]) }
                    } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        if let item = currentItem { albumCreationCoordinator.begin([item]) }
                    } label: {
                        Label("Create Album…", systemImage: "rectangle.stack.badge.plus")
                    }
                    Button {
                        showExport = true
                    } label: {
                        Label("Export to folder…", systemImage: "folder")
                    }
                    if currentItem?.assetLocalID != nil {
                        Button {
                            // iOS has no public API to open the Photos app to
                            // one exact asset — this opens the Photos app
                            // itself (best effort; usually lands on Recents).
                            if let url = URL(string: "photos-redirect://") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Show in Photos App", systemImage: "photo.on.rectangle")
                        }
                    }
                    Menu {
                        ForEach(library.projects()) { project in
                            Button(project.name) { addCurrentToProject(project) }
                        }
                        if !library.projects().isEmpty { Divider() }
                        Button {
                            newProjectName = ""
                            showNewProjectAlert = true
                        } label: {
                            Label("New Project…", systemImage: "plus")
                        }
                    } label: {
                        Label("Add to Project", systemImage: "folder.badge.plus")
                    }
                } label: {
                    ghostCircle("ellipsis")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .background(alignment: .top) {
            LinearGradient(
                colors: [.black.opacity(0.6), .black.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
    }

    /// A distinguishing name FIRST, in white (the prominent part — so shots
    /// are easy to tell apart at a glance), then a short date (day only, no
    /// time) in a dimmer secondary color. File shots already have a real
    /// filename; Photos-library assets carry id-ish base names (asset UUID
    /// prefixes) that aren't useful here, so their real original filename is
    /// fetched lazily (see `filenameCache`/`loadMetadata`) — until that
    /// arrives, the date shows alone rather than the meaningless UUID prefix.
    private func titleText(for item: CardItem) -> Text {
        let shortDate = item.fileDate.formatted(date: .abbreviated, time: .omitted)
        let name: String? = item.assetLocalID != nil ? filenameCache[item.id] : item.baseName
        guard let name else {
            return Text(shortDate).foregroundColor(Theme.textPrimary)
        }
        return Text(name).foregroundColor(Theme.textPrimary)
            + Text("  \(shortDate)").foregroundColor(Theme.textSecondary)
    }

    private func ghostButton(
        _ systemImage: String,
        active: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ghostCircle(systemImage, active: active)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    /// The styled circular glyph shared by ghost buttons and menu labels.
    private func ghostCircle(_ systemImage: String, active: Bool = false) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(active ? Theme.accent : Theme.textPrimary)
            .frame(width: 40, height: 40)
            .background(Theme.scrim, in: Circle())
            .contentShape(Circle())
    }

    private func typeBadge(for item: CardItem) -> some View {
        let tint: Color
        switch item.kind {
        case .rawPlusJpeg, .rawOnly: tint = Theme.rawBadge
        case .jpegOnly, .video: tint = Theme.textSecondary
        }
        return Text(item.badge)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 3.5)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.hairline, lineWidth: 1))
    }

    // MARK: Info overlay (filename + camera settings)

    private func infoOverlay(for item: CardItem) -> some View {
        let meta = metaCache[item.id]
        let line = item.kind == .video ? videoInfoLine(item, meta) : settingsLine(meta)
        return VStack(alignment: .leading, spacing: 3) {
            titleText(for: item)
                .font(.caption.weight(.semibold).monospaced())
            if let line {
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textSecondary)
            }
            if item.kind != .video, let model = meta?.cameraModel {
                Text(model)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textTertiary)
            }
            Button {
                showInfo = true
            } label: {
                Text("Details…")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 44, minHeight: 26, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .background(Theme.scrim, in: RoundedRectangle(cornerRadius: Theme.radius))
    }

    /// "ƒ/2.8 · 1/250 s · ISO 400 · 35 mm" — omits whatever is missing.
    private func settingsLine(_ meta: ImageMeta?) -> String? {
        guard let meta else { return nil }
        var parts: [String] = []
        if let f = meta.fNumber {
            parts.append(f == f.rounded() ? "ƒ/\(Int(f))" : String(format: "ƒ/%.1f", f))
        }
        if let t = meta.exposureSeconds {
            if t < 1 {
                parts.append("1/\(Int((1 / t).rounded())) s")
            } else if t == t.rounded() {
                parts.append("\(Int(t)) s")
            } else {
                parts.append(String(format: "%.1f s", t))
            }
        }
        if let iso = meta.iso {
            parts.append("ISO \(iso)")
        }
        if let mm = meta.focalLength35mm {
            parts.append("\(mm) mm")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "0:42 · 3840×2160 · 812 MB" — omits whatever is missing.
    private func videoInfoLine(_ item: CardItem, _ meta: ImageMeta?) -> String? {
        var parts: [String] = []
        if let secs = meta?.durationSeconds, secs > 0 {
            let total = Int(secs.rounded())
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        if let size = meta?.pixelSize {
            parts.append(String(Int(size.width)) + "×" + String(Int(size.height)))
        }
        if let bytes = sizeCache[item.id], bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Bottom toolbar (pick/reject · stars · labels)

    private func toolbar(for item: CardItem) -> some View {
        HStack(spacing: 0) {
            flagButton(
                title: "Pick", systemImage: "flag.fill",
                color: Theme.pick, isActive: item.flag == .pick
            ) {
                library.setFlag(.pick, for: item.id)
                Haptics.rate()
            }
            .padding(.trailing, 4)

            flagButton(
                title: "Reject", systemImage: "xmark.circle",
                color: Theme.reject, isActive: item.flag == .reject
            ) {
                library.setFlag(.reject, for: item.id)
                Haptics.rate()
            }

            toolbarDivider
            Spacer(minLength: 2)

            starControl(for: item)

            Spacer(minLength: 2)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(Theme.surface.opacity(0.92))
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        .animation(nil, value: item.rating)
        .animation(nil, value: item.flag)
    }

    private var toolbarDivider: some View {
        Theme.hairline
            .frame(width: 1, height: 26)
            .padding(.horizontal, 4)
    }

    private func flagButton(
        title: String,
        systemImage: String,
        color: Color,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(isActive ? Color.black : Theme.textSecondary)
            .frame(width: 40, height: 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .fill(isActive ? color : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .stroke(isActive ? Color.clear : Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Lightroom-style stars: neutral fills, faint outlines when unset.
    /// Tap star N sets rating N; tapping the current rating clears to 0.
    /// Updates are instant — no animation, ever.
    private func starControl(for item: CardItem) -> some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    library.setRating(item.rating == star ? 0 : star, for: item.id)
                    Haptics.rate()
                } label: {
                    Image(systemName: star <= item.rating ? "star.fill" : "star")
                        .font(.system(size: 18))
                        .foregroundStyle(star <= item.rating ? Theme.star : Theme.textTertiary)
                        .frame(width: 27, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

}

// MARK: - Filmstrip

struct FilmstripView: View {
    @Bindable var library: Library
    let itemIDs: [String]
    @Binding var index: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(Array(itemIDs.enumerated()), id: \.element) { i, id in
                        if let item = library.item(id: id) {
                            FilmstripThumb(item: item, isCurrent: i == index)
                                .id(id)
                                .onTapGesture { index = i }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .frame(height: 62)
            .background(Theme.surface.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
            .onChange(of: index) { _, newIndex in
                if itemIDs.indices.contains(newIndex) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(itemIDs[newIndex], anchor: .center)
                    }
                }
            }
            .onAppear {
                if itemIDs.indices.contains(index) {
                    proxy.scrollTo(itemIDs[index], anchor: .center)
                }
            }
        }
    }
}

private struct FilmstripThumb: View {
    let item: CardItem
    let isCurrent: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.cell)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: 52, height: 52)
        .clipped()
        .opacity(item.flag == .reject ? 0.35 : 1)
        .overlay(alignment: .bottomLeading) {
            if item.rating > 0 {
                Text("\(item.rating)★")
                    .font(.system(size: 8, weight: .bold).monospaced())
                    .foregroundStyle(Theme.star)
                    .padding(2)
                    .background(Theme.scrim)
            }
        }
        .overlay {
            Rectangle().stroke(isCurrent ? Theme.accent : Color.clear, lineWidth: 2)
        }
        .animation(nil, value: item.rating)
        .animation(nil, value: item.flag)
        .task(id: item.id) {
            image = await ThumbnailStore.shared.thumbnail(for: item, maxPixel: 168)
        }
    }
}

// MARK: - Info sheet

/// The full "Details" sheet — every metadata field Culler can read, not just
/// the compact loupe overlay's subset. For a Photos-library asset this
/// downloads the original bytes to read real EXIF (the overlay avoids that;
/// this sheet is an explicit, opt-in request, so it's worth the wait).
struct InfoSheet: View {
    let item: CardItem
    @State private var meta: ImageMeta?
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView().tint(Theme.textSecondary)
                        Text("Reading metadata…")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    detailList
                }
            }
            .background(Theme.bg)
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private var detailList: some View {
        List {
            Section {
                // Photos-library assets carry an opaque UUID-prefix base
                // name — meaningless to users, so it is not shown.
                if item.assetLocalID == nil {
                    row("Filename", item.baseName)
                }
                row("Type", item.badge)
                if let size = meta?.pixelSize {
                    row("Dimensions", "\(Int(size.width)) × \(Int(size.height)) px")
                }
                if let secs = meta?.durationSeconds, secs > 0 {
                    row("Duration", String(format: "%d:%02d", Int(secs) / 60, Int(secs) % 60))
                }
                if let date = meta?.captureDate {
                    row("Captured", date.formatted(date: .abbreviated, time: .standard))
                }
                row("File date", item.fileDate.formatted(date: .abbreviated, time: .standard))
                if let cs = meta?.colorSpace {
                    row("Color space", cs)
                }
                if let o = meta?.orientation, o != 1 {
                    row("Orientation", "\(o)")
                }
            } header: {
                sectionHeader("Shot")
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.hairline)

            if hasCameraInfo {
                Section {
                    if let camera = cameraText { row("Camera", camera) }
                    if let lens = meta?.lensModel { row("Lens", lens) }
                    if let f = meta?.fNumber {
                        row("Aperture", f == f.rounded() ? "ƒ/\(Int(f))" : String(format: "ƒ/%.1f", f))
                    }
                    if let t = meta?.exposureSeconds { row("Shutter", shutterText(t)) }
                    if let iso = meta?.iso { row("ISO", "\(iso)") }
                    if let mm = meta?.focalLength35mm { row("Focal length", "\(mm) mm") }
                    if let bias = meta?.exposureBias, bias != 0 {
                        row("Exposure bias", String(format: "%+.1f EV", bias))
                    }
                    if let gps = meta?.gpsCoordinateText { row("Location", gps) }
                } header: {
                    sectionHeader("Camera")
                }
                .listRowBackground(Theme.surface)
                .listRowSeparatorTint(Theme.hairline)
            } else if loadFailed {
                Section {
                    Text("Couldn't read full camera metadata — the original may be unavailable right now.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                } header: {
                    sectionHeader("Camera")
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                if item.assetLocalID != nil {
                    row("Location", "Photos library")
                } else {
                    if let raw = item.rawURL {
                        fileRow(url: raw, size: item.rawSize)
                    }
                    if let jpeg = item.jpegURL {
                        fileRow(url: jpeg, size: item.jpegSize)
                    }
                    if let video = item.videoURL {
                        fileRow(url: video, size: 0)
                    }
                }
            } header: {
                sectionHeader(item.assetLocalID == nil ? "Files on card" : "Storage")
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.hairline)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    private var hasCameraInfo: Bool {
        guard let meta else { return false }
        return meta.cameraModel != nil || meta.lensModel != nil || meta.fNumber != nil
            || meta.exposureSeconds != nil || meta.iso != nil || meta.focalLength35mm != nil
    }

    private var cameraText: String? {
        guard let model = meta?.cameraModel else { return nil }
        if let make = meta?.cameraMake, !model.localizedCaseInsensitiveContains(make) {
            return "\(make) \(model)"
        }
        return model
    }

    private func shutterText(_ t: Double) -> String {
        if t < 1 { return "1/\(Int((1 / t).rounded())) s" }
        if t == t.rounded() { return "\(Int(t)) s" }
        return String(format: "%.1f s", t)
    }

    private func load() async {
        if let assetID = item.assetLocalID {
            // Full EXIF needs the original bytes — a possible iCloud
            // download — but this sheet is an explicit, opt-in request.
            var combined = ImageMeta()
            if let info = await PhotoLibrarySource.shared.basicInfo(assetID: assetID) {
                combined.pixelSize = info.pixelSize
                combined.captureDate = info.creationDate
                combined.durationSeconds = info.durationSeconds
            }
            combined.cameraModel = item.camera
            if item.kind != .video, let data = await PhotoLibrarySource.shared.imageData(assetID: assetID) {
                var full = ThumbnailStore.assetMeta(from: data)
                if full.pixelSize == nil { full.pixelSize = combined.pixelSize }
                if full.captureDate == nil { full.captureDate = combined.captureDate }
                if full.cameraModel == nil { full.cameraModel = combined.cameraModel }
                combined = full
            } else if item.kind != .video {
                loadFailed = true
            }
            meta = combined
        } else if let url = item.videoURL ?? item.previewURL {
            meta = await ThumbnailStore.metadata(for: url)
        }
        isLoading = false
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .textCase(.uppercase)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func fileRow(url: URL, size: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(url.lastPathComponent)
                    .font(.subheadline.weight(.medium).monospaced())
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Text(url.deletingLastPathComponent().path)
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
        }
    }
}
