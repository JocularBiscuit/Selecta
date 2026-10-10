import SwiftUI

/// Posting-order controls for a set of photos: give them numbers (1 = post
/// first), clear them, or close gaps. Used by the grid's batch bar (numbers
/// the selection in tap order) and the loupe (numbers the shot on screen).
///
/// Taking a number that's already used moves the older photo later, and
/// everything directly after it, so the sequence "adapts" — see
/// `Library.placePostOrder`. Only meaningful inside an open project, where
/// the numbers live.
struct PostOrderMenu<MenuLabel: View>: View {
    @Bindable var library: Library
    /// Photos to number, in the order they should receive consecutive numbers.
    let ids: [String]
    @ViewBuilder var label: () -> MenuLabel

    @State private var showAlert = false
    @State private var text = ""

    private var hasNumber: Bool {
        ids.contains { library.item(id: $0)?.postOrder != nil }
    }

    /// One photo that already has a number → edit that number. Otherwise
    /// continue after the highest number in use.
    private var suggestedStart: Int {
        if ids.count == 1, let current = library.item(id: ids[0])?.postOrder { return current }
        return library.nextFreePostOrder
    }

    var body: some View {
        Menu {
            Button {
                text = String(suggestedStart)
                showAlert = true
            } label: {
                Label("Set Number…", systemImage: "number")
            }
            if hasNumber {
                Button(role: .destructive) {
                    library.clearPostOrder(ids: Set(ids))
                    Haptics.tap()
                } label: {
                    Label(ids.count == 1 ? "Clear Number" : "Clear Numbers", systemImage: "minus.circle")
                }
            }
            Button {
                library.closePostOrderGaps()
                Haptics.tap()
            } label: {
                Label("Close Gaps (renumber 1…N)", systemImage: "arrow.up.and.down.text.horizontal")
            }
        } label: {
            label()
        }
        .disabled(ids.isEmpty || library.openedProject == nil)
        .alert("Posting order", isPresented: $showAlert) {
            TextField("Number", text: $text)
                .keyboardType(.numberPad)
            Button("Set") { apply() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(ids.count == 1
                 ? "Number for this photo. A photo already using it moves later, and so does everything right after it."
                 : "Number the \(ids.count) selected photos in the order you tapped them, starting here. Photos already using these numbers move later.")
        }
    }

    private func apply() {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)), number >= 1 else { return }
        library.placePostOrder(ids: ids, startingAt: number)
        Haptics.tap()
    }
}
