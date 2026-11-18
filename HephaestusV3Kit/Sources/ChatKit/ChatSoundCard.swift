import AZDesign
import ChatData
import SwiftUI
import TextViews
import ToolsFoundation

/// Claude's request to choose a sound (docs/ui/chat.md › Sound card): the suggestions in a list, the recommended one
/// starred and preselected, a search over the Mac's and the project's sounds, a click playing the row's sound,
/// "Answer another way", Skip and Submit.
struct SoundCard: View {
    let request: PickerItem
    let projectID: Project.ID?
    let catalogs: PickerCatalogAccess
    var compact = false
    var allowsShortcut = true
    let answer: (String) async -> Bool

    /// The chosen sound; nil for "Answer another way".
    @State private var choice: String?
    @State private var otherText = ""
    @State private var query = ""
    @State private var catalog: SoundCatalog?
    @State private var listHeight: CGFloat = 40
    @State private var playFailure: String?
    @State private var isSending = false

    /// Eight rows show; more scroll inside the list.
    static let maxListHeight: CGFloat = 8 * 26

    init(request: PickerItem, projectID: Project.ID?, catalogs: PickerCatalogAccess, compact: Bool = false, allowsShortcut: Bool = true,
         answer: @escaping (String) async -> Bool) {
        self.request = request
        self.projectID = projectID
        self.catalogs = catalogs
        self.compact = compact
        self.allowsShortcut = allowsShortcut
        self.answer = answer
        // The recommended sound is chosen, without playing.
        _choice = State(initialValue: request.recommended.value)
    }

    private var suggestions: [String] { request.suggestions.map(\.value) }

    /// The suggestions, then the search's results; the suggestions alone while the field is empty.
    private var names: [String] {
        suggestions + (catalog.map { SoundCatalog.search(query, in: $0.names, excluding: Set(suggestions)) } ?? [])
    }

    var body: some View {
        PickerCardChrome(request: request, projectID: projectID, compact: compact, allowsShortcut: allowsShortcut,
                         canSubmit: SymbolCard.canSubmit(choice: choice, other: otherText), isSending: isSending,
                         skip: { send(PickerItem.skipped) },
                         submit: { send(SymbolCard.answer(request: request, choice: choice, other: otherText)) }) {
            TextField(String(localized: "Search sounds", bundle: #bundle), text: $query, prompt: Text("Search sounds", bundle: #bundle))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("chat.sound.search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(names.enumerated()), id: \.element) { index, name in
                        row(name, index: index)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(listHeight, 26), Self.maxListHeight))
            OtherAnswerRow(isSelected: choice == nil, text: $otherText, identifier: "chat.sound") { choice = nil }
        }
        .task {
            catalog = await catalogs.sounds()
        }
        .alert(String(localized: "Play Sound failed", bundle: #bundle, comment: "A sound of a marker couldn't be played"),
               isPresented: Binding(get: { playFailure != nil }, set: { if !$0 { playFailure = nil } })) {
            Button(String(localized: "OK", bundle: #bundle)) { playFailure = nil }
        } message: {
            Text(verbatim: playFailure ?? "")
        }
    }

    /// `sms-received1.caf · iOS 26.1`: the file, then its source.
    private func row(_ name: String, index: Int) -> some View {
        let isSelected = choice == name
        return Button {
            choice = name
            play(name)
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: SoundCatalog.file(of: name))
                    .foregroundStyle(.textPrimary)
                Text(verbatim: "· " + SoundCatalog.source(of: name))
                    .foregroundStyle(.textSecondary)
                Spacer(minLength: 4)
                if name == request.recommended.value {
                    RecommendedStar()
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .pickerSelection(isSelected)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chat.sound.row.\(index)")
    }

    /// Plays the row's sound, even when it is already chosen; one sound at a time.
    private func play(_ name: String) {
        Task {
            var found = catalog
            if found == nil {
                found = await catalogs.sounds()
                catalog = found
            }
            guard let url = found?.file(for: name) else {
                playFailure = String(localized: "\(name) is not a sound of this Mac or of the project.", bundle: #bundle)
                return
            }
            playFailure = SoundPlayer.shared.play(url)
        }
    }

    private func send(_ text: String) {
        isSending = true
        Task {
            _ = await answer(text)
            isSending = false
        }
    }
}

#Preview("Sound Card, Waiting", traits: .appChrome, .fixedLayout(width: 560, height: 420)) {
    SoundCard(request: .preview(.sound), projectID: nil, catalogs: .samples) { _ in true }
        .padding()
}

#Preview("Sound Card, Dark", traits: .appChrome, .fixedLayout(width: 560, height: 420)) {
    SoundCard(request: .preview(.sound), projectID: nil, catalogs: .samples) { _ in true }
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Sound Card, Narrow, Largest Text", traits: .largestText, .fixedLayout(width: 340, height: 600)) {
    SoundCard(request: .preview(.sound), projectID: nil, catalogs: .samples, compact: true) { _ in true }
        .padding()
}
