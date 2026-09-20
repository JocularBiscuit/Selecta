import SwiftUI

/// Opens one project via the shared `Library` engine (same call as iOS'
/// `openProject`) and shows its photos in a keyboard-driven grid — the
/// Mac-native equivalent of GridScreen, built for mouse + keyboard instead
/// of touch.
struct MacProjectView: View {
    @Bindable var library: Library
    let project: ProjectRecord

    @State private var showFolderImporter = false

    var body: some View {
        Group {
            if library.isLoading {
                ProgressView("Opening project…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.isSelectingFromGallery {
                MacPickingView(library: library)
            } else if library.items.isEmpty {
                ContentUnavailableView(
                    "No Photos Yet",
                    systemImage: "photo.badge.plus",
                    description: Text("Add photos from a folder or SD card to start culling.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacGridView(library: library)
            }
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem {
                Button {
                    library.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!library.canUndo)
            }
            ToolbarItem {
                Menu {
                    Button("From Folder or SD Card…") {
                        showFolderImporter = true
                    }
                } label: {
                    Label("Add Photos", systemImage: "plus.rectangle.on.folder")
                }
            }
        }
        .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            library.beginAddingPhotos(to: project)
            library.openCard(pickedURL: url)
        }
        .task(id: project.persistentModelID) {
            library.openProject(project)
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
}
