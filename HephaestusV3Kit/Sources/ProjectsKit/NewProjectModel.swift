import Foundation
import Observation
import ProjectData
import ToolsFoundation

/// New Project and New Sub Project: the fields, the values that follow the name and the folder until the
/// user picks their own, and the rules (docs/ui/projects.md › New Project).
@Observable
final class NewProjectModel {
    enum FolderMode: Hashable {
        /// A folder created for the project, inside a location.
        case newFolder
        /// A folder that exists.
        case existingFolder
    }

    /// The projects of the app, for the parent menu and the identifiers in use.
    let projects: [Project]
    /// New Sub Project: the parent is chosen first and the folder doesn't change it.
    let isSubProject: Bool

    var name = "" {
        didSet {
            if !identifierEdited { identifier = ProjectRules.suggestedIdentifier(fromName: name) }
            if !folderNameEdited { folderName = Self.folderName(from: name) }
        }
    }

    /// As typed; shown and stored in uppercase.
    var identifier = ""
    private(set) var identifierEdited = false
    /// The type the user picked; nil while it follows the folder.
    var pickedKind: Project.Kind?
    /// The parent the user picked, `.some(nil)` for None; nil while it follows the folder.
    var pickedParent: Project.ID??
    var folderMode: FolderMode = .newFolder
    /// Where the new folder is created.
    var location: URL
    var folderName = ""
    private(set) var folderNameEdited = false
    var existingFolder: URL?

    /// The field a folder panel fills.
    enum FolderChoice: Sendable, Hashable {
        case location, existingFolder
    }

    /// Whether the folder panel shows.
    var choosingFolder = false
    /// The field the folder panel fills. It outlives the panel: SwiftUI closes the panel before it hands the
    /// folder over.
    private(set) var folderChoice = FolderChoice.location

    init(projects: [Project], location: URL, parentID: Project.ID? = nil, existingFolder: URL? = nil) {
        self.projects = projects
        self.location = location
        isSubProject = parentID != nil
        if let parentID {
            pickedParent = .some(parentID)
            if let parent = projects.first(where: { $0.id == parentID }) {
                self.location = URL(fileURLWithPath: parent.path, isDirectory: true)
            }
        }
        if let existingFolder {
            folderMode = .existingFolder
            self.existingFolder = existingFolder
            name = existingFolder.lastPathComponent
            identifier = ProjectRules.suggestedIdentifier(fromName: name)
        }
    }

    // MARK: Edits that stop a field from following

    func setIdentifier(_ text: String) {
        identifier = text.uppercased()
        identifierEdited = true
    }

    func setFolderName(_ text: String) {
        folderName = text
        folderNameEdited = true
    }

    /// Opens the folder panel for a field.
    func chooseFolder(for choice: FolderChoice) {
        folderChoice = choice
        choosingFolder = true
    }

    /// The folder the panel gave, for the field it was opened for.
    func chose(_ folder: URL) {
        switch folderChoice {
        case .location: location = folder
        case .existingFolder: existingFolder = folder
        }
    }

    /// Picking a parent moves the location to its folder.
    func pickParent(_ id: Project.ID?) {
        pickedParent = .some(id)
        if let id, let parent = project(id) {
            location = URL(fileURLWithPath: parent.path, isDirectory: true)
        }
    }

    // MARK: What the fields give

    /// The project's folder: the location and the folder name, or the existing folder; nil without one.
    var projectFolder: String? {
        switch folderMode {
        case .newFolder:
            guard Self.isFolderName(folderName) else { return nil }
            return location.appendingPathComponent(folderName, isDirectory: true).standardizedFileURL.path
        case .existingFolder:
            return existingFolder?.standardizedFileURL.path
        }
    }

    /// Service when the folder has `go.mod`; Other otherwise, a folder that doesn't exist yet included.
    var detectedKind: Project.Kind {
        guard let folder = projectFolder, FileManager.default.fileExists(atPath: folder + "/go.mod") else { return .other }
        return .service
    }

    var kind: Project.Kind { pickedKind ?? detectedKind }

    /// The innermost project whose folder strictly holds the project's folder.
    var detectedParent: Project? {
        guard let folder = projectFolder else { return nil }
        return projects.filter { folder.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    var parentID: Project.ID? {
        if let pickedParent { return pickedParent }
        return isSubProject ? nil : detectedParent?.id
    }

    var parent: Project? { project(parentID) }

    /// The note New Project shows when the user picked no parent for a folder inside a project.
    var insideProject: Project? {
        guard !isSubProject, pickedParent == .some(nil) else { return nil }
        return detectedParent
    }

    /// The parent menu's projects: every project in tree order, or for New Sub Project the family of the
    /// chosen parent's top-level project.
    var parentChoices: [(project: Project, depth: Int)] {
        let tree = ProjectTree(projects)
        guard isSubProject, let id = pickedParent ?? nil else { return tree.ordered() }
        let top = tree.ancestors(of: id).first ?? tree.project(id)
        return top.map { tree.ordered(topLevel: [$0]) } ?? []
    }

    // MARK: Rules

    var nameMessage: String? {
        guard !name.isEmpty else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...100).contains(trimmed.count) && !trimmed.contains(where: \.isNewline)
            ? nil : ProjectMessages.ruleMessage(.nameLength(field: "name"))
    }

    var identifierMessage: String? {
        guard !identifier.isEmpty || identifierEdited else { return nil }
        let value = identifier.uppercased()
        if value.isEmpty { return String(localized: "Enter an identifier.", bundle: #bundle) }
        guard ProjectRules.isIdentifier(value) else { return ProjectMessages.ruleMessage(.identifierFormat) }
        if let other = projects.first(where: { $0.id == value }) {
            return ProjectMessages.ruleMessage(.identifierInUse(identifier: value, by: other.name))
        }
        return nil
    }

    var folderMessage: String? {
        switch folderMode {
        case .newFolder:
            if !folderName.isEmpty || folderNameEdited, !Self.isFolderName(folderName) {
                return String(localized: "Enter a folder name without “/” that does not start with “.”.", bundle: #bundle)
            }
        case .existingFolder:
            if existingFolder == nil { return String(localized: "Choose a folder.", bundle: #bundle) }
        }
        if let parent, let folder = projectFolder, !folder.hasPrefix(parent.path + "/") {
            return ProjectMessages.message(.notInsideParent(parentName: parent.name))
        }
        return nil
    }

    var canCreate: Bool {
        request != nil
    }

    /// What Create asks the library for; nil while a field breaks a rule.
    var request: NewProject? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, nameMessage == nil,
              !identifier.isEmpty, identifierMessage == nil, folderMessage == nil, let folder = projectFolder else { return nil }
        return NewProject(name: name, identifier: identifier, kind: kind.stored, folder: folder,
                          createsFolder: folderMode == .newFolder, parentID: parentID)
    }

    // MARK: Helpers

    private func project(_ id: Project.ID?) -> Project? {
        projects.first { $0.id == id }
    }

    /// A name made a folder name: `/` and `:` become `-`, trimmed, without leading dots.
    static func folderName(from name: String) -> String {
        var text = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix(".") { text.removeFirst() }
        return text
    }

    /// 1 to 255 UTF-8 bytes, no `/`, not starting with `.`.
    static func isFolderName(_ text: String) -> Bool {
        (1...255).contains(text.utf8.count) && !text.contains("/") && !text.hasPrefix(".")
    }

    /// Where a new project's folder goes: the folder holding the selected project's top-level project, else
    /// `~/Developer` when it exists, else the home folder.
    static func defaultLocation(selected: Project?, in tree: ProjectTree, home: String = NSHomeDirectory()) -> URL {
        if let selected {
            let top = tree.ancestors(of: selected.id).first ?? selected
            return URL(fileURLWithPath: top.path, isDirectory: true).deletingLastPathComponent()
        }
        let developer = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Developer", isDirectory: true)
        return FileManager.default.fileExists(atPath: developer.path) ? developer : URL(fileURLWithPath: home, isDirectory: true)
    }
}
