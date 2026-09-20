import SwiftUI
import SwiftData

/// Root window: a projects sidebar (like the iOS app's "photo albums" home
/// screen) and a detail pane that opens whichever project is selected.
/// Everything reads/writes through the same `Library` engine as iOS —
/// this app keeps its own independent SwiftData store (a separate app, no
/// sync with the iPhone app, by design).
struct MacRootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var library: Library?

    @Query(sort: \ProjectRecord.createdAt, order: .reverse) private var projects: [ProjectRecord]
    @State private var selectedProject: ProjectRecord?
    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""

    var body: some View {
        Group {
            if let library {
                NavigationSplitView {
                    sidebar(library: library)
                } detail: {
                    if let selectedProject {
                        MacProjectView(library: library, project: selectedProject)
                            .id(selectedProject.persistentModelID)
                    } else {
                        ContentUnavailableView(
                            "Select a Project",
                            systemImage: "photo.stack",
                            description: Text("Choose a project on the left, or create a new one.")
                        )
                    }
                }
            } else {
                ProgressView().onAppear {
                    library = Library(context: modelContext)
                }
            }
        }
        .alert("New Project", isPresented: $showNewProjectAlert) {
            TextField("Project name", text: $newProjectName)
            Button("Create") {
                let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                newProjectName = ""
                guard !name.isEmpty, let library else { return }
                let project = library.createProject(named: name)
                selectedProject = project
            }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        }
    }

    private func sidebar(library: Library) -> some View {
        List(selection: $selectedProject) {
            Section("Projects") {
                ForEach(projects) { project in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                        Text(project.itemIDs.isEmpty ? "Empty" : "\(project.itemIDs.count) photos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(project)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            if selectedProject === project { selectedProject = nil }
                            library.deleteProject(project)
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .toolbar {
            ToolbarItem {
                Button {
                    newProjectName = ""
                    showNewProjectAlert = true
                } label: {
                    Label("New Project", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Selecta")
    }
}
