import SwiftUI

/// App settings, grouped by workflow: Appearance → Culling → Export →
/// Storage → About. Neutral dark chrome matching the rest of the app.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    // Appearance
    @AppStorage(SettingsKeys.followSystemAppearance) private var followSystemAppearance = false
    @AppStorage(SettingsKeys.loupeBlackBackground) private var loupeBlackBackground = true

    // Culling
    @AppStorage(SettingsKeys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(SettingsKeys.showFilenames) private var showFilenames = false

    // Export
    @AppStorage(SettingsKeys.exportMinStars) private var exportMinStars = 3
    @AppStorage(SettingsKeys.exportIncludePicks) private var exportIncludePicks = true
    @AppStorage(SettingsKeys.writeSidecarsToCard) private var writeSidecarsToCard = true
    @AppStorage(SettingsKeys.sidecarIncludesExtension) private var sidecarIncludesExtension = false
    @AppStorage(SettingsKeys.exportDestBookmark) private var exportDestBookmark = Data()

    @State private var cacheSize: Int64 = 0
    @State private var rememberedFolderName: String?

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                cullingSection
                exportSection
                storageSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .tint(Theme.accent)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .task {
                cacheSize = ThumbnailStore.shared.cacheSizeBytes()
                resolveRememberedFolder()
            }
        }
    }

    // MARK: Sections

    private var appearanceSection: some View {
        Section {
            Toggle("Follow system appearance", isOn: $followSystemAppearance)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Toggle("Black loupe background", isOn: $loupeBlackBackground)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
        } header: {
            sectionHeader("Appearance")
        } footer: {
            Text("Off keeps Culler always dark — the standard for photo review. The loupe can use pure black behind photos for maximum contrast.")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .listRowBackground(Theme.surface)
    }

    private var cullingSection: some View {
        Section {
            Toggle("Haptic feedback", isOn: $hapticsEnabled)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Toggle("Show filenames in grid", isOn: $showFilenames)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
        } header: {
            sectionHeader("Culling")
        }
        .listRowBackground(Theme.surface)
    }

    private var exportSection: some View {
        Section {
            Stepper(value: $exportMinStars, in: 0...5) {
                HStack {
                    Text("Keepers: min. rating")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(exportMinStars == 0 ? "any" : "★\(exportMinStars)+")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Toggle("Keepers include flagged picks", isOn: $exportIncludePicks)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)

            Toggle("Write sidecars on the card", isOn: $writeSidecarsToCard)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Picker("Sidecar naming", selection: $sidecarIncludesExtension) {
                Text("DSC01234.xmp (Adobe default)").tag(false)
                Text("DSC01234.ARW.xmp").tag(true)
            }
            .pickerStyle(.inline)
            .font(.subheadline)
            .foregroundStyle(Theme.textPrimary)

            if !exportDestBookmark.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Custom export folder")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        Text(rememberedFolderName ?? "Currently unavailable")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Forget") {
                        exportDestBookmark = Data()
                        rememberedFolderName = nil
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.reject)
                }
                .frame(minHeight: 44)
            }
        } header: {
            sectionHeader("Export")
        } footer: {
            Text("Sidecars carry star ratings and color labels into Lightroom Classic and Bridge. Pick/reject flags aren't part of standard XMP and stay inside Culler — use them to drive the export selection. Lightroom mobile's sidecar support is inconsistent.")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .listRowBackground(Theme.surface)
    }

    private var storageSection: some View {
        Section {
            HStack {
                Text("Thumbnail cache")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Button("Clear cache") {
                ThumbnailStore.shared.clearCache()
                cacheSize = ThumbnailStore.shared.cacheSizeBytes()
            }
            .font(.subheadline)
            .foregroundStyle(Theme.reject)
        } header: {
            sectionHeader("Storage")
        } footer: {
            Text("Thumbnails are cached on this iPhone so reopening a card is instant. Clearing is always safe — nothing on your card is ever touched.")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .listRowBackground(Theme.surface)
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(appVersion)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        } header: {
            sectionHeader("About")
        } footer: {
            Text("Selecta never modifies, re-encodes, or deletes files on your card. Exports are byte-for-byte copies. Requires iOS 17; see the README for signing and deployment-target notes.")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Helpers

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func resolveRememberedFolder() {
        guard !exportDestBookmark.isEmpty else {
            rememberedFolderName = nil
            return
        }
        var stale = false
        rememberedFolderName = (try? URL(
            resolvingBookmarkData: exportDestBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ))?.lastPathComponent
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.textTertiary)
    }
}
