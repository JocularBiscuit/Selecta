import SwiftUI
import SwiftData
import MapKit

// MARK: - Finding locations

/// A photo with a known capture location.
struct LocatedPhoto: Identifiable {
    let item: CardItem
    let point: GeoPoint
    var id: String { item.id }
}

enum PhotoLocations {
    /// Capture locations for `items`, in their original order. Photos-library
    /// assets come from PhotoKit's index in batches (no download); card/folder
    /// files have their EXIF GPS read with ImageIO, a few at a time. Videos
    /// from a card are skipped (their location isn't in EXIF).
    static func locate(_ items: [CardItem]) async -> [LocatedPhoto] {
        var points: [String: GeoPoint] = [:]

        let assetPairs = items.compactMap { item in item.assetLocalID.map { (item.id, $0) } }
        if !assetPairs.isEmpty {
            let byAsset = await Task.detached(priority: .userInitiated) { () -> [String: GeoPoint] in
                var found: [String: GeoPoint] = [:]
                var index = 0
                while index < assetPairs.count {
                    let chunk = Array(assetPairs[index..<min(index + 500, assetPairs.count)])
                    index += chunk.count
                    found.merge(PhotoLibrarySource.shared.coordinates(for: chunk.map(\.1))) { a, _ in a }
                }
                return found
            }.value
            for (id, assetID) in assetPairs {
                if let point = byAsset[assetID] { points[id] = point }
            }
        }

        let files = items.compactMap { item -> (String, URL)? in
            guard item.assetLocalID == nil, item.kind != .video,
                  let url = item.jpegURL ?? item.rawURL else { return nil }
            return (item.id, url)
        }
        var next = 0
        while next < files.count {
            let chunk = files[next..<min(next + 8, files.count)]
            next += chunk.count
            await withTaskGroup(of: (String, GeoPoint?).self) { group in
                for (id, url) in chunk {
                    group.addTask { (id, await ThumbnailStore.metadata(for: url).coordinate) }
                }
                for await (id, point) in group {
                    if let point { points[id] = point }
                }
            }
        }

        return items.compactMap { item in points[item.id].map { LocatedPhoto(item: item, point: $0) } }
    }
}

/// A camera that shows every point with room to spare — MapKit's
/// `.automatic` fits pins edge to edge, cutting thumbnail pins in half. A
/// single point gets a neighborhood-sized view rather than street level.
func fittedCamera(_ points: [GeoPoint]) -> MapCameraPosition {
    guard let first = points.first else { return .automatic }
    if points.count == 1 {
        return .region(MKCoordinateRegion(center: first.clCoordinate,
                                          latitudinalMeters: 3000, longitudinalMeters: 3000))
    }
    let lats = points.map(\.latitude), lons = points.map(\.longitude)
    let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
    let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
    // The map is a tall, narrow phone view and MapKit fits a region by its
    // height, so a wide east–west spread falls off the sides unless the
    // vertical span grows to match: ~2.2 screen aspect, with Mercator's
    // cos(latitude) shrink of longitude.
    let lonSpan = (maxLon - minLon) * 1.6
    let latForWidth = lonSpan * 2.2 * cos(center.latitude * .pi / 180)
    let span = MKCoordinateSpan(
        latitudeDelta: min(170, max(0.02, (maxLat - minLat) * 1.6, latForWidth)),
        longitudeDelta: min(355, max(0.02, lonSpan))
    )
    return .region(MKCoordinateRegion(center: center, span: span))
}

extension GeoPoint {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Opens this spot in Apple Maps (leaves the app).
    var appleMapsURL: URL? {
        URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=Photo")
    }
}

// MARK: - One photo's location (Details sheet)

/// Small map with a pin, the coordinates, and an "Open in Maps" link.
/// Map tiles come from Apple and need a connection; without one the pin and
/// coordinates still show on an empty grid.
struct LocationMiniMap: View {
    let point: GeoPoint
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: point.clCoordinate,
                latitudinalMeters: 1500,
                longitudinalMeters: 1500
            ))) {
                Marker("", coordinate: point.clCoordinate)
                    .tint(Theme.accent)
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))

            HStack {
                Text(point.displayText)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    if let url = point.appleMapsURL { openURL(url) }
                } label: {
                    Label("Open in Maps", systemImage: "map")
                        .font(.caption.weight(.semibold))
                }
                .tint(Theme.accent)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - All of a project's photos on a map

/// Every located photo in `items` as a thumbnail pin. Tapping a pin hands
/// its id to `onSelect` (the loupe jumps there) and closes the map.
struct ProjectMapView: View {
    let title: String
    let items: [CardItem]
    var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var located: [LocatedPhoto]?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.surface, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .tint(Theme.accent)
                    }
                }
        }
        .preferredColorScheme(.dark)
        .task { located = await PhotoLocations.locate(items) }
    }

    @ViewBuilder
    private var content: some View {
        if let located {
            if located.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No location data")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("None of these \(items.count) photos has a geotag.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Map(initialPosition: fittedCamera(located.map(\.point))) {
                    ForEach(located) { photo in
                        Annotation("", coordinate: photo.point.clCoordinate) {
                            MapThumb(item: photo.item)
                                .onTapGesture {
                                    onSelect(photo.id)
                                    dismiss()
                                }
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    Text(verbatim: "\(located.count) of \(items.count) \(items.count == 1 ? "photo has" : "photos have") a location")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.surfaceElevated, in: Capsule())
                        .padding(.bottom, 16)
                        .allowsHitTesting(false)
                }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().tint(Theme.textSecondary)
                Text("Finding locations…")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// A pin that is the photo itself: small rounded thumbnail with a border.
private struct MapThumb: View {
    let item: CardItem
    var border: Color = .white
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.cell
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: border == .white ? 2 : 3))
        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        .task(id: item.id) {
            image = await ThumbnailStore.shared.thumbnail(for: item, maxPixel: 120)
        }
    }
}

// MARK: - Every project on one map (project overview)

/// All projects' located photos on one map, color-coded by project, with a
/// chip row to show/hide projects. Covers Photos-library members (located
/// straight from PhotoKit); photos that live on a card/folder need that card
/// mounted, so they're counted in a note instead of pinned. Tapping a pin
/// opens its project.
struct AllProjectsMapView: View {
    let projects: [ProjectRecord]
    var onOpenProject: (ProjectRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pins: [ProjectPin]?
    @State private var cardOnlyCount = 0
    @State private var hidden: Set<PersistentIdentifierKey> = []

    /// Distinct, dark-theme-friendly project colors, cycled by position.
    static let palette: [Color] = [
        Color(red: 0.38, green: 0.64, blue: 1.00),  // blue
        Color(red: 1.00, green: 0.62, blue: 0.26),  // orange
        Color(red: 0.36, green: 0.84, blue: 0.52),  // green
        Color(red: 0.95, green: 0.38, blue: 0.55),  // pink
        Color(red: 0.72, green: 0.52, blue: 1.00),  // violet
        Color(red: 0.98, green: 0.86, blue: 0.30),  // yellow
        Color(red: 0.30, green: 0.85, blue: 0.88),  // teal
        Color(red: 0.92, green: 0.40, blue: 0.32),  // red
    ]

    struct ProjectPin: Identifiable {
        let id: String           // project key + photo id (a photo can be in several projects)
        let projectKey: PersistentIdentifierKey
        let item: CardItem
        let point: GeoPoint
    }

    /// Hashable stand-in for a project's identity.
    typealias PersistentIdentifierKey = String

    private func key(_ project: ProjectRecord) -> PersistentIdentifierKey {
        "\(project.persistentModelID.hashValue)|\(project.name)"
    }

    private func color(for projectKey: PersistentIdentifierKey) -> Color {
        let index = projects.firstIndex { key($0) == projectKey } ?? 0
        return Self.palette[index % Self.palette.count]
    }

    private var visiblePins: [ProjectPin] {
        (pins ?? []).filter { !hidden.contains($0.projectKey) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chipBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.bg)
            .navigationTitle("All Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(Theme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    // MARK: Chips (filter)

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "All", color: nil, active: hidden.isEmpty) {
                    hidden = []
                }
                ForEach(projects, id: \.persistentModelID) { project in
                    let k = key(project)
                    let count = (pins ?? []).filter { $0.projectKey == k }.count
                    chip(title: pins == nil ? project.name : "\(project.name) \(count)",
                         color: color(for: k),
                         active: !hidden.contains(k)) {
                        if hidden.isEmpty {
                            // From "All", tapping a project shows just that one.
                            hidden = Set(projects.map(key)).subtracting([k])
                        } else if hidden.contains(k) {
                            hidden.remove(k)
                        } else {
                            hidden.insert(k)
                            if hidden.count == projects.count { hidden = [] }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }

    private func chip(title: String, color: Color?, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color {
                    Circle().fill(color).frame(width: 9, height: 9)
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(active ? Theme.surfaceElevated : Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(active ? (color ?? Theme.accent) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Map

    @ViewBuilder
    private var content: some View {
        if let pins {
            if pins.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No location data")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("None of your projects' photos has a geotag.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                let shown = visiblePins
                // Thumbnails for a manageable number of pins; colored dots
                // beyond that, so a big library stays smooth.
                let useThumbs = shown.count <= 150
                Map(initialPosition: fittedCamera(shown.map(\.point))) {
                    ForEach(shown) { pin in
                        Annotation("", coordinate: pin.point.clCoordinate) {
                            Group {
                                if useThumbs {
                                    MapThumb(item: pin.item, border: color(for: pin.projectKey))
                                } else {
                                    Circle()
                                        .fill(color(for: pin.projectKey))
                                        .frame(width: 14, height: 14)
                                        .overlay(Circle().stroke(.white, lineWidth: 2))
                                }
                            }
                            .onTapGesture { open(pin.projectKey) }
                        }
                    }
                }
                .id(hidden)   // refit the camera to whatever is shown
                .overlay(alignment: .bottom) {
                    VStack(spacing: 4) {
                        Text(verbatim: "\(shown.count) \(shown.count == 1 ? "photo" : "photos") with a location · tap one to open its project")
                        if cardOnlyCount > 0 {
                            Text(verbatim: "\(cardOnlyCount) card/folder \(cardOnlyCount == 1 ? "photo isn't" : "photos aren't") shown here — open their project to map them")
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .allowsHitTesting(false)
                }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().tint(Theme.textSecondary)
                Text("Finding locations…")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func open(_ projectKey: PersistentIdentifierKey) {
        guard let project = projects.first(where: { key($0) == projectKey }) else { return }
        dismiss()
        onOpenProject(project)
    }

    // MARK: Loading

    private func load() async {
        let prefix = "photoslib|"
        var assetIDsByProject: [(PersistentIdentifierKey, [String])] = []
        var cardOnly = 0
        for project in projects {
            let photoIDs = project.itemIDs.filter { $0.hasPrefix(prefix) }
            cardOnly += project.itemIDs.count - photoIDs.count
            assetIDsByProject.append((key(project), photoIDs.map { String($0.dropFirst(prefix.count)) }))
        }
        let allAssetIDs = Array(Set(assetIDsByProject.flatMap(\.1)))

        // Locations first (cheap, batched), then items only for located ones.
        let points = await Task.detached(priority: .userInitiated) { () -> [String: GeoPoint] in
            var found: [String: GeoPoint] = [:]
            var index = 0
            while index < allAssetIDs.count {
                let chunk = Array(allAssetIDs[index..<min(index + 500, allAssetIDs.count)])
                index += chunk.count
                found.merge(PhotoLibrarySource.shared.coordinates(for: chunk)) { a, _ in a }
            }
            return found
        }.value
        let items = await PhotoLibrarySource.shared.loadAssets(lowercasedLocalIDs: Array(points.keys))
        var itemByAsset: [String: CardItem] = [:]
        for item in items { itemByAsset[String(item.id.dropFirst(prefix.count))] = item }

        var result: [ProjectPin] = []
        for (projectKey, assetIDs) in assetIDsByProject {
            for assetID in assetIDs {
                guard let point = points[assetID], let item = itemByAsset[assetID] else { continue }
                result.append(ProjectPin(id: projectKey + "#" + assetID, projectKey: projectKey, item: item, point: point))
            }
        }
        cardOnlyCount = cardOnly
        pins = result
    }
}
