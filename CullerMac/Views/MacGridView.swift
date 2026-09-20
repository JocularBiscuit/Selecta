import SwiftUI

/// The culling grid, Mac-native: mouse click to focus/select, keyboard to
/// rate and flag — the equivalent of iOS' GridScreen, built for a pointer
/// and a keyboard instead of touch (no long-press, no drag-to-select yet).
struct MacGridView: View {
    @Bindable var library: Library
    @FocusState private var isFocused: Bool
    @State private var focusedIndex: Int = 0

    private var items: [CardItem] { library.filteredItems }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 3)], spacing: 3) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        MacThumbCell(item: item, isFocused: index == focusedIndex)
                            .id(item.id)
                            .onTapGesture { focusedIndex = index }
                    }
                }
                .padding(3)
            }
            .onChange(of: focusedIndex) { _, newValue in
                guard items.indices.contains(newValue) else { return }
                withAnimation(nil) { proxy.scrollTo(items[newValue].id, anchor: nil) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            handleArrow(press.key)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "012345pPxX")) { press in
            handleCharacter(press.characters)
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBar
        }
    }

    private func handleArrow(_ key: KeyEquivalent) {
        guard !items.isEmpty else { return }
        // Roughly matches the adaptive grid's typical column count at this
        // window width — good enough for up/down without measuring layout.
        let columns = 5
        switch key {
        case .leftArrow: focusedIndex = max(0, focusedIndex - 1)
        case .rightArrow: focusedIndex = min(items.count - 1, focusedIndex + 1)
        case .upArrow: focusedIndex = max(0, focusedIndex - columns)
        case .downArrow: focusedIndex = min(items.count - 1, focusedIndex + columns)
        default: break
        }
    }

    private func handleCharacter(_ characters: String) {
        guard items.indices.contains(focusedIndex) else { return }
        let id = items[focusedIndex].id
        switch characters {
        case "0", "1", "2", "3", "4", "5":
            if let stars = Int(characters) { library.setRating(stars, for: id) }
        case "p", "P":
            library.setFlag(.pick, for: id)
        case "x", "X":
            library.setFlag(.reject, for: id)
        default: break
        }
    }

    private var statusBar: some View {
        HStack {
            Text("\(items.count) shots")
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("Arrows to move · 0–5 to rate · P pick · X reject · ⌘Z undo")
                .foregroundStyle(Theme.textTertiary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface)
    }
}
