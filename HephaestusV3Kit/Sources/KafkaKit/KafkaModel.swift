import Foundation
import KafkaData
import Observation
import ToolsFoundation

/// The Kafka tool of a project (docs/ui/kafka.md): an environment, the topics to spy on, every topic at once by
/// default, and the events as they arrive, newest first. A spy runs while the tab lives, and ends with it.
@MainActor @Observable
public final class KafkaModel {
    enum SpyState: Equatable {
        case stopped
        case starting
        case running(since: Date)
        case failed(String)
    }

    enum TopicsState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// The events kept: past this, the oldest go first (keep RAM low).
    static let maximumEvents = 5_000
    /// How long arriving events wait to be shown together.
    static let flushDelay: Duration = .milliseconds(100)

    let projectID: Project.ID
    @ObservationIgnored let store: any KafkaStore

    private(set) var environments: [KafkaEnvironment] = []
    private(set) var environment: String?
    private(set) var topics: [KafkaTopic] = []
    private(set) var topicsState = TopicsState.idle
    /// Every topic at once, those created while the spy runs included; otherwise `chosenTopics`.
    var spiesAll = true
    var chosenTopics: Set<String> = []
    var fromBeginning = false
    private(set) var state = SpyState.stopped
    /// The last error kcat reported while it retries, such as a broker it can't reach; cleared by the next event.
    private(set) var problem: String?
    /// Newest first.
    private(set) var events: [KafkaEvent] = []
    /// How many events went to keep `maximumEvents`.
    private(set) var dropped = 0
    var filter = ""
    var selection: KafkaEvent.ID?

    @ObservationIgnored private var handle: KafkaSpyHandle?
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var pending: [KafkaEvent] = []
    @ObservationIgnored private var flushing: Task<Void, Never>?

    /// A tab that closes ends its spy.
    isolated deinit {
        following?.cancel()
        handle?.stop()
    }

    public init(projectID: Project.ID, store: any KafkaStore) {
        self.projectID = projectID
        self.store = store
        environments = store.environments(of: projectID)
        environment = environments.first?.name
    }

    var hasKafka: Bool { !environments.isEmpty }

    var isRunning: Bool {
        switch state {
        case .starting, .running: true
        case .stopped, .failed: false
        }
    }

    /// What the topics button reads: All Topics, the one topic, or how many.
    var selectionTitle: String {
        if spiesAll { return String(localized: "All Topics", bundle: #bundle) }
        switch chosenTopics.count {
        case 0: return String(localized: "No Topic", bundle: #bundle)
        case 1: return chosenTopics.first ?? ""
        default: return String(localized: "\(chosenTopics.count) Topics", bundle: #bundle)
        }
    }

    var canStart: Bool {
        environment != nil && store.hasKcat && (spiesAll || !chosenTopics.isEmpty)
    }

    /// The topics a user picks from: Kafka's own last.
    var pickableTopics: [KafkaTopic] {
        topics.filter { !$0.isInternal } + topics.filter(\.isInternal)
    }

    /// The events the filter keeps: its text in the topic, the key, the value or a header, letter case ignored.
    var visibleEvents: [KafkaEvent] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return events }
        return events.filter { event in
            event.topic.localizedCaseInsensitiveContains(text) || (event.key ?? "").localizedCaseInsensitiveContains(text)
                || (event.value ?? "").localizedCaseInsensitiveContains(text)
                || event.headers.contains { $0.name.localizedCaseInsensitiveContains(text) || ($0.value ?? "").localizedCaseInsensitiveContains(text) }
        }
    }

    var selectedEvent: KafkaEvent? {
        selection.flatMap { id in events.first { $0.id == id } }
    }

    /// How many events each topic got, for the topics list.
    var counts: [String: Int] {
        events.reduce(into: [:]) { $0[$1.topic, default: 0] += 1 }
    }

    // MARK: Topics

    /// Reads the environments again, then the topics of the selected one.
    func load() async {
        environments = store.environments(of: projectID)
        if environment == nil || !environments.contains(where: { $0.name == environment }) {
            environment = environments.first?.name
        }
        await store.waitForTools()
        await loadTopics()
    }

    func loadTopics() async {
        guard let environment, store.hasKcat else {
            topics = []
            return
        }
        topicsState = .loading
        do throws(KafkaError) {
            let found = try await store.topics(project: projectID, environment: environment)
            guard environment == self.environment else { return }
            topics = found
            chosenTopics.formIntersection(found.map(\.name))
            topicsState = .idle
        } catch {
            guard environment == self.environment else { return }
            topicsState = .failed(error.message)
        }
    }

    /// Another environment: the spy stops, the events go, its topics are read.
    func select(environment name: String) async {
        guard name != environment else { return }
        stop()
        clear()
        environment = name
        topics = []
        chosenTopics = []
        await loadTopics()
    }

    func toggle(_ topic: String) {
        spiesAll = false
        if chosenTopics.contains(topic) { chosenTopics.remove(topic) } else { chosenTopics.insert(topic) }
        restartIfRunning()
    }

    func chooseAll() {
        spiesAll = true
        restartIfRunning()
    }

    /// A change of what is spied on while a spy runs takes effect at once, the events kept.
    func restartIfRunning() {
        guard isRunning else { return }
        stop()
        start()
    }

    // MARK: Spying

    /// Starts a spy on the chosen topics, or on all of them.
    func start() {
        guard let environment, canStart else { return }
        stop()
        problem = nil
        let selection: Kcat.Selection = spiesAll ? .all : .topics(chosenTopics.sorted())
        do throws(KafkaError) {
            let handle = try store.spy(project: projectID, environment: environment, selection: selection, fromBeginning: fromBeginning)
            self.handle = handle
            state = .starting
            following = Task { [weak self] in
                for await update in handle.updates {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(update)
                }
            }
        } catch {
            state = .failed(error.message)
        }
    }

    /// Ends the spy; the events stay.
    func stop() {
        following?.cancel()
        following = nil
        handle?.stop()
        handle = nil
        flush()
        if isRunning { state = .stopped }
    }

    func clear() {
        events = []
        pending = []
        dropped = 0
        selection = nil
    }

    func apply(_ update: KafkaSpy.Update) {
        switch update {
        case .event(let event):
            if case .starting = state { state = .running(since: Date()) }
            problem = nil
            pending.append(event)
            scheduleFlush()
        case .problem(let message):
            problem = message
        case .ended(let reason):
            flush()
            handle = nil
            following = nil
            state = reason.map(SpyState.failed) ?? .stopped
        }
    }

    private func scheduleFlush() {
        guard flushing == nil else { return }
        flushing = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            self?.flush()
        }
    }

    /// Shows the events that arrived, newest first, the oldest dropped past `maximumEvents`.
    func flush() {
        flushing?.cancel()
        flushing = nil
        guard !pending.isEmpty else { return }
        events.insert(contentsOf: pending.reversed(), at: 0)
        pending = []
        if events.count > Self.maximumEvents {
            dropped += events.count - Self.maximumEvents
            events.removeLast(events.count - Self.maximumEvents)
        }
        if case .starting = state { state = .running(since: Date()) }
    }
}

/// What a tab keeps of the Kafka tool while another tab is in front: its model, so the spy keeps running and its
/// events stay. The app's window makes one per tab.
@MainActor
public final class KafkaTabState {
    let model: KafkaModel

    public init(project: Project, store: any KafkaStore) {
        model = KafkaModel(projectID: project.id, store: store)
    }

    /// Ends the spy, when the tab closes.
    public func close() {
        model.stop()
    }
}
