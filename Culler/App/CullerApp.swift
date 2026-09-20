import SwiftUI
import SwiftData

@main
struct CullerApp: App {
    let container: ModelContainer

    @AppStorage(SettingsKeys.followSystemAppearance) private var followSystemAppearance = false

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
            RootView()
                .preferredColorScheme(followSystemAppearance ? nil : .dark)
        }
        .modelContainer(container)
    }
}
