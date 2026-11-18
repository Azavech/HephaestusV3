import AppKit
import AZDesign
import ChatData
import SwiftUI
import TextFormats
import ToolsFoundation

/// What the shortcut card holds (docs/ui/chat.md › Shortcut card).
enum ShortcutChoice: Hashable {
    /// A suggestion, by its notation.
    case suggestion(String)
    /// The recorder field.
    case recorder
    /// "Answer another way".
    case other
}

/// Claude's request to choose a keyboard shortcut (docs/ui/chat.md › Shortcut card): the suggestions as key caps,
/// the recommended one starred and preselected, the recorder field, the warnings of the chosen shortcut, "Answer
/// another way", Skip and Submit.
struct ShortcutCard: View {
    let request: PickerItem
    let projectID: Project.ID?
    var compact = false
    var allowsShortcut = true
    let answer: (String) async -> Bool

    @State private var choice: ShortcutChoice
    @State private var recorded: KeyShortcut?
    @State private var isRecording = false
    @State private var recording = ShortcutRecording()
    @State private var otherText = ""
    @State private var isSending = false

    init(request: PickerItem, projectID: Project.ID?, compact: Bool = false, allowsShortcut: Bool = true, answer: @escaping (String) async -> Bool) {
        self.request = request
        self.projectID = projectID
        self.compact = compact
        self.allowsShortcut = allowsShortcut
        self.answer = answer
        _choice = State(initialValue: .suggestion(request.recommended.value))
    }

    var body: some View {
        PickerCardChrome(request: request, projectID: projectID, compact: compact, allowsShortcut: allowsShortcut && !isRecording,
                         canSubmit: Self.canSubmit(choice: choice, recorded: recorded, other: otherText), isSending: isSending,
                         skip: { send(PickerItem.skipped) },
                         submit: { send(Self.answer(choice: choice, recorded: recorded, other: otherText)) }) {
            FlowStack(spacing: 6) {
                ForEach(Array(request.suggestions.enumerated()), id: \.offset) { index, suggestion in
                    suggestionButton(suggestion.value, index: index)
                }
            }
            recorder
            let warnings = Self.warnings(for: Self.selected(choice: choice, recorded: recorded), inUse: request.inUse)
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { index, line in
                        Label(line, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.warning)
                            .accessibilityIdentifier("chat.shortcut.warning.\(index)")
                    }
                }
            }
            OtherAnswerRow(isSelected: choice == .other, text: $otherText, identifier: "chat.shortcut") {
                stopRecording()
                choice = .other
            }
        }
        .onDisappear { recording.stop() }
    }

    private func suggestionButton(_ shortcut: String, index: Int) -> some View {
        let isSelected = choice == .suggestion(shortcut)
        return Button {
            stopRecording()
            choice = .suggestion(shortcut)
        } label: {
            KeyCaps(caps: KeyShortcut.keyCaps(of: shortcut) ?? [shortcut])
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .pickerSelection(isSelected)
                .overlay(alignment: .topTrailing) {
                    if shortcut == request.recommended.value { RecommendedStar() }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(shortcut)
        .accessibilityLabel(shortcut)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chat.shortcut.suggestion.\(index)")
    }

    /// The recorded shortcut as key caps, or "Record Shortcut"; a click chooses it and starts recording. Chosen, it
    /// has the selection's outline; while it records, a 2 pt `accent` border on the sunken surface.
    private var recorder: some View {
        let isSelected = choice == .recorder
        return HStack {
            if let recorded {
                KeyCaps(caps: recorded.keyCaps)
            } else {
                Text("Record Shortcut", bundle: #bundle, comment: "The placeholder of the field that records a key combination")
                    .foregroundStyle(.textSecondary)
            }
        }
        .frame(minWidth: 160, minHeight: 22, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isRecording ? Color.surfaceSunken : .clear, in: CardShape(minimum: 6))
        .pickerSelection(isSelected && !isRecording)
        .overlay {
            CardShape(minimum: 6).stroke(isRecording ? Color.accent : Color.textSecondary.opacity(0.3), lineWidth: isRecording ? 2 : 1)
        }
        .contentShape(.rect)
        .onTapGesture { startRecording() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recorded?.notation ?? String(localized: "Record Shortcut", bundle: #bundle, comment: "The placeholder of the field that records a key combination"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chat.shortcut.recorder")
    }

    private func startRecording() {
        choice = .recorder
        isRecording = true
        recording.start { shortcut in
            recorded = shortcut
        } stopped: {
            isRecording = false
        }
    }

    private func stopRecording() {
        recording.stop()
        isRecording = false
    }

    private func send(_ text: String) {
        stopRecording()
        isSending = true
        Task {
            _ = await answer(text)
            isSending = false
        }
    }

    /// The chosen shortcut: a suggestion, or the recorder's; nil for "Answer another way" and an empty recorder.
    static func selected(choice: ShortcutChoice, recorded: KeyShortcut?) -> String? {
        switch choice {
        case .suggestion(let shortcut): shortcut
        case .recorder: recorded?.notation
        case .other: nil
        }
    }

    /// `Used by macOS: <action>`, then `Used by the app: <command>`, for the chosen shortcut.
    static func warnings(for shortcut: String?, inUse: [ShortcutInUse]) -> [String] {
        guard let shortcut else { return [] }
        var lines: [String] = []
        if let action = StandardShortcuts.action(for: shortcut) {
            lines.append(String(localized: "Used by macOS: \(action)", bundle: #bundle, comment: "A shortcut macOS already uses, then its action"))
        }
        if let command = inUse.first(where: { $0.shortcut == shortcut })?.command {
            lines.append(String(localized: "Used by the app: \(command)", bundle: #bundle, comment: "A shortcut the app already uses, then its command"))
        }
        return lines
    }

    /// `![](shortcut:<shortcut>)` for the chosen shortcut, else the field's text, trimmed.
    static func answer(choice: ShortcutChoice, recorded: KeyShortcut?, other: String) -> String {
        if let shortcut = selected(choice: choice, recorded: recorded).flatMap(KeyShortcut.init) { return shortcut.marker }
        return other.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func canSubmit(choice: ShortcutChoice, recorded: KeyShortcut?, other: String) -> Bool {
        switch choice {
        case .suggestion: true
        case .recorder: recorded != nil
        case .other: !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// A shortcut drawn as key caps: one per modifier and one for the key, each on the sunken surface.
struct KeyCaps: View {
    let caps: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(verbatim: cap)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.textPrimary)
                    .frame(minWidth: 14)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.surfaceSunken, in: CardShape(minimum: 4))
                    .overlay {
                        CardShape(minimum: 4).stroke(Color.textSecondary.opacity(0.5), lineWidth: 1)
                    }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// The recorder's watch of the keyboard: while it records, every key press of the app goes to it, menus and the
/// cards' ⌘Return included; a modifier alone records nothing; a key the notation can't write records nothing and
/// recording goes on; a click anywhere, or a window losing its key status, stops it.
@MainActor
final class ShortcutRecording {
    private var monitors: [Any] = []
    private var observer: NSObjectProtocol?

    func start(record: @escaping @MainActor (KeyShortcut) -> Void, stopped: @escaping @MainActor () -> Void) {
        stop()
        let finish: @MainActor () -> Void = { [weak self] in
            self?.stop()
            stopped()
        }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            MainActor.assumeIsolated {
                if let shortcut = Self.shortcut(of: event) {
                    record(shortcut)
                    finish()
                }
            }
            return nil
        }) {
            monitors.append(keys)
        }
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            MainActor.assumeIsolated { finish() }
            return event
        }) {
            monitors.append(clicks)
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { finish() }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// The shortcut of a key press: its key, written as the notation writes it, and the held modifiers among ⌃ ⌥ ⇧
    /// ⌘; nil when the notation can't write the key.
    static func shortcut(of event: NSEvent) -> KeyShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [KeyShortcut.Modifier] = []
        if flags.contains(.control) { modifiers.append(.control) }
        if flags.contains(.option) { modifiers.append(.option) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        if flags.contains(.command) { modifiers.append(.command) }
        guard let key = KeyShortcut.recordedKey(keyCode: event.keyCode, unmodifiedCharacters: event.characters(byApplyingModifiers: [])) else { return nil }
        return KeyShortcut(modifiers: modifiers, key: key)
    }
}

#Preview("Shortcut Card, Waiting", traits: .appChrome, .fixedLayout(width: 560, height: 360)) {
    ShortcutCard(request: .preview(.shortcut), projectID: nil) { _ in true }
        .padding()
}

#Preview("Shortcut Card, Warning, Dark", traits: .appChrome, .fixedLayout(width: 560, height: 360)) {
    var request = PickerItem.preview(.shortcut)
    request.recommended = PickerSuggestion("⌘L")
    return ShortcutCard(request: request, projectID: nil) { _ in true }
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Shortcut Card, Narrow, Largest Text", traits: .largestText, .fixedLayout(width: 340, height: 560)) {
    ShortcutCard(request: .preview(.shortcut), projectID: nil, compact: true) { _ in true }
        .padding()
}
