import SwiftUI
import SwiftData

/// Manage app-internal projects (Lightroom-style collections): show one as
/// the active filter, swipe to delete. Membership is edited from the grid's
/// batch bar ("Add to Project").
struct ProjectsSheet: View {
    @Bindable var library: Library
    @Environment(\.dismiss) private var dismiss

    @State private var projects: [ProjectRecord] = []
    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    emptyView
                } else {
                    projectList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showNewProjectAlert = true } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Theme.textPrimary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .alert("New Project", isPresented: $showNewProjectAlert) {
                TextField("Name", text: $newProjectName)
                Button("Create") { createProject() }
                Button("Cancel", role: .cancel) { newProjectName = "" }
            } message: {
                Text("Add photos by selecting them in a gallery album and tapping “Add to Project.”")
            }
        }
        .onAppear { reload() }
    }

    // MARK: List

    private var projectList: some View {
        List {
            ForEach(projects, id: \.persistentModelID) { project in
                projectRow(project)
                    .listRowBackground(Theme.surface)
                    .listRowSeparatorTint(Theme.hairline)
            }
            .onDelete(perform: delete)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        // Tap to OPEN (rate) — loads the project's photos directly from the
        // library, nothing is copied. Add photos by selecting them in a
        // gallery album and tapping "Add to Project".
        Button {
            library.openProject(project)
            Haptics.tap()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(memberText(for: project))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                Text("Open")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textTertiary)
            Text("No projects yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Select shots in the grid and use Add to Project, or create an empty project with +.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func reload() {
        projects = library.projects()
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        newProjectName = ""
        guard !name.isEmpty else { return }
        library.createProject(named: name)
        reload()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            library.deleteProject(projects[index])
        }
        reload()
    }

    private func memberText(for project: ProjectRecord) -> String {
        let count = library.memberCount(of: project)
        return count == 1 ? "1 shot" : "\(count) shots"
    }
}
