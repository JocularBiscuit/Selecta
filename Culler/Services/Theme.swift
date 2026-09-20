import SwiftUI

/// Design tokens — Lightroom/Bridge-inspired neutral dark chrome.
/// All views style themselves exclusively through these tokens so the app
/// stays visually coherent. The chrome is deliberately colorless so the
/// photos are the only colorful thing on screen. Plain `Color` values have
/// no platform dependency, so this is shared between the iOS and macOS apps.
enum Theme {
    // Surfaces
    static let bg = Color(white: 0.055)             // app background
    static let surface = Color(white: 0.105)        // bars & panels
    static let surfaceElevated = Color(white: 0.15) // menus, chips, cards
    static let cell = Color(white: 0.085)           // thumbnail placeholder
    static let scrim = Color.black.opacity(0.55)    // overlay backgrounds on photos
    static let hairline = Color.white.opacity(0.09) // 1px separators & strokes

    // Text
    static let textPrimary = Color(white: 0.92)
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.42)

    // Accents (used sparingly)
    static let accent = Color(red: 0.38, green: 0.64, blue: 1.0)  // selection, active filter
    static let star = Color(white: 0.95)                          // LR-style neutral stars
    static let pick = Color(red: 0.35, green: 0.78, blue: 0.45)
    static let reject = Color(red: 0.93, green: 0.35, blue: 0.35)
    static let rawBadge = Color(red: 1.0, green: 0.64, blue: 0.28)

    // Metrics
    static let radius: CGFloat = 8
    static let chipRadius: CGFloat = 6
}
