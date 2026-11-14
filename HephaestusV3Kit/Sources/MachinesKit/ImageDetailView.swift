import AZDesign
import SwiftUI
import ToolsFoundation

/// An image: its system, size and status, then its download or a button to make a machine from it.
/// The page takes the whole detail area, as every page does: its rows and download bar span its width.
struct ImageDetail: View {
    let image: MachineImage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: image.system.symbol)
                        .font(.largeTitle)
                        .foregroundStyle(.accent)
                        .accessibilityHidden(true)
                    Text(verbatim: image.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }

                VStack(spacing: 0) {
                    DetailRow(String(localized: "System", bundle: #bundle)) {
                        Text(verbatim: image.system.name)
                    }
                    .accessibilityIdentifier("machines.imageDetail.system")
                    Divider()
                    DetailRow(String(localized: "Size", bundle: #bundle)) {
                        Text(image.formattedSize())
                    }
                    .accessibilityIdentifier("machines.imageDetail.size")
                    Divider()
                    DetailRow(String(localized: "Status", bundle: #bundle)) {
                        Text(status)
                    }
                    .accessibilityIdentifier("machines.imageDetail.status")
                }

                switch image.state {
                case .ready:
                    // On the page's own background, not over other content: no glass.
                    Button(String(localized: "New Machine from This Image", bundle: #bundle), systemImage: "plus") {}
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("machines.imageDetail.newMachine")
                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView(value: progress) {
                            Text(image.downloadedSize() ?? "")
                        } currentValueLabel: {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                        }
                        .accessibilityIdentifier("machines.imageDetail.progress")
                        Button(String(localized: "Cancel Download", bundle: #bundle)) {}
                            .accessibilityIdentifier("machines.imageDetail.cancelDownload")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.canvas)
        .accessibilityIdentifier("machines.imageDetail")
    }

    private var status: String {
        switch image.state {
        case .ready: String(localized: "Ready", bundle: #bundle, comment: "A system image's status: downloaded, new machines can start from it")
        case .downloading: String(localized: "Downloading", bundle: #bundle, comment: "A system image's status")
        }
    }
}
