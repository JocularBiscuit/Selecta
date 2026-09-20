import Foundation
import Photos

/// Browse the Photos library in place. The album browser lists the user's
/// folders and albums (hierarchically); the primary tap opens an album
/// IN PLACE via PhotoLibrarySource — nothing is ever copied into the app.
/// Picking photos there gathers them into a project, where the user rates.
///
/// Pure PhotoKit fetch logic, no UI — shared between the iOS and macOS
/// album browsers (see PhotosImport.swift for the iOS-specific sheet UI).

// MARK: - Album/folder browsing (PhotoKit listing helpers)

/// Namespace for the PhotoKit fetches that back the album browser. No copying
/// or import happens anywhere — albums are opened in place.
enum PhotosImportCoordinator {

    // MARK: Album listing

    struct AlbumEntry: Identifiable {
        let id: String
        let title: String
        let count: Int
        let collection: PHAssetCollection
    }

    // MARK: Hierarchical browsing (folders + albums)

    /// One row in the album browser: a folder to drill into, or an album.
    enum BrowseEntry: Identifiable {
        case folder(id: String, title: String, list: PHCollectionList, subCount: Int)
        case album(AlbumEntry)
        var id: String {
            switch self {
            case .folder(let id, _, _, _): return "folder|" + id
            case .album(let a): return "album|" + a.id
            }
        }
    }

    private nonisolated static func albumEntry(for collection: PHAssetCollection) -> AlbumEntry? {
        let count = PHAsset.fetchAssets(in: collection, options: nil).count
        guard count > 0 else { return nil }
        return AlbumEntry(
            id: collection.localIdentifier,
            title: collection.localizedTitle ?? "Untitled",
            count: count,
            collection: collection
        )
    }

    private nonisolated static func mapCollections(_ result: PHFetchResult<PHCollection>) -> [BrowseEntry] {
        var entries: [BrowseEntry] = []
        result.enumerateObjects { collection, _, _ in
            if let album = collection as? PHAssetCollection {
                if let a = albumEntry(for: album) { entries.append(.album(a)) }
            } else if let folder = collection as? PHCollectionList {
                let subCount = PHCollection.fetchCollections(in: folder, options: nil).count
                guard subCount > 0 else { return }
                entries.append(.folder(
                    id: folder.localIdentifier,
                    title: folder.localizedTitle ?? "Folder",
                    list: folder,
                    subCount: subCount
                ))
            }
        }
        return entries
    }

    /// Top level: Recents + Favorites pinned, then the user's top-level
    /// folders and albums (mirrors the Photos app Albums tab).
    nonisolated static func fetchTopLevel() -> [BrowseEntry] {
        var entries: [BrowseEntry] = []
        for subtype in [PHAssetCollectionSubtype.smartAlbumUserLibrary, .smartAlbumFavorites] {
            PHAssetCollection
                .fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
                .enumerateObjects { collection, _, _ in
                    if let a = albumEntry(for: collection) { entries.append(.album(a)) }
                }
        }
        entries += mapCollections(PHCollectionList.fetchTopLevelUserCollections(with: nil))
        return entries
    }

    /// Contents of one folder (its sub-folders and albums).
    nonisolated static func fetchFolder(_ list: PHCollectionList) -> [BrowseEntry] {
        mapCollections(PHCollection.fetchCollections(in: list, options: nil))
    }

    private nonisolated static func mediaPredicate() -> NSPredicate {
        NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
    }

    /// A handful of representative assets for a folder's cover-collage
    /// preview: the most recent photos from its direct child albums, or —
    /// if it has none directly (a folder that only contains sub-folders) —
    /// descending into those sub-folders (depth-limited) until enough are
    /// found. Read-only PHCollection/PHAsset enumeration, no image data.
    nonisolated static func folderCoverAssetIDs(_ list: PHCollectionList, limit: Int = 6) -> [String] {
        var ids: [String] = []

        func collectAlbumAssets(_ album: PHAssetCollection) {
            guard ids.count < limit else { return }
            let options = PHFetchOptions()
            options.predicate = mediaPredicate()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = limit - ids.count
            PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
                ids.append(asset.localIdentifier)
            }
        }

        func visit(_ folder: PHCollectionList, depth: Int) {
            guard ids.count < limit, depth <= 3 else { return }
            var subFolders: [PHCollectionList] = []
            PHCollection.fetchCollections(in: folder, options: nil).enumerateObjects { collection, _, _ in
                guard ids.count < limit else { return }
                if let album = collection as? PHAssetCollection {
                    collectAlbumAssets(album)
                } else if let sub = collection as? PHCollectionList {
                    subFolders.append(sub)
                }
            }
            for sub in subFolders where ids.count < limit {
                visit(sub, depth: depth + 1)
            }
        }

        visit(list, depth: 0)
        return ids
    }
}
