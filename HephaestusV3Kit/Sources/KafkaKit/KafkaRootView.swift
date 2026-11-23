import AppKit
import AZDesign
import KafkaData
import SwiftUI
import ToolsFoundation

/// The Kafka tool (docs/ui/kafka.md): the events of an environment's topics as they arrive, every topic at once or
/// those chosen, newest first, the selected one in the inspector.
public struct KafkaRootView: View {
    @State private var model: KafkaModel
    @State private var choosesTopics = false
    @State private var showsInspector = true
    @Environment(\.openRoute) private var openRoute
    @Environment(\.reportChatSubject) private var reportChatSubject

    /// The model a tab keeps.
    public init(state: KafkaTabState) {
        _model = State(initialValue: state.model)
    }

    init(model: KafkaModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        content
            .background(.canvas)
            .task { await model.load() }
            .toolbar { toolbar }
            .searchable(text: $model.filter, placement: .toolbar, prompt: Text("Filter Events", bundle: #bundle))
            .inspector(isPresented: $showsInspector) {
                KafkaEventInspector(event: model.selectedEvent)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
            }
            .onChange(of: model.selection) {
                reportChatSubject(model.selectedEvent.map { KafkaReference.reference($0, project: model.projectID) })
            }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.store.hasLookedUpTools, !model.store.hasKcat {
            ContentUnavailableView {
                Label(String(localized: "kcat Isn't Installed", bundle: #bundle), systemImage: "terminal")
            } description: {
                Text("The Kafka tool reads topics with kcat. Install it with Homebrew, brew install kcat, then look again.", bundle: #bundle)
            } actions: {
                Button(String(localized: "Look Again", bundle: #bundle)) {
                    Task {
                        await model.store.lookAgain()
                        await model.load()
                    }
                }
                .accessibilityIdentifier("kafka.lookAgain")
            }
            .accessibilityIdentifier("kafka.noKcat")
        } else if !model.hasKafka {
            ContentUnavailableView {
                Label(String(localized: "No Kafka", bundle: #bundle), systemImage: ToolKind.kafka.symbol)
            } description: {
                Text("Give an environment its Kafka brokers in Project Settings.", bundle: #bundle)
            } actions: {
                Button(String(localized: "Project Settings…", bundle: #bundle)) { openRoute(.projectSettings(model.projectID)) }
                    .accessibilityIdentifier("kafka.projectSettings")
            }
            .accessibilityIdentifier("kafka.noKafka")
        } else {
            VStack(spacing: 0) {
                events
                Divider()
                statusBar
            }
        }
    }

    @ViewBuilder private var events: some View {
        let visible = model.visibleEvents
        Table(visible, selection: $model.selection) {
            TableColumn(String(localized: "Time", bundle: #bundle)) { event in
                Text(verbatim: event.timestamp.map(Self.time) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.textSecondary)
            }
            .width(min: 90, ideal: 100, max: 130)
            TableColumn(String(localized: "Topic", bundle: #bundle)) { event in
                Text(verbatim: event.topic)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(event.topic)
            }
            .width(min: 120, ideal: 220)
            TableColumn(String(localized: "Key", bundle: #bundle)) { event in
                Text(verbatim: event.key ?? "—")
                    .lineLimit(1)
                    .foregroundStyle(event.key == nil ? .textSecondary : .textPrimary)
            }
            .width(min: 60, ideal: 110, max: 220)
            TableColumn(String(localized: "Value", bundle: #bundle)) { event in
                Text(verbatim: Self.preview(event.value))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(event.value == nil ? .textSecondary : .textPrimary)
            }
            TableColumn(String(localized: "Partition · Offset", bundle: #bundle)) { event in
                Text(verbatim: "\(event.partition) · \(event.offset)")
                    .monospacedDigit()
                    .foregroundStyle(.textSecondary)
            }
            .width(min: 120, ideal: 130, max: 160)
        }
        .overlay { placeholder(visible.isEmpty) }
        .contextMenu(forSelectionType: KafkaEvent.ID.self) { ids in
            if let id = ids.first, let event = model.events.first(where: { $0.id == id }) {
                Button(String(localized: "Copy Value", bundle: #bundle)) { Self.copy(event.value ?? "") }
                    .disabled(event.value == nil)
                Button(String(localized: "Copy Key", bundle: #bundle)) { Self.copy(event.key ?? "") }
                    .disabled(event.key == nil)
                Button(String(localized: "Copy Topic", bundle: #bundle)) { Self.copy(event.topic) }
            }
        }
        .accessibilityIdentifier("kafka.events")
    }

    @ViewBuilder private func placeholder(_ isEmpty: Bool) -> some View {
        if isEmpty {
            if !model.filter.isEmpty, !model.events.isEmpty {
                ContentUnavailableView.search(text: model.filter)
            } else {
                switch model.state {
                case .starting, .running:
                    ContentUnavailableView {
                        Label(String(localized: "Waiting for Events", bundle: #bundle), systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("Events show here as \(model.selectionTitle) receive them.", bundle: #bundle)
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label(String(localized: "The Spy Stopped", bundle: #bundle), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: message)
                    }
                case .stopped:
                    ContentUnavailableView {
                        Label(String(localized: "Not Spying", bundle: #bundle), systemImage: ToolKind.kafka.symbol)
                    } description: {
                        Text("Choose topics, or keep All Topics, then press Start.", bundle: #bundle)
                    }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            switch model.state {
            case .running(let since):
                StatusDot(.success)
                Text("Spying on \(model.selectionTitle) since \(since.formatted(date: .omitted, time: .shortened))", bundle: #bundle)
            case .starting:
                ProgressView().controlSize(.small)
                Text("Joining \(model.selectionTitle)…", bundle: #bundle)
            case .failed(let message):
                StatusDot(.danger)
                Text(verbatim: message).lineLimit(1)
            case .stopped:
                StatusDot(.textSecondary)
                Text("Stopped", bundle: #bundle)
            }
            if let problem = model.problem {
                Label {
                    Text(verbatim: problem).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.warning)
                .help(problem)
                .accessibilityIdentifier("kafka.problem")
            }
            Spacer()
            Text("^[\(model.events.count) event](inflect: true)", bundle: #bundle)
                .monospacedDigit()
            if model.dropped > 0 {
                Text("(the oldest \(model.dropped) dropped)", bundle: #bundle)
            }
        }
        .font(.callout)
        .foregroundStyle(.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kafka.status")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.environments.count > 1 {
                Picker(String(localized: "Environment", bundle: #bundle), selection: Binding {
                    model.environment ?? ""
                } set: { name in
                    Task { await model.select(environment: name) }
                }) {
                    ForEach(model.environments) { environment in
                        Text(verbatim: environment.name).tag(environment.name)
                    }
                }
                .help(String(localized: "The environment whose Kafka the tool reads", bundle: #bundle))
                .accessibilityIdentifier("kafka.environment")
            }
            Button {
                choosesTopics = true
            } label: {
                Label(model.selectionTitle, systemImage: "line.3.horizontal.decrease.circle")
                    .labelStyle(.titleAndIcon)
            }
            .help(String(localized: "Choose the topics to spy on", bundle: #bundle))
            .popover(isPresented: $choosesTopics, arrowEdge: .bottom) {
                KafkaTopicPicker(model: model)
            }
            .disabled(!model.hasKafka)
            .accessibilityIdentifier("kafka.topics")
            Picker(String(localized: "From", bundle: #bundle), selection: $model.fromBeginning) {
                Text("From Now", bundle: #bundle).tag(false)
                Text("From the Beginning", bundle: #bundle).tag(true)
            }
            .help(String(localized: "Where the spy starts reading: new events, or every event the topics keep", bundle: #bundle))
            .disabled(model.isRunning || !model.hasKafka)
            .accessibilityIdentifier("kafka.from")
            if model.isRunning {
                Button(String(localized: "Stop", bundle: #bundle), systemImage: "stop.fill") { model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .help(String(localized: "Stop Spying (⌘.)", bundle: #bundle))
                    .accessibilityIdentifier("kafka.stop")
            } else {
                Button(String(localized: "Start", bundle: #bundle), systemImage: "play.fill") { model.start() }
                    .keyboardShortcut("r", modifiers: .command)
                    .help(String(localized: "Start Spying (⌘R)", bundle: #bundle))
                    .disabled(!model.canStart)
                    .accessibilityIdentifier("kafka.start")
            }
            Button(String(localized: "Clear", bundle: #bundle), systemImage: "trash") { model.clear() }
                .keyboardShortcut("k", modifiers: .command)
                .help(String(localized: "Clear the Events (⌘K)", bundle: #bundle))
                .disabled(model.events.isEmpty)
                .accessibilityIdentifier("kafka.clear")
            Button(String(localized: "Inspector", bundle: #bundle), systemImage: "sidebar.trailing") { showsInspector.toggle() }
                .help(String(localized: "Show or Hide the Event", bundle: #bundle))
                .accessibilityIdentifier("kafka.inspector")
        }
        ChatPanelToolbarItem()
    }

    // MARK: Formats

    /// `14:03:00.123`, in the Mac's time zone.
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
    }

    /// A value on one line, at most 300 characters.
    static func preview(_ value: String?) -> String {
        guard let value else { return "null" }
        let line = value.replacing("\n", with: " ")
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The topics popover: All Topics, then each topic with a checkbox and how many events it got, a filter, Refresh.
struct KafkaTopicPicker: View {
    @Bindable var model: KafkaModel
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding { model.spiesAll } set: { if $0 { model.chooseAll() } else { model.spiesAll = false } }) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("All Topics", bundle: #bundle)
                    Text("Every topic but Kafka's own, those created later included", bundle: #bundle)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }
            .accessibilityIdentifier("kafka.topics.all")
            Divider()
            HStack {
                TextField(String(localized: "Filter Topics", bundle: #bundle), text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Refresh", bundle: #bundle), systemImage: "arrow.clockwise") {
                    Task { await model.loadTopics() }
                }
                .labelStyle(.iconOnly)
                .help(String(localized: "Read the Topics Again", bundle: #bundle))
                .accessibilityIdentifier("kafka.topics.refresh")
            }
            switch model.topicsState {
            case .loading where model.topics.isEmpty:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.danger)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        let counts = model.counts
                        ForEach(model.pickableTopics.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { topic in
                            Toggle(isOn: Binding { !model.spiesAll && model.chosenTopics.contains(topic.name) } set: { _ in model.toggle(topic.name) }) {
                                HStack {
                                    Text(verbatim: topic.name)
                                        .foregroundStyle(topic.isInternal ? .textSecondary : .textPrimary)
                                    Spacer()
                                    if let count = counts[topic.name] {
                                        Text(verbatim: String(count))
                                            .monospacedDigit()
                                            .foregroundStyle(.textSecondary)
                                    }
                                }
                            }
                            .help(String(localized: "^[\(topic.partitions) partition](inflect: true)", bundle: #bundle))
                            .accessibilityIdentifier("kafka.topic.\(topic.name)")
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 340)
    }
}

/// The selected event: where it is, its key, its headers in order, and its value, as JSON indented when it is.
struct KafkaEventInspector: View {
    let event: KafkaEvent?

    var body: some View {
        if let event {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: event.topic)
                            .font(.headline)
                            .textSelection(.enabled)
                        Text("Partition \(event.partition) · Offset \(String(event.offset))", bundle: #bundle)
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                        if let timestamp = event.timestamp {
                            Text(verbatim: timestamp.formatted(date: .abbreviated, time: .standard) + " · " + KafkaRootView.time(timestamp))
                                .font(.callout)
                                .foregroundStyle(.textSecondary)
                        }
                    }
                    section(String(localized: "Key", bundle: #bundle), copy: event.key) {
                        Text(verbatim: event.key ?? "null")
                            .font(.callout.monospaced())
                            .foregroundStyle(event.key == nil ? .textSecondary : .textPrimary)
                            .textSelection(.enabled)
                    }
                    section(String(localized: "Headers", bundle: #bundle), copy: nil) {
                        if event.headers.isEmpty {
                            Text("None", bundle: #bundle).foregroundStyle(.textSecondary)
                        } else {
                            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                                ForEach(Array(event.headers.enumerated()), id: \.offset) { _, header in
                                    GridRow {
                                        Text(verbatim: header.name).foregroundStyle(.textSecondary)
                                        Text(verbatim: header.value ?? "null")
                                            .font(.callout.monospaced())
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .font(.callout)
                        }
                    }
                    section(String(localized: "Value", bundle: #bundle), copy: event.value) {
                        Text(verbatim: Self.pretty(event.value))
                            .font(.callout.monospaced())
                            .foregroundStyle(event.value == nil ? .textSecondary : .textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.surfaceSunken, in: .rect(cornerRadius: 6))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("kafka.event")
        } else {
            Text("Select an event", bundle: #bundle)
                .foregroundStyle(.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("kafka.noEvent")
        }
    }

    private func section(_ title: String, copy: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: title).font(.subheadline.weight(.semibold))
                Spacer()
                if let copy {
                    Button(String(localized: "Copy", bundle: #bundle)) { KafkaRootView.copy(copy) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            content()
        }
    }

    /// The value as JSON indented, keys in their order, when it is JSON; as it is otherwise.
    static func pretty(_ value: String?) -> String {
        guard let value else { return "null" }
        guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              object is [String: Any] || object is [Any],
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        else { return value }
        return String(decoding: pretty, as: UTF8.self)
    }
}

/// An event as a chat names it: `greetings.sent #42`, with `<topic>/<partition>/<offset>` as the focus.
enum KafkaReference {
    static func reference(_ event: KafkaEvent, project: Project.ID) -> ChatReference {
        ChatReference(tool: .kafka, projectID: project, focus: event.id, title: "\(event.topic) #\(event.offset)")
    }
}

// MARK: Previews

#Preview("Spying", traits: .fixedLayout(width: 1200, height: 640)) {
    let model = KafkaModel(projectID: "ORD", store: SampleKafkaStore())
    model.start()
    model.selection = SampleKafkaStore.sampleEvents[2].id
    return KafkaRootView(model: model)
}

#Preview("Not Spying", traits: .fixedLayout(width: 1000, height: 560)) {
    KafkaRootView(model: KafkaModel(projectID: "ORD", store: SampleKafkaStore()))
}

#Preview("No Kafka", traits: .fixedLayout(width: 900, height: 520)) {
    KafkaRootView(model: KafkaModel(projectID: "PAY", store: SampleKafkaStore()))
}
