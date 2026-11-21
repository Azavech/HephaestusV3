import FileStorage
import Foundation
import MCPKit

/// A question of a set Claude asks the user with `ask_questions` (docs/data.md › Chat items › Questions), as V2's
/// `Question`.
public struct ChatQuestion: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// The user chooses one option, or answers another way.
        case single
        /// The user checks every option that applies, and may add answers of their own.
        case multiple
    }

    public struct Option: Sendable, Hashable {
        /// One line, at most 200 characters: the answer as reported when chosen.
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    /// `A` for the first question of the set, `B` for the second…
    public var label: String
    /// Markdown.
    public var question: String
    public var kind: Kind
    /// The recommended ones first, as the app stores them.
    public var options: [Option]
    /// One label in a single question; one or more in a multiple one, in option order.
    public var recommended: [String]
    /// Multiple questions only: the fewest choices; nil is 1.
    public var minChoices: Int?
    /// Multiple questions only: the most choices; nil is no maximum.
    public var maxChoices: Int?

    public init(label: String, question: String, kind: Kind = .single, options: [Option], recommended: [String], minChoices: Int? = nil,
                maxChoices: Int? = nil) {
        self.label = label
        self.question = question
        self.kind = kind
        self.options = options
        self.recommended = recommended
        self.minChoices = minChoices
        self.maxChoices = maxChoices
    }

    /// Whether `count` choices, checked options and own answers together, fit the question's bounds.
    public func accepts(choices count: Int) -> Bool {
        count >= (minChoices ?? 1) && count <= (maxChoices ?? .max)
    }
}

/// A set of questions waiting for the user's answers, or answered (docs/data.md › Chat items › Questions).
public struct QuestionsItem: Sendable, Hashable {
    public var id: String
    public var created: Date
    public var questionSetID: String
    public var questions: [ChatQuestion]
    /// By question label: the chosen option's label, the user's own text, `Skipped`, or for a multiple question
    /// one line `- <choice>` per choice.
    public var answers: [String: String]
    /// Every question has an answer; the answers went to Claude.
    public var completed: Bool

    public init(id: String, created: Date, questionSetID: String, questions: [ChatQuestion], answers: [String: String] = [:], completed: Bool = false) {
        self.id = id
        self.created = created
        self.questionSetID = questionSetID
        self.questions = questions
        self.answers = answers
        self.completed = completed
    }

    /// What a skipped question's answer reads.
    public static let skipped = "Skipped"

    /// The message that gives Claude the answers once every question has one: `Answers:`, then one line
    /// `<label>: <answer>` per question in label order; a multiple question's answer, unless skipped, after
    /// `<label>:` on its own lines.
    public func answersMessage() -> String {
        var lines = ["Answers:"]
        for question in questions {
            let answer = answers[question.label] ?? Self.skipped
            if question.kind == .multiple, answer != Self.skipped {
                lines.append("\(question.label):")
                lines.append(answer)
            } else {
                lines.append("\(question.label): \(answer)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Asking

    /// The questions of an `ask_questions` call, checked against the rules (docs/data.md › Questions), each
    /// with its recommended options moved first, in their order among the options. Throws the first rule broken.
    public static func questions(from input: JSONValue) throws(ToolError) -> [ChatQuestion] {
        let entries = input["questions"]?.arrayValue ?? []
        guard (1...26).contains(entries.count) else { throw ToolError(.invalid, "questions: give 1 to 26 questions.") }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
        var result: [ChatQuestion] = []
        for (index, entry) in entries.enumerated() {
            let label = entry["label"]?.stringValue ?? ""
            guard label == letters[index] else { throw ToolError(.invalid, "questions: question \(index + 1) has the label \"\(letters[index])\".") }
            let text = (entry["question"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ToolError(.invalid, "questions: question \(label) has no text.") }
            let kind = ChatQuestion.Kind(rawValue: entry["kind"]?.stringValue ?? "single") ?? .single
            let options = (entry["options"]?.arrayValue ?? []).map { option in
                ChatQuestion.Option(label: (option["label"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces),
                                    description: option["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
            }
            guard (2...10).contains(options.count) else { throw ToolError(.invalid, "questions: question \(label) has 2 to 10 options.") }
            let lowered = options.map { $0.label.lowercased() }
            guard !lowered.contains(""), Set(lowered).count == lowered.count else {
                throw ToolError(.invalid, "questions: question \(label) has an empty option label, or two the same.")
            }
            guard options.allSatisfy({ $0.label.count <= 200 && !$0.label.contains(where: \.isNewline) }) else {
                throw ToolError(.invalid, "questions: question \(label) has an option label of several lines or over 200 characters.")
            }
            let minChoices = entry["minChoices"]?.intValue
            let maxChoices = entry["maxChoices"]?.intValue
            if kind == .single, minChoices != nil || maxChoices != nil {
                throw ToolError(.invalid, "questions: question \(label) has minChoices or maxChoices without the kind multiple.")
            }
            let recommended = (entry["recommended"]?.arrayValue ?? []).compactMap(\.stringValue)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let labels = options.map(\.label)
            switch kind {
            case .single:
                guard recommended.count == 1, labels.contains(recommended[0]) else {
                    throw ToolError(.invalid, "questions: question \(label) recommends exactly one of its option labels.")
                }
            case .multiple:
                guard !recommended.isEmpty, Set(recommended).count == recommended.count, recommended.allSatisfy(labels.contains) else {
                    throw ToolError(.invalid, "questions: question \(label) recommends one or more of its option labels, each once.")
                }
                if let minChoices, minChoices < 1 { throw ToolError(.invalid, "questions: question \(label) has a minChoices under 1.") }
                if let maxChoices, maxChoices < 1 { throw ToolError(.invalid, "questions: question \(label) has a maxChoices under 1.") }
                if let maxChoices, (minChoices ?? 1) > maxChoices {
                    throw ToolError(.invalid, "questions: question \(label) has a minChoices over its maxChoices.")
                }
                if let maxChoices, recommended.count > maxChoices {
                    throw ToolError(.invalid, "questions: question \(label) recommends more options than its maxChoices.")
                }
            }
            let ordered = options.filter { recommended.contains($0.label) } + options.filter { !recommended.contains($0.label) }
            result.append(ChatQuestion(label: label, question: text, kind: kind, options: ordered,
                                       recommended: ordered.map(\.label).filter(recommended.contains), minChoices: minChoices, maxChoices: maxChoices))
        }
        return result
    }

    /// `answer` for the question `label`, checked: 1 to 10,000 characters once trimmed; for a multiple question,
    /// `Skipped` or one line `- <choice>` per choice, their number within the question's bounds. Returns it
    /// trimmed.
    public func checkedAnswer(_ answer: String, for label: String) throws(ChatError) -> String {
        guard let question = questions.first(where: { $0.label == label }) else { throw .invalid("label: the set has no question \(label).") }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...10_000).contains(trimmed.count) else { throw .invalid("answer: write 1 to 10,000 characters.") }
        if question.kind == .multiple, trimmed != Self.skipped {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.allSatisfy({ $0.hasPrefix("- ") && !$0.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw .invalid("answer: write one line \"- <choice>\" per choice, or Skipped.")
            }
            guard question.accepts(choices: lines.count) else { throw .invalid("answer: the number of choices is outside the question's bounds.") }
        }
        return trimmed
    }
}

// MARK: JSON

extension ChatQuestion {
    var json: JSONValue {
        var object: [String: JSONValue] = [
            "label": .string(label), "question": .string(question), "kind": .string(kind.rawValue),
            "options": .array(options.map { option in
                var value: [String: JSONValue] = ["label": .string(option.label)]
                value["description"] = option.description.map(JSONValue.string) ?? .null
                return .object(value)
            }),
            // V2's form: one label as a string in a single question, a list in a multiple one.
            "recommended": kind == .single ? .string(recommended.first ?? "") : .array(recommended.map(JSONValue.string)),
        ]
        if kind == .multiple {
            object["minChoices"] = minChoices.map(JSONValue.int) ?? .null
            object["maxChoices"] = maxChoices.map(JSONValue.int) ?? .null
        }
        return .object(object)
    }

    /// A question of a transcript's line, as V2 wrote it too; nil without its label, text or options.
    init?(json: JSONValue) {
        guard let label = json["label"]?.stringValue, let question = json["question"]?.stringValue,
              let options = json["options"]?.arrayValue else { return nil }
        let recommended: [String] = json["recommended"]?.stringValue.map { [$0] } ?? (json["recommended"]?.arrayValue ?? []).compactMap(\.stringValue)
        self.init(label: label, question: question, kind: json["kind"]?.stringValue.flatMap(Kind.init(rawValue:)) ?? .single,
                  options: options.compactMap { option in
                      option["label"]?.stringValue.map { Option(label: $0, description: option["description"]?.stringValue) }
                  },
                  recommended: recommended, minChoices: json["minChoices"]?.intValue, maxChoices: json["maxChoices"]?.intValue)
    }
}

// MARK: Posting and answering

extension ChatSession {
    /// The chat's questions waiting for the user's answers; nil when none, or when its transcript isn't read.
    public func waitingQuestions(in chatID: String) -> QuestionsItem? {
        for case .questions(let item) in (transcripts[chatID] ?? []).reversed() where !item.completed {
            return item
        }
        return nil
    }

    /// Shows Claude's questions in the chat, as `ask_questions` asks (docs/data.md › Questions). A chat has one
    /// set waiting at most.
    public func postQuestions(_ chatID: String, questions: [ChatQuestion]) async throws(ChatError) -> QuestionsItem {
        guard chats[chatID] != nil else { throw .notFound("Chat \(chatID) not found.") }
        await open(chatID)
        // One request waits at most: questions or a picker request (docs/data.md › Picker requests).
        if let conflict = waitingConflict(in: chatID) { throw .conflict(conflict) }
        let id = UUID().uuidString
        let item = QuestionsItem(id: id, created: now(), questionSetID: id, questions: questions)
        record(.questions(item), in: chatID)
        // The one set allowed after a CI failure is used up (docs/data.md › CI chats).
        ciQuestionChats.remove(chatID)
        refreshState(chatID)
        return item
    }

    /// Stores the user's answer to one question, replacing an earlier one. The answer that completes the set
    /// sends Claude the answers as the user's message, starting the chat's CLI when none runs.
    public func answerQuestion(_ chatID: String, setID: String, label: String, answer: String) async throws(ChatError) {
        guard let waiting = waitingQuestions(in: chatID), waiting.questionSetID == setID else {
            throw .conflict("These questions are already answered.")
        }
        let checked = try waiting.checkedAnswer(answer, for: label)
        let completes = waiting.questions.allSatisfy { $0.label == label || waiting.answers[$0.label] != nil }
        let cli = completes ? try await availableCLI() : nil
        // The set may have changed while the CLI was checked.
        guard var item = waitingQuestions(in: chatID), item.questionSetID == setID else { throw .conflict("These questions are already answered.") }
        item.answers[label] = checked
        item.completed = item.questions.allSatisfy { item.answers[$0.label] != nil }
        record(.questions(item), in: chatID, op: .update)
        if item.completed, let cli {
            post(item.answersMessage(), references: [], images: [], to: chatID, cli: cli)
        }
        refreshState(chatID)
    }
}
