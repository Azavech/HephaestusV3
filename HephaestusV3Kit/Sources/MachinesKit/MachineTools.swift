import Foundation
import MachineData
import MCPKit
import ToolsFoundation

/// The virtual machine operations the MCP server offers Claude (docs/mcp.md › Virtual machine tools): the same
/// actions the Virtual Machines window gives the user, on the images and machines of the data folder.
public enum MachineTools {
    @MainActor
    public static func operations(host: MachineHost) -> [ToolOperation] {
        let set = MachineToolSet(host: host)
        return [set.listImages, set.list, set.setAccount, set.create, set.start, set.stop, set.shell, set.screenshot, set.click, set.drag,
                set.scroll, set.type, set.key, set.uiTree, set.copyIn, set.copyOut]
    }

    static let machineID = ToolSchema.string("A virtual machine's id, as vm_list gives it.")

    static func describe(_ name: String) -> @Sendable (JSONValue) -> ToolCallText {
        { arguments in
            // Machines aren't a tool of a project: a row has no item to open.
            switch name {
            case "vm_list_images": return ToolCallText(action: String(localized: "Listed the virtual machine images", bundle: #bundle))
            case "vm_list": return ToolCallText(action: String(localized: "Listed the virtual machines", bundle: #bundle))
            case "vm_set_account":
                return ToolCallText(action: String(localized: "Stored an image's guest account", bundle: #bundle),
                                    request: String(localized: "Claude wants to store the guest account of an image", bundle: #bundle))
            case "vm_create":
                let machine = arguments["name"]?.stringValue ?? ""
                return ToolCallText(action: String(localized: "Created the virtual machine \(machine)", bundle: #bundle),
                                    request: String(localized: "Claude wants to create and start the virtual machine \(machine)", bundle: #bundle))
            case "vm_start":
                return ToolCallText(action: String(localized: "Started a virtual machine", bundle: #bundle),
                                    request: String(localized: "Claude wants to start a virtual machine", bundle: #bundle))
            case "vm_stop":
                return ToolCallText(action: String(localized: "Stopped a virtual machine", bundle: #bundle),
                                    request: String(localized: "Claude wants to stop a virtual machine", bundle: #bundle))
            case "vm_shell":
                let command = arguments["command"]?.stringValue ?? ""
                return ToolCallText(action: String(localized: "Ran a command in a virtual machine", bundle: #bundle),
                                    request: arguments["asRoot"]?.boolValue == true
                                        ? String(localized: "Claude wants to run a command as root in a virtual machine", bundle: #bundle)
                                        : String(localized: "Claude wants to run a command in a virtual machine", bundle: #bundle),
                                    preview: command)
            case "vm_screenshot": return ToolCallText(action: String(localized: "Looked at a virtual machine's screen", bundle: #bundle))
            case "vm_ui_tree": return ToolCallText(action: String(localized: "Read a virtual machine's interface", bundle: #bundle))
            case "vm_click", "vm_drag", "vm_scroll":
                return ToolCallText(action: String(localized: "Used the mouse in a virtual machine", bundle: #bundle),
                                    request: String(localized: "Claude wants to use the mouse in a virtual machine", bundle: #bundle))
            case "vm_type", "vm_key":
                return ToolCallText(action: String(localized: "Typed in a virtual machine", bundle: #bundle),
                                    request: String(localized: "Claude wants to type in a virtual machine", bundle: #bundle),
                                    preview: arguments["text"]?.stringValue ?? arguments["key"]?.stringValue)
            case "vm_copy_in":
                return ToolCallText(action: String(localized: "Copied files into a virtual machine", bundle: #bundle),
                                    request: String(localized: "Claude wants to copy files of this Mac into a virtual machine", bundle: #bundle),
                                    preview: arguments["from"]?.stringValue)
            case "vm_copy_out":
                return ToolCallText(action: String(localized: "Copied files out of a virtual machine", bundle: #bundle),
                                    request: String(localized: "Claude wants to copy files of a virtual machine to this Mac", bundle: #bundle),
                                    preview: arguments["to"]?.stringValue)
            default: return ToolCallText(action: name)
            }
        }
    }
}

@MainActor
private struct MachineToolSet {
    let host: MachineHost

    static func toolError(_ error: MachineError) -> ToolError {
        let code: ToolError.Code = switch error.kind {
        case .invalid: .invalid
        case .notFound: .notFound
        case .conflict: .conflict
        case .unavailable: .unavailable
        case .internal: .internal
        }
        return ToolError(code, error.message)
    }

    func call<T>(_ work: () async throws(MachineError) -> T) async throws(ToolError) -> T {
        do { return try await work() } catch { throw Self.toolError(error) }
    }

    func operation(_ name: String, _ description: String, _ properties: [(String, ToolSchema)], required: [String] = ["id"],
                   permission: ToolPermission, run: @escaping @MainActor (JSONValue) async throws(ToolError) -> JSONValue) -> ToolOperation {
        let withID = required.contains("id") ? [("id", MachineTools.machineID)] + properties : properties
        return ToolOperation(name: name, description: description, inputSchema: .object(properties: withID, required: required),
                             permission: permission, describe: MachineTools.describe(name)) { @MainActor arguments throws(ToolError) in
            try await run(arguments)
        }
    }

    /// A request to the machine's agent, its result as JSON.
    func agent(_ arguments: JSONValue, _ method: String, _ params: [String: JSONValue], timeout: Duration = .seconds(60)) async throws(ToolError) -> JSONValue {
        let id = try arguments.string("id")
        let response = try await call { () throws(MachineError) in try await host.agentRequest(id, method: method, params: params, timeout: timeout) }
        return .object(response.result)
    }

    static func date(_ date: Date?) -> JSONValue { date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null }

    var listImages: ToolOperation {
        operation("vm_list_images", "Returns the macOS images new virtual machines start from: id, version, build, state (downloading, installing, needsSetup, ready or failed), progress while it downloads or installs, the failure, the guest account's user name, and diskGB, the size of its disk, which is the smallest disk a machine of it can have. Only a ready image makes machines.", [], required: [], permission: .read) { _ throws(ToolError) in
            .array(host.images.map { image in
                ["id": .string(image.id), "version": .string(image.version), "build": .string(image.build), "state": .string(image.state.rawValue),
                 "diskGB": host.library.map { .int($0.folder(image: image.id).diskGB) } ?? .null,
                 "progress": host.progress[image.id].map(JSONValue.double) ?? .null, "failure": image.failure.map(JSONValue.string) ?? .null,
                 "userName": image.userName.map(JSONValue.string) ?? .null, "hasPassword": .bool(!(image.password ?? "").isEmpty),
                 "settingUp": .bool(host.setups[image.id] != nil)].removingNullMembers
            })
        }
    }

    var list: ToolOperation {
        operation("vm_list", "Returns the virtual machines: id, name, imageID, macOS version, state (stopped, starting, running, paused or stopping), cores, memoryGB, diskGB, the guest's IP address, whether its guest agent is connected, and when it started. Shell, screen, input and file tools need it running with its agent connected.", [], required: [], permission: .read) { _ throws(ToolError) in
            .array(host.machines.map { machine in
                let run = host.runs[machine.id]
                let state = switch run?.state {
                case nil: "stopped"
                case .starting?: "starting"
                case .running?: "running"
                case .paused?: "paused"
                case .stopping?: "stopping"
                }
                return ["id": .string(machine.id), "name": .string(machine.name), "imageID": .string(machine.imageID), "version": .string(machine.version),
                        "state": .string(state), "cores": .int(machine.cores), "memoryGB": .int(machine.memoryGB),
                        "diskGB": machine.diskGB.map(JSONValue.int) ?? .null, "address": run?.address.map(JSONValue.string) ?? .null,
                        "agentConnected": .bool(run?.agent != nil), "startedAt": Self.date(run?.startedAt)].removingNullMembers
            })
        }
    }

    var setAccount: ToolOperation {
        operation("vm_set_account", "Stores the guest account of an image, the one created in its Setup Assistant: an absent value keeps the stored one, an empty one removes it.", [
            ("imageID", .string("An image's id, as vm_list_images gives it.")), ("userName", .string("The account's short name.")),
            ("password", .string("The account's password.")),
        ], required: ["imageID"], permission: .operateMachines) { arguments throws(ToolError) in
            let id = try arguments.string("imageID")
            try await call { () throws(MachineError) in
                try host.setAccount(id, userName: arguments["userName"]?.stringValue, password: arguments["password"]?.stringValue)
            }
            return "Stored."
        }
    }

    var create: ToolOperation {
        operation("vm_create", "Creates a virtual machine from a ready image and starts it. Its disk is a clone of the image's, grown to diskGB; cores, memoryGB and diskGB default to Settings ▸ Virtual Machines. At most 2 machines run at once.", [
            ("name", .string("The machine's name, 1 to 100 characters.")), ("imageID", .string("A ready image's id, as vm_list_images gives it.")),
            ("cores", .integer("Processor cores.", minimum: 2)), ("memoryGB", .integer("Memory, in GB.", minimum: 4)),
            ("diskGB", .integer("Disk size, in GB.", minimum: 32, maximum: 2048)),
        ], required: ["name", "imageID"], permission: .operateMachines) { arguments throws(ToolError) in
            let defaults = host.defaults
            let machine = try await call { () throws(MachineError) in
                try await host.createMachine(name: try arguments.stringOrInvalid("name"), imageID: try arguments.stringOrInvalid("imageID"),
                                             cores: arguments["cores"]?.intValue ?? defaults.cores, memoryGB: arguments["memoryGB"]?.intValue ?? defaults.memoryGB,
                                             diskGB: arguments["diskGB"]?.intValue ?? defaults.diskGB)
            }
            return ["id": .string(machine.id), "name": .string(machine.name)]
        }
    }

    var start: ToolOperation {
        operation("vm_start", "Starts a stopped virtual machine, or resumes a paused one. At most 2 machines run at once.", [], permission: .operateMachines) { arguments throws(ToolError) in
            let id = try arguments.string("id")
            try await call { () throws(MachineError) in
                if host.runs[id]?.state == .paused { try await host.resume(id) } else { try await host.start(id) }
            }
            return "Started."
        }
    }

    var stop: ToolOperation {
        operation("vm_stop", "Shuts a virtual machine down through its guest agent, waiting up to 60 seconds, or stops it at once without the agent. The machine keeps its disk.", [], permission: .operateMachines) { arguments throws(ToolError) in
            let id = try arguments.string("id")
            try await call { () throws(MachineError) in try await host.stop(id) }
            return "Stopped."
        }
    }

    var shell: ToolOperation {
        operation("vm_shell", "Runs a command in the guest with /bin/zsh -lc, in the account's home folder, as the account or as root. Returns exitStatus, timedOut, stdout, stderr and truncated (each output is cut at 1 MB).", [
            ("command", .string("The command.")), ("asRoot", .boolean("Run it with sudo, as root.")),
            ("timeout", .integer("Seconds before the command is killed; 60 by default.", minimum: 1, maximum: 3600)),
        ], required: ["id", "command"], permission: .operateMachines) { arguments throws(ToolError) in
            let id = try arguments.string("id")
            let command = try arguments.string("command")
            let result = try await call { () throws(MachineError) in
                try await host.shell(id, command: command, asRoot: arguments["asRoot"]?.boolValue == true, timeout: arguments["timeout"]?.intValue ?? 60)
            }
            return ["exitStatus": .int(result.exitStatus), "timedOut": .bool(result.timedOut), "stdout": .string(result.stdout),
                    "stderr": .string(result.stderr), "truncated": .bool(result.truncated)]
        }
    }

    var screenshot: ToolOperation {
        operation("vm_screenshot", "Returns the guest's main display as a PNG image. Coordinates of vm_click, vm_drag and vm_scroll are pixels of this image, from its top-left corner.", [], permission: .read) { arguments throws(ToolError) in
            let id = try arguments.string("id")
            let png = try await call { () throws(MachineError) in try await host.screenshot(id) }
            return ["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/png"]
        }
    }

    var click: ToolOperation {
        operation("vm_click", "Clicks at a point of the guest's screen, in screenshot pixels.", [
            ("x", .integer("Pixels from the left edge.", minimum: 0)), ("y", .integer("Pixels from the top edge.", minimum: 0)),
            ("button", .string("The mouse button; left by default.", oneOf: ["left", "right"])),
            ("count", .integer("1 for a click, 2 for a double click, 3 for a triple click.", minimum: 1, maximum: 3)),
        ], required: ["id", "x", "y"], permission: .operateMachines) { arguments throws(ToolError) in
            var params: [String: JSONValue] = ["x": arguments["x"] ?? 0, "y": arguments["y"] ?? 0]
            if let button = arguments["button"] { params["button"] = button }
            if let count = arguments["count"] { params["count"] = count }
            return try await agent(arguments, "click", params)
        }
    }

    var drag: ToolOperation {
        operation("vm_drag", "Drags with the left button from one point of the guest's screen to another, in screenshot pixels.", [
            ("fromX", .integer(minimum: 0)), ("fromY", .integer(minimum: 0)), ("toX", .integer(minimum: 0)), ("toY", .integer(minimum: 0)),
        ], required: ["id", "fromX", "fromY", "toX", "toY"], permission: .operateMachines) { arguments throws(ToolError) in
            try await agent(arguments, "drag", ["fromX": arguments["fromX"] ?? 0, "fromY": arguments["fromY"] ?? 0,
                                                "toX": arguments["toX"] ?? 0, "toY": arguments["toY"] ?? 0])
        }
    }

    var scroll: ToolOperation {
        operation("vm_scroll", "Scrolls at a point of the guest's screen; positive deltas scroll down and right, in pixels.", [
            ("x", .integer(minimum: 0)), ("y", .integer(minimum: 0)), ("deltaX", .integer()), ("deltaY", .integer()),
        ], required: ["id", "x", "y"], permission: .operateMachines) { arguments throws(ToolError) in
            try await agent(arguments, "scroll", ["x": arguments["x"] ?? 0, "y": arguments["y"] ?? 0, "deltaX": arguments["deltaX"] ?? 0,
                                                  "deltaY": arguments["deltaY"] ?? 0])
        }
    }

    var type: ToolOperation {
        operation("vm_type", "Types text where the guest's keyboard focus is, whatever its keyboard layout; a line break presses Return.", [
            ("text", .string("The text to type.")),
        ], required: ["id", "text"], permission: .operateMachines) { arguments throws(ToolError) in
            try await agent(arguments, "type", ["text": .string(try arguments.string("text"))])
        }
    }

    var key: ToolOperation {
        operation("vm_key", "Presses a key with modifiers: a character of the guest's layout, or return, enter, tab, space, delete, forwardDelete, escape, left, right, up, down, home, end, pageUp, pageDown or f1 to f20.", [
            ("key", .string("The key.")),
            ("modifiers", .array("Held while the key is pressed.", of: .string(oneOf: ["control", "option", "shift", "command"]))),
        ], required: ["id", "key"], permission: .operateMachines) { arguments throws(ToolError) in
            try await agent(arguments, "key", ["key": .string(try arguments.string("key")), "modifiers": arguments["modifiers"] ?? .array([])])
        }
    }

    var uiTree: ToolOperation {
        operation("vm_ui_tree", "Returns the Accessibility tree of an app of the guest, the frontmost one by default: each element's role, title, value, identifier, enabled, focused and frame in screenshot pixels.", [
            ("app", .string("A bundle identifier or an app name.")), ("maxDepth", .integer("Levels of the tree; 40 by default.", minimum: 1, maximum: 200)),
        ], permission: .read) { arguments throws(ToolError) in
            var params: [String: JSONValue] = [:]
            if let app = arguments["app"] { params["app"] = app }
            if let depth = arguments["maxDepth"] { params["maxDepth"] = depth }
            return try await agent(arguments, "uiTree", params, timeout: .seconds(120))
        }
    }

    var copyIn: ToolOperation {
        operation("vm_copy_in", "Copies a file or a folder's contents of this Mac into the guest, as the guest's account.", [
            ("from", .string("An absolute path on this Mac, or one starting with ~/.")), ("to", .string("An absolute path in the guest, or one starting with ~/.")),
        ], required: ["id", "from", "to"], permission: .operateMachines) { arguments throws(ToolError) in
            let id = try arguments.string("id")
            let from = try MachineTools.macPath(try arguments.string("from"), argument: "from")
            let to = try arguments.string("to")
            try await call { () throws(MachineError) in try await host.copyIn(id, from: URL(fileURLWithPath: from), to: to) }
            return "Copied."
        }
    }

    var copyOut: ToolOperation {
        operation("vm_copy_out", "Copies a file or a folder's contents of the guest to this Mac; a file replaces one of the same name.", [
            ("from", .string("An absolute path in the guest, or one starting with ~/.")), ("to", .string("An absolute path on this Mac, or one starting with ~/.")),
        ], required: ["id", "from", "to"], permission: .operateMachines) { arguments throws(ToolError) in
            let id = try arguments.string("id")
            let from = try arguments.string("from")
            let to = try MachineTools.macPath(try arguments.string("to"), argument: "to")
            try await call { () throws(MachineError) in try await host.copyOut(id, from: from, to: URL(fileURLWithPath: to)) }
            return "Copied."
        }
    }
}

extension MachineTools {
    /// A path on this Mac: absolute, or starting with ~/ for the home folder, as V2 took it.
    static func macPath(_ path: String, argument: String, home: String = NSHomeDirectory()) throws(ToolError) -> String {
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        guard path.hasPrefix("/") else { throw ToolError(.invalid, "\(argument): use an absolute path or a path starting with ~/.") }
        return path
    }
}

private extension JSONValue {
    /// A required string, its absence a machine error, for the arguments read inside a machine call.
    func stringOrInvalid(_ name: String) throws(MachineError) -> String {
        guard let value = self[name]?.stringValue else { throw MachineError(.invalid, "\(name): required.") }
        return value
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    var removingNullMembers: JSONValue { JSONValue.object(self).removingNullMembers }
}
