import AppKit
import AZDesign
import Carbon.HIToolbox
import Observation
import SwiftUI
import Virtualization

/// A running machine's screen: the Virtualization framework's view, driven by the user's mouse and keyboard. The
/// guest's display takes the view's size as the window resizes.
struct VirtualMachineScreen: NSViewRepresentable {
    let machine: VZVirtualMachine
    let keyboard: GuestKeyboard

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = machine
        keyboard.view = view
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
        keyboard.view = view
    }

    static func dismantleNSView(_ view: VZVirtualMachineView, coordinator: ()) {
        view.virtualMachine = nil
    }
}

/// One key press: a key's virtual key code and the modifiers that type its character.
nonisolated struct GuestKeyStroke: Hashable, Sendable {
    var keyCode: UInt16
    var shift = false
    var option = false
}

/// The keys that type each character on a keyboard layout: for each character, the first key of the codes 0 to
/// 127 that types it alone, else with Shift, else Option, else both. A dead key types no character.
nonisolated struct KeyboardLayoutKeys {
    static let modifierStates: [(shift: Bool, option: Bool)] = [(false, false), (true, false), (false, true), (true, true)]

    private(set) var strokes: [Character: GuestKeyStroke] = [:]

    /// `translate` gives the text a key types with these modifiers; nil for a dead key or none.
    init(translate: (_ keyCode: UInt16, _ shift: Bool, _ option: Bool) -> String?) {
        for state in Self.modifierStates {
            for keyCode in UInt16(0)..<128 {
                guard let text = translate(keyCode, state.shift, state.option), text.count == 1, let character = text.first,
                      strokes[character] == nil, Self.isPrintable(character) else { continue }
                strokes[character] = GuestKeyStroke(keyCode: keyCode, shift: state.shift, option: state.option)
            }
        }
    }

    /// The presses of a text; the first character no key types fails.
    func strokes(for text: String) -> Result<[GuestKeyStroke], GuestKeyboardError> {
        var result: [GuestKeyStroke] = []
        for character in text {
            guard let stroke = strokes[character] else { return .failure(.cannotType(character)) }
            result.append(stroke)
        }
        return .success(result)
    }

    private static func isPrintable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value != 0x7F }
    }

    /// The keys of this Mac's keyboard layout now, read with `UCKeyTranslate`; nil without layout data.
    static func current() -> KeyboardLayoutKeys? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { buffer -> KeyboardLayoutKeys? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            return KeyboardLayoutKeys { keyCode, shift, option in
                var modifiers: UInt32 = 0
                if shift { modifiers |= UInt32(shiftKey >> 8) }
                if option { modifiers |= UInt32(optionKey >> 8) }
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType, 0, &deadKeyState,
                                            characters.count, &length, &characters)
                guard status == noErr, deadKeyState == 0, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }
}

nonisolated enum GuestKeyboardError: LocalizedError, Equatable {
    case cannotType(Character)
    case noScreen

    var errorDescription: String? {
        switch self {
        case .cannotType(let character):
            String(localized: "The keyboard layout of this Mac cannot type “\(String(character))”.", bundle: #bundle)
        case .noScreen:
            String(localized: "The screen of the virtual machine is not shown.", bundle: #bundle)
        }
    }
}

/// Type Password: presses a password's keys through the machine's screen, as the user's keyboard does, so they
/// reach the guest without its agent (in Setup Assistant, at the login window, in a password dialog). No Return.
@Observable
final class GuestKeyboard {
    static let eventInterval: Duration = .milliseconds(10)
    /// The device bits of the left Shift and Option keys: the framework passes a modifier to the guest only with them.
    private static let leftShiftDeviceBit: UInt = 0x02
    private static let leftOptionDeviceBit: UInt = 0x20

    @ObservationIgnored weak var view: VZVirtualMachineView?
    private(set) var isTyping = false

    /// Gives the screen the keyboard focus, then presses the text's keys on this Mac's layout. A character the
    /// layout can't type fails before any key is pressed.
    func type(_ text: String) async throws(GuestKeyboardError) {
        guard !isTyping else { return }
        guard let view, let window = view.window else { throw .noScreen }
        let layout = KeyboardLayoutKeys.current() ?? KeyboardLayoutKeys { _, _, _ in nil }
        let strokes = try layout.strokes(for: text).get()
        isTyping = true
        defer { isTyping = false }
        window.makeFirstResponder(view)
        for (stroke, character) in zip(strokes, text) {
            await press(stroke, character: String(character), in: view, window: window)
        }
    }

    private func press(_ stroke: GuestKeyStroke, character: String, in view: VZVirtualMachineView, window: NSWindow) async {
        var flags: NSEvent.ModifierFlags = []
        if stroke.shift {
            flags.formUnion([.shift, NSEvent.ModifierFlags(rawValue: Self.leftShiftDeviceBit)])
            await send(.flagsChanged, keyCode: UInt16(kVK_Shift), flags: flags, characters: "", to: view, window: window)
        }
        if stroke.option {
            flags.formUnion([.option, NSEvent.ModifierFlags(rawValue: Self.leftOptionDeviceBit)])
            await send(.flagsChanged, keyCode: UInt16(kVK_Option), flags: flags, characters: "", to: view, window: window)
        }
        await send(.keyDown, keyCode: stroke.keyCode, flags: flags, characters: character, to: view, window: window)
        await send(.keyUp, keyCode: stroke.keyCode, flags: flags, characters: character, to: view, window: window)
        if stroke.option {
            flags.subtract([.option, NSEvent.ModifierFlags(rawValue: Self.leftOptionDeviceBit)])
            await send(.flagsChanged, keyCode: UInt16(kVK_Option), flags: flags, characters: "", to: view, window: window)
        }
        if stroke.shift {
            flags.subtract([.shift, NSEvent.ModifierFlags(rawValue: Self.leftShiftDeviceBit)])
            await send(.flagsChanged, keyCode: UInt16(kVK_Shift), flags: flags, characters: "", to: view, window: window)
        }
    }

    private func send(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String,
                      to view: VZVirtualMachineView, window: NSWindow) async {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
        switch type {
        case .flagsChanged: view.flagsChanged(with: event)
        case .keyDown: view.keyDown(with: event)
        default: view.keyUp(with: event)
        }
        // Not cancelled: every modifier pressed is released.
        try? await Task.sleep(for: Self.eventInterval)
    }
}

/// Type Password: disabled without a password, while it types, or when `enabled` is false.
struct TypePasswordButton: View {
    let keyboard: GuestKeyboard
    let password: String?
    var enabled = true
    let failed: (String) -> Void

    var body: some View {
        Button(String(localized: "Type Password", bundle: #bundle), systemImage: "key") {
            guard let password else { return }
            Task {
                do {
                    try await keyboard.type(password)
                } catch {
                    failed(error.localizedDescription)
                }
            }
        }
        .help(String(localized: "Type the image's password into the machine", bundle: #bundle))
        .disabled(!enabled || (password ?? "").isEmpty || keyboard.isTyping)
    }
}
