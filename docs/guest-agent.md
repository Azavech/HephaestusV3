# Guest agent

The guest agent is a small program that runs inside a macOS virtual machine and gives the host what the
Virtualization framework doesn't: the guest's SIP state, a shell, its files, its screen, input events and the
Accessibility tree. The host listens for it on the machine's virtio socket device. The agent and its protocol are
a package of their own.

## Build

| Piece | Where |
| --- | --- |
| Code | `GuestAgent/`, a Swift package of its own (`platforms: [.macOS(.v12)]`): the library `GuestAgentKit`, its tests `GuestAgentKitTests`. Nothing newer than macOS 12 without an availability check: the guests run every macOS of ipsw.me's list. |
| Program | The Xcode target `HephaestusAgent` (a command-line tool, `MACOSX_DEPLOYMENT_TARGET` 12.0, `ARCHS` arm64), whose `HephaestusAgent/main.swift` calls `GuestAgent.main()`. Signed with team USWJAJULN9 and the Hardened Runtime, as every target. |
| Bundle | The app target depends on it; its **Embed Guest Agent** script phase copies the signed program to `Contents/Helpers/HephaestusAgent` and `GuestAgent/install-agent.sh` to `Contents/Resources/install-agent.sh`. The app's own signature then seals them. |
| Guest | `MachineHost.startSetup` copies both into `<data folder>/Runtime/guest/` as `hephaestus-agent` and `install.sh`, the folder the setup machine shares read-only at `/Volumes/My Shared Files` ([Data › Virtual machines › Setup](data.md#setup)). |

`hephaestus-agent --version` prints the agent's version, `3.0`. Tests: `cd GuestAgent && swift test`; commands run
through `/bin/sh -c`, never as root, and the methods that need a permission aren't called.

## Install script

`install.sh`, run by the user in the guest's Terminal, as the account Setup Assistant created, once SIP is off:

```sh
sh "/Volumes/My Shared Files/install.sh"
```

It refuses to run as root (`Run this script as your account, without sudo.`), without the agent beside it, and
while SIP is on (`System Integrity Protection is on. Do step 2 first.`). It asks for the password once, for `sudo`,
then:

1. **Agent.** Stops a running agent (the label `fr.azavech.hephaestusv3.agent`), then installs
   `/usr/local/bin/hephaestus-agent`, owned by root, mode 755.
2. **sudo.** `/etc/sudoers.d/hephaestus` with `<account> ALL=(ALL) NOPASSWD: ALL`, mode 440, checked with `visudo
   -c` first.
3. **Privacy.** Accessibility and Screen Recording for the agent's path, rows of the guest's
   `/Library/Application Support/com.apple.TCC/TCC.db`, which SIP off makes writable; on macOS 15 and later, the
   screen capture approval in replayd's `ScreenCaptureApprovals.plist`, then replayd restarts (a failure there
   only means macOS asks once).
4. **LaunchAgent.** `~/Library/LaunchAgents/fr.azavech.hephaestusv3.agent.plist`: the agent in the account's
   graphical session (`Aqua`) at every login, restarted when it exits; loaded at once.

It can run again: every step replaces what an earlier run wrote.

## Connection

The host listens on port 47822 of the machine's socket device. The agent connects to that port of the host
(`AF_VSOCK`, CID 2) and tries again every 2 seconds while it has no connection; one connection at a time, a new
one replacing the one the host holds. The host's side is `GuestAgentConnection` in MachineData, the agent's
`AgentConnector` and `AgentSession`.

## Frames

| Bytes | Content |
| --- | --- |
| 4 | `N`, the JSON part's length, big-endian, 1 to 16,777,216. |
| 4 | `M`, the data part's length, big-endian, 0 to 67,108,864. |
| `N` | One JSON object, UTF-8. |
| `M` | Raw bytes: a PNG, a part of a file. |

A frame over a limit, or whose JSON part isn't an object, ends the connection. The agent sends none: an answer over
the limits is `The answer is over the limits of the protocol.`, one JSON can't carry `The answer cannot be written
as JSON.`

## Messages

| Message | From | JSON part |
| --- | --- | --- |
| hello | agent | `{"type": "hello", "protocol": 1, "status": <status>}`, the first frame of every connection; the host waits 10 seconds for it. |
| request | host | `{"type": "request", "id": <integer>, "method": <string>, "params": <object>}` |
| response | agent | `{"type": "response", "id": <integer>, "result": <object>}` or `{…, "error": <string>}` |

The agent answers a connection's requests one at a time, in order. An unknown method is `Unknown method <name>.`
The host writes them one at a time too, the next once the agent has answered the last: a request whose caller
gave up while it waited its turn, timed out or cancelled, is never written, so it can't run in the guest later.
The status: `version` (`3.0`), `sip` (`disabled`, `enabled` or `unknown`, from `csrutil
status`), `user`, `osVersion`, `osBuild`, `accessibility`, `screenRecording`.

## Methods

Coordinates are pixels of the main display's screenshot, from its top-left corner. Paths are absolute in the guest,
or start with `~/`.

| Method | Params | Result | Data |
| --- | --- | --- | --- |
| `status` | — | the status | — |
| `screenshot` | — | `width`, `height`, `scale` | the PNG |
| `click` | `x`, `y`, `button`? (`left`, `right`), `count`? (1 to 3) | `{}` | — |
| `drag` | `fromX`, `fromY`, `toX`, `toY` | `{}` | — |
| `scroll` | `x`, `y`, `deltaX`?, `deltaY`? (positive: down and right) | `{}` | — |
| `type` | `text` | `{}` | — |
| `key` | `key`, `modifiers`? (`control`, `option`, `shift`, `command`) | `{}` | — |
| `uiTree` | `app`?, `maxDepth`? (40) | `app`, `bundleID`, `pid`, `tree` | — |
| `exec` | `command`, `asRoot`? (false), `timeout`? (60 s) | `exitStatus`, `timedOut`, `stdout`, `stderr`, `truncated` | — |
| `stat` | `path` | `exists`, `isDirectory`, `size`, `mode` | — |
| `list` | `path` | `entries` (`name`, `isDirectory`, `size`, `mode`), by name | — |
| `makeDirectory` | `path` | `{}` | — |
| `readFile` | `path`, `offset`? (0), `length`? (at most 8,388,608) | `size`, `eof` | the bytes |
| `writeFile` | `path`, `offset`? (0), `truncate`? (false), `mode`? | `{}` | the bytes (request) |

- **exec** runs `/bin/zsh -lc <command>` in the home folder, as the account or through `sudo -n` as root, with
  `/dev/null` as input, no other descriptor of the agent, and SIGPIPE's default action. Each output is cut at
  1,048,576 bytes (`truncated`). A process the command leaves running doesn't hold the answer more than a second.
  At the timeout the command's process group is killed, as the account then with `sudo -n /bin/kill`: `timedOut`,
  `exitStatus` 137.
- **screenshot** uses ScreenCaptureKit on macOS 14 and later (with the pointer), Core Graphics before.
- **click**, **drag**, **scroll**, **type**, **key** post Core Graphics events; **key** names one character of the
  guest's layout or `return`, `enter`, `tab`, `space`, `delete`, `forwardDelete`, `escape`, the arrows, `home`,
  `end`, `pageUp`, `pageDown`, `f1` to `f20` (`Unknown key <key>.`).
- **uiTree**: each element `role`, `subrole`, `title`, `value` (cut at 2,000), `description`, `identifier`,
  `enabled`, `focused`, `frame`, `children`; at most 5,000 elements, 5 seconds per element.
- Events and the tree need Accessibility, the screenshot Screen Recording: without them, `The agent has no
  Accessibility permission.`, `The agent has no Screen Recording permission.`

## What uses it

| User | Through |
| --- | --- |
| The setup view | The status line and Finish Setup (SIP off), Restart in Recovery and Stop (`exec` of `/sbin/shutdown -h now`) ([UI › Virtual Machines › Setup](ui/virtual-machines.md#setup)). |
| Stop | The shutdown through `exec`, else a stop at once. |
| A grown disk | `exec` of `diskutil apfs resizeContainer` as root at the first start ([Data › Growing a disk](data.md#growing-a-disk)). |
| Open Shell | `exec` ([UI › Virtual Machines › Open Shell](ui/virtual-machines.md#open-shell)). |
| The `vm_` tools | Every method but `status` ([MCP › Tools](mcp.md#tools)). |

Defaults chosen at design time: the separate package, the Xcode target and its script phase, the version `3.0`, the
install script's label `fr.azavech.hephaestusv3.agent`.
