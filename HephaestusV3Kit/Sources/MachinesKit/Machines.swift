import AZDesign
import Foundation
import SwiftUI
import ToolsFoundation

/// A virtual machine to test an app in a closed environment. Sample data in this example.
nonisolated struct VirtualMachine: Identifiable, Hashable, Sendable {
    enum State: Sendable {
        case running
        case paused
        case stopped
    }

    enum System: Sendable {
        case macOS
        case linux
    }

    let id: String
    let name: String
    let system: System
    let systemVersion: String
    let state: State
    let cores: Int
    let memoryGB: Int
    let diskGB: Int
    let address: String?
    let projectID: Project.ID?
    /// From 0 to 1.
    let cpuUsage: Double
    let snapshots: [MachineSnapshot]
}

nonisolated struct MachineSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let date: Date
}

/// A system image new machines start from.
nonisolated struct MachineImage: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        case ready
        /// From 0 to 1.
        case downloading(progress: Double)
    }

    let id: String
    let name: String
    let system: VirtualMachine.System
    let sizeGB: Double
    let state: State
}

/// What starts a machine that isn't running.
nonisolated enum MachineStartAction: Sendable {
    /// A stopped machine boots.
    case start
    /// A paused machine carries on where it was.
    case resume

    var title: String {
        switch self {
        case .start: String(localized: "Start", bundle: #bundle, comment: "Starts a stopped virtual machine")
        case .resume: String(localized: "Resume", bundle: #bundle, comment: "Resumes a paused virtual machine")
        }
    }
}

nonisolated extension VirtualMachine.State {
    var title: String {
        switch self {
        case .running: String(localized: "Running", bundle: #bundle, comment: "A virtual machine's state")
        case .paused: String(localized: "Paused", bundle: #bundle, comment: "A virtual machine's state")
        case .stopped: String(localized: "Stopped", bundle: #bundle, comment: "A virtual machine's state")
        }
    }

    /// Pause and Stop show while the machine runs.
    var isRunning: Bool { self == .running }

    /// What replaces Pause and Stop when the machine isn't running; nil while it runs.
    var startAction: MachineStartAction? {
        switch self {
        case .running: nil
        case .paused: .resume
        case .stopped: .start
        }
    }

    /// A snapshot needs the machine's memory: it can be taken while it runs or is paused.
    var allowsSnapshot: Bool { self != .stopped }

    /// A shell needs a running machine.
    var allowsShell: Bool { self == .running }
}

extension VirtualMachine.State {
    var color: Color {
        switch self {
        case .running: .success
        case .paused: .warning
        case .stopped: .textSecondary
        }
    }
}

nonisolated extension VirtualMachine.System {
    var symbol: String {
        switch self {
        case .macOS: "laptopcomputer"
        case .linux: "server.rack"
        }
    }

    /// The system's name, a product name shown as is.
    var name: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        }
    }
}

/// Sizes of disks, memory and images, written in the user's locale ("8 GB", "18.4 GB").
nonisolated enum StorageSize {
    /// `gigabytes` with `fractionDigits` decimals.
    static func formatted(gigabytes: Double, fractionDigits: Int = 0, locale: Locale = .autoupdatingCurrent) -> String {
        Measurement(value: gigabytes, unit: UnitInformationStorage.gigabytes).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(fractionDigits)))
                .locale(locale)
        )
    }
}

nonisolated extension MachineImage {
    /// The image's size, with one decimal: "18.4 GB".
    func formattedSize(locale: Locale = .autoupdatingCurrent) -> String {
        StorageSize.formatted(gigabytes: sizeGB, fractionDigits: 1, locale: locale)
    }

    /// How much of the image is downloaded, out of its size: "11.7 GB of 18.9 GB". Nil once it's ready.
    func downloadedSize(locale: Locale = .autoupdatingCurrent) -> String? {
        guard case .downloading(let progress) = state else { return nil }
        let downloaded = StorageSize.formatted(gigabytes: sizeGB * progress, fractionDigits: 1, locale: locale)
        let total = formattedSize(locale: locale)
        return String(
            localized: "\(downloaded) of \(total)", bundle: #bundle, locale: locale,
            comment: "How much of a system image is downloaded, out of its size: 11.7 GB of 18.9 GB"
        )
    }
}

extension VirtualMachine {
    static let samples: [VirtualMachine] = [
        VirtualMachine(
            id: "orders-sandbox", name: "Orders sandbox", system: .linux, systemVersion: "Ubuntu 26.04",
            state: .running, cores: 4, memoryGB: 8, diskGB: 64, address: "192.168.64.12", projectID: "ORD", cpuUsage: 0.34,
            snapshots: [
                MachineSnapshot(id: "s1", name: "Database seeded", date: SampleClock.date(days: -1, hours: -2)),
                MachineSnapshot(id: "s2", name: "Fresh install", date: SampleClock.date(days: -6)),
            ]
        ),
        VirtualMachine(
            id: "tools-test-mac", name: "Tools test Mac", system: .macOS, systemVersion: "macOS 27.2",
            state: .running, cores: 4, memoryGB: 8, diskGB: 100, address: "192.168.64.14", projectID: "TLS", cpuUsage: 0.12,
            snapshots: [MachineSnapshot(id: "s1", name: "Signed in, Xcode installed", date: SampleClock.date(days: -2))]
        ),
        VirtualMachine(
            id: "payments-replay", name: "Payments replay", system: .linux, systemVersion: "Ubuntu 26.04",
            state: .paused, cores: 2, memoryGB: 4, diskGB: 32, address: "192.168.64.15", projectID: "PAY", cpuUsage: 0,
            snapshots: []
        ),
        VirtualMachine(
            id: "clean-mac", name: "Clean macOS 27.1", system: .macOS, systemVersion: "macOS 27.1",
            state: .stopped, cores: 4, memoryGB: 8, diskGB: 80, address: nil, projectID: nil, cpuUsage: 0,
            snapshots: [MachineSnapshot(id: "s1", name: "Setup Assistant done", date: SampleClock.date(days: -12))]
        ),
    ]
}

extension MachineImage {
    static let samples: [MachineImage] = [
        MachineImage(id: "macos-27-2", name: "macOS 27.2", system: .macOS, sizeGB: 18.4, state: .ready),
        MachineImage(id: "ubuntu-26-04", name: "Ubuntu 26.04 Server", system: .linux, sizeGB: 2.1, state: .ready),
        MachineImage(id: "macos-27-3-beta", name: "macOS 27.3 beta", system: .macOS, sizeGB: 18.9, state: .downloading(progress: 0.62)),
    ]
}
