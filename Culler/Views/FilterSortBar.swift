import SwiftData
import SwiftUI

/// Sticky bar under the nav bar: a horizontally scrolling row of compact
/// rectangular filter/sort chips, plus a Lightroom-style inline options strip
/// that expands BELOW the chip row (never a popover/Menu), so neighboring
/// chips stay visible and reachable while adjusting filters. Selecting an
/// option applies immediately; the panel stays open for further tweaks.
struct FilterSortBar: View {
    @Bindable var library: Library
    @Binding var showFilenames: Bool
    @Binding var thumbSize: Double

    enum Panel: String {
        case rating, flag, label, type, project, sort, view
    }

    private enum RatingMode {
        case atLeast, exactly
    }

    @State private var expandedPanel: Panel?
    @State private var ratingMode: RatingMode = .atLeast

    var body: some View {
        VStack(spacing: 0) {
            chipRow
            if let panel = expandedPanel {
                optionsPanel(panel)
            }
            Theme.hairline.frame(height: 1)
        }
        .background(Theme.surface)
        #if DEBUG
        .onAppear {
            if let raw = ProcessInfo.processInfo.environment["CULLER_AUTO_FILTER"],
               let panel = Panel(rawValue: raw) {
                expandedPanel = panel
            }
        }
        #endif
    }

    // MARK: Row 1 — chips

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                panelChip(ratingChipText, panel: .rating, active: library.ratingFilter != .off, icon: "star")
                panelChip(
                    library.flagFilter == .any ? "Flag" : library.flagFilter.rawValue,
                    panel: .flag,
                    active: library.flagFilter != .any,
                    icon: "flag"
                )
                panelChip(labelChipText, panel: .label, active: !library.labelFilter.isEmpty, icon: "tag")
                panelChip(
                    library.typeFilter == .any ? "Type" : library.typeFilter.rawValue,
                    panel: .type,
                    active: library.typeFilter != .any,
                    icon: "doc"
                )
                panelChip(
                    library.activeProject?.name ?? "Project",
                    panel: .project,
                    active: library.activeProject != nil,
                    icon: "folder"
                )
                panelChip(
                    sortShortLabel,
                    panel: .sort,
                    active: false,
                    icon: library.sortAscending ? "arrow.up" : "arrow.down"
                )
                panelChip("View", panel: .view, active: showFilenames, icon: "square.grid.2x2")

                if library.hasActiveFilter {
                    Button {
                        library.clearFilters()
                        Haptics.tap()
                    } label: {
                        chip("Clear", active: false, icon: "xmark")
                    }
                    .buttonStyle(.plain)
                }

                Text("\(library.filteredItems.count)/\(library.items.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 10)
        }
    }

    /// Chip that expands/collapses its options panel below the row.
    private func panelChip(_ text: String, panel: Panel, active: Bool, icon: String) -> some View {
        Button {
            expandedPanel = (expandedPanel == panel) ? nil : panel
            Haptics.tap()
        } label: {
            chip(text, active: active, icon: icon, chevronUp: expandedPanel == panel)
        }
        .buttonStyle(.plain)
    }

    /// Compact rectangular chip. The extra vertical padding keeps the tap
    /// target at ~44pt while the visible chip stays compact.
    private func chip(_ text: String, active: Bool, icon: String, chevronUp: Bool? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.caption2.weight(.medium))
            if let up = chevronUp {
                Image(systemName: up ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(up ? Theme.textPrimary : Theme.textTertiary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            active ? Theme.accent.opacity(0.15) : Theme.surfaceElevated,
            in: RoundedRectangle(cornerRadius: Theme.chipRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(active ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1)
        )
        .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    // MARK: Row 2 — inline options panel

    private func optionsPanel(_ panel: Panel) -> some View {
        VStack(spacing: 0) {
            Theme.hairline.frame(height: 1)
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        switch panel {
                        case .rating: ratingOptions
                        case .flag: flagOptions
                        case .label: labelOptions
                        case .type: typeOptions
                        case .project: projectOptions
                        case .sort: sortOptions
                        case .view: viewOptions
                        }
                    }
                    .padding(.horizontal, 10)
                }
                Button {
                    expandedPanel = nil
                    Haptics.tap()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 48)
        }
        .background(Theme.surfaceElevated)
    }

    /// Compact option button used inside panels. Applies instantly; the
    /// panel stays open so several options can be adjusted in a row.
    private func optionButton(
        _ text: String,
        active: Bool,
        icon: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(text)
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                active ? Theme.accent.opacity(0.15) : Theme.surfaceElevated,
                in: RoundedRectangle(cornerRadius: Theme.chipRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(active ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1)
            )
            .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Rating

    private var effectiveRatingMode: RatingMode {
        switch library.ratingFilter {
        case .atLeast: return .atLeast
        case .exactly: return .exactly
        case .off: return ratingMode
        }
    }

    @ViewBuilder
    private var ratingOptions: some View {
        optionButton("Any", active: library.ratingFilter == .off) {
            library.ratingFilter = .off
        }
        optionButton("≥ At least", active: effectiveRatingMode == .atLeast) {
            switchRatingMode(to: .atLeast)
        }
        optionButton("= Exactly", active: effectiveRatingMode == .exactly) {
            switchRatingMode(to: .exactly)
        }
        if effectiveRatingMode == .atLeast {
            ForEach(1...5, id: \.self) { n in
                optionButton("★\(n)+", active: library.ratingFilter == .atLeast(n)) {
                    // Second tap on the active option clears the filter.
                    library.ratingFilter = library.ratingFilter == .atLeast(n) ? .off : .atLeast(n)
                }
            }
        } else {
            optionButton("Unrated", active: library.ratingFilter == .exactly(0)) {
                library.ratingFilter = library.ratingFilter == .exactly(0) ? .off : .exactly(0)
            }
            ForEach(1...5, id: \.self) { n in
                optionButton("★\(n)", active: library.ratingFilter == .exactly(n)) {
                    library.ratingFilter = library.ratingFilter == .exactly(n) ? .off : .exactly(n)
                }
            }
        }
    }

    /// Switch the star-mode selector, carrying the star count across when
    /// it makes sense (Unrated has no "at least" counterpart).
    private func switchRatingMode(to mode: RatingMode) {
        ratingMode = mode
        switch (mode, library.ratingFilter) {
        case (.atLeast, .exactly(let n)) where n >= 1:
            library.ratingFilter = .atLeast(n)
        case (.atLeast, .exactly):
            library.ratingFilter = .off
        case (.exactly, .atLeast(let n)):
            library.ratingFilter = .exactly(n)
        default:
            break
        }
    }

    private var ratingChipText: String {
        switch library.ratingFilter {
        case .off: return "Rating"
        case .atLeast(let n): return "★\(n)+"
        case .exactly(0): return "Unrated"
        case .exactly(let n): return "★\(n)"
        }
    }

    // MARK: Flag

    @ViewBuilder
    private var flagOptions: some View {
        ForEach(FlagFilter.allCases) { f in
            optionButton(f.rawValue, active: library.flagFilter == f) {
                // Second tap on the active option clears back to Any.
                library.flagFilter = library.flagFilter == f ? .any : f
            }
        }
    }

    // MARK: Label (multi-select — panel stays open)

    @ViewBuilder
    private var labelOptions: some View {
        ForEach(ColorLabel.allCases) { label in
            labelDot(label)
        }
        optionButton(
            "Unlabeled",
            active: library.labelFilter.contains(Library.unlabeledFilterToken),
            icon: "circle.slash"
        ) {
            toggleLabelToken(Library.unlabeledFilterToken)
        }
        if !library.labelFilter.isEmpty {
            optionButton("Clear", active: false, icon: "xmark") {
                library.labelFilter = []
            }
        }
    }

    private func labelDot(_ label: ColorLabel) -> some View {
        let active = library.labelFilter.contains(label.rawValue)
        return Button {
            toggleLabelToken(label.rawValue)
            Haptics.tap()
        } label: {
            Circle()
                .fill(label.color)
                .frame(width: 24, height: 24)
                .overlay(
                    Circle().strokeBorder(
                        active ? Color.white : Theme.hairline,
                        lineWidth: active ? 2 : 1
                    )
                )
                .frame(width: 40, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleLabelToken(_ token: String) {
        if library.labelFilter.contains(token) {
            library.labelFilter.remove(token)
        } else {
            library.labelFilter.insert(token)
        }
    }

    private var labelChipText: String {
        if library.labelFilter.isEmpty { return "Label" }
        if library.labelFilter.count == 1, let token = library.labelFilter.first {
            return token == Library.unlabeledFilterToken ? "Unlabeled" : token
        }
        return "\(library.labelFilter.count) labels"
    }

    // MARK: Type

    @ViewBuilder
    private var typeOptions: some View {
        ForEach(TypeFilter.allCases) { t in
            optionButton(t.rawValue, active: library.typeFilter == t) {
                // Second tap on the active option clears back to All types.
                library.typeFilter = library.typeFilter == t ? .any : t
            }
        }
    }

    // MARK: Project

    @ViewBuilder
    private var projectOptions: some View {
        optionButton("All photos", active: library.activeProject == nil) {
            library.activeProject = nil
        }
        ForEach(library.projects(), id: \.persistentModelID) { project in
            optionButton(
                "\(project.name) (\(library.memberCount(of: project)))",
                active: library.activeProject === project,
                icon: "folder"
            ) {
                // Second tap on the active project clears the filter.
                library.activeProject = library.activeProject === project ? nil : project
            }
        }
    }

    // MARK: Sort

    /// One button per sort key. Tap cycles: inactive → sensible first
    /// direction → flipped → back to the default order (newest first).
    @ViewBuilder
    private var sortOptions: some View {
        cyclingSortOption("Time", key: .captureTime, firstAscending: false)
        cyclingSortOption("Name", key: .filename, firstAscending: true)
        cyclingSortOption("Rating", key: .rating, firstAscending: false)
        cyclingSortOption("Type", key: .fileType, firstAscending: true)
        cyclingSortOption("Camera", key: .camera, firstAscending: true)
    }

    private func cyclingSortOption(_ title: String, key: SortKey, firstAscending: Bool) -> some View {
        let isActive = library.sortKey == key
        return optionButton(
            title,
            active: isActive,
            icon: isActive
                ? (library.sortAscending ? "arrow.up" : "arrow.down")
                : "arrow.up.arrow.down"
        ) {
            if !isActive {
                library.sortKey = key
                library.sortAscending = firstAscending
            } else if library.sortAscending == firstAscending {
                library.sortAscending = !firstAscending
            } else {
                // Third tap: back to the default order (capture time, newest first).
                library.sortKey = .captureTime
                library.sortAscending = false
            }
        }
    }

    private var sortShortLabel: String {
        switch library.sortKey {
        case .captureTime: return "Time"
        case .filename: return "Name"
        case .rating: return "Rating"
        case .fileType: return "Type"
        case .camera: return "Camera"
        }
    }

    // MARK: View

    @ViewBuilder
    private var viewOptions: some View {
        optionButton("Filenames", active: showFilenames, icon: "textformat") {
            showFilenames.toggle()
        }
        optionButton("Smaller", active: false, icon: "minus.magnifyingglass") {
            thumbSize = max(70, thumbSize - 25)
        }
        optionButton("Bigger", active: false, icon: "plus.magnifyingglass") {
            thumbSize = min(240, thumbSize + 25)
        }
    }
}
