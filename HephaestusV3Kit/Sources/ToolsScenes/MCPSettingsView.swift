import AppKit
import AZDesign
import FileStorage
import MCPKit
import ProjectData
import SwiftUI

/// Settings ▸ MCP on the app's data.
struct MCPSettingsPane: View {
    let appData: AppData

    var body: some View {
        MCPSettingsView(
            state: appData.mcpState, port: appData.mcpPort, environmentPort: appData.environmentPort,
            externalToken: appData.externalToken, command: appData.addCommand,
            changePort: { port throws(StorageError) in try await appData.changePort(to: port) },
            regenerate: { () throws(StorageError) in try appData.regenerateToken() }
        )
    }
}

/// Settings ▸ MCP: the MCP server's state and port, and what a terminal Claude session needs to use it: the
/// external token and the `claude mcp add` command (docs/mcp.md › Settings ▸ MCP).
struct MCPSettingsView: View {
    let state: MCPServer.State
    let port: Int
    let environmentPort: Int?
    let externalToken: String?
    let command: String?
    let changePort: (Int) async throws(StorageError) -> Void
    let regenerate: () throws(StorageError) -> Void

    @State private var portText = ""

    @State private var portMessage: String?
    @State private var tokenMessage: String?
    @State private var confirmsRegenerate = false

    var body: some View {
        Form {
            Section(String(localized: "Server", bundle: #bundle)) {
                LabeledContent(String(localized: "Status", bundle: #bundle)) {
                    status
                }
                .accessibilityIdentifier("settings.mcp.status")
                LabeledContent(String(localized: "Port", bundle: #bundle)) {
                    TextField(String(localized: "Port", bundle: #bundle), text: $portText)
                        .labelsHidden()
                        .monospaced()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                        .onSubmit(applyPort)
                        .disabled(environmentPort != nil)
                        .accessibilityIdentifier("settings.mcp.port")
                }
                if let portMessage {
                    Text(verbatim: portMessage).font(.callout).foregroundStyle(.danger)
                }
                if let environmentPort {
                    Text("HEPHAESTUS_MCP_PORT sets the port to \(String(environmentPort)) while the app runs.", bundle: #bundle)
                        .font(.callout)
                        .foregroundStyle(.textSecondary)
                }
            }
            Section {
                LabeledContent(String(localized: "External Token", bundle: #bundle)) {
                    HStack(spacing: 8) {
                        Text(verbatim: externalToken.map { String($0.prefix(8)) + "…" } ?? "—")
                            .monospaced()
                            .foregroundStyle(.textSecondary)
                        Button(String(localized: "Copy", bundle: #bundle)) {
                            copy(externalToken)
                        }
                        .disabled(externalToken == nil)
                        .accessibilityIdentifier("settings.mcp.copyToken")
                        Button(String(localized: "Regenerate…", bundle: #bundle)) {
                            confirmsRegenerate = true
                        }
                        .disabled(externalToken == nil)
                        .accessibilityIdentifier("settings.mcp.regenerate")
                    }
                }
                if let tokenMessage {
                    Text(verbatim: tokenMessage).font(.callout).foregroundStyle(.danger)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Command", bundle: #bundle)
                    Text(verbatim: command.map(Self.masked) ?? "—")
                        .font(.callout.monospaced())
                        .foregroundStyle(.textSecondary)
                        .lineLimit(3)
                        .accessibilityIdentifier("settings.mcp.command")
                    Button(String(localized: "Copy Command", bundle: #bundle)) {
                        copy(command)
                    }
                    .disabled(command == nil)
                    .accessibilityIdentifier("settings.mcp.copyCommand")
                }
            } header: {
                Text("Claude Code in Terminal", bundle: #bundle)
            } footer: {
                Text("Run the command in Terminal to give Claude Code the tools of Hephaestus V3. After Regenerate or a new port, run “claude mcp remove hephaestus” first.", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(port) }
        .confirmationDialog(Text("Regenerate the external token?", bundle: #bundle), isPresented: $confirmsRegenerate) {
            Button(String(localized: "Regenerate", bundle: #bundle), role: .destructive) {
                do throws(StorageError) {
                    try regenerate()
                    tokenMessage = nil
                } catch {
                    tokenMessage = String(localized: "Regenerate failed: \(error.description)", bundle: #bundle)
                }
            }
        } message: {
            Text("Terminal sessions that use the current token stop working until you add the server again.", bundle: #bundle)
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .listening(let port):
            Label {
                Text("Listening on 127.0.0.1:\(String(port))", bundle: #bundle)
            } icon: {
                StatusDot(.success)
            }
        case .stopped:
            Label {
                Text("Not running", bundle: #bundle)
            } icon: {
                StatusDot(.textSecondary)
            }
        case .failed(let reason):
            Label {
                Text("Not listening: \(reason)", bundle: #bundle)
            } icon: {
                StatusDot(.danger)
            }
        }
    }

    private func applyPort() {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), SettingsFile.isPort(value) else {
            portMessage = String(localized: "Enter a port from 1024 to 65535.", bundle: #bundle)
            return
        }
        portMessage = nil
        guard value != port else { return }
        Task {
            do throws(StorageError) {
                try await changePort(value)
            } catch {
                portMessage = error.description
            }
        }
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The command with the token shortened, as the window shows it; Copy copies it whole.
    static func masked(_ command: String) -> String {
        guard let range = command.range(of: "Bearer ") else { return command }
        let token = command[range.upperBound...].prefix { $0 != "\"" }
        return command.replacingOccurrences(of: token, with: token.prefix(8) + "…")
    }
}

// MARK: - Previews

private let previewToken = "3f9c2a7be41d8f06c5a9e2b17d4f8a3c6e0b9d2f5a8c1e4b7d0f3a6c9e2b5d8f"

private func previewSettings(_ state: MCPServer.State, environmentPort: Int? = nil) -> MCPSettingsView {
    MCPSettingsView(
        state: state, port: environmentPort ?? 47830, environmentPort: environmentPort, externalToken: previewToken,
        command: "claude mcp add --transport http hephaestus http://127.0.0.1:47830/mcp --header \"Authorization: Bearer \(previewToken)\"",
        changePort: { _ throws(StorageError) in }, regenerate: { () throws(StorageError) in }
    )
}

#Preview("Listening", traits: .fixedLayout(width: 520, height: 520)) {
    previewSettings(.listening(port: 47830))
}

#Preview("Failed, Dark", traits: .fixedLayout(width: 520, height: 520)) {
    previewSettings(.failed("Address already in use"))
        .preferredColorScheme(.dark)
}

#Preview("Port From Environment", traits: .fixedLayout(width: 520, height: 560)) {
    previewSettings(.listening(port: 49000), environmentPort: 49000)
}
