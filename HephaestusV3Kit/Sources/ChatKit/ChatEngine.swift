import Foundation
import ToolsFoundation

/// What answers the user's messages: a model, once one is connected. Until then the app and the
/// previews use `SampleChatEngine`.
///
/// An engine reaches the tools only through `reader`, the read function each tool offers any client.
protocol ChatEngine {
    /// Whether its replies stand in for a model's: each shows a "Sample reply" caption.
    var repliesAreSamples: Bool { get }

    /// Claude's reply to `message`, sent about `project` with `attachments`: what it read, then what
    /// it says.
    func reply(to message: String, attachments: [ChatReference], project: Project, reader: ToolReader) async -> [ChatBlock]
}

/// Stands in for a model until one is connected: it reads what the message attaches or names through
/// the tools, as a model would, and says plainly that it can't answer.
struct SampleChatEngine: ChatEngine {
    /// The pause before the reply. The engine answers at once; the pause only shows how a reply arrives.
    var delay: Duration = .milliseconds(700)

    var repliesAreSamples: Bool { true }

    func reply(to message: String, attachments: [ChatReference], project: Project, reader: ToolReader) async -> [ChatBlock] {
        try? await Task.sleep(for: delay)
        let reads = Self.references(for: message, attachments: attachments, project: project).compactMap { reference in
            reader(reference).map { ChatBlock(.toolCall(reference, $0)) }
        }
        let text = reads.isEmpty
            ? String(localized: """
                No model is connected to this example yet, so I can't answer. Attach an item, or name one \
                such as ORD-142, run 1288 or req-8f3a, and I'll show what I would read through its tool.
                """, bundle: #bundle)
            : String(localized: """
                No model is connected to this example yet, so I can't answer. Above is what I read through \
                the tools; a connected model would answer from it.
                """, bundle: #bundle)
        return reads + [ChatBlock(.text(text))]
    }

    /// What a message reads, each item once: the attachments, then the items it names. A named item
    /// that is attached too is the attached one, seen in the environment the user has on screen.
    static func references(for message: String, attachments: [ChatReference], project: Project) -> [ChatReference] {
        let attached = Set(attachments.map(\.route))
        let named = mentions(in: message, project: project).filter { !attached.contains($0.route) }
        var seen: Set<ChatReference.ID> = []
        return (attachments + named).filter { seen.insert($0.id).inserted }
    }

    /// The items a message names, in this order: ticket ids (`ORD-142`), requests (`req-8f3a`) and runs
    /// (`run 1288`). A ticket belongs to the project its prefix names; requests and runs to `project`.
    static func mentions(in message: String, project: Project) -> [ChatReference] {
        var references: [ChatReference] = []
        for match in message.matches(of: /\b([A-Z]{2,5})-\d+\b/) {
            let id = String(match.output.0)
            let prefix = String(match.output.1)
            if Project.sample(prefix) != nil {
                references.append(ChatReference(tool: .tickets, projectID: prefix, focus: id, title: id))
            }
        }
        for match in message.matches(of: /\breq-[0-9a-f]{4}\b/) {
            let id = String(match.output)
            references.append(ChatReference(tool: .serviceMap, projectID: project.id, focus: "request:\(id)", title: id))
        }
        for match in message.matches(of: /(?i)\brun\s+#?(\d+)\b/) {
            let number = String(match.output.1)
            references.append(ChatReference(
                tool: .builds, projectID: project.id, focus: number,
                title: String(localized: "Run \(number)", bundle: #bundle, comment: "A run of Builds, as a chip names it")
            ))
        }
        return references
    }
}
