import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var library: Library?
    @State private var showFolderPicker = false
    #if DEBUG
    @State private var didAutoOpen = false
    #endif

    var body: some View {
        Group {
            if let library {
                if library.hasCard {
                    GridScreen(library: library, showFolderPicker: $showFolderPicker)
                } else {
                    ProjectsHomeView(library: library, showFolderPicker: $showFolderPicker)
                }
            } else {
                Theme.bg.ignoresSafeArea()
            }
        }
        .onAppear {
            let lib = library ?? Library(context: context)
            if library == nil { library = lib }
            #if DEBUG
            // Automated-screenshot hook: launch with CULLER_AUTO_OPEN set to a
            // folder path to skip the picker and open that card directly.
            if !didAutoOpen,
               let path = ProcessInfo.processInfo.environment["CULLER_AUTO_OPEN"] {
                didAutoOpen = true
                lib.openCard(pickedURL: URL(fileURLWithPath: path))
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library?.checkCardStillPresent() }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                library?.openCard(pickedURL: url)
            }
        }
    }
}

// MARK: - Projects home (the app's start screen)

/// Everything starts here: pick an existing project to rate, or create a new
/// one. A project's photos are gathered from your Photos library or a
/// card/folder — nothing is copied until you export.
struct ProjectsHomeView: View {
    @Bindable var library: Library
    @Binding var showFolderPicker: Bool

    @State private var projects: [ProjectRecord] = []
    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""
    @State private var showAddPhotosChooser = false
    @State private var addPhotosTarget: ProjectRecord?
    @State private var showAlbumBrowser = false
    @State private var isOpeningAlbum = false
    @State private var showGuideSheet = false

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    emptyState
                } else {
                    projectGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text("SELECTA")
                            .font(.system(size: 15, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showGuideSheet = true } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 18))
                    }
                    .tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newProjectName = ""
                        showNewProjectAlert = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                    }
                    .tint(Theme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { reload() }
        .onChange(of: library.scanGeneration) { _, _ in reload() }
        .sheet(isPresented: $showGuideSheet) {
            GuideSheet()
        }
        .alert("New Project", isPresented: $showNewProjectAlert) {
            TextField("Project name", text: $newProjectName)
            Button("Create") { createProject() }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        } message: {
            Text("You'll pick photos from your Photos library or a card/folder next.")
        }
        .sheet(isPresented: $showAddPhotosChooser) {
            if let target = addPhotosTarget {
                AddPhotosChooserView(
                    projectName: target.name,
                    onChooseGallery: {
                        showAddPhotosChooser = false
                        library.beginAddingPhotos(to: target)
                        presentAfterDismiss { showAlbumBrowser = true }
                    },
                    onChooseFiles: {
                        showAddPhotosChooser = false
                        library.beginAddingPhotos(to: target)
                        presentAfterDismiss { showFolderPicker = true }
                    }
                )
            }
        }
        .sheet(isPresented: $showAlbumBrowser) {
            AlbumBrowserSheet(onOpenAlbum: { albumID in openAlbum(albumID) })
        }
        .overlay {
            if isOpeningAlbum {
                LoadingOverlay(label: "Opening album…")
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
    }

    // MARK: Project grid

    private var projectGrid: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 156, maximum: 220), spacing: 14)],
                    spacing: 18
                ) {
                    ForEach(projects, id: \.persistentModelID) { project in
                        ProjectCard(
                            project: project,
                            memberCount: library.memberCount(of: project),
                            pickCount: library.pickCount(of: project),
                            onOpen: { library.openProject(project) },
                            onAddPhotos: { beginAddingPhotos(to: project) },
                            onDelete: { library.deleteProject(project); reload() }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "star.square.on.square")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 8) {
                Text("Start a project")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("A project gathers the photos you pick from your Photos library or a card, so you can rate and export just those.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
            }
            Button {
                newProjectName = ""
                showNewProjectAlert = true
            } label: {
                Label("New Project", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 22).padding(.vertical, 13)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            Button {
                showGuideSheet = true
            } label: {
                Text("How it works")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func reload() {
        projects = library.projects()
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        newProjectName = ""
        guard !name.isEmpty else { return }
        let project = library.createProject(named: name)
        reload()
        // A brand-new project is empty — go straight to picking its photos.
        beginAddingPhotos(to: project)
    }

    private func beginAddingPhotos(to project: ProjectRecord) {
        addPhotosTarget = project
        showAddPhotosChooser = true
    }

    /// Load the album's assets in place (nothing copied) and either add the
    /// current selection's destination project, or open it directly.
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
}

// MARK: - Project card

private struct ProjectCard: View {
    let project: ProjectRecord
    let memberCount: Int
    let pickCount: Int
    var onOpen: () -> Void
    var onAddPhotos: () -> Void
    var onDelete: () -> Void

    /// Up to 4 tiles for the collage; fewer photos just fill fewer tiles.
    @State private var covers: [UIImage?] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                coverView
            }
            .buttonStyle(.plain)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(countText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 6)
                Menu {
                    Button { onOpen() } label: {
                        Label("Open", systemImage: "star.square")
                    }
                    Button { onAddPhotos() } label: {
                        Label("Add Photos…", systemImage: "plus.rectangle.on.folder")
                    }
                    Divider()
                    Button(role: .destructive) { onDelete() } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
        }
        // Keyed on memberCount too: a brand-new project starts with zero
        // members (no cover), then gains its first photo — without this the
        // task never re-ran (persistentModelID alone never changes), so the
        // cover stayed the empty placeholder forever even after photos were
        // added.
        .task(id: "\(project.persistentModelID)-\(memberCount)") {
            covers = await coverThumbnails()
        }
    }

    private var countText: String {
        guard memberCount > 0 else { return "Empty" }
        var text = memberCount == 1 ? "1 photo" : "\(memberCount) photos"
        if pickCount > 0 { text += " · \(pickCount) picked" }
        return text
    }

    /// A single photo for 1 result, an L-shaped 3-split for 2–3, a 2×2 grid
    /// for 4+ — like a miniature contact sheet instead of one repeated shot.
    private var coverView: some View {
        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .fill(Theme.cell)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                let loaded = covers.compactMap { $0 }
                if loaded.isEmpty {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 28, weight: .thin))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    GeometryReader { geo in
                        collageLayout(loaded, in: geo.size)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    /// Photos in the collage: as full a contact sheet as the card can
    /// usefully show, capped at an 8×8 grid (64) so tiles never shrink to
    /// nothing on a card this size.
    private static let maxGridSide = 8
    private static let collageCount = maxGridSide * maxGridSide

    @ViewBuilder
    private func collageLayout(_ images: [UIImage], in size: CGSize) -> some View {
        let hair: CGFloat = 1.5
        switch images.count {
        case 1:
            tile(images[0], width: size.width, height: size.height)
        case 2:
            row([images[0], images[1]], height: size.width, hair: hair)
        case 3:
            HStack(spacing: hair) {
                tile(images[0], width: (size.width - hair) / 2, height: size.height)
                VStack(spacing: hair) {
                    tile(images[1], width: (size.width - hair) / 2, height: (size.height - hair) / 2)
                    tile(images[2], width: (size.width - hair) / 2, height: (size.height - hair) / 2)
                }
            }
        case 5, 6:
            // Two rows: 3 over 2 (or 3 over 3 for 6), so every tile is the
            // same size within its row rather than leaving an empty gap.
            VStack(spacing: hair) {
                row(Array(images[0..<3]), height: (size.height - hair) / 2, hair: hair)
                row(Array(images[3...]), height: (size.height - hair) / 2, hair: hair)
            }
        default:
            // Every other count (4, 7, 8, 9…64): the largest complete N×N
            // square that fits, so the grid is always full rows and full
            // columns — never a ragged last row — up to 8×8.
            let side = min(Self.maxGridSide, Int(Double(images.count).squareRoot()))
            grid(Array(images.prefix(side * side)), columns: side, size: size, hair: hair)
        }
    }

    /// One row of equally-sized tiles filling the given width.
    private func row(_ images: [UIImage], height: CGFloat, hair: CGFloat) -> some View {
        HStack(spacing: hair) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                tile(image, width: .infinity, height: height)
            }
        }
    }

    /// An evenly-spaced N×N grid (only as many rows as needed for the count).
    private func grid(_ images: [UIImage], columns: Int, size: CGSize, hair: CGFloat) -> some View {
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let tileHeight = (size.height - hair * CGFloat(rows - 1)) / CGFloat(rows)
        return VStack(spacing: hair) {
            ForEach(0..<rows, id: \.self) { r in
                let rowImages = Array(images[(r * columns)..<min((r + 1) * columns, images.count)])
                row(rowImages, height: tileHeight, hair: hair)
            }
        }
    }

    private func tile(_ image: UIImage, width: CGFloat, height: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: width == .infinity ? nil : max(width, 0), height: max(height, 0))
            .frame(maxWidth: width == .infinity ? .infinity : nil)
            .clipped()
    }

    /// Best-effort collage: up to `collageCount` Photos-library members'
    /// thumbnails. Folder-sourced-only projects show the placeholder icon
    /// (their files aren't reachable without re-resolving the card's
    /// bookmark).
    private func coverThumbnails() async -> [UIImage?] {
        let photoIDs = project.itemIDs.filter { $0.hasPrefix("photoslib|") }.prefix(Self.collageCount)
        guard !photoIDs.isEmpty else { return [] }
        // Cheap no-op when already authorized; only actually prompts if
        // permission was somehow never asked, which can't normally happen
        // here (a photoslib member implies the album browser already asked).
        guard await PhotoLibrarySource.shared.requestAccess() else { return [] }
        return await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (offset, id) in photoIDs.enumerated() {
                let assetID = String(id.dropFirst("photoslib|".count))
                group.addTask {
                    // Smaller than before (200→110): with up to 64 tiles on
                    // one card, each one renders tiny — no need to decode
                    // full-size thumbnails for it.
                    (offset, await PhotoLibrarySource.shared.thumbnail(assetID: assetID, maxPixel: 110))
                }
            }
            var ordered = [UIImage?](repeating: nil, count: photoIDs.count)
            for await (offset, image) in group { ordered[offset] = image }
            return ordered
        }
    }
}

// MARK: - Add-photos source chooser

/// Simple, non-presenting picker sheet: two buttons, one for each source.
/// The caller (parent) does the actual presenting of the next sheet/picker
/// after this one dismisses, to keep sheet-chaining in one place.
struct AddPhotosChooserView: View {
    let projectName: String
    var onChooseGallery: () -> Void
    var onChooseFiles: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Spacer(minLength: 8)
                Text("Add photos to “\(projectName)”")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                sourceButton(
                    title: "From Photos Library",
                    detail: "Browse your albums, tap to pick photos",
                    icon: "photo.stack",
                    action: onChooseGallery
                )
                sourceButton(
                    title: "From a Card or Folder",
                    detail: "Plug in an SD card, or pick any folder",
                    icon: "sdcard",
                    action: onChooseFiles
                )
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(320)])
    }

    private func sourceButton(title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Guide (how it works)

/// The guide — reachable ONLY via the "?" toolbar button (and the empty
/// state's "How it works" link), never shown automatically.
struct GuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct GuideEntry {
        let icon: String
        let title: String
        let body: String
    }
    private let sections: [GuideEntry] = [
        GuideEntry(icon: "folder.badge.plus", title: "Projects gather your photos",
                body: "A project is a working set — the photos from one shoot or trip you want to cull together. Create one, then add photos to it from your Photos library or an SD card/folder. Nothing is copied when you add — Selecta just remembers which photos belong to the project."),
        GuideEntry(icon: "star.fill", title: "Rate as you go",
                body: "Open a photo and rate it: tap stars for 0–5, Pick to mark a keeper, Reject to mark it out, or tap a color dot to label it. Swipe up on a photo to bump the rating, swipe down to reject — no need to tap every time."),
        GuideEntry(icon: "square.grid.2x2", title: "Picks & Rejects",
                body: "Inside a project, the Picks and Rejects folders automatically show just the photos you've flagged that way — no extra organizing needed."),
        GuideEntry(icon: "square.and.arrow.up", title: "Export or share",
                body: "Export sends the real, untouched original files (RAW and/or JPEG) to a folder, with an XMP sidecar carrying your star rating and label for Lightroom. Share sends a photo straight to another app, like AirDrop or Lightroom mobile."),
        GuideEntry(icon: "sdcard", title: "Works with SD cards",
                body: "Plug in a card reader and pick the card's folder like any other source — Selecta pairs RAW+JPEG shots automatically and never modifies the originals."),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections.indices, id: \.self) { i in
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(sections[i].title, systemImage: sections[i].icon)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(sections[i].body)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Theme.surface)
                    .listRowSeparatorTint(Theme.hairline)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("How It Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Shared loading overlay

struct LoadingOverlay: View {
    let label: String

    var body: some View {
        ZStack {
            Theme.scrim.ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Theme.textSecondary)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
        }
    }
}
