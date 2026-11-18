import AZDesign
import ChatData
import SwiftUI

/// Claude's questions waiting for the user's answers, over the composer (docs/ui/chat.md › Questions): one
/// question at a time, its recommended options preselected, "Answer another way", Skip, and Next or Submit.
struct QuestionsCard: View {
    let questionSet: ChatQuestionSet
    /// Tighter, for the side panel.
    var compact = false
    /// Stores an answer; false when it wasn't taken.
    let answer: (_ label: String, _ text: String) async -> Bool

    /// The question shown, by index.
    @State private var displayed = 0
    /// The single question's choice: an option's label; nil for "Answer another way".
    @State private var choice: String?
    @State private var otherText = ""
    /// The multiple question's checked options, by label.
    @State private var checked: Set<String> = []
    /// The multiple question's own answers; the last one is always empty.
    @State private var own: [String] = [""]
    @State private var isMinimized = false
    /// The question and its options' height, which the card takes up to its maximum, then scrolls.
    @State private var contentHeight: CGFloat = 120
    @State private var isSending = false

    private var question: ChatQuestion { questionSet.questions[min(displayed, questionSet.questions.count - 1)] }

    var body: some View {
        Group {
            if isMinimized {
                Button {
                    isMinimized = false
                } label: {
                    HStack {
                        Text(header)
                            .font(.headline)
                            .foregroundStyle(.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up")
                            .foregroundStyle(.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Show the Questions", bundle: #bundle))
                .accessibilityIdentifier("chat.questions.expand")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    headerRow
                    ScrollView {
                        questionContent
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(contentHeight, compact ? 300 : 380))
                    buttons
                }
            }
        }
        .padding(12)
        .background(.surface, in: CardShape(minimum: 10))
        .overlay {
            CardShape(minimum: 10)
                .stroke(Color.accent.opacity(0.5), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.questions")
        .onAppear { show(questionSet.firstUnanswered) }
        .onChange(of: questionSet.id) { show(questionSet.firstUnanswered) }
        .onChange(of: questionSet.answers[question.label]) { load() }
    }

    /// "Question B (2 of 3)".
    private var header: String {
        String(localized: "Question \(question.label) (\(displayed + 1) of \(questionSet.questions.count))", bundle: #bundle,
               comment: "The questions card's title: a question's label, its place and the number of questions")
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(header)
                .font(.headline)
                .foregroundStyle(.textPrimary)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("chat.questions.header")
            Spacer(minLength: 8)
            Button(String(localized: "Previous Question", bundle: #bundle), systemImage: "chevron.left") { show(displayed - 1) }
                .disabled(displayed == 0)
                .accessibilityIdentifier("chat.questions.previous")
            Button(String(localized: "Next Question", bundle: #bundle), systemImage: "chevron.right") { show(displayed + 1) }
                .disabled(displayed >= questionSet.questions.count - 1)
                .accessibilityIdentifier("chat.questions.next")
            Button(String(localized: "Minimize", bundle: #bundle, comment: "Folds the questions card into one line"), systemImage: "chevron.down") {
                isMinimized = true
            }
            .accessibilityIdentifier("chat.questions.minimize")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private var questionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ChatTurnView.markdown(question.question))
                .foregroundStyle(.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.questions.text")
            if question.kind == .multiple {
                Text(choiceBounds)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
            }
            ForEach(Array(question.options.enumerated()), id: \.element.label) { index, option in
                optionRow(option, index: index)
            }
            if question.kind == .single {
                otherRow
            } else {
                ownAnswers
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Choose 1 to 3", "Choose 2", or "Choose at least 1".
    private var choiceBounds: String {
        let low = question.minChoices ?? 1
        if let high = question.maxChoices {
            return low == high
                ? String(localized: "Choose \(low)", bundle: #bundle, comment: "A multiple question: the number of choices to make")
                : String(localized: "Choose \(low) to \(high)", bundle: #bundle, comment: "A multiple question: the fewest and the most choices")
        }
        return String(localized: "Choose at least \(low)", bundle: #bundle, comment: "A multiple question without a maximum")
    }

    private func optionRow(_ option: ChatQuestion.Option, index: Int) -> some View {
        let isOn = question.kind == .single ? choice == option.label : checked.contains(option.label)
        let symbol = question.kind == .single ? (isOn ? "largecircle.fill.circle" : "circle") : (isOn ? "checkmark.square.fill" : "square")
        return Button {
            if question.kind == .single {
                choice = option.label
            } else if checked.contains(option.label) {
                checked.remove(option.label)
            } else {
                checked.insert(option.label)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(isOn ? Color.accent : Color.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: option.label)
                            .fontWeight(.semibold)
                            .foregroundStyle(.textPrimary)
                        if question.recommended.contains(option.label) {
                            RecommendedTag()
                        }
                    }
                    if let description = option.description {
                        Text(verbatim: description)
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("chat.questions.option.\(index)")
    }

    /// The single question's last row: its own radio button and a field of one to six lines.
    private var otherRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                choice = nil
            } label: {
                Image(systemName: choice == nil ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == nil ? Color.accent : Color.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Answer another way", bundle: #bundle))
            .accessibilityAddTraits(choice == nil ? .isSelected : [])
            .accessibilityIdentifier("chat.questions.other")
            TextField(String(localized: "Answer another way", bundle: #bundle), text: $otherText,
                      prompt: Text("Answer another way", bundle: #bundle), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onChange(of: otherText) {
                    if !otherText.isEmpty { choice = nil }
                }
                .accessibilityIdentifier("chat.questions.other.field")
        }
    }

    /// The multiple question's own answers: one-line fields, a new empty one after the last that has text.
    private var ownAnswers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Answer another way", bundle: #bundle)
                .font(.callout)
                .foregroundStyle(.textSecondary)
            ForEach(own.indices, id: \.self) { index in
                TextField(String(localized: "Your answer", bundle: #bundle), text: Binding(
                    get: { own.indices.contains(index) ? own[index] : "" },
                    set: { setOwn($0, at: index) }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("chat.questions.own.\(index)")
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(String(localized: "Skip", bundle: #bundle, comment: "Skips one of Claude's questions")) {
                submit(QuestionsItem.skipped)
            }
            .disabled(isSending)
            .accessibilityIdentifier("chat.questions.skip")
            Button(questionSet.completes(at: displayed) ? String(localized: "Submit", bundle: #bundle, comment: "Sends the answers to Claude's questions")
                                                : String(localized: "Next", bundle: #bundle, comment: "Answers a question and shows the next one")) {
                submit(currentAnswer)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isSending || !canSubmit)
            .help(String(localized: "Answer (⌘↩)", bundle: #bundle))
            .accessibilityIdentifier("chat.questions.submit")
        }
    }

    /// The displayed question's answer as chosen: the option's label or the text; for a multiple question one
    /// line `- <choice>` per choice, the checked options in option order, then the own answers in order.
    private var currentAnswer: String {
        if question.kind == .single {
            return choice ?? otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let options = question.options.map(\.label).filter(checked.contains)
        let texts = own.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (options + texts).map { "- \($0)" }.joined(separator: "\n")
    }

    private var canSubmit: Bool {
        if question.kind == .single {
            return choice != nil || !otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let count = checked.count + own.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return question.accepts(choices: count)
    }

    private func submit(_ text: String) {
        let label = question.label
        let index = displayed
        isSending = true
        Task {
            let taken = await answer(label, text)
            isSending = false
            guard taken, let next = questionSet.nextUnanswered(after: index, answered: label) else { return }
            show(next)
        }
    }

    private func show(_ index: Int) {
        guard !questionSet.questions.isEmpty else { return }
        displayed = max(0, min(index, questionSet.questions.count - 1))
        load()
    }

    /// The displayed question's selection: its answer, else its recommended options.
    private func load() {
        let current = question
        let given = questionSet.answers[current.label]
        if current.kind == .single {
            if let given {
                choice = current.options.contains { $0.label == given } ? given : nil
                otherText = choice == nil ? given : ""
            } else {
                choice = current.recommended.first
                otherText = ""
            }
        } else if let given {
            let lines = given.split(separator: "\n").map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
            checked = Set(lines.filter { line in current.options.contains { $0.label == line } })
            own = lines.filter { line in !current.options.contains { $0.label == line } } + [""]
        } else {
            checked = Set(current.recommended)
            own = [""]
        }
    }

    /// A field's text: the list always ends with one empty field, and a field emptied before it goes.
    private func setOwn(_ text: String, at index: Int) {
        guard own.indices.contains(index) else { return }
        own[index] = text
        if text.isEmpty, index < own.count - 1 {
            own.remove(at: index)
        }
        if own.last?.isEmpty == false {
            own.append("")
        }
    }
}

/// "Recommended", beside an option.
private struct RecommendedTag: View {
    var body: some View {
        Text("Recommended", bundle: #bundle, comment: "Marks the option Claude recommends")
            .font(.caption)
            .foregroundStyle(.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accent.opacity(0.14), in: .capsule)
    }
}

/// Claude's questions in the transcript: each question, its options, and its answer so far.
struct QuestionsSummary: View {
    let questionSet: ChatQuestionSet

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Questions", bundle: #bundle, comment: "The title of Claude's questions in the transcript")
                    .font(.headline)
                    .foregroundStyle(.textPrimary)
            } icon: {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(.accent)
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isHeader)
            ForEach(questionSet.questions, id: \.label) { question in
                VStack(alignment: .leading, spacing: 3) {
                    Text(ChatTurnView.markdown("\(question.label). \(question.question)"))
                        .foregroundStyle(.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(question.options, id: \.label) { option in
                        HStack(spacing: 6) {
                            Text(verbatim: option.description.map { "\(option.label) — \($0)" } ?? option.label)
                                .foregroundStyle(.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if question.recommended.contains(option.label) {
                                RecommendedTag()
                            }
                        }
                        .font(.callout)
                    }
                    answerLine(question)
                        .font(.callout)
                }
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surface, in: CardShape(minimum: 10))
        .overlay {
            CardShape(minimum: 10)
                .stroke(Color.divider, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.questionSet.\(questionSet.id)")
    }

    @ViewBuilder private func answerLine(_ question: ChatQuestion) -> some View {
        if let answer = questionSet.answers[question.label] {
            Text("Answer: \(answer)", bundle: #bundle, comment: "The user's answer to one of Claude's questions")
                .foregroundStyle(.textPrimary)
        } else {
            Text("Not answered yet", bundle: #bundle)
                .foregroundStyle(.textSecondary)
        }
    }
}

// MARK: - Previews

extension ChatQuestionSet {
    static let preview = ChatQuestionSet(id: "preview.questions", questions: [
        ChatQuestion(label: "A", question: "Should **⌘W** on a locked tab do nothing, or select the next tab?", options: [
            .init(label: "Do nothing and beep", description: "The tab never closes, as its lock promises."),
            .init(label: "Select the next tab", description: "⌘W still moves away from the locked tab."),
        ], recommended: ["Do nothing and beep"]),
        ChatQuestion(label: "B", question: "Which tabs can be locked?", kind: .multiple, options: [
            .init(label: "Web tabs"), .init(label: "Editor tabs"), .init(label: "Docs tabs"),
        ], recommended: ["Web tabs", "Editor tabs"], maxChoices: 3),
    ])
}

#Preview("Questions, Single", traits: .appChrome, .fixedLayout(width: 560, height: 360)) {
    QuestionsCard(questionSet: .preview) { _, _ in true }
        .padding()
}

#Preview("Questions, Multiple, Dark", traits: .appChrome, .fixedLayout(width: 560, height: 360)) {
    var questionSet = ChatQuestionSet.preview
    questionSet.answers = ["A": "Do nothing and beep"]
    return QuestionsCard(questionSet: questionSet) { _, _ in true }
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Questions, Narrow, Largest Text", traits: .largestText, .fixedLayout(width: 340, height: 700)) {
    QuestionsCard(questionSet: .preview, compact: true) { _, _ in true }
        .padding()
}

#Preview("Questions in the Transcript", traits: .appChrome, .fixedLayout(width: 560, height: 420)) {
    var questionSet = ChatQuestionSet.preview
    questionSet.answers = ["A": "Do nothing and beep", "B": "- Web tabs\n- Terminal tabs"]
    return QuestionsSummary(questionSet: questionSet)
        .padding()
}
