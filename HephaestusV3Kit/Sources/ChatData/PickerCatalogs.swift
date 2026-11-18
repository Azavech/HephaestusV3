import CoreText
import Darwin
import ExternalTools
import Foundation
import Synchronization
import TextFormats

/// The catalogues the picker requests check their suggestions against and the cards search (docs/data.md ›
/// Picker catalogues): the Mac's SF Symbols, its sounds and its fonts, and a project's sound and font files. The
/// Mac's are read once, the first time they are needed, and kept until the app quits; a project's files are read
/// at each use. Their sources are injectable: tests read fixtures and temporary folders.
public actor PickerCatalogs {
    /// Where the Mac's catalogues come from.
    public struct Sources: Sendable {
        /// The folder of `name_availability.plist` and `symbol_search.plist`.
        public var symbolsFolder: URL
        public var macOSVersion: OperatingSystemVersion
        /// The macOS sounds' folder.
        public var soundsFolder: URL
        /// The installed Simulator runtimes, and what failed while listing them.
        public var runtimes: @Sendable () async -> (runtimes: [SoundCatalog.Runtime], problems: [String])
        /// The font families installed on the Mac.
        public var installedFonts: @Sendable () -> [FontFamily]

        public init(symbolsFolder: URL, macOSVersion: OperatingSystemVersion, soundsFolder: URL,
                    runtimes: @escaping @Sendable () async -> (runtimes: [SoundCatalog.Runtime], problems: [String]),
                    installedFonts: @escaping @Sendable () -> [FontFamily]) {
            self.symbolsFolder = symbolsFolder
            self.macOSVersion = macOSVersion
            self.soundsFolder = soundsFolder
            self.runtimes = runtimes
            self.installedFonts = installedFonts
        }

        /// This Mac's: CoreGlyphs, `/System/Library/Sounds`, `xcrun simctl list runtimes --json` run by `runner`
        /// with `environment`, CoreText's families.
        public static func system(runner: any ProcessRunning = SystemProcessRunner.shared, environment: [String: String] = [:]) -> Sources {
            Sources(symbolsFolder: SFSymbolCatalog.systemFolder, macOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
                    soundsFolder: SoundCatalog.macOSFolder,
                    runtimes: { await SoundCatalog.listRuntimes(runner: runner, environment: environment) },
                    installedFonts: { FontCatalog.readInstalledFamilies() })
        }
    }

    let sources: Sources
    private var symbolCatalog: SFSymbolCatalog?
    private var systemSoundList: SoundCatalog.SystemSounds?
    private var fonts: [FontFamily]?

    public init(sources: Sources) {
        self.sources = sources
    }

    /// The Mac's SF Symbols.
    public func symbols() -> SFSymbolCatalog {
        if let symbolCatalog { return symbolCatalog }
        let catalog = SFSymbolCatalog(folder: sources.symbolsFolder, macOSVersion: sources.macOSVersion)
        symbolCatalog = catalog
        return catalog
    }

    /// The macOS and Simulator runtime sounds.
    public func systemSounds() async -> SoundCatalog.SystemSounds {
        if let systemSoundList { return systemSoundList }
        let listed = await sources.runtimes()
        // Another call may have read them meanwhile.
        if let systemSoundList { return systemSoundList }
        let sounds = SoundCatalog.SystemSounds.read(macOSFolder: sources.soundsFolder, runtimes: listed.runtimes, problems: listed.problems)
        systemSoundList = sounds
        return sounds
    }

    /// The families installed on the Mac.
    public func installedFonts() -> [FontFamily] {
        if let fonts { return fonts }
        let read = sources.installedFonts()
        fonts = read
        return read
    }

    /// The sound catalogue of the project at `root`: the Mac's sounds and the project's sound files.
    public func sounds(project root: URL, files: ProjectFiles) async -> SoundCatalog {
        let system = await systemSounds()
        let paths = await files.paths(in: root, matching: SoundCatalog.extensions)
        return SoundCatalog(system: system, projectRoot: root, projectPaths: paths)
    }

    /// The font catalogue of the project at `root`: the Mac's families and those of the project's font files.
    public func fonts(project root: URL, files: ProjectFiles) async -> FontCatalog {
        let installed = installedFonts()
        let paths = await files.paths(in: root, matching: FontCatalog.fontFileExtensions)
        let project = FontCatalog.projectFamilies(files: paths.map { ($0, root.appendingPathComponent($0)) })
        return FontCatalog(installed: installed, project: project)
    }
}

/// How a project's files are listed for its sounds and fonts (docs/data.md › Picker catalogues): git's files, the
/// tracked and the untracked ones it doesn't ignore, else a walk of the folder without hidden names; the folders
/// of its sub projects are left out.
public struct ProjectFiles: Sendable {
    /// git, when the tools found it.
    public var git: Git?
    /// The sub projects' folders, relative to the project's, left out.
    public var excluded: [String]

    public init(git: Git?, excluded: [String] = []) {
        self.git = git
        self.excluded = excluded
    }

    /// The most a walk visits.
    static let walkLimit = 100_000
    /// Folders a walk never enters: build products and dependencies.
    static let skippedFolders: Set<String> = ["node_modules", "DerivedData", "Pods", "build"]

    /// The files of the folder whose extension, lowercased, is one of `extensions`, as paths from the folder.
    public func paths(in root: URL, matching extensions: Set<String>) async -> [String] {
        let listed: [String]
        if let fromGit = await gitFiles(in: root) {
            listed = fromGit
        } else {
            let excluded = self.excluded
            listed = await Task.detached { Self.walk(root, extensions: extensions, excluded: excluded) }.value
        }
        return listed.filter { path in
            extensions.contains((path as NSString).pathExtension.lowercased())
                && !excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    /// `git ls-files -z --cached --others --exclude-standard`, run in the folder; nil outside a work tree or when
    /// git fails.
    private func gitFiles(in root: URL) async -> [String]? {
        guard let git else { return nil }
        let request = ProcessRequest(executable: git.executable, arguments: ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                     environment: git.environment, currentDirectory: root.path)
        guard let result = try? await git.runner.run(request, timeout: .seconds(10)), result.succeeded else { return nil }
        return result.standardOutput.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The regular files under `root` with one of `extensions`: names starting with `.`, symbolic links and the
    /// skipped folders left out, at most `walkLimit` entries visited.
    static func walk(_ root: URL, extensions: Set<String>, excluded: [String]) -> [String] {
        var found: [String] = []
        var visited = 0
        func visit(_ folder: URL, prefix: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                visited += 1
                guard visited <= walkLimit else { return }
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let url = folder.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    if extensions.contains((name as NSString).pathExtension.lowercased()) { found.append(path) }
                case S_IFDIR:
                    if !skippedFolders.contains(name), !excluded.contains(path) { visit(url, prefix: path) }
                default:
                    continue
                }
            }
        }
        visit(root, prefix: "")
        return found
    }
}

// MARK: - SF Symbols

/// The SF Symbols of a Mac, read from the catalogue of its macOS, and their search (docs/data.md › Picker
/// catalogues), as V2's `SFSymbolCatalog`.
public struct SFSymbolCatalog: Sendable {
    /// The folder of the running macOS's catalogue files.
    public static let systemFolder = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// The last dot-separated components of the localized variants.
    public static let localizationSuffixes: Set<String> = [
        "ar", "bn", "el", "gu", "he", "hi", "ja", "km", "kn", "ko", "ml", "mni", "mr", "my", "or", "pa", "rtl", "ru", "sat",
        "si", "ta", "te", "th", "zh",
    ]

    private struct Entry: Sendable {
        var name: String
        var lowercasedName: String
        var keywords: [String]
    }

    /// Every name of the catalogue, localized variants included.
    public let names: Set<String>
    /// The names the search lists, in alphabetical order: no localized variant.
    private let entries: [Entry]
    /// What couldn't be read; empty when both files were.
    public let problems: [String]

    public init(names: Set<String>, keywords: [String: [String]], problems: [String] = []) {
        self.names = names
        self.problems = problems
        entries = names.filter { !Self.isLocalizedVariant($0) }.sorted().map { name in
            Entry(name: name, lowercasedName: name.lowercased(), keywords: (keywords[name] ?? []).map { $0.lowercased() })
        }
    }

    /// Reads `name_availability.plist` and `symbol_search.plist` of `folder`: a name belongs to the catalogue when
    /// the `macOS` version of its release is at most `macOSVersion`, or when its release gives none. A file that
    /// can't be read leaves the catalogue empty, or its names without keywords.
    public init(folder: URL, macOSVersion: OperatingSystemVersion) {
        var problems: [String] = []
        var names: Set<String> = []
        if let plist = Self.dictionary(folder.appendingPathComponent("name_availability.plist")),
           let symbols = plist["symbols"] as? [String: String] {
            let releases = plist["year_to_release"] as? [String: [String: String]] ?? [:]
            for (name, release) in symbols {
                if let version = releases[release]?["macOS"], !Self.isAvailable(version, on: macOSVersion) { continue }
                names.insert(name)
            }
        } else {
            problems.append("name_availability.plist can't be read.")
        }
        var keywords: [String: [String]] = [:]
        if let plist = Self.dictionary(folder.appendingPathComponent("symbol_search.plist")) {
            for (name, value) in plist {
                keywords[name] = value as? [String] ?? []
            }
        } else {
            problems.append("symbol_search.plist can't be read.")
        }
        self.init(names: names, keywords: keywords, problems: problems)
    }

    public func contains(_ name: String) -> Bool {
        names.contains(name)
    }

    /// A name whose last dot-separated component is one of `localizationSuffixes`.
    public static func isLocalizedVariant(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return localizationSuffixes.contains(String(name[name.index(after: dot)...]))
    }

    /// The name matches, then the keyword matches, each in alphabetical order, without localized variants and
    /// without `excluded`; nothing for an empty query. A name matches by name when it contains every word of the
    /// trimmed, lowercased query; by keyword when each word is in the name or one of its keywords.
    public func search(_ query: String, excluding excluded: Set<String> = []) -> [String] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        var byName: [String] = []
        var byKeyword: [String] = []
        for entry in entries where !excluded.contains(entry.name) {
            if words.allSatisfy({ entry.lowercasedName.contains($0) }) {
                byName.append(entry.name)
            } else if words.allSatisfy({ word in entry.lowercasedName.contains(word) || entry.keywords.contains { $0.contains(word) } }) {
                byKeyword.append(entry.name)
            }
        }
        return byName + byKeyword
    }

    private static func dictionary(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Whether a release's `macOS` version, such as `27.2`, is at most the running version.
    private static func isAvailable(_ version: String, on running: OperatingSystemVersion) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let release = [parts.first ?? 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0]
        let current = [running.majorVersion, running.minorVersion, running.patchVersion]
        return release == current || release.lexicographicallyPrecedes(current)
    }
}

// MARK: - Sounds

/// The sound catalogue of a project and its search (docs/data.md › Picker catalogues), as V2's `SoundCatalog`: the
/// macOS sounds, the sounds of the installed Simulator runtimes and the project's sound files.
public struct SoundCatalog: Sendable {
    /// The extensions of a sound file, lowercased.
    public static let extensions: Set<String> = ["caf", "aiff", "wav", "mp3"]
    public static let macOSSource = "macOS"
    public static let projectSource = "Project"
    public static let macOSFolder = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    /// The folder of a Simulator runtime's sounds, relative to its root.
    public static let runtimeSoundsFolder = "System/Library/Audio/UISounds"
    static let simctlTimeout: Duration = .seconds(30)

    /// An installed Simulator runtime: its name, `<platform> <version>`, and its root folder.
    public struct Runtime: Sendable, Hashable {
        public var name: String
        public var root: URL

        public init(name: String, root: URL) {
            self.name = name
            self.root = root
        }
    }

    /// The macOS and Simulator runtime sounds.
    public struct SystemSounds: Sendable {
        /// The names in catalogue order: the macOS sounds, then each runtime's.
        public let names: [String]
        public let files: [String: URL]
        public let problems: [String]

        public static let none = SystemSounds(names: [], files: [:], problems: [])

        init(names: [String], files: [String: URL], problems: [String]) {
            self.names = names
            self.files = files
            self.problems = problems
        }

        /// The sounds of `macOSFolder`, then of the runtimes in the order of their names; a runtime whose name
        /// was already read is skipped.
        public static func read(macOSFolder: URL, runtimes: [Runtime], problems: [String] = []) -> SystemSounds {
            var names: [String] = []
            var files: [String: URL] = [:]
            func add(source: String, paths: [String], folder: URL) {
                for path in paths {
                    let name = "\(source)/\(path)"
                    guard files[name] == nil else { continue }
                    names.append(name)
                    files[name] = folder.appendingPathComponent(path)
                }
            }
            add(source: SoundCatalog.macOSSource, paths: SoundCatalog.soundFiles(in: macOSFolder, recursive: false), folder: macOSFolder)
            var seen = Set<String>()
            var ordered: [Runtime] = []
            for runtime in runtimes where seen.insert(runtime.name).inserted {
                ordered.append(runtime)
            }
            ordered.sort { SoundCatalog.finderOrder($0.name, $1.name) }
            for runtime in ordered {
                let folder = runtime.root.appendingPathComponent(SoundCatalog.runtimeSoundsFolder, isDirectory: true)
                add(source: runtime.name, paths: SoundCatalog.soundFiles(in: folder, recursive: true), folder: folder)
            }
            return SystemSounds(names: names, files: files, problems: problems)
        }
    }

    public let system: SystemSounds
    /// The project's sound files, as paths from its folder, in Finder order.
    public let projectPaths: [String]
    public let projectRoot: URL
    private let projectSet: Set<String>

    public init(system: SystemSounds, projectRoot: URL, projectPaths: [String]) {
        self.system = system
        self.projectRoot = projectRoot
        let paths = projectPaths.filter { Self.isSoundFile($0) && Self.canBeMarked("\(Self.projectSource)/\($0)") }
            .sorted(by: Self.finderOrder)
        self.projectPaths = paths
        projectSet = Set(paths)
    }

    /// Every name, in catalogue order: the macOS sounds, each runtime's, then the project's.
    public var names: [String] {
        system.names + projectPaths.map { "\(Self.projectSource)/\($0)" }
    }

    public func contains(_ name: String) -> Bool {
        file(for: name) != nil
    }

    /// The file of a sound of the catalogue; nil for another name.
    public func file(for name: String) -> URL? {
        if let file = system.files[name] { return file }
        let prefix = Self.projectSource + "/"
        guard name.hasPrefix(prefix) else { return nil }
        let path = String(name.dropFirst(prefix.count))
        guard projectSet.contains(path) else { return nil }
        return projectRoot.appendingPathComponent(path)
    }

    /// The source of a name, the part before its first `/`.
    public static func source(of name: String) -> String {
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[..<slash])
    }

    /// The file of a name, the part after its first `/`.
    public static func file(of name: String) -> String {
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// A path whose extension is `.caf`, `.aiff`, `.wav` or `.mp3`, in any letter case.
    public static func isSoundFile(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// A name a sound marker can carry: no line break, balanced parentheses, no white space at either end.
    public static func canBeMarked(_ name: String) -> Bool {
        guard let first = name.first, let last = name.last, !first.isWhitespace, !last.isWhitespace,
              !name.contains(where: \.isNewline) else { return false }
        var depth = 0
        for character in name {
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    /// Finder order (`localizedStandardCompare`).
    static func finderOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    /// The names that contain every word of the trimmed, lowercased query, in the order of `names`, without
    /// `excluded`; nothing for an empty query.
    public static func search(_ query: String, in names: [String], excluding excluded: Set<String> = []) -> [String] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return names.filter { name in
            guard !excluded.contains(name) else { return false }
            let lowercased = name.lowercased()
            return words.allSatisfy { lowercased.contains($0) }
        }
    }

    /// The sound files of a folder, as paths from it, in Finder order: regular files with a sound extension,
    /// names starting with `.` and symbolic links skipped; at any depth when `recursive`.
    static func soundFiles(in folder: URL, recursive: Bool) -> [String] {
        var paths: [String] = []
        func visit(_ directory: URL, prefix: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let url = directory.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    if isSoundFile(name) { paths.append(path) }
                case S_IFDIR:
                    if recursive { visit(url, prefix: path) }
                default:
                    continue
                }
            }
        }
        visit(folder, prefix: "")
        return paths.filter { canBeMarked("x/\($0)") }.sorted(by: finderOrder)
    }

    /// The installed Simulator runtimes: `/usr/bin/xcrun simctl list runtimes --json`, 30 s at most; none when it
    /// fails, with the reason.
    static func listRuntimes(runner: any ProcessRunning, environment: [String: String]) async -> (runtimes: [Runtime], problems: [String]) {
        let request = ProcessRequest(executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "runtimes", "--json"],
                                     environment: ShellEnvironment.forChildren(environment))
        guard let result = try? await runner.run(request, timeout: simctlTimeout) else { return ([], ["xcrun can't be started."]) }
        guard result.succeeded else { return ([], ["xcrun simctl list runtimes failed."]) }
        guard let runtimes = runtimes(fromSimctlJSON: result.standardOutput) else { return ([], ["xcrun simctl printed no readable JSON."]) }
        return (runtimes, [])
    }

    /// The `name` and `runtimeRoot` of each entry of `runtimes`, in the order listed; nil for other output.
    static func runtimes(fromSimctlJSON data: Data) -> [Runtime]? {
        struct Output: Decodable {
            struct Entry: Decodable {
                var name: String?
                var runtimeRoot: String?
            }
            var runtimes: [Entry]
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else { return nil }
        return output.runtimes.compactMap { entry in
            guard let name = entry.name, !name.isEmpty, !name.contains("/"), let root = entry.runtimeRoot, root.hasPrefix("/") else { return nil }
            return Runtime(name: name, root: URL(fileURLWithPath: root, isDirectory: true))
        }
    }
}

// MARK: - Fonts

/// A face of a font family: its style name, its weight from -1 to 1, and where it comes from.
public struct FontFace: Sendable, Hashable {
    /// The style name, such as `Demi Bold`: the weight of the font notation.
    public var name: String
    public var weight: Double
    public var italic: Bool
    /// Empty for the system designs.
    public var postScriptName: String
    /// The file of a project's face; nil for an installed one.
    public var file: URL?

    public init(name: String, weight: Double, italic: Bool, postScriptName: String, file: URL? = nil) {
        self.name = name
        self.weight = weight
        self.italic = italic
        self.postScriptName = postScriptName
        self.file = file
    }
}

/// A font family and its faces, sorted.
public struct FontFamily: Sendable, Hashable {
    public var name: String
    public var faces: [FontFace]

    public init(name: String, faces: [FontFace]) {
        self.name = name
        self.faces = faces
    }
}

/// The font catalogue of a project on the Mac (docs/data.md › Picker catalogues), as V2's `FontCatalog`: the system
/// designs, the installed families, the project's font files' families and the text styles, with the search and
/// the nearest weight.
public struct FontCatalog: Sendable {
    /// The system designs, in the order of the search.
    public static let systemDesigns = ["System", "System Rounded", "System Serif", "System Monospaced"]

    /// The nine weights of the system designs, with the values of SwiftUI's weights.
    public static let systemWeights: [FontFace] = [
        ("Ultralight", -0.8), ("Thin", -0.6), ("Light", -0.4), ("Regular", 0), ("Medium", 0.23), ("Semibold", 0.3),
        ("Bold", 0.4), ("Heavy", 0.56), ("Black", 0.62),
    ].map { FontFace(name: $0.0, weight: $0.1, italic: false, postScriptName: "") }

    /// The extensions of a project's font files, lowercased.
    public static let fontFileExtensions: Set<String> = ["ttf", "otf", "ttc"]

    /// The system designs, then the other families in alphabetical order.
    public let families: [FontFamily]
    private let positions: [String: Int]

    /// A project family with an installed family's name adds the faces whose style name the installed one lacks;
    /// a family named like a system design is left out.
    public init(installed: [FontFamily], project: [FontFamily]) {
        var merged: [String: FontFamily] = [:]
        for family in installed + project where !Self.systemDesigns.contains(family.name) {
            guard var existing = merged[family.name] else {
                merged[family.name] = family
                continue
            }
            let names = Set(existing.faces.map(\.name))
            existing.faces = Self.sortedFaces(existing.faces + family.faces.filter { !names.contains($0.name) })
            merged[family.name] = existing
        }
        let others = merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        families = Self.systemDesigns.map { FontFamily(name: $0, faces: Self.systemWeights) } + others
        var positions: [String: Int] = [:]
        for (index, family) in families.enumerated() {
            positions[family.name] = index
        }
        self.positions = positions
    }

    public static func isSystemDesign(_ name: String) -> Bool {
        systemDesigns.contains(name)
    }

    public func family(named name: String) -> FontFamily? {
        positions[name].map { families[$0] }
    }

    /// The face of a family font; nil when the catalogue has no such family or weight.
    public func face(family: String, weight: String) -> FontFace? {
        self.family(named: family)?.faces.first { $0.name == weight }
    }

    /// Whether the font is in the catalogue: a text style, or a family and one of its weights.
    public func contains(_ font: FontNotation) -> Bool {
        switch font {
        case .textStyle: true
        case .family(let family, let weight, _): face(family: family, weight: weight) != nil
        }
    }

    /// A row of the search's results.
    public enum SearchResult: Sendable, Hashable {
        case family(String)
        case textStyle(FontTextStyle)
    }

    /// The families whose name contains every word of the query, then the text styles whose notation does,
    /// compared in lowercase; every family and text style for an empty query. Text styles that are suggestions
    /// are left out.
    public func search(_ query: String, excludingSuggestions suggestions: [String] = []) -> [SearchResult] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func matches(_ name: String) -> Bool {
            let lowercased = name.lowercased()
            return words.allSatisfy { lowercased.contains($0) }
        }
        let suggested = Set(suggestions)
        let families = families.filter { matches($0.name) }.map { SearchResult.family($0.name) }
        let styles = FontTextStyle.allCases.filter { !suggested.contains($0.notation) && matches($0.notation) }.map { SearchResult.textStyle($0) }
        return families + styles
    }

    /// The weight the menu takes when `family` is chosen in the results: the face named `name`, else the one whose
    /// value is nearest `value`, an upright face before an italic one on a tie, then the first in the family's
    /// order.
    public static func nearestFace(name: String, value: Double, in family: FontFamily) -> FontFace? {
        if let same = family.faces.first(where: { $0.name == name }) { return same }
        var best: FontFace?
        for face in family.faces {
            guard let current = best else {
                best = face
                continue
            }
            let distance = abs(face.weight - value), bestDistance = abs(current.weight - value)
            if distance < bestDistance - 1e-9 || (abs(distance - bestDistance) <= 1e-9 && current.italic && !face.italic) {
                best = face
            }
        }
        return best
    }

    /// The face that draws a family's name in the results: its `Regular` face, else the one nearest 0.
    public static func nameFace(of family: FontFamily) -> FontFace? {
        nearestFace(name: "Regular", value: 0, in: family)
    }

    /// Faces by value, upright before italic, then by name.
    public static func sortedFaces(_ faces: [FontFace]) -> [FontFace] {
        faces.sorted { a, b in
            if a.weight != b.weight { return a.weight < b.weight }
            if a.italic != b.italic { return !a.italic }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Every family CoreText lists on this Mac, with its faces.
    public static func readInstalledFamilies() -> [FontFamily] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        var families: [FontFamily] = []
        for name in names where !name.hasPrefix(".") {
            let request = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
            let mandatory = Set([kCTFontFamilyNameAttribute as String]) as CFSet
            let descriptors = CTFontDescriptorCreateMatchingFontDescriptors(request, mandatory) as? [CTFontDescriptor] ?? []
            var faces: [FontFace] = []
            for descriptor in descriptors {
                guard let face = face(of: descriptor, file: nil), !faces.contains(where: { $0.name == face.face.name }) else { continue }
                faces.append(face.face)
            }
            if !faces.isEmpty {
                families.append(FontFamily(name: name, faces: sortedFaces(faces)))
            }
        }
        return families
    }

    /// The families of a project's font files, in the order given: a face whose family and style name an earlier
    /// file gave is left out, a family named like a system design too, and a file CoreText can't read is skipped.
    public static func projectFamilies(files: [(path: String, url: URL)]) -> [FontFamily] {
        var faces: [String: [FontFace]] = [:]
        for file in files {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file.url as CFURL) as? [CTFontDescriptor] else { continue }
            for descriptor in descriptors {
                guard let found = face(of: descriptor, file: file.url), !isSystemDesign(found.family),
                      !(faces[found.family] ?? []).contains(where: { $0.name == found.face.name }) else { continue }
                faces[found.family, default: []].append(found.face)
            }
        }
        return faces.map { FontFamily(name: $0.key, faces: sortedFaces($0.value)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The family name and the face of a descriptor; nil without a family, style or PostScript name.
    static func face(of descriptor: CTFontDescriptor, file: URL?) -> (family: String, face: FontFace)? {
        guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String, !family.isEmpty,
              let style = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String, !style.isEmpty,
              let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return nil }
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [String: Any] ?? [:]
        let weight = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
        let symbolic = (traits[kCTFontSymbolicTrait as String] as? NSNumber)?.uint32Value ?? 0
        let italic = symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0
        return (family, FontFace(name: style, weight: (weight * 100).rounded() / 100, italic: italic, postScriptName: postScriptName, file: file))
    }
}
