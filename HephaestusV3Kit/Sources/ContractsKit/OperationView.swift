import AZDesign
import AZDesignCode
import SwiftUI
import ToolsFoundation

/// One operation: what the contract says about it, a request to fill in, and the last response.
///
/// A wide pane puts the request and the response side by side, each as tall as the pane, as an API
/// client does. A narrow or short one, or text at an accessibility size, stacks them and scrolls.
///
/// The fields hold what you type and nothing else: Send in the toolbar does nothing in this example.
struct OperationView: View {
    /// The request being written, which names its operation.
    @Binding var draft: RequestDraft
    let environment: DeploymentEnvironment?

    @State private var fitsWide = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var operation: Operation { draft.operation }

    /// Side by side needs the room, and text at a size that fits in it.
    private var isWide: Bool {
        fitsWide && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        Group {
            if isWide {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    HStack(alignment: .top, spacing: 18) {
                        VStack(spacing: 18) {
                            request(fillsHeight: operation.requestBody != nil)
                            documentedResponses(fillsHeight: operation.requestBody == nil)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        lastResponse(fillsHeight: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        request(fillsHeight: false)
                        lastResponse(fillsHeight: false)
                        documentedResponses(fillsHeight: false)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.canvas)
        .onGeometryChange(for: Bool.self) { $0.size.width >= 760 && $0.size.height >= 500 } action: { fitsWide = $0 }
    }

    /// The request to send: its URL, its parameters and its body. Beside the response when the pane
    /// is wide, where the body editor takes the height left.
    private func request(fillsHeight: Bool) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if let environment {
                    // The request line as it will be sent: code, in the code font.
                    Text(verbatim: draft.url(on: environment))
                        .codeFont(.callout)
                        .foregroundStyle(.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(Text("URL", bundle: #bundle))
                        .accessibilityValue(Text(verbatim: draft.url(on: environment)))
                        .accessibilityIdentifier("contracts.request.url")
                }
                if !operation.parameters.isEmpty {
                    ParameterList(parameters: operation.parameters, draft: $draft)
                }
                if operation.requestBody != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Body", bundle: #bundle, comment: "Heading of the request's body editor.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.textSecondary)
                            .accessibilityHidden(true)
                        TextEditor(text: $draft.body)
                            .codeFont(.callout)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(minHeight: 96, maxHeight: fillsHeight ? .infinity : nil)
                            .background(.surfaceSunken, in: .rect(corners: .concentric(minimum: .fixed(6)), isUniform: true))
                            .accessibilityLabel(Text("Body", bundle: #bundle, comment: "Heading of the request's body editor."))
                            .accessibilityIdentifier("contracts.request.body")
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        } label: {
            Label(String(localized: "Request", bundle: #bundle), systemImage: "arrow.up.circle")
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("contracts.request")
    }

    private func lastResponse(fillsHeight: Bool) -> some View {
        GroupBox {
            ResponseView(response: operation.lastResponse, fillsHeight: fillsHeight)
                .padding(6)
        } label: {
            Label(String(localized: "Last Response", bundle: #bundle), systemImage: "arrow.down.circle")
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("contracts.response")
    }

    private func documentedResponses(fillsHeight: Bool) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(operation.responses) { response in
                    DocumentedResponseRow(response: response)
                        .accessibilityIdentifier("contracts.documentedResponse.\(response.status)")
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        } label: {
            Label(String(localized: "Documented Responses", bundle: #bundle), systemImage: "doc.text")
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("contracts.documentedResponses")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MethodBadge(method: operation.method)
                    .font(.callout)
                Text(verbatim: operation.path)
                    .font(.title2.monospaced().weight(.semibold))
                    .foregroundStyle(.textPrimary)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(verbatim: operation.summary)
                .font(.title3)
                .foregroundStyle(.textPrimary)
            Text(verbatim: operation.id)
                .font(.caption.monospaced())
                .foregroundStyle(.textSecondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("contracts.operation.header")
    }
}

/// The parameters to fill in: a table with Name, In, Type and Value; at an accessibility text size,
/// one block per parameter with its field under its name, so that nothing squeezes.
private struct ParameterList: View {
    let parameters: [Parameter]
    @Binding var draft: RequestDraft

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(parameters) { parameter in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            name(parameter)
                            Text("\(parameter.location.rawValue) · \(parameter.type)", bundle: #bundle, comment: "A parameter's location and type, such as: path · string.")
                                .font(.callout.monospaced())
                                .foregroundStyle(.textSecondary)
                        }
                        field(parameter)
                    }
                }
            }
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Name", bundle: #bundle, comment: "Column heading: a parameter's name.")
                    Text("In", bundle: #bundle, comment: "Column heading: where a parameter goes in the request (path, query or header).")
                    Text("Type", bundle: #bundle, comment: "Column heading: a parameter's type.")
                    Text("Value", bundle: #bundle, comment: "Column heading: a parameter's value.")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.textSecondary)
                .accessibilityHidden(true)
                ForEach(parameters) { parameter in
                    GridRow {
                        name(parameter)
                        Text(verbatim: parameter.location.rawValue)
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                        Text(verbatim: parameter.type)
                            .font(.callout.monospaced())
                            .foregroundStyle(.textSecondary)
                        field(parameter)
                            .gridColumnAlignment(.leading)
                    }
                }
            }
        }
    }

    /// The name, with a red asterisk when the parameter is required.
    private func name(_ parameter: Parameter) -> some View {
        HStack(spacing: 2) {
            Text(verbatim: parameter.name)
                .font(.callout.monospaced())
                .foregroundStyle(.textPrimary)
            if parameter.isRequired {
                Text(verbatim: "*")
                    .foregroundStyle(.danger)
                    .accessibilityLabel(Text("Required", bundle: #bundle))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func field(_ parameter: Parameter) -> some View {
        TextField(parameter.name, text: $draft[parameter])
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            .labelsHidden()
            .accessibilityHint(Text("\(parameter.location.rawValue) parameter, \(parameter.type)", bundle: #bundle, comment: "VoiceOver hint of a parameter's field: where it goes, then its type, such as: path parameter, string."))
            .accessibilityIdentifier("contracts.parameter.\(parameter.id)")
    }
}

/// A documented response: its status in the status color, and what it means.
private struct DocumentedResponseRow: View {
    let response: DocumentedResponse

    /// Room for three digits at the text size.
    @ScaledMetric(relativeTo: .callout) private var statusWidth = 40.0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: String(response.status))
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(statusColor(response.status))
                .frame(minWidth: statusWidth, alignment: .leading)
            Text(verbatim: response.description)
                .font(.callout)
                .foregroundStyle(.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// A response: its status, how long it took, its size and its body.
private struct ResponseView: View {
    let response: SampleResponse
    let fillsHeight: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            if response.body.isEmpty {
                Text("No body.", bundle: #bundle, comment: "In place of a response's body, when it has none.")
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                    .accessibilityIdentifier("contracts.response.body")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(verbatim: response.body)
                        .codeFont(.callout)
                        .foregroundStyle(.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.topLeading)
                .frame(maxHeight: fillsHeight ? .infinity : nil)
                .fixedSize(horizontal: false, vertical: !fillsHeight)
                .background(.surfaceSunken, in: .rect(corners: .concentric(minimum: .fixed(6)), isUniform: true))
                .accessibilityIdentifier("contracts.response.body")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
    }

    /// The status badge, the duration and the size: on one line, or one under the other at an
    /// accessibility text size.
    private var summary: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Label {
                Text(verbatim: String(response.status))
            } icon: {
                Image(systemName: response.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
            }
            .labelStyle(.badge(statusColor(response.status)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Status \(String(response.status))", bundle: #bundle, comment: "VoiceOver label of a response's HTTP status, such as: Status 504."))
            .accessibilityIdentifier("contracts.response.status")
            Text(response.duration, format: response.durationStyle)
                .monospacedDigit()
            Text(Int64(response.bytes), format: .byteCount(style: .file))
                .monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.textSecondary)
    }
}

/// An HTTP method in a tinted capsule. The text keeps the text color so it stays readable.
struct MethodBadge: View {
    let method: HTTPMethod

    var body: some View {
        Text(verbatim: method.rawValue)
            .font(.caption.monospaced().weight(.bold))
            .foreground(.textPrimary, onSelection: .primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(method.color.opacity(0.22), in: Capsule())
            .fixedSize()
            .accessibilityLabel(Text(verbatim: method.rawValue))
    }
}

extension HTTPMethod {
    var color: Color {
        switch self {
        case .get: .info
        case .post: .success
        case .put: .warning
        case .patch: .accentSecondary
        case .delete: .danger
        }
    }
}

/// Green for success, orange for client errors, red for server errors.
func statusColor(_ status: Int) -> Color {
    switch status {
    case 500...: .danger
    case 400..<500: .warning
    default: .success
    }
}

// MARK: - Previews

/// The request of a sample operation of Orders, for a preview.
private func previewDraft(_ id: Operation.ID) -> RequestDraft {
    RequestDraft(operation: SampleContractStore().contract(of: "ORD")!.operation(id)!)
}

#Preview("Request With Body", traits: .appChrome, .fixedLayout(width: 820, height: 640)) {
    @Previewable @State var draft = previewDraft("createOrder")
    OperationView(draft: $draft, environment: Project.samples[0].environments[1])
}

#Preview("Stacked", traits: .appChrome, .fixedLayout(width: 520, height: 800)) {
    @Previewable @State var draft = previewDraft("checkoutOrder")
    OperationView(draft: $draft, environment: Project.samples[0].environments[1])
}

#Preview("No Environment", traits: .appChrome, .fixedLayout(width: 820, height: 640)) {
    @Previewable @State var draft = previewDraft("listOrders")
    OperationView(draft: $draft, environment: nil)
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 520, height: 900)) {
    @Previewable @State var draft = previewDraft("createOrder")
    OperationView(draft: $draft, environment: Project.samples[0].environments[1])
}
