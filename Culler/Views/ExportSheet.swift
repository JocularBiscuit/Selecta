import SwiftUI
import UniformTypeIdentifiers

/// Export flow: destination first, then scope → files → options → go.
/// Styled like a desktop photo tool's export dialog: neutral dark chrome,
/// dense rows, hairline strokes, monospaced counts.
struct ExportSheet: View {
    @Bindable var library: Library
    @Environment(\.dismiss) private var dismiss

    /// When non-nil the sheet is preset to export exactly these items
    /// (e.g. the single photo open in the loupe); other scopes stay available.
    let fixedItems: [CardItem]?

    @State private var manager = ExportManager()

    enum Scope: String, CaseIterable, Identifiable {
        case fixed = "These photos"
        case selection = "Selected"
        case filtered = "Current filter"
        case keepers = "Keepers rule"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .keepers

    init(library: Library, fixedItems: [CardItem]? = nil, initialScope: Scope? = nil) {
        self.library = library
        self.fixedItems = fixedItems
        if fixedItems != nil {
            _scope = State(initialValue: .fixed)
        } else if let initialScope {
            _scope = State(initialValue: initialScope)
        }
    }
    @State private var fileChoice: ExportManager.FileChoice = .both
    @State private var useCustomDestination = false
    @State private var customDestination: URL?
    @State private var showDestinationPicker = false
    @State private var writeSidecars = true
    @State private var addToPhotos = false
    @State private var albumName = "Selecta Picks"
    @State private var subfolderName = Self.defaultSubfolderName()

    @AppStorage(SettingsKeys.exportMinStars) private var keeperMinStars = 3
    @AppStorage(SettingsKeys.exportIncludePicks) private var keeperIncludePicks = true
    @AppStorage(SettingsKeys.sidecarIncludesExtension) private var sidecarIncludesExtension = false
    @AppStorage(SettingsKeys.exportDestBookmark) private var exportDestBookmark = Data()

    private var itemsToExport: [CardItem] {
        switch scope {
        case .fixed: return fixedItems ?? []
        case .selection: return library.items.filter { library.selection.contains($0.id) }
        case .filtered: return library.filteredItems
        case .keepers: return library.keepers(minStars: keeperMinStars, includePicks: keeperIncludePicks)
        }
    }

    private var canExport: Bool {
        !itemsToExport.isEmpty && !(useCustomDestination && customDestination == nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch manager.phase {
                case .idle:
                    form
                case .running:
                    progressView
                case .done, .failed:
                    resultView
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if manager.phase == .idle {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .interactiveDismissDisabled(manager.phase == .running)
        .fileImporter(isPresented: $showDestinationPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                rememberCustomDestination(url)
            }
        }
        .onAppear(perform: restoreCustomDestination)
    }

    // MARK: Form

    private var form: some View {
        Form {
            destinationSection
            whatSection
            filesSection
            optionsSection
            exportButtonSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .tint(Theme.accent)
    }

    private var destinationSection: some View {
        Section {
            destinationChoiceRow(
                title: "Selecta folder",
                detail: "Visible in Files app: On My iPhone → Culler → Exports",
                selected: !useCustomDestination
            ) { useCustomDestination = false }

            destinationChoiceRow(
                title: "Custom folder",
                detail: customDestination?.lastPathComponent ?? "No folder chosen yet",
                selected: useCustomDestination
            ) { useCustomDestination = true }

            if useCustomDestination {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Text(customDestination?.lastPathComponent ?? "No folder chosen")
                        .font(.subheadline)
                        .foregroundStyle(customDestination == nil ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Button("Change…") { showDestinationPicker = true }
                        .font(.subheadline)
                        .foregroundStyle(Theme.accent)
                }
                .frame(minHeight: 44)
            }

            HStack {
                Text("Subfolder")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                TextField("Subfolder name", text: $subfolderName)
                    .font(.subheadline)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Theme.textPrimary)
                    .autocorrectionDisabled()
            }
            .frame(minHeight: 44)
        } header: {
            sectionHeader("Destination")
        } footer: {
            Text("Files are copied into this subfolder inside the chosen destination.")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .listRowBackground(Theme.surface)
    }

    private var whatSection: some View {
        Section {
            Picker("Items", selection: $scope) {
                if let fixed = fixedItems {
                    Text(fixed.count == 1 ? "This photo" : "These \(fixed.count) photos")
                        .tag(Scope.fixed)
                }
                Text("Selected (\(library.selection.count))").tag(Scope.selection)
                Text("Current filter (\(library.filteredItems.count))").tag(Scope.filtered)
                Text("Keepers rule").tag(Scope.keepers)
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textPrimary)

            if scope == .keepers {
                Stepper(value: $keeperMinStars, in: 0...5) {
                    HStack {
                        Text("Min. rating")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(keeperMinStars == 0 ? "any" : "★\(keeperMinStars)+")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Toggle("Include flagged picks", isOn: $keeperIncludePicks)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            }

            HStack {
                Text("Will export")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(itemsToExport.count) shots")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
        } header: {
            sectionHeader("What")
        }
        .listRowBackground(Theme.surface)
    }

    private var filesSection: some View {
        Section {
            Picker("Copy", selection: $fileChoice) {
                ForEach(ExportManager.FileChoice.allCases) { c in
                    Text(c.rawValue).tag(c)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            sectionHeader("Files")
        } footer: {
            Text("Originals are copied byte-for-byte — never re-encoded, never renamed (except to avoid overwriting).")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .listRowBackground(Theme.surface)
    }

    private var optionsSection: some View {
        Section {
            Toggle("Write XMP sidecars (ratings for Lightroom)", isOn: $writeSidecars)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Toggle("Also add to Photos album", isOn: $addToPhotos)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            if addToPhotos {
                TextField("Album name", text: $albumName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            }
        } header: {
            sectionHeader("Options")
        } footer: {
            if addToPhotos {
                Text("JPEGs are added when available (RAW support in Photos varies). The folder export is the reliable Lightroom path.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .listRowBackground(Theme.surface)
    }

    private var exportButtonSection: some View {
        Section {
            Button(action: startExport) {
                Text("Export \(itemsToExport.count) shots")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(canExport ? Theme.textPrimary : Theme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExport)
            .listRowInsets(EdgeInsets())
            .listRowBackground(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            )
        }
    }

    private func destinationChoiceRow(
        title: String,
        detail: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.textTertiary)
    }

    // MARK: Destination persistence

    /// Compact timestamped default, computed once per sheet presentation.
    private static func defaultSubfolderName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Export " + formatter.string(from: Date())
    }

    /// Persist the picked folder as a security-scoped bookmark so it survives
    /// app relaunches. The scope itself is re-acquired at export time.
    private func rememberCustomDestination(_ url: URL) {
        customDestination = url
        useCustomDestination = true
        let accessing = url.startAccessingSecurityScopedResource()
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            exportDestBookmark = bookmark
        }
        if accessing { url.stopAccessingSecurityScopedResource() }
    }

    /// Resolve the persisted bookmark (if any) so the sheet shows the
    /// remembered folder name and can reuse it without re-picking.
    private func restoreCustomDestination() {
        guard customDestination == nil, !exportDestBookmark.isEmpty else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: exportDestBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }
        customDestination = url
        if stale {
            let accessing = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                exportDestBookmark = fresh
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
    }

    private func startExport() {
        let destination: URL
        let scoped: Bool
        if useCustomDestination, let custom = customDestination {
            destination = custom
            scoped = true
        } else {
            destination = ExportManager.appExportsRoot()
            scoped = false
        }
        let trimmed = subfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.export(
            items: itemsToExport,
            choice: fileChoice,
            destination: destination,
            destinationIsSecurityScoped: scoped,
            subfolderName: trimmed.isEmpty ? nil : trimmed,
            writeSidecars: writeSidecars,
            sidecarIncludesExtension: sidecarIncludesExtension,
            addToPhotos: addToPhotos,
            albumName: albumName
        )
    }

    // MARK: Progress & result

    private var progressView: some View {
        VStack(spacing: 18) {
            Text("EXPORTING")
                .font(.caption2.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.textTertiary)
            ProgressView(value: manager.fractionComplete)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(maxWidth: 280)
            Text("\(manager.completed) / \(manager.total)")
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            Text(manager.currentFile)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(height: 16)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var resultView: some View {
        VStack(spacing: 16) {
            Spacer()
            if let summary = manager.summary {
                Image(systemName: summary.failures.isEmpty ? "checkmark" : "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(summary.failures.isEmpty ? Theme.pick : Theme.rawBadge)
                Text(summary.failures.isEmpty ? "Export complete" : "Finished with issues")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                VStack(spacing: 8) {
                    statRow("Files copied", "\(summary.copied)")
                    if summary.sidecars > 0 { statRow("XMP sidecars", "\(summary.sidecars)") }
                    if summary.renamedCollisions > 0 { statRow("Renamed (collisions)", "\(summary.renamedCollisions)") }
                    // When the option was on, always show the count — a zero
                    // must be visible, not silently hidden.
                    if addToPhotos || summary.addedToPhotos > 0 { statRow("Added to Photos", "\(summary.addedToPhotos)") }
                    if summary.alreadyInPhotos > 0 { statRow("Already in Photos", "\(summary.alreadyInPhotos)") }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .frame(maxWidth: 300)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )

                if !summary.failures.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.failures, id: \.self) { failure in
                                Text(failure)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Theme.reject)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(maxHeight: 120)
                }

                Text("Destination: \(summary.destination.lastPathComponent)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                manager.reset()
                dismiss()
            } label: {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}
