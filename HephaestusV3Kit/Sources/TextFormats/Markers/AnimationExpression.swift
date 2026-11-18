import Foundation

/// A SwiftUI animation preset of `ask_animation` (docs/text.md › Animation expressions).
public enum AnimationPreset: String, CaseIterable, Sendable, Hashable {
    case smooth, snappy, bouncy, spring, easeIn, easeOut, easeInOut, linear

    /// The parameters of the preset, in the order of its SwiftUI signature.
    public var parameters: [AnimationParameter] {
        switch self {
        case .smooth, .snappy, .bouncy: [.duration, .extraBounce]
        case .spring: [.duration, .bounce]
        case .easeIn, .easeOut, .easeInOut, .linear: [.duration]
        }
    }

    /// `.smooth`, `.snappy`, `.bouncy` and `.spring` are springs; the others are timing curves.
    public var isSpring: Bool {
        switch self {
        case .smooth, .snappy, .bouncy, .spring: true
        case .easeIn, .easeOut, .easeInOut, .linear: false
        }
    }

    /// SwiftUI's default of a parameter left out: 0.5 s for the springs, 0.35 s for the timing curves, no bounce.
    public func defaultValue(_ parameter: AnimationParameter) -> Double {
        switch parameter {
        case .duration: isSpring ? 0.5 : 0.35
        case .bounce, .extraBounce: 0
        }
    }

    /// `.` and the name, as SwiftUI writes it.
    public var expression: String { "." + rawValue }
}

/// A parameter of an animation preset, with the range of its slider in the card's Custom row.
public enum AnimationParameter: String, CaseIterable, Sendable, Hashable {
    case duration, bounce, extraBounce

    public var range: ClosedRange<Double> {
        switch self {
        case .duration: 0.1...2
        case .bounce: -1...1
        case .extraBounce: 0...1
        }
    }
}

/// Why a text isn't an animation of `ask_animation`, in the order of the checks.
public enum AnimationExpressionError: Error, Equatable, Sendable {
    /// Not `.`, a name of letters, and optionally parameters in parentheses.
    case syntax
    /// The name isn't a preset.
    case unknownPreset
    /// The labels aren't those of the preset, each at most once, in its order.
    case parameters(AnimationPreset)
    /// A value is outside the range of its parameter.
    case range(AnimationParameter)
}

/// An animation written as its SwiftUI expression, such as `.spring(duration: 0.4, bounce: 0.2)`
/// (docs/text.md › Animation expressions), as V2's.
public struct AnimationExpression: Sendable, Hashable {
    public var preset: AnimationPreset
    /// The parameters written; the others take SwiftUI's defaults.
    public var values: [AnimationParameter: Double]

    public init(preset: AnimationPreset, values: [AnimationParameter: Double] = [:]) {
        self.preset = preset
        self.values = values
    }

    /// Reads an expression: `.` and a preset, alone or followed by `(<label>: <number>, …)`. Spaces may follow
    /// `(`, `:` and `,` and precede `)`, `:` and `,`.
    public init(parsing text: String) throws(AnimationExpressionError) {
        let parsed = try Self.parse(text)
        guard let preset = AnimationPreset(rawValue: parsed.name) else { throw .unknownPreset }
        var remaining = preset.parameters[...]
        var values: [AnimationParameter: Double] = [:]
        for (label, _) in parsed.arguments {
            guard let index = remaining.firstIndex(where: { $0.rawValue == label }) else { throw .parameters(preset) }
            remaining = remaining[(index + 1)...]
        }
        for (label, value) in parsed.arguments {
            guard let parameter = AnimationParameter(rawValue: label) else { throw .parameters(preset) }
            guard parameter.range.contains(value) else { throw .range(parameter) }
            values[parameter] = value
        }
        self.init(preset: preset, values: values)
    }

    /// Whether `text` is an expression that passes every check.
    public static func isValid(_ text: String) -> Bool {
        (try? AnimationExpression(parsing: text)) != nil
    }

    /// The value of a parameter: the one written, else SwiftUI's default.
    public func value(_ parameter: AnimationParameter) -> Double {
        values[parameter] ?? preset.defaultValue(parameter)
    }

    /// The Custom row's expression: the preset with every one of its parameters, each value with at most two
    /// decimals and without trailing zeros.
    public var fullExpression: String {
        let arguments = preset.parameters.map { "\($0.rawValue): \(Self.format(value($0)))" }
        return preset.expression + "(" + arguments.joined(separator: ", ") + ")"
    }

    /// A value with at most two decimals and without trailing zeros: `0.5`, `0.25`, `1`, `-0.3`.
    public static func format(_ value: Double) -> String {
        var text = String(format: "%.2f", (value * 100).rounded() / 100)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text == "-0" ? "0" : text
    }

    /// The message of `ask_animation` for a suggestion that fails `error` (docs/data.md › Picker requests).
    public static func message(for error: AnimationExpressionError, suggestion: String) -> String {
        switch error {
        case .syntax:
            return "\(suggestion) is not a SwiftUI animation expression."
        case .unknownPreset:
            return "\(suggestion): use .smooth, .snappy, .bouncy, .spring, .easeIn, .easeOut, .easeInOut or .linear."
        case .parameters(let preset):
            return "\(suggestion): \(preset.expression) takes (\(preset.parameters.map { $0.rawValue + ":" }.joined()))."
        case .range(let parameter):
            return "\(suggestion): \(parameter.rawValue) must be from \(format(parameter.range.lowerBound)) to \(format(parameter.range.upperBound))."
        }
    }

    // MARK: Syntax

    private static func parse(_ text: String) throws(AnimationExpressionError) -> (name: String, arguments: [(String, Double)]) {
        let characters = Array(text)
        var index = 0
        func peek() -> Character? { index < characters.count ? characters[index] : nil }
        func skipSpaces() {
            while peek() == " " { index += 1 }
        }
        func letters() -> String {
            let start = index
            while let character = peek(), character.isASCII, character.isLetter { index += 1 }
            return String(characters[start..<index])
        }
        func number() -> Double? {
            let start = index
            if peek() == "-" { index += 1 }
            let digitsStart = index
            while let character = peek(), character.isASCII, character.isNumber { index += 1 }
            guard index > digitsStart else { return nil }
            if peek() == "." {
                index += 1
                let fractionStart = index
                while let character = peek(), character.isASCII, character.isNumber { index += 1 }
                guard index > fractionStart else { return nil }
            }
            return Double(String(characters[start..<index]))
        }
        guard peek() == "." else { throw .syntax }
        index += 1
        let name = letters()
        guard !name.isEmpty else { throw .syntax }
        guard index < characters.count else { return (name, []) }
        guard peek() == "(" else { throw .syntax }
        index += 1
        skipSpaces()
        var arguments: [(String, Double)] = []
        while true {
            let label = letters()
            guard !label.isEmpty else { throw .syntax }
            skipSpaces()
            guard peek() == ":" else { throw .syntax }
            index += 1
            skipSpaces()
            guard let value = number() else { throw .syntax }
            arguments.append((label, value))
            skipSpaces()
            if peek() == ")" {
                index += 1
                break
            }
            guard peek() == "," else { throw .syntax }
            index += 1
            skipSpaces()
        }
        guard index == characters.count else { throw .syntax }
        return (name, arguments)
    }
}
