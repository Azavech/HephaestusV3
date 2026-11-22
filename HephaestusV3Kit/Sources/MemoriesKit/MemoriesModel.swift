import FileStorage
import Foundation
import MemoryData
import Observation
import ToolsFoundation

/// Whose memories the tab shows: the global ones, or a project's.
public enum MemoryScope: Hashable, Sendable {
    case global
    case project(Project.ID)

    /// As a route's focus and a tab's: `global`, or the project's id.
    public var focus: String {
        switch self {
        case .global: "global"
        case .project(let id): id
        }
    }

    public init(focus: String?) {
        guard let focus, focus != "global", !focus.isEmpty else {
            self = .global
            return
        }
        self = .project(focus)
    }
}

/// A row of the list: `MEMORY.md`, a memory of the shown folder, or one inherited from a parent project.
enum MemoryRow: Hashable {
    case index
    case memory(String)
    case inherited(projectID: Project.ID, file: String)
}

/// How a body shows: edited as text, rendered as Markdown, or both side by side.
enum MemoryBodyMode: String, CaseIterable, Identifiable {
    case edit, preview, split
    var id: Self { self }
}

/// What an editor shows and the user changes. `MEMORY.md` uses the body alone.
struct MemoryDraft: Equatable {
    var name = ""
    var description = ""
    var type: MemoryType = .other
    var body = ""
}

/// The file the editor shows.
struct ShownFile: Equatable {
    var row: MemoryRow
    var folder: String
    var file: String
    var isReadOnly: Bool
    var path: String { (folder as NSString).appendingPathComponent(file) }
}

/// Memories (docs/ui/memories.md): the global memories and each project's, as V2's Memories section and Global
/// Memories view showed them, in V3's way: one tab, a change saved by itself as System Prompts saves. The list follows
/// the folders' changes while the tab shows.
@MainActor @Observable
public final class MemoriesModel {
    private(set) var scope: MemoryScope = .global
    private(set) var listing: MemoryListing?
    private(set) var inherited: [(folder: InheritedMemoryFolder, listing: MemoryListing)] = []
    private(set) var listFailure: String?
    var filter = ""
    private(set) var selection: MemoryRow?
    var bodyMode: MemoryBodyMode = .preview

    private(set) var shown: ShownFile?
    var draft = MemoryDraft()
    private(set) var saved = MemoryDraft()
    private(set) var otherFrontMatter = ""
    /// Why the name typed can't be given; the field keeps it.
    private(set) var nameMessage: String?
    private(set) var saveFailure: String?
    /// Why the shown file can't be read, or that it is gone.
    private(set) var loadFailure: String?

    @ObservationIgnored let directory: ProjectDirectory
    @ObservationIgnored private let locations: () -> MemoryLocations
    @ObservationIgnored private let trash: Trash
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var hub: FileEventHub?
    @ObservationIgnored private var watching: Task<Void, Never>?

    public init(directory: ProjectDirectory, locations: @escaping () -> MemoryLocations, trash: Trash = .system,
                saveDelay: Duration = .seconds(1), scope: MemoryScope = .global) {
        self.directory = directory
        self.locations = locations
        self.trash = trash
        self.saveDelay = saveDelay
        self.scope = scope
    }

    // MARK: Folders

    /// The shown scope's folder.
    var folder: String {
        switch scope {
        case .global: return locations().globalFolder
        case .project(let id): return locations().projectFolder(root: directory.project(id)?.path ?? "/")
        }
    }

    var memoryFolder: MemoryFolder { MemoryFolder(path: folder, trash: trash) }

    /// A project's ancestors, nearest parent first.
    func ancestors(of id: Project.ID) -> [Project] {
        var result: [Project] = []
        var parentID = directory.project(id)?.parentID
        while let parent = directory.project(parentID), !result.contains(where: { $0.id == parent.id }) {
            result.append(parent)
            parentID = parent.parentID
        }
        return result
    }

    /// Shows a scope's memories; the shown file's change is saved first.
    func select(_ scope: MemoryScope) {
        guard scope != self.scope || listing == nil else { return }
        saveNow()
        self.scope = scope
        select(row: nil)
        filter = ""
        reload()
        restartWatching()
    }

    /// Reads the folders again: the scope's own, and the ones a project inherits.
    func reload() {
        do throws(StorageError) {
            listing = try memoryFolder.list()
            listFailure = nil
        } catch {
            listing = nil
            listFailure = error.description
        }
        if case .project(let id) = scope, directory.project(id) != nil {
            let ancestors = ancestors(of: id).map { (id: $0.id, name: $0.name, root: $0.path) }
            inherited = locations().inherited(ownFolder: folder, ancestors: ancestors).map { folder in
                (folder, (try? MemoryFolder(path: folder.folder).list()) ?? MemoryListing(folder: folder.folder))
            }
        } else {
            inherited = []
        }
        refreshShown()
    }

    /// Whether the scope has nothing at all: no memory, no `MEMORY.md`, nothing inherited.
    var isEmpty: Bool {
        guard let listing else { return false }
        return !listing.hasIndex && listing.memories.isEmpty && inherited.allSatisfy { $0.listing.memories.isEmpty }
    }

    // MARK: Rows

    /// The memories of a type, as the filter keeps them.
    func memories(of type: MemoryType) -> [MemorySummary] {
        (listing?.memories ?? []).filter { $0.type == type && matches($0) }
    }

    /// The inherited groups with memories the filter keeps.
    var inheritedGroups: [(folder: InheritedMemoryFolder, memories: [MemorySummary])] {
        inherited.map { ($0.folder, $0.listing.memories.filter(matches)) }.filter { !$0.memories.isEmpty }
    }

    var showsIndexRow: Bool {
        (listing?.hasIndex ?? false) && (filter.isEmpty || MemoryFolder.indexName.localizedCaseInsensitiveContains(filter))
    }

    var hasMatches: Bool {
        showsIndexRow || MemoryType.allCases.contains { !memories(of: $0).isEmpty } || !inheritedGroups.isEmpty
    }

    private func matches(_ memory: MemorySummary) -> Bool {
        filter.isEmpty || memory.name.localizedCaseInsensitiveContains(filter) || memory.description.localizedCaseInsensitiveContains(filter)
    }

    /// The project whose name heads an inherited group: its current name, else its id.
    func name(of projectID: Project.ID) -> String {
        directory.project(projectID)?.name ?? projectID
    }

    // MARK: Selection

    /// Shows a row in the editor, the shown one's change saved first.
    func select(row: MemoryRow?) {
        guard row != selection || shown == nil else { return }
        saveNow()
        selection = row
        nameMessage = nil
        saveFailure = nil
        load()
    }

    private func load() {
        loadFailure = nil
        guard let selection else {
            shown = nil
            return
        }
        switch selection {
        case .index:
            shown = ShownFile(row: .index, folder: folder, file: MemoryFolder.indexName, isReadOnly: false)
            do throws(MemoryFileError) {
                let text = try memoryFolder.readIndex() ?? ""
                draft = MemoryDraft(body: text)
                saved = draft
                otherFrontMatter = ""
            } catch {
                loadFailure = error.reason
            }
        case .memory(let file):
            show(file, in: folder, row: selection, readOnly: false)
        case .inherited(let projectID, let file):
            let source = inherited.first { $0.folder.projectID == projectID }?.folder.folder ?? ""
            show(file, in: source, row: selection, readOnly: true)
        }
    }

    private func show(_ file: String, in folder: String, row: MemoryRow, readOnly: Bool) {
        shown = ShownFile(row: row, folder: folder, file: file, isReadOnly: readOnly)
        do throws(MemoryFileError) {
            let memory = try MemoryFolder(path: folder).read(file)
            draft = MemoryDraft(name: memory.summary.name, description: memory.summary.description, type: memory.summary.type, body: memory.body)
            saved = draft
            otherFrontMatter = memory.otherFrontMatter
        } catch {
            let missing = !FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(file))
            let name = saved.name.isEmpty ? String(file.dropLast(3)) : saved.name
            loadFailure = missing ? String(localized: "Memory \(name) was not found.", bundle: #bundle) : error.reason
        }
    }

    /// After the folder changed: the shown file again, unless it has a change of the user's waiting.
    private func refreshShown() {
        guard let shown, !hasUnsavedChanges else { return }
        if case .index = shown.row, !(listing?.hasIndex ?? false), !FileManager.default.fileExists(atPath: shown.path) {
            loadFailure = String(localized: "File MEMORY.md was not found.", bundle: #bundle)
            return
        }
        load()
    }

    var hasUnsavedChanges: Bool { draft != saved && shown?.isReadOnly == false }

    // MARK: Editing

    /// The description or the body typed: saved after `saveDelay` without another change.
    func edited() {
        nameMessage = nil
        guard hasUnsavedChanges else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// A type chosen: saved at once.
    func setType(_ type: MemoryType) {
        guard draft.type != type else { return }
        draft.type = type
        saveNow()
    }

    /// The name typed, given on Return or when the field loses the focus: the memory is renamed, its file with it.
    func commitName() {
        guard let shown, case .memory(let file) = shown.row, draft.name != saved.name else { return }
        let name = draft.name
        guard MemoryFolder.isValidName(name) else {
            nameMessage = String(localized: "Use 1–64 lowercase letters, digits and single hyphens.", bundle: #bundle)
            return
        }
        guard !memoryFolder.isTaken(name, except: file) else {
            nameMessage = String(localized: "A memory named “\(name)” already exists.", bundle: #bundle)
            return
        }
        nameMessage = nil
        do throws(MemoryFileError) {
            let newFile = try memoryFolder.update(file, MemoryChange(name: name))
            saved.name = name
            self.shown?.file = newFile
            self.shown?.row = .memory(newFile)
            selection = .memory(newFile)
            saveFailure = nil
            reloadListingOnly()
        } catch {
            saveFailure = error.reason
        }
    }

    /// Saves the shown file's change now: description, type and body; the name waits for its own commit.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let shown, hasUnsavedChanges else { return }
        do throws(MemoryFileError) {
            switch shown.row {
            case .index:
                guard draft.body != saved.body else { return }
                try memoryFolder.writeIndex(draft.body)
                saved.body = draft.body
            case .memory(let file):
                var change = MemoryChange()
                if draft.description != saved.description { change.description = draft.description }
                if draft.type != saved.type, draft.type != .other { change.type = draft.type }
                if draft.body != saved.body { change.body = draft.body }
                guard change != MemoryChange() else { return }
                try memoryFolder.update(file, change)
                if let description = change.description { saved.description = description }
                if let type = change.type { saved.type = type }
                if let body = change.body { saved.body = body }
            case .inherited:
                return
            }
            saveFailure = nil
            reloadListingOnly()
        } catch {
            saveFailure = error.reason
        }
    }

    private func reloadListingOnly() {
        if let listing = try? memoryFolder.list() { self.listing = listing }
    }

    /// Why the description can't be saved as typed, when it is empty.
    var descriptionMessage: String? {
        draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.description != saved.description
            ? String(localized: "A description is required.", bundle: #bundle) : nil
    }

    // MARK: Create and delete

    /// New Memory: writes the file and its `MEMORY.md` line, then shows it, its body in Edit.
    func create(name: String, description: String, type: MemoryType) throws(MemoryFileError) {
        saveNow()
        let file = try memoryFolder.create(name: name, description: description, type: type)
        reload()
        bodyMode = .edit
        select(row: .memory(file))
    }

    /// Why a name can't be given to a new memory; nil when it can.
    func newNameMessage(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if !MemoryFolder.isValidName(name) { return String(localized: "Use 1–64 lowercase letters, digits and single hyphens.", bundle: #bundle) }
        if memoryFolder.isTaken(name) { return String(localized: "A memory named “\(name)” already exists.", bundle: #bundle) }
        return nil
    }

    /// Move to Trash: the memory's `MEMORY.md` lines go, then its file.
    func delete(_ file: String) throws(MemoryFileError) {
        pendingSave?.cancel()
        pendingSave = nil
        try memoryFolder.delete(file)
        if case .memory(let shownFile)? = selection, shownFile == file {
            selection = nil
            shown = nil
        }
        reload()
    }

    /// The selected memory of the scope's own folder, which Move to Trash takes.
    var deletableFile: String? {
        if case .memory(let file)? = selection { return file }
        return nil
    }

    // MARK: Watching

    /// Follows the folders' changes while the tab shows: Claude writes memories from its chats.
    func startWatching() {
        reload()
        restartWatching()
    }

    func stopWatching() {
        saveNow()
        watching?.cancel()
        watching = nil
        if let hub { Task { await hub.stop() } }
        hub = nil
    }

    private func restartWatching() {
        watching?.cancel()
        if let hub { Task { await hub.stop() } }
        let hub = FileEventHub()
        self.hub = hub
        let folders = [folder] + inherited.map(\.folder.folder)
        // A folder that doesn't exist yet is watched through its nearest existing parent.
        let watched = Set(folders.map(Self.existingAncestor))
        watching = Task { [weak self] in
            for folder in watched { await hub.watch(folder) }
            for await batch in hub.batches {
                guard let self else { return }
                if batch.contains(where: { event in folders.contains { event.path.hasPrefix($0) || $0.hasPrefix(event.path) } }) {
                    self.reload()
                }
            }
        }
    }

    static func existingAncestor(_ path: String) -> String {
        var folder = path
        while !FileManager.default.fileExists(atPath: folder), folder != "/", !folder.isEmpty {
            folder = (folder as NSString).deletingLastPathComponent
        }
        return folder
    }

    /// A path as the footer shows it: the home folder written `~`.
    func abbreviated(_ path: String) -> String {
        let home = locations().home
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// What a tab keeps of Memories while another tab is in front: its model, so the scope, the selection and what is
/// typed are still there when the tab comes back. The app's window makes one per tab.
@MainActor
public final class MemoriesTabState {
    let model: MemoriesModel

    public init(directory: ProjectDirectory, locations: @escaping () -> MemoryLocations, scope: MemoryScope) {
        model = MemoriesModel(directory: directory, locations: locations, scope: scope)
    }
}
