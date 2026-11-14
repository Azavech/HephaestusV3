import Darwin
import ExternalTools
import Foundation
import Synchronization

/// A port of this Mac forwarded to a port of the cluster.
public struct PortForward: Sendable, Hashable, Identifiable {
    public let id: String
    public let target: String
    public let localPort: Int
    public let remotePort: Int
}

/// The port forwards kubectl keeps open: Jaeger's, shared by the reads and ended 60 s after the last one, and
/// those the user or Claude opens, ended when asked or when the app quits (docs/data.md › Clusters › Port
/// forwards).
public actor PortForwards {
    private struct Open {
        let forward: PortForward
        let process: ChildProcess
        var lastUse: Date
        let shared: Bool
    }

    private var open: [String: Open] = [:]
    private var reaper: Task<Void, Never>?
    /// Starts kubectl; tests pass a fake.
    private let spawn: @Sendable (ProcessRequest) throws -> ChildProcess

    public static let startTimeout: Duration = .seconds(30)
    public static let idle: TimeInterval = 60

    public init(spawn: @escaping @Sendable (ProcessRequest) throws -> ChildProcess = { try ChildProcess.spawn($0) }) {
        self.spawn = spawn
    }

    /// `kubectl … port-forward <target> --address=127.0.0.1 <local>:<remote>`; waits at most 30 s for kubectl's
    /// `Forwarding from 127.0.0.1:<port> -> <remote>`. A shared forward of the same key is reused.
    public func forward(_ cluster: Cluster, target: String, namespace: String?, remotePort: Int, localPort: Int? = nil,
                        shared: Bool) async throws(ClusterError) -> PortForward {
        let key = "\(cluster.target.kubeconfig ?? "")|\(namespace ?? "")|\(target)|\(remotePort)"
        if shared, var existing = open[key], !existing.process.hasExited {
            existing.lastUse = Date()
            open[key] = existing
            return existing.forward
        }
        let arguments = cluster.prefix(namespace: namespace)
            + ["port-forward", target, "--address=127.0.0.1", "\(localPort.map(String.init) ?? ""):\(remotePort)"]
        let request = ProcessRequest(executable: cluster.kubectl.executable, arguments: arguments, environment: cluster.kubectl.environment,
                                     currentDirectory: cluster.target.directory, standardInput: .null, standardOutput: .pipe, standardError: .pipe)
        let process: ChildProcess
        do {
            process = try spawn(request)
        } catch {
            throw .unavailable("kubectl could not start: \(error)")
        }
        guard let port = await Self.waitForPort(process, remotePort: remotePort) else {
            process.signalGroup(SIGTERM)
            throw .unavailable("\(Kubectl.command(arguments)) did not start forwarding within 30 seconds.")
        }
        let forward = PortForward(id: shared ? key : UUID().uuidString, target: target, localPort: port, remotePort: remotePort)
        open[shared ? key : forward.id] = Open(forward: forward, process: process, lastUse: Date(), shared: shared)
        startReaper()
        return forward
    }

    /// The forwards the user or Claude opened, still running.
    public func list() -> [PortForward] {
        open.values.filter { !$0.shared && !$0.process.hasExited }.map(\.forward).sorted { $0.localPort < $1.localPort }
    }

    /// Ends a forward; false when there is none with that id.
    @discardableResult
    public func stop(_ id: String) -> Bool {
        guard let entry = open.removeValue(forKey: id) else { return false }
        entry.process.signalGroup(SIGTERM)
        return true
    }

    /// Ends every forward: when the app quits.
    public func stopAll() {
        for entry in open.values { entry.process.signalGroup(SIGTERM) }
        open = [:]
        reaper?.cancel()
    }

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.reap()
            }
        }
    }

    private func reap() {
        let now = Date()
        for (key, entry) in open where entry.process.hasExited || (entry.shared && now.timeIntervalSince(entry.lastUse) > Self.idle) {
            entry.process.signalGroup(SIGTERM)
            open[key] = nil
        }
    }

    /// Reads kubectl's output until the forwarding line, at most 30 s.
    static func waitForPort(_ process: ChildProcess, remotePort: Int) async -> Int? {
        guard let output = process.standardOutput else { return nil }
        let found = Mutex<Int?>(nil)
        // Blocking reads, on a thread of their own; a forward that doesn't start in time is ended, which ends them.
        let reader = Task.detached { () -> Int? in
            var buffer = Data()
            while true {
                let chunk = output.availableData
                if chunk.isEmpty { return nil }
                buffer.append(chunk)
                for line in String(decoding: buffer, as: UTF8.self).split(whereSeparator: \.isNewline) {
                    if let port = forwardingPort(String(line), remotePort: remotePort) {
                        found.withLock { $0 = port }
                        return port
                    }
                }
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: startTimeout)
            guard !Task.isCancelled, found.withLock({ $0 }) == nil else { return }
            process.signalGroup(SIGTERM)
        }
        let port = await reader.value
        deadline.cancel()
        // The pipe keeps being drained, so that kubectl never blocks on a full pipe.
        Thread.detachNewThread { while !output.availableData.isEmpty {} }
        return port ?? found.withLock { $0 }
    }

    /// The local port of `Forwarding from 127.0.0.1:<port> -> <remote>`.
    static func forwardingPort(_ line: String, remotePort: Int) -> Int? {
        let start = "Forwarding from 127.0.0.1:", end = " -> \(remotePort)"
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix(start), text.hasSuffix(end) else { return nil }
        let port = text.dropFirst(start.count).dropLast(end.count)
        guard port.count <= 5, port.allSatisfy(\.isNumber), let value = Int(port), (1...65535).contains(value) else { return nil }
        return value
    }
}
