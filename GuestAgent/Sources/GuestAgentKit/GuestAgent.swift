import Darwin
import Foundation

/// The guest agent of Hephaestus V3's virtual machines (docs/guest-agent.md). It runs in the account's
/// graphical session of a macOS guest, as a LaunchAgent, connects to the host over virtio-vsock and answers the
/// host's requests. Built for Apple silicon and macOS 12: nothing newer without an availability check.
public enum GuestAgent {
    public static func main() -> Never {
        if CommandLine.arguments.dropFirst().contains("--version") {
            print(AgentInfo.version)
            exit(0)
        }
        // A host that goes away must not end the agent with SIGPIPE; the commands of `exec` get its default back.
        signal(SIGPIPE, SIG_IGN)
        _ = chdir(NSHomeDirectory())
        // A guest whose display sleeps shows black screenshots, then locks its screen.
        AgentPower.keepAwake()
        // The connection runs on its own thread; the main thread serves the main queue, which the keyboard
        // layout calls need.
        let connection = Thread { AgentConnector.run() }
        connection.name = "host-connection"
        // The JSON of a deep Accessibility tree needs more than the 512 KB of a secondary thread.
        connection.stackSize = 8 << 20
        connection.start()
        RunLoop.main.run()
        exit(0)
    }
}
