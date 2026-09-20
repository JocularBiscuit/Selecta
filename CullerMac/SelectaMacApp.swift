import SwiftUI
import SwiftData

@main
struct SelectaMacApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: AssetRecord.self, CardSession.self, ProjectRecord.self)
        } catch {
            // If the store is corrupted, start fresh rather than crash-looping.
            // Ratings also live in XMP sidecars on the card, so nothing is truly lost.
            let fresh = ModelConfiguration(isStoredInMemoryOnly: false)
            container = try! ModelContainer(
                for: AssetRecord.self, CardSession.self, ProjectRecord.self,
                configurations: fresh
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 560)
        }
        .modelContainer(container)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
