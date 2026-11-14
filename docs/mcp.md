# MCP server

Hephaestus V3 serves its tools to Claude over the Model Context Protocol. Each tool's window and Claude call
the same operations: an MCP tool is a `ToolOperation` that a kit declares beside its window, and it runs the
function the window calls ([Architecture › MCPKit](architecture.md#mcpkit)). The server is HephaestusV2's
(V2's `docs/mcp.md`), with the tools V3 has brought over so far; each feature adds its own as it comes over.

## Overview

| Item | Value |
| --- | --- |
| Component | `MCPServer` in `MCPKit`, started by ToolsScenes' `AppData` once the projects are loaded |
| Address | `127.0.0.1` only, TCP port `mcpPort` of `settings.yml` (default 47830, [Data › Settings file](data.md#settings-file)); `HEPHAESTUS_MCP_PORT` replaces it while set |
| Endpoint | `/mcp` |
| Transport | MCP Streamable HTTP, limited to POST requests answered with `application/json`: no SSE stream, no sessions |
| Protocol versions | `2025-06-18` and `2025-03-26`, negotiated in `initialize` |
| JSON-RPC methods | `initialize`, `ping`, `tools/list`, `tools/call`; every notification is accepted and ignored |
| Server name | `hephaestus`, so Claude names the tools `mcp__hephaestus__<tool>` |
| Authentication | `Authorization: Bearer <token>` with the external token ([Authentication](#authentication)) |
| Tools | [Tools](#tools): 45 today |
| Instructions to Claude | None: no `instructions` in `initialize`, no system prompt, no skills ([What Claude reads](#what-claude-reads)) |

## Server lifecycle

- The server starts once the projects are loaded, after the data folder's lock is taken, and stops with the
  app.
- It listens on `127.0.0.1` at the port in effect: `HEPHAESTUS_MCP_PORT` when set, otherwise `mcpPort`. Port
  0, which tests use, lets the system pick a free port.
- When the port can't be bound, the server tries again once a second, 5 attempts in all, then stays failed
  until the port changes or the app restarts. A listener that fails after it was listening becomes failed too.
- Its state is `stopped`, `listening(port)` or `failed(message)`, the message being the system's. Settings ▸
  MCP shows it ([Settings ▸ MCP](#settings--mcp)).
- A new port in Settings ▸ MCP is written to `settings.yml` and moves the server at once, unless
  `HEPHAESTUS_MCP_PORT` is set: then it applies when the app runs without the variable. Terminal sessions must
  add the server again ([External use](#external-use)).

## HTTP transport

Each request goes through these steps in order; the first that fails sends its response.

1. **Head.** Empty lines before the request line are skipped. The request line and the header fields, up to
   the first empty line, must parse as HTTP/1.1 or HTTP/1.0: `<method> <target> HTTP/1.1`, fields
   `<name>: <value>`, at most one `Content-Length` of digits, no `Transfer-Encoding` other than `chunked`;
   otherwise 400. A head longer than 65 536 bytes gets 413.
2. **Origin.** A request with an `Origin` header, whatever its value, gets 403.
3. **Path.** The target's path, without its query, must be `/mcp`; otherwise 404.
4. **Method.** Only POST; otherwise 405 with `Allow: POST`. (The Claude CLI's `GET /mcp`, which asks for an
   SSE stream, gets this 405 and goes on without one.)
5. **Authorization.** Exactly one `Authorization` field, `Bearer` in any letter case, one or more spaces, a
   token the server accepts; otherwise 401 with `WWW-Authenticate: Bearer realm="hephaestus"`.
6. **Declared size.** A `Content-Length` above 4 194 304 bytes gets 413 before the body is read.
7. **Continue.** With `Expect: 100-continue`, the interim `HTTP/1.1 100 Continue` is sent.
8. **Body.** `Content-Length` bytes, or the decoded chunks with `Transfer-Encoding: chunked` (extensions and
   trailer fields ignored); none without either. A chunked body beyond 4 194 304 bytes gets 413, a malformed
   chunk 400.
9. **JSON-RPC.** The body is handled as [JSON-RPC](#json-rpc) says, and answered with 200, 202, or 400 for an
   unsupported `MCP-Protocol-Version`.

| Status | Sent when | Body (`text/plain; charset=utf-8` for rejections) |
| --- | --- | --- |
| 200 OK | A JSON-RPC request was handled, its errors included | The JSON-RPC response, `application/json` |
| 202 Accepted | A notification, or a response from the client | None |
| 400 Bad Request | A malformed head or chunked body | `Bad Request: malformed HTTP request.` |
| 400 Bad Request | `ping`, `tools/list` or `tools/call` with an unsupported `MCP-Protocol-Version` | `Bad Request: unsupported MCP-Protocol-Version <value>; supported: 2025-06-18, 2025-03-26.` |
| 401 Unauthorized | A missing, malformed or unknown token | `Unauthorized: missing or invalid bearer token.` |
| 403 Forbidden | An `Origin` header | `Forbidden: requests with an Origin header are refused.` |
| 404 Not Found | Another path | `Not Found: the MCP endpoint is /mcp.` |
| 405 Method Not Allowed | Another method | `Method Not Allowed: use POST.` |
| 413 Content Too Large | The head exceeds 65 536 bytes | `Content Too Large: the request head exceeds 65536 bytes.` |
| 413 Content Too Large | The body exceeds 4 194 304 bytes | `Content Too Large: the request body exceeds 4194304 bytes.` |

- Every response has `Content-Length` and `Cache-Control: no-store`. Rejections, answers to HTTP/1.0 requests
  and answers to requests with `Connection: close` carry `Connection: close`, and the connection closes after
  them.
- HTTP/1.1 connections are persistent: their requests are answered one after the other; connections are
  served concurrently. A connection silent for 60 seconds is closed.
- The server is stateless: no `Mcp-Session-Id`, no state per client; `initialize` isn't required first. A JSON
  array, a batch, is refused with -32600.

## Authentication

- The server accepts the **external token**: 64 lowercase hexadecimal characters encoding 32 bytes from
  `SecRandomCopyBytes`, made at the first start and kept as `mcpExternalToken` in the data folder's
  `secrets.json`, mode 0600 ([Data › Secrets file](data.md#secrets-file)). Tokens are compared in constant
  time and never logged.
- **Regenerate…** in Settings ▸ MCP replaces it at once: requests with the old one get 401. When
  `secrets.json` can't be written, the old token stays and Settings shows "Regenerate failed: <reason>".
- Each **chat token** belongs to one chat's Claude process: made from `SecRandomCopyBytes` when the process
  starts, passed in its MCP configuration file ([Data › Launch](data.md#launch)), and ended with the process.
  The server knows which chat a token belongs to: the call runs with that **caller**
  (`MCPCaller.chat(<chat id>)`, a task-local value), the external token's as `MCPCaller.external`. The ticket
  tools record a chat's id with Claude's changes ([Data › Ticket history](data.md#ticket-file)), and the
  [permissions](#permissions) apply to chats only.

## JSON-RPC

The body is decoded as UTF-8 JSON and classified by the first matching step:

| Step | Condition | Outcome |
| --- | --- | --- |
| 1 | Not valid JSON, an empty body included | -32700 `Parse error` |
| 2 | A JSON array | -32600 `Invalid Request: batches are not supported` |
| 3 | Not a JSON object | -32600 `Invalid Request: the message must be a JSON object` |
| 4 | `jsonrpc` missing or not `"2.0"` | -32600 `Invalid Request: jsonrpc must be "2.0"` |
| 5 | `method` present, not a string | -32600 `Invalid Request: method must be a string` |
| 6 | `method` present, `id` absent | A notification: 202, no effect |
| 7 | `method` present, `id` neither a string nor an integer (`null` included) | -32600 `Invalid Request: id must be a string or an integer` |
| 8 | `method` present, `id` valid | A request: [Methods](#methods) |
| 9 | `method` absent, `result` or `error` present | A response from the client: 202, ignored |
| 10 | Anything else | -32600 `Invalid Request: method must be a string` |

The errors of this table carry `"id": null`. Other errors:

| Code | Message | When |
| --- | --- | --- |
| -32601 | `Method not found: <method>` | Another method than `initialize`, `ping`, `tools/list`, `tools/call` |
| -32602 | `Invalid params: params must be an object` | `params` present and not an object |
| -32602 | `Invalid params: protocolVersion must be a string` | `initialize` without a string `protocolVersion` |
| -32602 | `Invalid params: name must be a string` | `tools/call` without a string `name` |
| -32602 | `Invalid params: arguments must be an object` | `tools/call` with `arguments` neither absent, `null` nor an object |
| -32602 | `Unknown tool: <name>` | `tools/call` names a tool `tools/list` doesn't list |

-32601 is checked before the protocol version, and the version before -32602. A request for `ping`,
`tools/list` or `tools/call` whose `MCP-Protocol-Version` field names a version other than `2025-06-18` and
`2025-03-26` gets the 400 of [HTTP transport](#http-transport), the first such value named; a request without
the field is accepted. A response is one JSON object, `{"jsonrpc": "2.0", "id": <id>, "result": <result>}` or
`{"jsonrpc": "2.0", "id": <id>, "error": {"code": <code>, "message": <message>}}`, UTF-8, without
insignificant white space, keys sorted.

## Methods

- **`initialize`**: `protocolVersion` is required; `capabilities` and `clientInfo` are ignored. The result is
  `{"protocolVersion": <the requested version when supported, else 2025-06-18>, "capabilities": {"tools":
  {"listChanged": false}}, "serverInfo": {"name": "hephaestus", "version": <the app's version>}}`, with no
  `instructions` member.
- **Notifications** get 202 and do nothing.
- **`ping`**: the result is `{}`.
- **`tools/list`**: `params`, when present, must be an object; its members, `cursor` included, are ignored. The
  result is `{"tools": [...]}`, every tool of [Tools](#tools) in its order, each `{"name", "description",
  "inputSchema"}` with the exact values given there. No `nextCursor`.
- **`tools/call`**: `name` names a listed tool; `arguments` absent or `null` means `{}`. The arguments are
  validated ([Argument validation](#argument-validation)), then the operation runs. From validation on, every
  failure is a tool result with `isError: true`, never a JSON-RPC error.

## Tool results

```json
{"content": [{"type": "text", "text": "{}"}], "isError": false}
```

- `content` holds exactly one text item: the operation's result as JSON, keys sorted, slashes not escaped;
  `{}` for an empty result. Absent optional values are left out.
- A result that is an image (`vm_screenshot`) is one image item instead: `{"type": "image", "data": <base 64>,
  "mimeType": "image/png"}`. An operation returns it as a JSON object with `type` `image`, `data` and `mimeType`.
- On failure, the text is the error's message alone, with `isError: true`. Every error has a code, for the
  logs: `notFound`, `invalid`, `conflict`, `forbidden`, `unavailable` or `internal`.

## Argument validation

The server checks `arguments` against the tool's `inputSchema`, with these keywords only: `type` (`object`,
`array`, `string`, `boolean`, `integer`; an integer is a JSON number with an integral value), `properties`,
`required`, `additionalProperties` (always `false`: other properties are refused), `items`, `enum`,
`minimum`, `maximum` (inclusive), `description` (not checked). Every other rule is the operation's, so Claude
gets the same message the window shows.

- A property whose value is `null` is removed first, at every depth, and counts as absent; a `null` element of
  an array stays and fails its type.
- Validation stops at the first violation. Within an object: first the properties `properties` doesn't name,
  in ascending order of name; then the missing `required` properties, in order; then each present property in
  the order of `properties`, checked completely before the next. For a value: `type`, then `enum`, `minimum`,
  `maximum`.

| Violation | Text |
| --- | --- |
| A property not in `properties` | `<path>: unknown argument.` |
| A missing required property | `<path>: required.` |
| A wrong type | `<path>: must be <a string, an integer, a boolean, an array, an object>.` |
| Not in `enum` | `<path>: must be one of <values joined by ", ">.` |
| Below `minimum`, above `maximum` | `<path>: must be at least <n>.`, `<path>: must be at most <n>.` |

`<path>` names the argument from the top level, indexes from 0: `projectID`, `target.kind`, `items[2].label`;
`arguments` for the whole value. These failures have the code `invalid`.

## Permissions

The user decides what a chat's Claude may change, in Settings ▸ Chat › Claude Can and the Chat window's
inspector ([UI › Chat](ui/chat.md#inspector)). After a call's arguments are validated, the server's gate
(`MCPProtocol.Gate`, `ChatGate.check`) decides by the caller and the operation's permission:

| Permission | Tools | External token | A chat's Claude |
| --- | --- | --- | --- |
| `read` | the `list_` and `get_` tools, `open_in_app` | runs | runs |
| `renameChats` | `rename_chat` | runs | runs |
| `startBuilds` | `rerun_run`, `cancel_run` | runs | Start builds: Ask First shows a card and waits; Never (the default) refuses |
| `operateClusters` | `k8s_restart`, `k8s_scale`, `k8s_port_forward`, `k8s_stop_port_forward`, `argocd_sync` | runs | Operate deployments, as Change tickets |
| `operateMachines` | `vm_set_account`, `vm_create`, `vm_start`, `vm_stop`, `vm_shell`, `vm_click`, `vm_drag`, `vm_scroll`, `vm_type`, `vm_key`, `vm_copy_in`, `vm_copy_out` | runs | Operate virtual machines, as Change tickets |
| `callAPIs` | `api_call` | runs | an `operation` starting `GET ` or `HEAD ` runs; another follows Call APIs that change data, as Change tickets |
| `changeTickets` | `create_ticket`, `update_ticket`, `set_ticket_status`, `add_comment`, `update_comment`, the bundle tools but `delete_bundle` | runs | Change tickets: Always runs; Ask First shows a card and waits; Never refuses |
| `deleteTickets` | `delete_ticket`, `delete_comment`, `remove_attachment`, `delete_bundle` | runs | Change tickets Never refuses; otherwise a card, even under Always |
| `changeProjects` | `create_project`, `update_project` | runs | Change projects, as Change tickets |
| `removeProjects` | `remove_project` | runs | Change projects Never refuses; otherwise a card |

- A card is a `permissionRequest` item of the chat (`ChatSession.requestApproval`): the call waits until the
  user answers, Stop, or the chat's process ends. The CLI waits up to `MCP_TOOL_TIMEOUT`, 30 minutes.
- A refusal is a tool error (`forbidden`) with one of these messages: `The user doesn't let Claude change
  tickets from chats (Settings ▸ Chat).`, `The user doesn't let Claude change projects from chats (Settings ▸
  Chat).`, `The user doesn't let Claude start or cancel builds from chats (Settings ▸ Chat).`, `The user doesn't let
  Claude call APIs that change data from chats (Settings ▸ Chat).`, `The user doesn't let Claude operate deployments
  from chats (Settings ▸ Chat).`, `The user doesn't let Claude operate virtual machines from chats (Settings ▸ Chat).`,
  `The user didn't allow this call.`
- The permissions are the user defaults `chat.ticketChanges` and `chat.projectChanges`: `never`, `askFirst`
  (the default) or `always`; `chat.apiCalls`, `chat.clusterChanges` and `chat.machineChanges`, the same; and `chat.buildStarts`: `never` (the default) or
  `askFirst`.
- The CLI runs every tool of the server without asking (`--allowedTools`): the gate is where the user's
  permissions hold, whatever the CLI's own settings say.

## External use

Terminal Claude Code sessions on this Mac use the server with the external token. Settings ▸ MCP shows this
command with the port and the token filled in, and copies it:

```sh
claude mcp add --transport http hephaestus http://127.0.0.1:47830/mcp --header "Authorization: Bearer <token>"
```

After Regenerate or a new port, run `claude mcp remove hephaestus`, then the new command: `claude mcp add`
refuses a name that exists.

## Settings ▸ MCP

The Settings window's **MCP** tab (`point.3.connected.trianglepath.dotted`):

![Settings ▸ MCP: the server listening on 127.0.0.1:47830, the external token and the command](ui/images/settings-mcp.png)
*Settings ▸ MCP, the server listening.*


| Row | Shows and does |
| --- | --- |
| **Status** | "Listening on 127.0.0.1:<port>" with a green dot, "Not running" with a gray one, or "Not listening: <reason>" with a red one. |
| **Port** | Text field, monospaced, 90 pt; Return applies a port from 1024 to 65535 ("Enter a port from 1024 to 65535." otherwise), stores it and moves the server. Disabled while `HEPHAESTUS_MCP_PORT` is set, with "HEPHAESTUS_MCP_PORT sets the port to <n> while the app runs." |
| **External Token** | Its first 8 characters and "…", monospaced; **Copy** copies it whole; **Regenerate…** asks "Regenerate the external token?" ("Terminal sessions that use the current token stop working until you add the server again.") with **Regenerate** (destructive). |
| **Command** | The `claude mcp add` command, the token shortened the same way, monospaced; **Copy Command** copies it whole. |

The section "Claude Code in Terminal" ends with: "Run the command in Terminal to give Claude Code the tools of
Hephaestus V3. After Regenerate or a new port, run “claude mcp remove hephaestus” first." Identifiers:
`settings.mcp.status`, `.port`, `.copyToken`, `.regenerate`, `.command`, `.copyCommand`.

## What Claude reads

The tool names, descriptions and input schemas are all V3 tells Claude. A description says what the tool does,
what it returns and which rules the app enforces; it never tells Claude how to work: when to change a status,
what to ask the user, how to write a ticket. None of V2's prompts come over: not its system prompts and skills,
not its hook texts, not its tool descriptions, which V3 wrote anew (the owner's rule:
[Decisions › V2's prompts](decisions.md#v2s-prompts)). Claude follows the same rules as the user, except the
changes reserved to the user ([Data › Ticket rules](data.md#ticket-rules)). In the app's chats, Claude also
reads one line V3 writes with each message, naming the item the message carries ([Data ›
Messages](data.md#messages)); nothing else.

## Tools

Each tool runs the operation its kit declares ([Architecture › MCPKit](architecture.md#mcpkit)); its section
gives what it calls, its result, its errors, then the exact `description` and `inputSchema` of `tools/list`.
Every tool can also return the [argument validation](#argument-validation) errors, and a chat's call the
[permissions](#permissions)' refusals. Each operation also words its calls for the chat, in the user's
language: the row's action, and for a change the card's sentence and preview ([UI › Chat › Tool-call
rows](ui/chat.md#tool-call-rows)); that text is the user's, never sent to Claude. The tools aren't limited to
a project: Claude may read and change every project of this Mac, as the user can.

| Tool | Kit | Permission | Calls |
| --- | --- | --- | --- |
| `list_projects` | ProjectsKit | read | the session's snapshot |
| `get_project` | ProjectsKit | read | the session's snapshot |
| `create_project` | ProjectsKit | changeProjects | `ProjectSession.create` |
| `update_project` | ProjectsKit | changeProjects | `ProjectSession.update` |
| `remove_project` | ProjectsKit | removeProjects | `ProjectSession.remove` |
| `list_tickets`, `get_ticket`, `list_bundles`, `get_bundle` | TicketsKit | read | the ticket library's snapshot |
| `create_ticket`, `update_ticket`, `delete_ticket`, `set_ticket_status`, `add_comment`, `update_comment`, `delete_comment`, `remove_attachment` | TicketsKit | changeTickets (the deletions and `remove_attachment`: deleteTickets) | `TicketLibrary`, as Claude (`TicketTools`) |
| `create_bundle`, `update_bundle`, `set_bundle_status`, `delete_bundle` | TicketsKit | changeTickets (`delete_bundle`: deleteTickets) | `TicketLibrary`, as Claude |
| `list_chats`, `get_chat` | ChatKit | read | the chat session |
| `rename_chat` | ChatKit | renameChats | `ChatSession.rename` |
| `list_runs`, `get_run`, `get_run_log`, `list_releases`, `get_release` | BuildsKit | read | gh ([Data › Builds](data.md#builds)) |
| `rerun_run`, `cancel_run` | BuildsKit | startBuilds | gh |
| `api_operations` | ContractsKit | read | the project's contract ([Data › Contracts](data.md#contracts)) |
| `api_call` | ContractsKit | callAPIs | the contract's request, the app's HTTP client |
| `k8s_status`, `k8s_logs`, `k8s_events`, `argocd_status`, `get_service_map`, `get_request` | ServiceMapKit | read | kubectl, Jaeger ([Data › Clusters](data.md#clusters)) |
| `k8s_restart`, `k8s_scale`, `k8s_port_forward`, `k8s_stop_port_forward`, `argocd_sync` | ServiceMapKit | operateClusters | kubectl |
| `vm_list_images`, `vm_list`, `vm_screenshot`, `vm_ui_tree` | MachinesKit | read | the machine host, the guest agent ([Data › Virtual machines](data.md#virtual-machines)) |
| `vm_set_account`, `vm_create`, `vm_start`, `vm_stop`, `vm_shell`, `vm_click`, `vm_drag`, `vm_scroll`, `vm_type`, `vm_key`, `vm_copy_in`, `vm_copy_out` | MachinesKit | operateMachines | the machine host, the guest agent ([Guest agent](guest-agent.md)) |
| `open_in_app` | ToolsScenes | read | a route ([Navigation › Routes](ui/navigation.md#routes)) |

A project's JSON (`get_project`, `create_project`, `update_project`): `id`, `name`, `type` (`none`,
`goService`, `swiftApplication`, `library`), `color`, `icon`, `folder`, `parentID`, `subprojects` (the loaded
sub projects' identifiers), `docsPath`, `githubPage` (as it resolves), `useParentSettings`, `graphEnabled` (as
it resolves), `environments` (as they apply), `inheritedEnvironments`, `currentEnvironment`, `fileIssue`. Each
environment: `name`, `url`, `port`, `baseURL`, `allowInvalidCertificates`, `namespace`, `deployment`, `jaeger`,
`argoCDApplication`, `kubeconfig`. Absent values are left out. Errors map to codes this way: an identifier in
use or a folder that holds a project, `conflict`; a broken rule or a folder outside the parent, `invalid`; an
unknown project or folder, `notFound`; no data folder, `unavailable`; a file that can't be written,
`internal`. The messages are the English ones of [Data › Validation](data.md#validation) and `ProjectError`.

**Tickets and bundles.** The ticket tools act as Claude (`TicketActor.claude(chat:)`: the chat's id with a chat
token, `external` with the external token), so V2's rules for Claude hold ([Data › Ticket rules](data.md#ticket-rules)),
and every change shows in the open Tickets windows at once. A ticket's JSON: `id`, `title`, `status` (`draft`,
`todo`, `in_progress`, `review`, `done`), `created`, `updated`, `createdBy`, `description`, `priority` (when
set), `labels`, `attachments` (`id`, `name`, `path` absolute, `contentType`, `size`), `comments` (`id`, `author`,
`created`, `updated` when edited, `text`, `attachments`), `chats`, `links` and `inverseLinks` (`kind`,
`ticket`), `history` (`kind`, `date`, `from`, `to`, `author`, `device`, `chat`, as stored). A bundle's JSON:
`id`, `title`, `status`, `created`, `updated`, `tickets`, `chats`. Dates are ISO 8601. Attachment paths are
files on this Mac: absolute, `~/`, or relative to the project's folder. Errors map to codes this way: a broken
rule, `invalid`; an unknown project, ticket, bundle, comment or attachment, `notFound`; a change Claude may not
make, `forbidden`; a file that can't be moved to the Trash, `unavailable`; a file that can't be written,
`internal`. V2's `implement_ticket` and `implement_bundle` aren't brought over.

**Virtual machines.** The `vm_` tools are the Virtual Machines window's actions, on the user's machines: a
machine Claude creates is the user's, kept and listed as any other (V2's machines that Claude started and deleted
at their stop aren't brought over, nor the setup tools `vm_setup_recovery` and `vm_setup_finish`: the setup is
the user's, in the window). Errors map from `MachineError`'s kinds, with V2's messages ([Data › Virtual
machines](data.md#virtual-machines)): `invalid`, `notFound`, `conflict`, `unavailable`, `internal`. The tools that
act in a guest need the machine running and its guest agent connected ([Guest agent](guest-agent.md)). No result
carries the guest account's password: Type Password in the window types it.

### list_projects

- **Calls:** the session's snapshot.
- **Result:** an array, each project's `id`, `name`, `type`, `folder`, `parentID`, `subprojects` and
  `fileIssue`, depth first: each top-level project followed by its sub projects.

Description:

```text
Returns every project in Hephaestus V3, sub projects included, each with its identifier, name, type, folder, parent and sub projects.
```

Input schema:

```json
{
  "type": "object",
  "properties": {},
  "additionalProperties": false
}
```

### get_project

- **Calls:** the session's snapshot.
- **Result:** the project's JSON.
- **Errors:** an unknown project (`notFound`, `No project <ID>.`).

Description:

```text
Returns one project: its settings (name, type, color, icon, docs folder, GitHub page, use parent settings, graph enabled), folder, parent and sub projects, and its environments. environments holds those that apply: for a sub project on its parent's settings, the parent's with this project's changes, then its own. inheritedEnvironments holds the parent's as they are, and currentEnvironment the one selected in the app.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {"type": "string", "description": "Project identifier, 2 to 8 letters, such as ORD."}
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### create_project

- **Calls:** `ProjectSession.create` with the `path` (a leading `~/` is the home folder), the `name`, the
  `identifier`, the `type` (`none` when omitted), the `parentID` when given, and `createsFolder`.
- A `path` that isn't absolute once expanded fails first: `path: use an absolute path or a path starting with
  ~/.` (`invalid`).
- **Result:** the new project's JSON.
- **Errors:** those of [Data › Changes](data.md#changes): an identifier in use or a folder that holds a project
  (`conflict`), an unknown parent (`notFound`), a broken rule or a folder outside the parent (`invalid`).

Description:

```text
Adds a project to Hephaestus V3 for a folder on this Mac, creating the folder if it doesn't exist. The identifier can't be changed later. With parentID, the project becomes a sub project of that parent, whose folder must contain this one. Without type, the type is none.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "path": {"type": "string", "description": "The project's folder: an absolute path, or one starting with ~/."},
    "name": {"type": "string", "description": "The name the app shows."},
    "identifier": {"type": "string", "description": "2 to 8 letters A–Z, saved in uppercase, not used by another project."},
    "type": {
      "type": "string",
      "description": "none, goService (a service), swiftApplication (an app) or library.",
      "enum": ["none", "goService", "swiftApplication", "library"]
    },
    "parentID": {"type": "string", "description": "The parent's identifier, for a sub project."}
  },
  "required": ["path", "name", "identifier"],
  "additionalProperties": false
}
```

### update_project

- **Calls:** `ProjectSession.update` with the values given: `name`, `type`, `color` (an empty one removes it),
  `icon` (an empty one removes it) and `docsPath`. Claude never changes a project's GitHub page, Use parent
  settings, graph or environments: only the user does, in [Project Settings](ui/project-settings.md).
- An `icon` that isn't an SF Symbol of this Mac fails first: `<name> is not an SF Symbol of this Mac.`
  (`invalid`).
- **Result:** the project's JSON.
- **Errors:** an unknown project (`notFound`), a broken rule (`invalid`).

Description:

```text
Changes a project's name, type, color, icon or docs folder. Arguments left out keep their value, and an empty color or icon clears it.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {"type": "string", "description": "Project identifier, 2 to 8 letters, such as ORD."},
    "name": {"type": "string", "description": "The new name."},
    "type": {
      "type": "string",
      "description": "none, goService (a service), swiftApplication (an app) or library.",
      "enum": ["none", "goService", "swiftApplication", "library"]
    },
    "color": {"type": "string", "description": "A tint (accent, accentSecondary, info, success, warning) or #RRGGBB."},
    "icon": {"type": "string", "description": "An SF Symbol name, such as hammer."},
    "docsPath": {"type": "string", "description": "The docs folder, relative to the project's folder, such as docs."}
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### remove_project

- **Calls:** `ProjectSession.remove`: the project and its sub projects leave the list; no file changes.
- **Result:** `{}`.
- **Errors:** an unknown project (`notFound`, `No project <ID> is loaded.`).

Description:

```text
Removes a project and its sub projects from Hephaestus V3. Nothing on disk is deleted: adding the folder again restores the project.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {"type": "string", "description": "Project identifier, 2 to 8 letters, such as ORD."}
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### list_tickets

- **Calls:** the ticket library's snapshot: the tickets of the project, then of each of its loaded sub projects in tree order, each in ascending number, with `status` only those in it.
- **Result:** an array of tickets' JSON.
- **Errors:** an unknown project (`notFound`, `Project <ID> not found.`).

Description:

```text
Returns a project's tickets, its sub projects' included. With status, only the tickets in that status.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "status" : {
      "description" : "draft, todo, in_progress, review or done.",
      "enum" : [
        "draft",
        "todo",
        "in_progress",
        "review",
        "done"
      ],
      "type" : "string"
    }
  },
  "required" : [
    "projectID"
  ],
  "type" : "object"
}
```

### get_ticket

- **Calls:** the ticket library's snapshot.
- **Result:** the ticket's JSON, its attachments' paths absolute (`<project folder>/.hephaestus/<path>`).
- **Errors:** a malformed id (`invalid`), an unknown ticket (`notFound`).

Description:

```text
Returns a ticket: title, status, priority, labels, dates, creator, description, attachments with absolute paths, comments, chat ids, links and history. links holds the links written in this ticket (dependsOn, related); inverseLinks holds the links written in other tickets that point here (blocks, related). history records the creation, status changes, renames, link changes and description edits, each with its author and date.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "ticketID" : {
      "description" : "Ticket id, such as ORD-12.",
      "type" : "string"
    }
  },
  "required" : [
    "ticketID"
  ],
  "type" : "object"
}
```

### create_ticket

- **Calls:** `TicketLibrary.create` as Claude: [Data › Ticket changes](data.md#ticket-changes). The description is free Markdown, as the user's; the ticket starts `todo`, `createdBy: claude`. `title`, `priority` and `labels` are V3's: without a title, the provisional title is kept.
- **Result:** the new ticket's JSON.
- **Errors:** an unknown project or linked ticket (`notFound`); an empty description without a title, a title, an attachment or a link that breaks a rule (`invalid`).

Description:

```text
Creates a ticket by Claude in a project, with the status todo. Without a title, the description's first line that is neither empty nor a heading becomes the title. The files listed in attachments are copied into the ticket.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "attachments" : {
      "description" : "Files on this Mac to copy in, each an absolute path, a path from ~/, or a path within the project's folder.",
      "items" : {
        "type" : "string"
      },
      "type" : "array"
    },
    "description" : {
      "description" : "The description, in Markdown.",
      "type" : "string"
    },
    "labels" : {
      "description" : "The labels, replacing the current ones; [] clears them.",
      "items" : {
        "type" : "string"
      },
      "type" : "array"
    },
    "links" : {
      "description" : "Links to tickets in the same project.",
      "items" : {
        "additionalProperties" : false,
        "properties" : {
          "kind" : {
            "description" : "dependsOn: this ticket waits for the other one to be done. related: a plain link.",
            "enum" : [
              "dependsOn",
              "related"
            ],
            "type" : "string"
          },
          "ticket" : {
            "description" : "Id of a ticket in the same project, such as ORD-15.",
            "type" : "string"
          }
        },
        "required" : [
          "kind",
          "ticket"
        ],
        "type" : "object"
      },
      "type" : "array"
    },
    "priority" : {
      "description" : "low, medium, high or urgent; empty to clear it.",
      "enum" : [
        "",
        "low",
        "medium",
        "high",
        "urgent"
      ],
      "type" : "string"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "title" : {
      "description" : "One line of 1 to 200 characters.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "description"
  ],
  "type" : "object"
}
```

### update_ticket

- **Calls:** `TicketLibrary.update` as Claude. `links` replaces the declared links; each new one is checked with the [link rules](data.md#link-rules). A call that changes nothing writes nothing.
- **Result:** the ticket's JSON.
- **Errors:** an unknown ticket or newly linked ticket (`notFound`); a malformed id, a title or a link that breaks a rule (`invalid`).

Description:

```text
Changes a ticket's title, description, priority, labels or links. Arguments left out keep their value.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "description" : {
      "description" : "The new description, in Markdown.",
      "type" : "string"
    },
    "labels" : {
      "description" : "The labels, replacing the current ones; [] clears them.",
      "items" : {
        "type" : "string"
      },
      "type" : "array"
    },
    "links" : {
      "description" : "Every link the ticket declares after the change; links missing from the list are removed, and [] removes them all.",
      "items" : {
        "additionalProperties" : false,
        "properties" : {
          "kind" : {
            "description" : "dependsOn: this ticket waits for the other one to be done. related: a plain link.",
            "enum" : [
              "dependsOn",
              "related"
            ],
            "type" : "string"
          },
          "ticket" : {
            "description" : "Id of a ticket in the same project, such as ORD-15.",
            "type" : "string"
          }
        },
        "required" : [
          "kind",
          "ticket"
        ],
        "type" : "object"
      },
      "type" : "array"
    },
    "priority" : {
      "description" : "low, medium, high or urgent; empty to clear it.",
      "enum" : [
        "",
        "low",
        "medium",
        "high",
        "urgent"
      ],
      "type" : "string"
    },
    "ticketID" : {
      "description" : "Ticket id, such as ORD-12.",
      "type" : "string"
    },
    "title" : {
      "description" : "The new title, one line of 1 to 200 characters.",
      "type" : "string"
    }
  },
  "required" : [
    "ticketID"
  ],
  "type" : "object"
}
```

### delete_ticket

- **Calls:** `TicketLibrary.delete`: its bundles and the other tickets' links first, then its file and attachments to the Trash.
- **Result:** `{}`.
- **Errors:** an unknown ticket (`notFound`); a file that can't be moved to the Trash (`unavailable`).

Description:

```text
Deletes a ticket, moving its file and attachments to the Trash, and takes it out of every bundle and every other ticket's links.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "ticketID" : {
      "description" : "Ticket id, such as ORD-12.",
      "type" : "string"
    }
  },
  "required" : [
    "ticketID"
  ],
  "type" : "object"
}
```

### set_ticket_status

- **Calls:** `TicketLibrary.setStatus` as Claude; the bundles that list the ticket follow their automatic rules.
- **Result:** the ticket's JSON.
- **Errors:** another status (`invalid`, `status: must be one of todo, in_progress, review, done.`); an unknown ticket (`notFound`); a done ticket or a draft (`forbidden`, `<ID> is done; only the user can change its status.`, `<ID> is a draft; only the user can change its status.`).

Description:

```text
Changes a ticket's status to todo, in_progress, review or done. Drafts and done tickets can only be changed by the user.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "status" : {
      "description" : "New status.",
      "enum" : [
        "todo",
        "in_progress",
        "review",
        "done"
      ],
      "type" : "string"
    },
    "ticketID" : {
      "description" : "Ticket id, such as ORD-12.",
      "type" : "string"
    }
  },
  "required" : [
    "ticketID",
    "status"
  ],
  "type" : "object"
}
```

### add_comment

- **Calls:** `TicketLibrary.addComment` as Claude (`author: claude`).
- **Result:** the ticket's JSON.
- **Errors:** an unknown ticket (`notFound`); empty text without files, or a file that isn't readable or is over 20 MB (`invalid`).

Description:

```text
Adds a comment by Claude to a ticket, with optional files copied in.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "attachments" : {
      "description" : "Files on this Mac to copy in, each an absolute path, a path from ~/, or a path within the project's folder.",
      "items" : {
        "type" : "string"
      },
      "type" : "array"
    },
    "text" : {
      "description" : "The comment, in Markdown.",
      "type" : "string"
    },
    "ticketID" : {
      "description" : "Ticket id, such as ORD-12.",
      "type" : "string"
    }
  },
  "required" : [
    "ticketID",
    "text"
  ],
  "type" : "object"
}
```

### update_comment

- **Calls:** `TicketLibrary.updateComment`.
- **Result:** the ticket's JSON.
- **Errors:** an unknown ticket or comment (`notFound`, `Comment <id> not found.`); empty text on a comment without files (`invalid`).

Description:

```text
Replaces the text of a ticket's comment, whoever wrote it. Its files stay as they are.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "commentID" : {
      "description" : "The comment's UUID, as get_ticket returns it.",
      "type" : "string"
    },
    "text" : {
      "description" : "The new text, in Markdown.",
      "type" : "string"
    },
    "ticketID" : {
      "description" : "Ticket id, such as ORD-12.",
      "type" : "string"
    }
  },
  "required" : [
    "ticketID",
    "commentID",
    "text"
  ],
  "type" : "object"
}
```

### delete_comment

- **Calls:** `TicketLibrary.deleteComment`: the ticket file, then the comment's files to the Trash.
- **Result:** the ticket's JSON.
- **Errors:** an unknown ticket or comment (`notFound`); a file that can't be moved to the Trash (`unavailable`).

Description:

```text
Deletes a ticket's comment, whoever wrote it, and moves its files to the Trash.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "commentID" : {
      "description" : "The comment's UUID, as get_ticket returns it.",
      "type" : "string"
    },
    "ticketID" : {
      "description" : "Ticket id, such as ORD-12.",
      "type" : "string"
    }
  },
  "required" : [
    "ticketID",
    "commentID"
  ],
  "type" : "object"
}
```

### remove_attachment

- **Calls:** `TicketLibrary.removeAttachment`: the ticket file, then the file to the Trash.
- **Result:** the ticket's JSON.
- **Errors:** an unknown ticket or ticket attachment (`notFound`, `Attachment <id> not found.`); a file that can't be moved to the Trash (`unavailable`).

Description:

```text
Removes a file attached to the ticket itself, not to a comment, and moves it to the Trash.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "attachmentID" : {
      "description" : "The attachment's UUID, as get_ticket returns it.",
      "type" : "string"
    },
    "ticketID" : {
      "description" : "Ticket id, such as ORD-12.",
      "type" : "string"
    }
  },
  "required" : [
    "ticketID",
    "attachmentID"
  ],
  "type" : "object"
}
```

### list_bundles

- **Calls:** the ticket library's snapshot.
- **Result:** an array of the project's bundles' JSON, in ascending number.
- **Errors:** an unknown project (`notFound`).

Description:

```text
Returns a project's bundles: ordered groups of its tickets, each with the status todo, in_progress or done.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID"
  ],
  "type" : "object"
}
```

### get_bundle

- **Calls:** the ticket library's snapshot.
- **Result:** the bundle's JSON.
- **Errors:** a malformed id (`invalid`), an unknown bundle (`notFound`).

Description:

```text
Returns a bundle: title, status, dates, its ticket ids in order, and chat ids.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "bundleID" : {
      "description" : "Bundle id, such as ORD-B2.",
      "type" : "string"
    }
  },
  "required" : [
    "bundleID"
  ],
  "type" : "object"
}
```

### create_bundle

- **Calls:** `TicketLibrary.createBundle`; without a title, the provisional one from its tickets' titles.
- **Result:** the new bundle's JSON.
- **Errors:** an unknown project or ticket (`notFound`); no ticket, a ticket of another project or listed twice, a title that breaks the rule (`invalid`).

Description:

```text
Creates a bundle from tickets of one project, kept in the order given. Without a title, it is named after its tickets. When every ticket is already done, the bundle starts done.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "ticketIDs" : {
      "description" : "Ids of the project's tickets, in order; one at least.",
      "items" : {
        "type" : "string"
      },
      "type" : "array"
    },
    "title" : {
      "description" : "One line of 1 to 200 characters.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "ticketIDs"
  ],
  "type" : "object"
}
```

### update_bundle

- **Calls:** `TicketLibrary.updateBundle`; a change of its set of tickets applies the automatic rules.
- **Result:** the bundle's JSON.
- **Errors:** an unknown bundle or ticket (`notFound`); a ticket of another project or listed twice (`invalid`).

Description:

```text
Changes a bundle's title or tickets. Arguments left out keep their value.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "bundleID" : {
      "description" : "Bundle id, such as ORD-B2.",
      "type" : "string"
    },
    "ticketIDs" : {
      "description" : "Ids of the project's tickets, in order, replacing the whole list.",
      "items" : {
        "type" : "string"
      },
      "type" : "array"
    },
    "title" : {
      "description" : "The new title, one line of 1 to 200 characters.",
      "type" : "string"
    }
  },
  "required" : [
    "bundleID"
  ],
  "type" : "object"
}
```

### set_bundle_status

- **Calls:** `TicketLibrary.setBundleStatus` as Claude.
- **Result:** the bundle's JSON.
- **Errors:** another status (`invalid`); an unknown bundle (`notFound`); a done bundle (`forbidden`, `<ID> is done; only the user can change its status.`).

Description:

```text
Changes a bundle's status to todo or in_progress. A bundle turns done on its own once all its tickets are done, and a done bundle can only be changed by the user.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "bundleID" : {
      "description" : "Bundle id, such as ORD-B2.",
      "type" : "string"
    },
    "status" : {
      "description" : "New status.",
      "enum" : [
        "todo",
        "in_progress"
      ],
      "type" : "string"
    }
  },
  "required" : [
    "bundleID",
    "status"
  ],
  "type" : "object"
}
```

### delete_bundle

- **Calls:** `TicketLibrary.deleteBundle`.
- **Result:** `{}`.
- **Errors:** an unknown bundle (`notFound`); a file that can't be moved to the Trash (`unavailable`).

Description:

```text
Deletes a bundle, moving its file to the Trash; its tickets stay.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "bundleID" : {
      "description" : "Bundle id, such as ORD-B2.",
      "type" : "string"
    }
  },
  "required" : [
    "bundleID"
  ],
  "type" : "object"
}
```

### list_chats

- **Calls:** the chat session: the chats of the project and its loaded sub projects, the latest `updated` first.
- **Result:** an array of chats' JSON: `id`, `project`, `title`, `kind`, `created`, `updated`, `model`,
  `effort`, `state` (`idle`, `starting`, `running`, `waitingPermission`, `error`), and when set `origin`,
  `ticket`, `bundle`.
- **Errors:** an unknown project (`notFound`, `Project <ID> not found.`).

Description:

```text
Returns a project's chats, its sub projects' included, the latest first: id, project, title, kind, created, updated, origin, model, effort and state.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID"
  ],
  "type" : "object"
}
```

### get_chat

- **Calls:** the chat session, which reads the chat's transcript when it isn't read yet.
- **Result:** the chat's JSON, as `list_chats` gives it, with `items`: every item of its transcript, as the
  file holds it ([Data › Chat items](data.md#chat-items)).
- **Errors:** an unknown chat (`notFound`, `Chat <ID> not found.`).

Description:

```text
Returns a chat with its messages: the user's messages, Claude's replies, the tool calls and their results, the permission requests and their answers, in order.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "chatID" : {
      "description" : "Chat id, an uppercase UUID.",
      "type" : "string"
    }
  },
  "required" : [
    "chatID"
  ],
  "type" : "object"
}
```

### rename_chat

- **Calls:** `ChatSession.rename`, which writes the chat's file with the new `title` and `updated`.
- **Result:** the chat's JSON.
- **Errors:** an unknown chat (`notFound`); a title that is empty, longer than 100 characters or on more than
  one line (`invalid`, `title: use 1 to 100 characters on one line.`).

Description:

```text
Renames a chat. The title is 1 to 100 characters on one line. Returns the chat.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "chatID" : {
      "description" : "Chat id, an uppercase UUID.",
      "type" : "string"
    },
    "title" : {
      "description" : "The new title.",
      "type" : "string"
    }
  },
  "required" : [
    "chatID",
    "title"
  ],
  "type" : "object"
}
```

### list_runs

- **Calls:** `gh run list` ([Data › Builds › gh calls](data.md#gh-calls)).
- **Result:** an array of runs: `id` (GitHub's), `number`, `title`, `workflow`, `branch`, `commit`, `event`, `status`, `conclusion`, `created`, `started`, `updated`; absent values left out.
- **Errors:** an unknown project (`notFound`); the project without a GitHub page, no gh, no login, or gh failing (`unavailable`, with the messages of [Data › Builds](data.md#builds)); gh's output not as expected (`internal`).

Description:

```text
Returns the newest 50 workflow runs of the project's GitHub repository, of every branch and workflow, newest first: id, number, title, workflow, branch, commit, event, status, conclusion and dates. A sub project on its parent's settings has its parent's repository.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID"
  ],
  "type" : "object"
}
```

### get_run

- **Calls:** `gh run view` with `jobs`.
- **Result:** the run, with `jobs`: each `name`, `status`, `conclusion`, `started`, `completed` and `steps` (`number`, `name`, `status`, `conclusion`, `started`, `completed`).
- **Errors:** an unknown project (`notFound`); the project without a GitHub page, no gh, no login, or gh failing (`unavailable`, with the messages of [Data › Builds](data.md#builds)); gh's output not as expected (`internal`). A run that doesn't exist fails with gh's reason.

Description:

```text
Returns one workflow run with its jobs and their steps, each with its status, conclusion and dates.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "runID" : {
      "description" : "The run's id on GitHub, as list_runs gives it.",
      "type" : "integer"
    }
  },
  "required" : [
    "projectID",
    "runID"
  ],
  "type" : "object"
}
```

### get_run_log

- **Calls:** `gh run view` for the run's jobs, then `gh run view --log --job=<job id>`.
- **Result:** an array, one element per step (or the one named): `step`, `lines` (at most the last 2000, without GitHub's times), `truncated`.
- **Errors:** an unknown project (`notFound`); the project without a GitHub page, no gh, no login, or gh failing (`unavailable`, with the messages of [Data › Builds](data.md#builds)); gh's output not as expected (`internal`). An unknown job or step (`notFound`); a job still running fails with gh's reason.

Description:

```text
Returns the log of one job of a completed run, step by step; with step, that step's only. At most the last 2000 lines of each step. The log exists once the job has completed.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "job" : {
      "description" : "The job's name, as get_run gives it.",
      "type" : "string"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "runID" : {
      "description" : "The run's id on GitHub, as list_runs gives it.",
      "type" : "integer"
    },
    "step" : {
      "description" : "A step's name, as get_run gives it.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "runID",
    "job"
  ],
  "type" : "object"
}
```

### rerun_run

- **Calls:** `gh run rerun`, with `--failed` when `failedOnly`.
- **Result:** `{"rerun": <run id>}`.
- **Errors:** an unknown project (`notFound`); the project without a GitHub page, no gh, no login, or gh failing (`unavailable`, with the messages of [Data › Builds](data.md#builds)); gh's output not as expected (`internal`). A chat's call follows Start builds ([Permissions](#permissions)).

Description:

```text
Runs every job of a completed workflow run again, or with failedOnly only its failed jobs.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "failedOnly" : {
      "description" : "Only the jobs that failed.",
      "type" : "boolean"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "runID" : {
      "description" : "The run's id on GitHub, as list_runs gives it.",
      "type" : "integer"
    }
  },
  "required" : [
    "projectID",
    "runID"
  ],
  "type" : "object"
}
```

### cancel_run

- **Calls:** `gh run cancel`.
- **Result:** `{"cancelled": <run id>}`.
- **Errors:** an unknown project (`notFound`); the project without a GitHub page, no gh, no login, or gh failing (`unavailable`, with the messages of [Data › Builds](data.md#builds)); gh's output not as expected (`internal`). A chat's call follows Start builds.

Description:

```text
Cancels a queued or running workflow run.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "runID" : {
      "description" : "The run's id on GitHub, as list_runs gives it.",
      "type" : "integer"
    }
  },
  "required" : [
    "projectID",
    "runID"
  ],
  "type" : "object"
}
```

### list_releases

- **Calls:** `gh api repos/<owner>/<name>/releases` and `gh release list` (for the latest).
- **Result:** an array of releases: `tag`, `name`, `latest`, `prerelease`, `created`, `published`, `assets` (`name`, `size`); drafts left out.
- **Errors:** an unknown project (`notFound`); the project without a GitHub page, no gh, no login, or gh failing (`unavailable`, with the messages of [Data › Builds](data.md#builds)); gh's output not as expected (`internal`).

Description:

```text
Returns the newest 50 published releases of the project's GitHub repository, newest first: tag, name, whether it is the latest or a pre-release, dates and the names and sizes of its files, without notes.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID"
  ],
  "type" : "object"
}
```

### get_release

- **Calls:** as `list_releases`.
- **Result:** the release, as `list_releases` gives it, with `notes`.
- **Errors:** an unknown project (`notFound`); the project without a GitHub page, no gh, no login, or gh failing (`unavailable`, with the messages of [Data › Builds](data.md#builds)); gh's output not as expected (`internal`). An unknown tag (`notFound`, `Release <tag> not found.`).

Description:

```text
Returns one published release with its notes and its files.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "tag" : {
      "description" : "The release's tag, such as v1.4.0.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "tag"
  ],
  "type" : "object"
}
```

### api_operations

- **Calls:** the contracts store, which reads `openapi/contract.yaml` of the project's folder when it isn't read.
- **Result:** `title`, `version`, `operations`: each `key` (`<METHOD> <path>`), `operationId` when set,
  `summary`, `description`, `tags`, `parameters` (`name`, `in`, `required`, `type`, `description`),
  `requestBody` (`required`, `mediaTypes`: `name`, `example`) when it has one, `responses` (`code`,
  `description`).
- **Errors:** an unknown project, or one without the file (`notFound`); a contract that can't be read
  (`invalid`, `The contract can't be read: <reason>`).

Description:

```text
Returns the operations of the project's OpenAPI contract, openapi/contract.yaml, with its $ref pointers resolved: key (METHOD and path, what api_call takes), operationId, summary, description, tags, parameters, the request body's media types with their example, and the documented responses.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID"
  ],
  "type" : "object"
}
```

### api_call

- **Calls:** the request of [Data › Contracts › Sending a request](data.md#sending-a-request), with the
  parameters, body, media type and headers given, the credentials and added headers stored for the contract
  on this Mac (Claude never sees them), to the environment named or the project's current one, with its
  `allowInvalidCertificates`.
- **Result:** `status`, `headers` (`<name>: <value>`, sorted), `body` (pretty JSON for JSON, else the text, at
  most 100,000 characters, or `Binary body (<n> bytes)`), `durationMs`.
- **Errors:** those of `api_operations`; an unknown operation or environment (`notFound`); no URL or no answer
  (`unavailable`, `The request failed: <reason>`). A chat's call follows [Permissions](#permissions).

Description:

```text
Sends the request of one operation of the project's contract to one of its environments, as the Contracts window sends it, with the credentials and headers stored for the contract on this Mac. Returns the status, the headers, the body (text, at most 100000 characters) and the duration.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "body" : {
      "description" : "The request body, as text.",
      "type" : "string"
    },
    "environment" : {
      "description" : "An environment of the project; without it, the project's current environment.",
      "type" : "string"
    },
    "headers" : {
      "additionalProperties" : {
        "type" : "string"
      },
      "description" : "Headers to add, by name; each replaces a header of the same name.",
      "type" : "object"
    },
    "mediaType" : {
      "description" : "The body's media type; without it, the first the operation takes.",
      "type" : "string"
    },
    "operation" : {
      "description" : "The operation's key from api_operations: its method and path, such as GET /orders/{id}.",
      "type" : "string"
    },
    "parameters" : {
      "additionalProperties" : {
        "type" : "string"
      },
      "description" : "Parameter values by name, or by in:name when two share a name.",
      "type" : "object"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "operation"
  ],
  "type" : "object"
}
```

### k8s_status

- **Calls:** `kubectl get deployment/<deployment> -o json`, then the pods of its selector.
- **Result:** `deployment`, `replicas`, `ready`, `updated`, `available`, `images`, `pods` (`name`, `phase`, `ready`, `restarts`, `started`).
- **Errors:** an unknown project or environment, a field the call needs that the environment hasn't (`Environment “<name>” has no deployment.`, `… has no Argo CD application.`), no kubectl (`invalid`); kubectl failing (`unavailable`, V2's messages of [Data › Clusters](data.md#clusters)); unexpected output (`internal`).

Description:

```text
Returns the environment's Deployment: its replicas, ready, updated and available pods, its images, and each pod's phase, readiness, restarts and start.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "environment" : {
      "description" : "An environment of the project, such as Staging.",
      "type" : "string"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "environment"
  ],
  "type" : "object"
}
```

### k8s_logs

- **Calls:** `kubectl logs <pod or deployment/<deployment>> --tail=<n> --timestamps`, `--all-containers` for the Deployment, `--container`, `--since`, `--previous` when given.
- **Result:** the lines, as text.
- **Errors:** an unknown project or environment, a field the call needs that the environment hasn't (`Environment “<name>” has no deployment.`, `… has no Argo CD application.`), no kubectl (`invalid`); kubectl failing (`unavailable`, V2's messages of [Data › Clusters](data.md#clusters)); unexpected output (`internal`).

Description:

```text
Returns log lines of the environment's Deployment, all its containers, or of one pod; the last 200 by default.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "container" : {
      "description" : "A container of the pod.",
      "type" : "string"
    },
    "environment" : {
      "description" : "An environment of the project, such as Staging.",
      "type" : "string"
    },
    "pod" : {
      "description" : "A pod's name, as k8s_status gives it.",
      "type" : "string"
    },
    "previous" : {
      "description" : "The previous container's lines, after a restart.",
      "type" : "boolean"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "sinceSeconds" : {
      "description" : "Only lines of the last seconds.",
      "minimum" : 1,
      "type" : "integer"
    },
    "tailLines" : {
      "description" : "The last lines to return.",
      "maximum" : 5000,
      "minimum" : 1,
      "type" : "integer"
    }
  },
  "required" : [
    "projectID",
    "environment"
  ],
  "type" : "object"
}
```

### k8s_events

- **Calls:** `kubectl get events -o json`, those of the Deployment and of the objects named after it.
- **Result:** an array: `type`, `reason`, `message`, `object`, `count`, `lastSeen`, newest first.
- **Errors:** an unknown project or environment, a field the call needs that the environment hasn't (`Environment “<name>” has no deployment.`, `… has no Argo CD application.`), no kubectl (`invalid`); kubectl failing (`unavailable`, V2's messages of [Data › Clusters](data.md#clusters)); unexpected output (`internal`).

Description:

```text
Returns the events of the environment's Deployment, its ReplicaSets and its pods, newest first.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "environment" : {
      "description" : "An environment of the project, such as Staging.",
      "type" : "string"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "environment"
  ],
  "type" : "object"
}
```

### k8s_restart

- **Calls:** `kubectl rollout restart deployment/<deployment>`.
- **Result:** kubectl's output, as text.
- **Errors:** an unknown project or environment, a field the call needs that the environment hasn't (`Environment “<name>” has no deployment.`, `… has no Argo CD application.`), no kubectl (`invalid`); kubectl failing (`unavailable`, V2's messages of [Data › Clusters](data.md#clusters)); unexpected output (`internal`).

Description:

```text
Restarts the pods of the environment's Deployment (kubectl rollout restart).
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "environment" : {
      "description" : "An environment of the project, such as Staging.",
      "type" : "string"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "environment"
  ],
  "type" : "object"
}
```

### k8s_scale

- **Calls:** `kubectl scale deployment/<deployment> --replicas=<n>`.
- **Result:** kubectl's output, as text.
- **Errors:** an unknown project or environment, a field the call needs that the environment hasn't (`Environment “<name>” has no deployment.`, `… has no Argo CD application.`), no kubectl (`invalid`); kubectl failing (`unavailable`, V2's messages of [Data › Clusters](data.md#clusters)); unexpected output (`internal`).

Description:

```text
Sets the number of pods of the environment's Deployment.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "environment" : {
      "description" : "An environment of the project, such as Staging.",
      "type" : "string"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "replicas" : {
      "description" : "0 to 100.",
      "maximum" : 100,
      "minimum" : 0,
      "type" : "integer"
    }
  },
  "required" : [
    "projectID",
    "environment",
    "replicas"
  ],
  "type" : "object"
}
```

### k8s_port_forward

- **Calls:** `kubectl port-forward deployment/<deployment> --address=127.0.0.1 <local>:<remote>`, kept until stopped or the app quits.
- **Result:** `portForwardID`, `localPort`, `remotePort`.
- **Errors:** an unknown project or environment, a field the call needs that the environment hasn't (`Environment “<name>” has no deployment.`, `… has no Argo CD application.`), no kubectl (`invalid`); kubectl failing (`unavailable`, V2's messages of [Data › Clusters](data.md#clusters)); unexpected output (`internal`).

Description:

```text
Forwards a port of the environment's Deployment to a port of this Mac on 127.0.0.1, until stopped or the app quits. Returns its id and local port.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "environment" : {
      "description" : "An environment of the project, such as Staging.",
      "type" : "string"
    },
    "localPort" : {
      "description" : "A port of this Mac; without it, a free one.",
      "maximum" : 65535,
      "minimum" : 1024,
      "type" : "integer"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "remotePort" : {
      "description" : "The Deployment's port.",
      "maximum" : 65535,
      "minimum" : 1,
      "type" : "integer"
    }
  },
  "required" : [
    "projectID",
    "environment",
    "remotePort"
  ],
  "type" : "object"
}
```

### k8s_stop_port_forward

- **Calls:** the port forwards: ends kubectl's process.
- **Result:** `{}`.
- **Errors:** an unknown id (`notFound`, `Port forward <id> not found.`).

Description:

```text
Stops a port forward that k8s_port_forward started.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "portForwardID" : {
      "description" : "The id k8s_port_forward returned.",
      "type" : "string"
    }
  },
  "required" : [
    "portForwardID"
  ],
  "type" : "object"
}
```

### argocd_status

- **Calls:** `kubectl get applications.argoproj.io/<name> -o json`, in the Application's namespace (`argocd` by default).
- **Result:** `name`, `sync`, `health`, `revision`, `operation`.
- **Errors:** an unknown project or environment, a field the call needs that the environment hasn't (`Environment “<name>” has no deployment.`, `… has no Argo CD application.`), no kubectl (`invalid`); kubectl failing (`unavailable`, V2's messages of [Data › Clusters](data.md#clusters)); unexpected output (`internal`).

Description:

```text
Returns the environment's Argo CD Application: its sync status, health, revision and running operation.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "environment" : {
      "description" : "An environment of the project, such as Staging.",
      "type" : "string"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "environment"
  ],
  "type" : "object"
}
```

### argocd_sync

- **Calls:** `kubectl patch applications.argoproj.io/<name> --type=merge` with an `operation` that syncs, as Argo CD's UI does; refused while an operation runs.
- **Result:** kubectl's output, as text.
- **Errors:** an unknown project or environment, a field the call needs that the environment hasn't (`Environment “<name>” has no deployment.`, `… has no Argo CD application.`), no kubectl (`invalid`); kubectl failing (`unavailable`, V2's messages of [Data › Clusters](data.md#clusters)); unexpected output (`internal`).

Description:

```text
Asks Argo CD to sync the environment's Application, as its own UI does.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "environment" : {
      "description" : "An environment of the project, such as Staging.",
      "type" : "string"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "environment"
  ],
  "type" : "object"
}
```

### get_service_map

- **Calls:** the Service Map's read of the namespace over the last hour ([Data › Clusters › Service map](data.md#service-map)).
- **Result:** `nodes` (`id`, `kind`, `pods`, `ready`, `health`, `requestsPerSecond`, `p95Ms`, `errorRate`), `calls` (`from`, `to`, `callsPerSecond`, `errorRate`), `requests` (their number).
- **Errors:** an unknown project or environment, a field the call needs that the environment hasn't (`Environment “<name>” has no deployment.`, `… has no Argo CD application.`), no kubectl (`invalid`); kubectl failing (`unavailable`, V2's messages of [Data › Clusters](data.md#clusters)); unexpected output (`internal`).

Description:

```text
Returns the service map of the environment's namespace over the last hour: each service, database and bucket with its pods, health, requests per second, p95 latency and error rate, and each call with its calls per second and error rate.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "environment" : {
      "description" : "An environment of the project, such as Staging.",
      "type" : "string"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "environment"
  ],
  "type" : "object"
}
```

### get_request

- **Calls:** Jaeger's `GET /api/v3/traces/<id>` through the port forward of the environment's Jaeger.
- **Result:** `id`, `method`, `route`, `status`, `durationMs`, `start`, `spans` (`service`, `name`, `startMs`, `durationMs`, `failed`), `logs` (`time`, `service`, `level`, `message`).
- **Errors:** an unknown project or environment, a field the call needs that the environment hasn't (`Environment “<name>” has no deployment.`, `… has no Argo CD application.`), no kubectl (`invalid`); kubectl failing (`unavailable`, V2's messages of [Data › Clusters](data.md#clusters)); unexpected output (`internal`).

Description:

```text
Returns one request of the environment's traces by its id: its method, route, status, duration, spans and log lines.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "environment" : {
      "description" : "An environment of the project, such as Staging.",
      "type" : "string"
    },
    "projectID" : {
      "description" : "Project identifier, 2 to 8 letters, such as ORD.",
      "type" : "string"
    },
    "requestID" : {
      "description" : "The request's id: its trace id, 32 hexadecimal digits.",
      "type" : "string"
    }
  },
  "required" : [
    "projectID",
    "environment",
    "requestID"
  ],
  "type" : "object"
}
```

### vm_list_images

- **Calls:** the machine host's images ([Data › Virtual machines](data.md#virtual-machines)).
- **Result:** an array, each image's `id`, `version`, `build`, `state`, `progress` (0 to 1, while it downloads or installs), `failure`, `userName`, `hasPassword`, `settingUp`. The password itself is never returned.
- **Errors:** none.

Description:

```text
Returns the macOS images new virtual machines start from: id, version, build, state (downloading, installing, needsSetup, ready or failed), progress while it downloads or installs, the failure, and the guest account's user name. Only a ready image makes machines.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {

  },
  "type" : "object"
}
```

### vm_list

- **Calls:** the machine host's machines and the ones that run.
- **Result:** an array, each machine's `id`, `name`, `imageID`, `version`, `state`, `cores`, `memoryGB`, `diskGB`, `address`, `agentConnected`, `startedAt`.
- **Errors:** none.

Description:

```text
Returns the virtual machines: id, name, imageID, macOS version, state (stopped, starting, running, paused or stopping), cores, memoryGB, diskGB, the guest's IP address, whether its guest agent is connected, and when it started. Shell, screen, input and file tools need it running with its agent connected.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {

  },
  "type" : "object"
}
```

### vm_set_account

- **Calls:** `MachineHost.setAccount`.
- **Result:** `Stored.`
- **Errors:** an unknown image (`notFound`); a value with a line break (`invalid`, `userName: use one line.`, `password: use one line.`).

Description:

```text
Stores the guest account of an image, the one created in its Setup Assistant: an absent value keeps the stored one, an empty one removes it.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "imageID" : {
      "description" : "An image's id, as vm_list_images gives it.",
      "type" : "string"
    },
    "password" : {
      "description" : "The account's password.",
      "type" : "string"
    },
    "userName" : {
      "description" : "The account's short name.",
      "type" : "string"
    }
  },
  "required" : [
    "imageID"
  ],
  "type" : "object"
}
```

### vm_create

- **Calls:** `MachineHost.createMachine`, then its start, as New Machine does.
- **Result:** `id`, `name`.
- **Errors:** V2's checks, in order: no Apple silicon (`unavailable`), the name (`invalid`, `name: use 1 to 100 characters on one line.`), an unknown image (`notFound`) or one not Ready (`conflict`), a value out of its range (`invalid`, `<param>: use a number from <min> to <max>.`), 2 already running (`conflict`); a start that fails (`unavailable`, the framework's message), the machine then staying, stopped.

Description:

```text
Creates a virtual machine from a ready image and starts it. Its disk is a clone of the image's, grown to diskGB; cores, memoryGB and diskGB default to Settings ▸ Virtual Machines. At most 2 machines run at once.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "cores" : {
      "description" : "Processor cores.",
      "minimum" : 2,
      "type" : "integer"
    },
    "diskGB" : {
      "description" : "Disk size, in GB.",
      "maximum" : 2048,
      "minimum" : 32,
      "type" : "integer"
    },
    "imageID" : {
      "description" : "A ready image's id, as vm_list_images gives it.",
      "type" : "string"
    },
    "memoryGB" : {
      "description" : "Memory, in GB.",
      "minimum" : 4,
      "type" : "integer"
    },
    "name" : {
      "description" : "The machine's name, 1 to 100 characters.",
      "type" : "string"
    }
  },
  "required" : [
    "name",
    "imageID"
  ],
  "type" : "object"
}
```

### vm_start

- **Calls:** `MachineHost.resume` for a paused machine, else `MachineHost.start`.
- **Result:** `Started.`
- **Errors:** an unknown machine (`notFound`), one that runs (`conflict`), 2 already running (`conflict`), a start that fails (`unavailable`).

Description:

```text
Starts a stopped virtual machine, or resumes a paused one. At most 2 machines run at once.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    }
  },
  "required" : [
    "id"
  ],
  "type" : "object"
}
```

### vm_stop

- **Calls:** `MachineHost.stop`.
- **Result:** `Stopped.`
- **Errors:** a machine that doesn't run (`conflict`).

Description:

```text
Shuts a virtual machine down through its guest agent, waiting up to 60 seconds, or stops it at once without the agent. The machine keeps its disk.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    }
  },
  "required" : [
    "id"
  ],
  "type" : "object"
}
```

### vm_shell

- **Calls:** the agent's `exec` ([Guest agent › Methods](guest-agent.md#methods)).
- **Result:** `exitStatus`, `timedOut`, `stdout`, `stderr`, `truncated`.
- **Errors:** no running machine (`conflict`, `The virtual machine is not running.`), no agent connected (`unavailable`, `The guest agent is not connected.`), the agent's own message (`unavailable`).

Description:

```text
Runs a command in the guest with /bin/zsh -lc, in the account's home folder, as the account or as root. Returns exitStatus, timedOut, stdout, stderr and truncated (each output is cut at 1 MB).
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "asRoot" : {
      "description" : "Run it with sudo, as root.",
      "type" : "boolean"
    },
    "command" : {
      "description" : "The command.",
      "type" : "string"
    },
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    },
    "timeout" : {
      "description" : "Seconds before the command is killed; 60 by default.",
      "maximum" : 3600,
      "minimum" : 1,
      "type" : "integer"
    }
  },
  "required" : [
    "id",
    "command"
  ],
  "type" : "object"
}
```

### vm_screenshot

- **Calls:** the agent's `screenshot`.
- **Result:** an image content item, `image/png` ([Tool results](#tool-results)).
- **Errors:** no running machine (`conflict`, `The virtual machine is not running.`), no agent connected (`unavailable`, `The guest agent is not connected.`), the agent's own message (`unavailable`); no Screen Recording permission in the guest (`unavailable`, `The agent has no Screen Recording permission.`).

Description:

```text
Returns the guest's main display as a PNG image. Coordinates of vm_click, vm_drag and vm_scroll are pixels of this image, from its top-left corner.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    }
  },
  "required" : [
    "id"
  ],
  "type" : "object"
}
```

### vm_click

- **Calls:** the agent's `click`.
- **Result:** `{}`.
- **Errors:** no running machine (`conflict`, `The virtual machine is not running.`), no agent connected (`unavailable`, `The guest agent is not connected.`), the agent's own message (`unavailable`); no Accessibility permission in the guest.

Description:

```text
Clicks at a point of the guest's screen, in screenshot pixels.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "button" : {
      "description" : "The mouse button; left by default.",
      "enum" : [
        "left",
        "right"
      ],
      "type" : "string"
    },
    "count" : {
      "description" : "1 for a click, 2 for a double click, 3 for a triple click.",
      "maximum" : 3,
      "minimum" : 1,
      "type" : "integer"
    },
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    },
    "x" : {
      "description" : "Pixels from the left edge.",
      "minimum" : 0,
      "type" : "integer"
    },
    "y" : {
      "description" : "Pixels from the top edge.",
      "minimum" : 0,
      "type" : "integer"
    }
  },
  "required" : [
    "id",
    "x",
    "y"
  ],
  "type" : "object"
}
```

### vm_drag

- **Calls:** the agent's `drag`.
- **Result:** `{}`.
- **Errors:** no running machine (`conflict`, `The virtual machine is not running.`), no agent connected (`unavailable`, `The guest agent is not connected.`), the agent's own message (`unavailable`); no Accessibility permission in the guest.

Description:

```text
Drags with the left button from one point of the guest's screen to another, in screenshot pixels.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "fromX" : {
      "minimum" : 0,
      "type" : "integer"
    },
    "fromY" : {
      "minimum" : 0,
      "type" : "integer"
    },
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    },
    "toX" : {
      "minimum" : 0,
      "type" : "integer"
    },
    "toY" : {
      "minimum" : 0,
      "type" : "integer"
    }
  },
  "required" : [
    "id",
    "fromX",
    "fromY",
    "toX",
    "toY"
  ],
  "type" : "object"
}
```

### vm_scroll

- **Calls:** the agent's `scroll`.
- **Result:** `{}`.
- **Errors:** no running machine (`conflict`, `The virtual machine is not running.`), no agent connected (`unavailable`, `The guest agent is not connected.`), the agent's own message (`unavailable`); no Accessibility permission in the guest.

Description:

```text
Scrolls at a point of the guest's screen; positive deltas scroll down and right, in pixels.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "deltaX" : {
      "type" : "integer"
    },
    "deltaY" : {
      "type" : "integer"
    },
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    },
    "x" : {
      "minimum" : 0,
      "type" : "integer"
    },
    "y" : {
      "minimum" : 0,
      "type" : "integer"
    }
  },
  "required" : [
    "id",
    "x",
    "y"
  ],
  "type" : "object"
}
```

### vm_type

- **Calls:** the agent's `type`.
- **Result:** `{}`.
- **Errors:** no running machine (`conflict`, `The virtual machine is not running.`), no agent connected (`unavailable`, `The guest agent is not connected.`), the agent's own message (`unavailable`); no Accessibility permission in the guest.

Description:

```text
Types text where the guest's keyboard focus is, whatever its keyboard layout; a line break presses Return.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    },
    "text" : {
      "description" : "The text to type.",
      "type" : "string"
    }
  },
  "required" : [
    "id",
    "text"
  ],
  "type" : "object"
}
```

### vm_key

- **Calls:** the agent's `key`.
- **Result:** `{}`.
- **Errors:** no running machine (`conflict`, `The virtual machine is not running.`), no agent connected (`unavailable`, `The guest agent is not connected.`), the agent's own message (`unavailable`); an unknown key (`unavailable`, `Unknown key <key>.`).

Description:

```text
Presses a key with modifiers: a character of the guest's layout, or return, enter, tab, space, delete, forwardDelete, escape, left, right, up, down, home, end, pageUp, pageDown or f1 to f20.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    },
    "key" : {
      "description" : "The key.",
      "type" : "string"
    },
    "modifiers" : {
      "description" : "Held while the key is pressed.",
      "items" : {
        "enum" : [
          "control",
          "option",
          "shift",
          "command"
        ],
        "type" : "string"
      },
      "type" : "array"
    }
  },
  "required" : [
    "id",
    "key"
  ],
  "type" : "object"
}
```

### vm_ui_tree

- **Calls:** the agent's `uiTree`, with 120 seconds to answer.
- **Result:** `app`, `bundleID`, `pid`, `tree`.
- **Errors:** no running machine (`conflict`, `The virtual machine is not running.`), no agent connected (`unavailable`, `The guest agent is not connected.`), the agent's own message (`unavailable`); no such app (`unavailable`, `No running app named <app>.`).

Description:

```text
Returns the Accessibility tree of an app of the guest, the frontmost one by default: each element's role, title, value, identifier, enabled, focused and frame in screenshot pixels.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "app" : {
      "description" : "A bundle identifier or an app name.",
      "type" : "string"
    },
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    },
    "maxDepth" : {
      "description" : "Levels of the tree; 40 by default.",
      "maximum" : 200,
      "minimum" : 1,
      "type" : "integer"
    }
  },
  "required" : [
    "id"
  ],
  "type" : "object"
}
```

### vm_copy_in

- **Calls:** `MachineHost.copyIn`: a file through `writeFile`, 8 MiB at a time, with its permission bits; a folder's contents through a tar archive extracted in the guest.
- **Result:** `Copied.`
- **Errors:** a relative path (`invalid`); a missing source (`notFound`); no running machine (`conflict`, `The virtual machine is not running.`), no agent connected (`unavailable`, `The guest agent is not connected.`), the agent's own message (`unavailable`); tar failing (`internal`).

Description:

```text
Copies a file or a folder's contents of this Mac into the guest, as the guest's account.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "from" : {
      "description" : "An absolute path on this Mac.",
      "type" : "string"
    },
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    },
    "to" : {
      "description" : "An absolute path in the guest, or one starting with ~/.",
      "type" : "string"
    }
  },
  "required" : [
    "id",
    "from",
    "to"
  ],
  "type" : "object"
}
```

### vm_copy_out

- **Calls:** `MachineHost.copyOut`: a file through `readFile` into a partial file beside the destination, which then takes its place; a folder's contents through a tar archive.
- **Result:** `Copied.`
- **Errors:** a relative path (`invalid`); a missing source (`notFound`, `<path> does not exist in the guest.`); no running machine (`conflict`, `The virtual machine is not running.`), no agent connected (`unavailable`, `The guest agent is not connected.`), the agent's own message (`unavailable`); a destination that can't be written or tar failing (`internal`).

Description:

```text
Copies a file or a folder's contents of the guest to this Mac; a file replaces one of the same name.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "from" : {
      "description" : "An absolute path in the guest, or one starting with ~/.",
      "type" : "string"
    },
    "id" : {
      "description" : "A virtual machine's id, as vm_list gives it.",
      "type" : "string"
    },
    "to" : {
      "description" : "An absolute path on this Mac.",
      "type" : "string"
    }
  },
  "required" : [
    "id",
    "from",
    "to"
  ],
  "type" : "object"
}
```

### open_in_app

- **Calls:** a route: `project` opens the Projects window with the project selected (`.project(id)`),
  `projectSettings` its Project Settings window (`.projectSettings(id)`), `ticket` and `bundle` the Tickets
  window of its project with it selected (`.tool(.tickets, project:, focus: <id>)`); an open window comes
  forward. Each feature adds its own kinds as it comes over.
- **Result:** `{}`.
- **Errors:** an unknown project, ticket or bundle (`notFound`); no window has appeared yet to open routes
  (`unavailable`, `The app has no window to show it in.`).

Description:

```text
Opens an item in Hephaestus V3 for the user: a project in the Projects window, a project's settings window, or a ticket or bundle in its project's Tickets window.
```

Input schema:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "target" : {
      "additionalProperties" : false,
      "description" : "The item to open. project and projectSettings take projectID, ticket takes ticketID, bundle takes bundleID.",
      "properties" : {
        "bundleID" : {
          "description" : "Bundle id, such as ORD-B2.",
          "type" : "string"
        },
        "kind" : {
          "description" : "The item's kind.",
          "enum" : [
            "project",
            "projectSettings",
            "ticket",
            "bundle"
          ],
          "type" : "string"
        },
        "projectID" : {
          "description" : "Project identifier, 2 to 8 letters, such as ORD.",
          "type" : "string"
        },
        "ticketID" : {
          "description" : "Ticket id, such as ORD-12.",
          "type" : "string"
        }
      },
      "required" : [
        "kind"
      ],
      "type" : "object"
    }
  },
  "required" : [
    "target"
  ],
  "type" : "object"
}
```

## Checking it

With the app running, from Terminal (the token from Settings ▸ MCP):

```sh
curl -s -X POST http://127.0.0.1:47830/mcp -H "Authorization: Bearer <token>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

`ToolsScenesTests` check that this page lists exactly the registered tools, in their order, with their exact
descriptions and input schemas.
