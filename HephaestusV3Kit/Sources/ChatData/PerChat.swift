import Observation

/// Values by chat id, each observed on its own: a view that reads one chat's value is drawn again when that value
/// changes, not when another chat's does (docs/architecture.md › ChatData). The session keeps its transcripts and
/// the text streaming into its chats in them, which change at every line and every word Claude writes.
@MainActor
public final class PerChat<Value>: Observable {
    private var values: [String: Value] = [:]
    /// How many times each chat's value changed: equal counts mean the value is the same.
    private var revisions: [String: Int] = [:]
    private let registrar = ObservationRegistrar()

    init() {}

    public internal(set) subscript(chatID: String) -> Value? {
        get {
            registrar.access(self, keyPath: \.[chatID])
            return values[chatID]
        }
        set {
            registrar.withMutation(of: self, keyPath: \.[chatID]) {
                values[chatID] = newValue
                revisions[chatID, default: 0] += 1
            }
        }
    }

    /// The number of changes of the chat's value, which a reader compares to tell whether it changed since; read
    /// as the value is, so that a view reading it is drawn again at the next change.
    public func revision(of chatID: String) -> Int {
        registrar.access(self, keyPath: \.[chatID])
        return revisions[chatID] ?? 0
    }

    /// Changes the chat's value in place: adding an item to a long transcript doesn't copy it.
    func modify<Result>(_ chatID: String, _ change: (inout Value?) -> Result) -> Result {
        registrar.withMutation(of: self, keyPath: \.[chatID]) {
            revisions[chatID, default: 0] += 1
            return change(&values[chatID])
        }
    }
}
