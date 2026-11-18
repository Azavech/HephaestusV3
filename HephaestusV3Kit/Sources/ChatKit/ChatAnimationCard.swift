import AZDesign
import ChatData
import SwiftUI
import TextFormats
import ToolsFoundation

/// What the animation card has chosen (docs/ui/chat.md › Animation card).
enum AnimationChoice: Hashable {
    /// A suggestion, by its place.
    case suggestion(Int)
    /// The Custom row.
    case custom
    /// "Answer another way".
    case other
}

/// Claude's request to choose an animation (docs/ui/chat.md › Animation card): one row per suggestion with its
/// lane, the recommended one starred and preselected, a Custom row with a preset and sliders, Play All, "Answer
/// another way", Skip and Submit.
struct AnimationCard: View {
    let request: PickerItem
    let projectID: Project.ID?
    var compact = false
    var allowsShortcut = true
    let answer: (String) async -> Bool

    @State private var choice: AnimationChoice
    /// The Custom row: its preset and the three sliders' values, kept when the preset changes.
    @State private var custom: AnimationExpression
    @State private var otherText = ""
    /// Each lane's plays, by suggestion index; `customLane` for the Custom row's.
    @State private var plays: [Int: Int] = [:]
    @State private var isSending = false

    static let customLane = -1

    init(request: PickerItem, projectID: Project.ID?, compact: Bool = false, allowsShortcut: Bool = true, answer: @escaping (String) async -> Bool) {
        self.request = request
        self.projectID = projectID
        self.compact = compact
        self.allowsShortcut = allowsShortcut
        self.answer = answer
        _choice = State(initialValue: .suggestion(request.suggestions.firstIndex(of: request.recommended) ?? 0))
        _custom = State(initialValue: Self.customStart(request.recommended.value))
    }

    var body: some View {
        PickerCardChrome(request: request, projectID: projectID, compact: compact, allowsShortcut: allowsShortcut,
                         canSubmit: Self.canSubmit(choice: choice, other: otherText), isSending: isSending,
                         skip: { send(PickerItem.skipped) },
                         submit: { send(Self.answer(choice: choice, suggestions: request.suggestions.map(\.value), custom: custom, other: otherText)) }) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(request.suggestions.enumerated()), id: \.offset) { index, suggestion in
                    suggestionRow(suggestion.value, index: index)
                }
                customRow
                sliders
            }
            OtherAnswerRow(isSelected: choice == .other, text: $otherText, identifier: "chat.animation") { choice = .other }
        } leading: {
            Button(String(localized: "Play All", bundle: #bundle, comment: "Plays every lane of the animation card"), systemImage: "play.fill") {
                for index in request.suggestions.indices + [Self.customLane] {
                    plays[index, default: 0] += 1
                }
            }
            .accessibilityIdentifier("chat.animation.playAll")
        }
    }

    private func radio(_ isOn: Bool) -> some View {
        Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(isOn ? Color.accent : Color.textSecondary)
            .accessibilityHidden(true)
    }

    private func suggestionRow(_ expression: String, index: Int) -> some View {
        let isSelected = choice == .suggestion(index)
        return Button {
            choice = .suggestion(index)
            plays[index, default: 0] += 1
        } label: {
            HStack(spacing: 8) {
                radio(isSelected)
                Text(verbatim: expression)
                    .monospaced()
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                if expression == request.recommended.value {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.accent)
                        .accessibilityLabel(String(localized: "Recommended", bundle: #bundle, comment: "Marks the option Claude recommends"))
                }
                Spacer(minLength: 8)
                AnimationLane(animation: (try? AnimationExpression(parsing: expression)).map(Self.animation) ?? .default, plays: plays[index] ?? 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chat.animation.row.\(index)")
    }

    private var customRow: some View {
        let isSelected = choice == .custom
        return HStack(spacing: 8) {
            Button {
                selectCustom(playing: true)
            } label: {
                HStack(spacing: 8) {
                    radio(isSelected)
                    Text("Custom", bundle: #bundle, comment: "The animation card's row of an animation of the user's own")
                        .foregroundStyle(.textPrimary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("chat.animation.custom")
            Picker(String(localized: "Preset", bundle: #bundle, comment: "The menu of SwiftUI's animation presets"), selection: Binding(
                get: { custom.preset },
                set: { custom.preset = $0; selectCustom(playing: true) }
            )) {
                ForEach(AnimationPreset.allCases, id: \.self) { Text(verbatim: $0.expression).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("chat.animation.preset")
            Text(verbatim: custom.fullExpression)
                .monospaced()
                .foregroundStyle(.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            AnimationLane(animation: Self.animation(custom), plays: plays[Self.customLane] ?? 0)
        }
    }

    /// One slider per parameter of the preset: Duration, then Bounce or Extra Bounce.
    private var sliders: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(custom.preset.parameters, id: \.self) { parameter in
                HStack(spacing: 8) {
                    Text(verbatim: Self.title(parameter))
                        .foregroundStyle(.textPrimary)
                        .frame(minWidth: 90, alignment: .leading)
                    Slider(value: Binding(
                        get: { custom.value(parameter) },
                        set: { value in
                            custom.values[parameter] = (value * 100).rounded() / 100
                            selectCustom(playing: false)
                        }
                    ), in: parameter.range) { editing in
                        if !editing { plays[Self.customLane, default: 0] += 1 }
                    }
                    .accessibilityIdentifier("chat.animation.\(parameter.rawValue)")
                    Text(verbatim: Self.valueText(custom.value(parameter), parameter: parameter))
                        .monospacedDigit()
                        .foregroundStyle(.textSecondary)
                        .frame(minWidth: 50, alignment: .trailing)
                }
            }
        }
        .padding(.leading, 24)
    }

    private func selectCustom(playing: Bool) {
        choice = .custom
        if playing { plays[Self.customLane, default: 0] += 1 }
    }

    private func send(_ text: String) {
        isSending = true
        Task {
            _ = await answer(text)
            isSending = false
        }
    }

    static func title(_ parameter: AnimationParameter) -> String {
        switch parameter {
        case .duration: String(localized: "Duration", bundle: #bundle, comment: "An animation's duration, in seconds")
        case .bounce: String(localized: "Bounce", bundle: #bundle, comment: "A spring animation's bounce")
        case .extraBounce: String(localized: "Extra Bounce", bundle: #bundle, comment: "The extra bounce of a smooth, snappy or bouncy animation")
        }
    }

    /// Two decimals, then ` s` for the duration.
    static func valueText(_ value: Double, parameter: AnimationParameter) -> String {
        let text = String(format: "%.2f", value)
        return parameter == .duration ? text + " s" : text
    }

    /// The Custom row when the card appears: the recommended suggestion's preset and parameters, those it leaves
    /// out at SwiftUI's defaults.
    static func customStart(_ recommended: String) -> AnimationExpression {
        let parsed = (try? AnimationExpression(parsing: recommended)) ?? AnimationExpression(preset: .smooth)
        var values: [AnimationParameter: Double] = [:]
        for parameter in AnimationParameter.allCases {
            values[parameter] = parsed.value(parameter)
        }
        if !parsed.preset.parameters.contains(.bounce) { values[.bounce] = 0 }
        if !parsed.preset.parameters.contains(.extraBounce) { values[.extraBounce] = 0 }
        return AnimationExpression(preset: parsed.preset, values: values)
    }

    /// `![](animation:<expression>)`: a suggestion as Claude wrote it, or the Custom row's; else the field's text.
    static func answer(choice: AnimationChoice, suggestions: [String], custom: AnimationExpression, other: String) -> String {
        switch choice {
        case .suggestion(let index) where suggestions.indices.contains(index): "![](animation:\(suggestions[index]))"
        case .custom: "![](animation:\(custom.fullExpression))"
        default: other.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func canSubmit(choice: AnimationChoice, other: String) -> Bool {
        choice != .other || !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The SwiftUI animation of an expression: the preset of the same name with the parameters written, the others
    /// at SwiftUI's defaults.
    static func animation(_ expression: AnimationExpression) -> Animation {
        let duration = expression.value(.duration)
        return switch expression.preset {
        case .smooth: .smooth(duration: duration, extraBounce: expression.value(.extraBounce))
        case .snappy: .snappy(duration: duration, extraBounce: expression.value(.extraBounce))
        case .bouncy: .bouncy(duration: duration, extraBounce: expression.value(.extraBounce))
        case .spring: .spring(duration: duration, bounce: expression.value(.bounce))
        case .easeIn: .easeIn(duration: duration)
        case .easeOut: .easeOut(duration: duration)
        case .easeInOut: .easeInOut(duration: duration)
        case .linear: .linear(duration: duration)
        }
    }
}

/// A lane: a circle that slides from the left end of a capsule track to its right end with the animation. It rests
/// at the left until it plays; each play starts it again from the left end.
struct AnimationLane: View {
    let animation: Animation
    /// Each increase plays the lane.
    let plays: Int

    @State private var atEnd = false

    static let width: CGFloat = 160
    static let height: CGFloat = 14

    var body: some View {
        Capsule()
            .fill(Color.textSecondary.opacity(0.2))
            .frame(width: Self.width, height: Self.height)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.accent)
                    .frame(width: Self.height, height: Self.height)
                    .offset(x: atEnd ? Self.width - Self.height : 0)
            }
            .onChange(of: plays) {
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { atEnd = false }
                Task {
                    // The next frame, so that the circle starts from the left end.
                    try? await Task.sleep(for: .milliseconds(20))
                    withAnimation(animation) { atEnd = true }
                }
            }
            .accessibilityHidden(true)
    }
}

#Preview("Animation Card, Waiting", traits: .appChrome, .fixedLayout(width: 640, height: 440)) {
    AnimationCard(request: .preview(.animation), projectID: nil) { _ in true }
        .padding()
}

#Preview("Animation Card, Dark", traits: .appChrome, .fixedLayout(width: 640, height: 440)) {
    AnimationCard(request: .preview(.animation), projectID: nil) { _ in true }
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Animation Card, Narrow, Largest Text", traits: .largestText, .fixedLayout(width: 360, height: 760)) {
    AnimationCard(request: .preview(.animation), projectID: nil, compact: true) { _ in true }
        .padding()
}
