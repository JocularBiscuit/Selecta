import UIKit

/// Central haptics — honors the Settings toggle. iOS-only (no Mac
/// equivalent yet); the shared color tokens live in Services/Theme.swift.
enum Haptics {
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.hapticsEnabled) == nil
            ? true
            : UserDefaults.standard.bool(forKey: SettingsKeys.hapticsEnabled)
    }
    static func tap() {
        if enabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }
    static func rate() {
        if enabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }
}
