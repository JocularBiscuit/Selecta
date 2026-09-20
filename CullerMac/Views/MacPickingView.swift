import SwiftUI

/// Picking photos from a folder/SD card to add to a project — the Mac
/// equivalent of iOS' SourceSelectBar + gallery-select grid. Click toggles
/// selection; no drag-to-select or long-press yet (mouse click-drag to
/// paint-select is a natural fit here later).
struct MacPickingView: View {
    @Bindable var library: Library

    private var items: [CardItem] { library.filteredItems }
    private var count: Int { library.selection.count }

    var body: some View {
        Group {
            if library.items.isEmpty {
                ContentUnavailableView("This folder is empty", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 3)], spacing: 3) {
                        ForEach(items) { item in
                            MacPickCell(item: item, isSelected: library.selection.contains(item.id))
                                .onTapGesture { toggle(item.id) }
                        }
                    }
                    .padding(3)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
    }

    private func toggle(_ id: String) {
        if library.selection.contains(id) {
            library.selection.remove(id)
        } else {
            library.selection.insert(id)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("Back") { library.cancelPicking() }

            Text(count == 0 ? "Click photos to select" : "\(count) selected")
                .foregroundStyle(count == 0 ? Theme.textSecondary : Theme.textPrimary)

            Spacer()

            if let target = library.targetProject {
                Button("Add \(count) to “\(target.name)”") {
                    library.addSelectionToProject(target)
                    library.openProject(target)
                }
                .disabled(count == 0)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }
}

private struct MacPickCell: View {
    let item: CardItem
    let isSelected: Bool

    @State private var image: PlatformImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(Theme.cell)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if item.kind == .video {
                Image(systemName: "video.fill").foregroundStyle(Theme.textTertiary)
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.textTertiary)
            }
            if isSelected {
                Theme.accent.opacity(0.15)
            }
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                .padding(5)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay(
            Rectangle().strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .task(id: item.id) {
            image = await ThumbnailStore.shared.thumbnail(for: item, maxPixel: 400)
        }
    }
}
