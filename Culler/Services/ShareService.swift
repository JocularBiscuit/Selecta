import SwiftUI
import UIKit

/// Send the actual original file(s) to other apps via the iOS share sheet —
/// "Open in Lightroom" for a RAW, AirDrop, Files, Messages, etc.
///
/// Originals are never re-encoded: file-based shots share their URLs directly;
/// Photos-library assets have their original resource(s) written to a temp
/// folder (RAW preferred for Lightroom) and shared from there.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum ShareFileChoice { case raw, jpeg, both }

/// Drives the share flow: decides whether to ask RAW/JPEG/Both, prepares the
/// file URLs (downloading iCloud originals if needed), and hands them to the
/// share sheet. Temp files are cleaned up when the sheet closes.
@MainActor
@Observable
final class ShareCoordinator {
    var isPreparing = false
    /// Non-nil → show the RAW / JPEG / Both chooser for these items.
    var pendingChoiceItems: [CardItem]?
    /// Non-nil → present the share sheet with these URLs.
    var shareURLs: [URL]?
    var errorMessage: String?

    private var tempDir: URL?

    /// Entry point. If any item has a RAW, ask which file(s) to share;
    /// otherwise share the photo/video directly.
    func begin(_ items: [CardItem]) {
        guard !items.isEmpty, !isPreparing else { return }
        isPreparing = true
        Task {
            let hasRaw = await Self.anyHasRaw(items)
            isPreparing = false
            if hasRaw {
                pendingChoiceItems = items
            } else {
                await produce(items: items, choice: .jpeg)
            }
        }
    }

    func choose(_ choice: ShareFileChoice) {
        guard let items = pendingChoiceItems else { return }
        pendingChoiceItems = nil
        isPreparing = true
        Task { await produce(items: items, choice: choice) }
    }

    func cancelChoice() { pendingChoiceItems = nil }

    /// Called when the share sheet closes — clean up temp originals.
    func finish() {
        shareURLs = nil
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
            tempDir = nil
        }
    }

    // MARK: Building the file list

    private func produce(items: [CardItem], choice: ShareFileChoice) async {
        var urls: [URL] = []
        for item in items {
            if let assetID = item.assetLocalID {
                let dir = ensureTempDir()
                let result = await PhotoLibrarySource.shared.exportResources(
                    assetID: assetID,
                    to: dir,
                    includeRAW: choice != .jpeg,
                    includeNonRAW: choice != .raw
                )
                urls += result.written
                // If the RAW-only request produced nothing (e.g. no RAW after
                // all), fall back to the non-RAW original so sharing isn't empty.
                if result.written.isEmpty, choice == .raw {
                    let fallback = await PhotoLibrarySource.shared.exportResources(
                        assetID: assetID, to: dir, includeRAW: false, includeNonRAW: true
                    )
                    urls += fallback.written
                }
            } else {
                urls += fileURLs(for: item, choice: choice)
            }
        }
        isPreparing = false
        if urls.isEmpty {
            errorMessage = "Couldn't prepare the file to share."
        } else {
            shareURLs = urls
        }
    }

    private func fileURLs(for item: CardItem, choice: ShareFileChoice) -> [URL] {
        switch choice {
        case .raw:
            return [item.rawURL ?? item.jpegURL].compactMap { $0 }
        case .jpeg:
            return [item.jpegURL ?? item.rawURL].compactMap { $0 }
        case .both:
            if item.rawURL == nil && item.jpegURL == nil, let video = item.videoURL { return [video] }
            return [item.rawURL, item.jpegURL].compactMap { $0 }
        }
    }

    private func ensureTempDir() -> URL {
        if let dir = tempDir { return dir }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectaShare-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        return dir
    }

    static func anyHasRaw(_ items: [CardItem]) async -> Bool {
        for item in items {
            if item.rawURL != nil { return true }
            if let id = item.assetLocalID, await PhotoLibrarySource.shared.assetHasRaw(id) { return true }
        }
        return false
    }
}

/// A reusable modifier that presents the RAW/JPEG/Both chooser, the share
/// sheet, and an error alert for a ShareCoordinator. Attach to any view that
/// owns a coordinator and calls `coordinator.begin(...)`.
struct ShareFlow: ViewModifier {
    @Bindable var coordinator: ShareCoordinator

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Share which file?",
                isPresented: Binding(
                    get: { coordinator.pendingChoiceItems != nil },
                    set: { if !$0 { coordinator.cancelChoice() } }
                ),
                titleVisibility: .visible
            ) {
                Button("RAW (for Lightroom)") { coordinator.choose(.raw) }
                Button("JPEG / Photo") { coordinator.choose(.jpeg) }
                Button("Both") { coordinator.choose(.both) }
                Button("Cancel", role: .cancel) { coordinator.cancelChoice() }
            }
            .sheet(isPresented: Binding(
                get: { coordinator.shareURLs != nil },
                set: { if !$0 { coordinator.finish() } }
            )) {
                if let urls = coordinator.shareURLs {
                    ShareSheet(items: urls) { coordinator.finish() }
                        .ignoresSafeArea()
                }
            }
            .alert("Share", isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { if !$0 { coordinator.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { coordinator.errorMessage = nil }
            } message: {
                Text(coordinator.errorMessage ?? "")
            }
    }
}

extension View {
    func shareFlow(_ coordinator: ShareCoordinator) -> some View {
        modifier(ShareFlow(coordinator: coordinator))
    }
}

// MARK: - Create Album (a normal, non-shared Photos album from a selection)

/// Drives "Create Album…", offered right next to "Share…": name a new
/// album, then `PhotosSaver.createAlbum` copies/references the given items
/// into it directly — no folder export step involved.
@MainActor
@Observable
final class AlbumCreationCoordinator {
    var isWorking = false
    /// Non-nil → show the "name this album" prompt for these items.
    var pendingItems: [CardItem]?
    var resultMessage: String?

    func begin(_ items: [CardItem]) {
        guard !items.isEmpty, !isWorking else { return }
        pendingItems = items
    }

    func cancel() { pendingItems = nil }

    func create(named name: String) {
        guard let items = pendingItems else { return }
        pendingItems = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        Task {
            do {
                let (added, failed) = try await PhotosSaver.createAlbum(named: trimmed, from: items)
                isWorking = false
                resultMessage = failed == 0
                    ? "Added \(added) photo\(added == 1 ? "" : "s") to “\(trimmed)”."
                    : "Added \(added) to “\(trimmed)” — \(failed) couldn't be added."
            } catch {
                isWorking = false
                resultMessage = "Couldn't create the album: \(error.localizedDescription)"
            }
        }
    }
}

struct AlbumCreationFlow: ViewModifier {
    @Bindable var coordinator: AlbumCreationCoordinator
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("New Album", isPresented: Binding(
                get: { coordinator.pendingItems != nil },
                set: { if !$0 { coordinator.cancel() } }
            )) {
                TextField("Album name", text: $name)
                Button("Create") {
                    coordinator.create(named: name)
                    name = ""
                }
                Button("Cancel", role: .cancel) {
                    coordinator.cancel()
                    name = ""
                }
            } message: {
                let count = coordinator.pendingItems?.count ?? 0
                Text("Creates a new album in your Photos library (not a Shared Album) with the selected \(count) photo\(count == 1 ? "" : "s").")
            }
            .alert("Create Album", isPresented: Binding(
                get: { coordinator.resultMessage != nil },
                set: { if !$0 { coordinator.resultMessage = nil } }
            )) {
                Button("OK", role: .cancel) { coordinator.resultMessage = nil }
            } message: {
                Text(coordinator.resultMessage ?? "")
            }
    }
}

extension View {
    func albumCreationFlow(_ coordinator: AlbumCreationCoordinator) -> some View {
        modifier(AlbumCreationFlow(coordinator: coordinator))
    }
}
