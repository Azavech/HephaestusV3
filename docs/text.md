# Text: Markdown and syntax highlighting

`TextFormats` turns text into what the windows draw: Markdown into a block model, and code into highlight
tokens. It has no UI and no default isolation. The code and this page come from HephaestusV2
(`Sources/TextFormats`, `docs/documentation-viewer.md` and `docs/code-editor.md`), without what V3 leaves
out: the Markdown markers (SF Symbols, colors, sounds, shortcuts, fonts, animations) and the HTML output of
V2's documentation viewer. The sections below are V2's, kept as written so that the conformance tests read
their examples and word lists here; where they name V2's documentation viewer or code editor, V3 uses the same
rules for the descriptions and comments of tickets (and later the chats).

In V3, the Tickets window renders a description or a comment with `MarkdownBlockRenderer.render(_:options:)`,
`projectIdentifiers` set to the identifiers of the loaded projects, `projectRootPath` to the ticket's project folder and `softBreaksAsLineBreaks` on, and draws
the blocks with `MarkdownView` ([UI › Tickets](ui/tickets.md#markdown)). A ticket or bundle id becomes a link
that opens it in its Tickets window. Code blocks are highlighted with `SyntaxHighlighter`.

## Markdown renderer

The renderer lives in `TextFormats` (`Sources/TextFormats/Markdown/`). It parses with swift-markdown
(CommonMark plus the GFM table, strikethrough and task list extensions) with smart punctuation off, so quotes
and dashes stay as typed, and writes a block model ([Block model](#block-model)) that `MarkdownView` draws.

swift-markdown 0.9 does not attach the GFM autolink extension, so `TextFormats` finds extended URL autolinks
itself, in text outside links: `www.`, `http://` and `https://` followed by a valid domain, with the rules of
cmark-gfm's extension ported to Swift (the characters allowed before `www.`, the domain check, and the trailing
punctuation, unbalanced `)` and entity reference left out of the link). E-mail addresses are not detected and
stay text. Default chosen at design time.

```swift
public struct MarkdownRenderOptions: Sendable {
    /// Project path of the folder the text belongs to; "" for the project root.
    public var baseDirectory: String
    /// Absolute path of the project root; recognizes absolute paths and file URLs.
    public var projectRootPath: String?
    /// Removes a leading YAML front matter block before parsing.
    public var stripFrontMatter: Bool
    /// Identifiers of the projects loaded in the app; their ticket and bundle ids become links.
    public var projectIdentifiers: Set<String>
    /// Writes each soft line break as a hard line break.
    public var softBreaksAsLineBreaks: Bool

    public init(baseDirectory: String = "", projectRootPath: String? = nil, stripFrontMatter: Bool = false,
                projectIdentifiers: Set<String> = [], softBreaksAsLineBreaks: Bool = false)
}

public enum MarkdownBlockRenderer {
    public static func render(_ markdown: String, options: MarkdownRenderOptions) -> [MarkdownBlock]
}
```

| Caller | `baseDirectory` | `projectRootPath` | `stripFrontMatter` | `projectIdentifiers` | `softBreaksAsLineBreaks` |
| --- | --- | --- | --- | --- | --- |
| Ticket descriptions and comments ([UI › Tickets](ui/tickets.md#markdown)) | `""` | the project's folder | false | the identifiers of the loaded projects, sub projects included | true: people type lines, as V2's template headings, without blank lines between them |

The output depends only on the text and the options: the same input always gives the same blocks.

`softBreaksAsLineBreaks` is off by default. With it, every soft line break is read as a hard line break
(`.lineBreak`). It changes nothing else; heading anchors and alt texts still read every line break as a space.

### Front matter

With `stripFrontMatter`, when the first line of the text is exactly `---` and a later line is exactly `---` or `...`, every line up to and including that closing line is removed before parsing. Without a closing line nothing is removed. Default chosen at design time.

### Supported syntax

| Feature                                                                                                                                                                                                                                                                                                                | Rendering                                                                                                                                           |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| CommonMark blocks and inlines: paragraphs, ATX and setext headings, thematic breaks, block quotes, lists, indented and fenced code, link reference definitions, emphasis, strong emphasis, code spans, links, images, autolinks, hard and soft line breaks, backslash escapes, entity and numeric character references | Rendered.                                                                                                             |
| GFM tables                                                                                                                                                                                                                                                                                                             | Rendered ([Tables](#tables)).                                                                                                                       |
| GFM strikethrough, `~~text~~` and `~text~`                                                                                                                                                                                                                                                                             | Rendered.                                                                                                                                           |
| GFM task list items, `[ ]`, `[x]`, `[X]`                                                                                                                                                                                                                                                                               | Rendered as disabled checkboxes; clicking them changes nothing.                                                                                     |
| GFM extended autolinks: `http://…`, `https://…`, `www.…`, e-mail addresses                                                                                                                                                                                                                                             | URLs become links; e-mail addresses stay text.                                                                                                      |
| Ticket and bundle ids, such as `HEPH-12` and `HEPH-B2`                                                                                                                                                                                                                                                                 | Links when `projectIdentifiers` holds their identifier ([Ticket and bundle ids](#ticket-and-bundle-ids)); text otherwise.                           |
| Raw HTML: HTML blocks and inline HTML                                                                                                                                                                                                                                                                                  | Escaped and shown as text ([Sanitization](#sanitization)).                                                                                          |
| HTML comments                                                                                                                                                                                                                                                                                                          | Omitted.                                                                                                                                            |
| YAML front matter                                                                                                                                                                                                                                                                                                      | Omitted with `stripFrontMatter`, otherwise parsed as Markdown.                                                                                      |
| GFM footnotes, GitHub alerts (`> [!NOTE]`), math, emoji shortcodes, Mermaid diagrams, heading attributes, definition lists                                                                                                                                                                                             | Not supported: the source renders as ordinary Markdown (an alert as a block quote, `$x$` and `:smile:` as text, a `mermaid` block as a code block). |

swift-markdown also reads `^[text](attributes)` as inline attributes, which GFM does not have; the renderers write what GFM reads: the text `^` followed by a link to `attributes` with the content `text`, accepted or refused as [Links](#links) specifies.

The unsupported list, the omitted comments and the inline attributes rendering are design-time choices. Default chosen at design time.

### Heading anchors

Every heading gets an `id` computed like GitHub's, so links such as `engine-api.md#fileslist` work both on GitHub and in the app:

1. Take the heading's text: its text, code span contents and link texts, with emphasis removed and images and inline HTML left out (GitHub renders inline HTML as elements); line breaks become spaces.
2. Lowercase it (Unicode lowercase mapping).
3. Remove every character that is not a letter (Unicode categories L), a mark (M), a number (N), connector punctuation (Pc, which includes `_`), a space (U+0020) or a hyphen-minus (U+002D).
4. Replace each space with `-`.
5. When the result is empty, use `section`. When the document already has a heading with this id, append `-1`, or `-2`, and so on: the first suffix not used yet.

| Heading                                        | id               |
| ---------------------------------------------- | ---------------- |
| `# Web tabs`                                   | `web-tabs`       |
| `## files.list`                                | `fileslist`      |
| `## Swift 6 & Go`                              | `swift-6--go`    |
| `## C++ / Objective-C`                         | `c--objective-c` |
| `## Über uns`                                  | `über-uns`       |
| `## 🚀`                                        | `section`        |
| `### Examples` (second heading with this text) | `examples-1`     |

The `section` fallback is a design-time choice. Default chosen at design time.

### Code blocks

```html
<div class="md-codeblock">
<div class="md-codeblock-bar"><span class="md-codeblock-lang">swift</span><button type="button" class="md-copy">Copy</button></div>
<pre><code data-lang="swift"><span class="tok-keyword">let</span> answer = <span class="tok-number">42</span>
</code></pre>
</div>
```

- The language word is the info string of a fenced block up to its first space or `{`. The label (`md-codeblock-lang` and `data-lang`) is that word lowercased with every character other than `a`–`z`, `0`–`9`, `+`, `#`, `.`, `_` and `-` removed, at most 32 characters. Without a label (indented blocks, no info string, or a word that the filter leaves empty) the `<span class="md-codeblock-lang">` and the `data-lang` attribute are left out; the bar and its Copy button stay.
- The code is the block's content, with its final newline. It is highlighted by the TextFormats highlighter for the language of this table and written as escaped text in which each token is `<span class="tok-…">…</span>` with the class of its kind (Code editor); text outside tokens is escaped text. A block longer than 200,000 characters is not highlighted.

| Language word (lowercased)                  | Highlighter language  |
| ------------------------------------------- | --------------------- |
| `go`, `golang`                              | Go                    |
| `swift`                                     | Swift                 |
| `md`, `markdown`                            | Markdown              |
| `json`, `jsonc`, `jsonl`, `json5`           | JSON                  |
| `yaml`, `yml`                               | YAML                  |
| `sh`, `bash`, `zsh`, `shell`, `ksh`, `dash` | Shell                 |
| any other word, or none                     | plain: no token spans |

- The Copy button: the page's script sends `{"action":"copy","text":…}` with the `textContent` of the block's `code` element ([Preview web view](#preview-web-view)), and the button reads `Copied` for 1.5 seconds.

The bar, the 200,000-character limit and the language words are design-time choices. Default chosen at design time.

### Tables

- `<div class="md-table-wrap"><table>`, then `<thead>` with one `<tr>` of `<th>` cells, then `<tbody>` with one `<tr>` of `<td>` cells per body row, then `</table></div>`. `<tbody>` is left out when the table has no body row.
- A column aligned with `:---`, `:---:` or `---:` gives each of its cells the class `md-align-left`, `md-align-center` or `md-align-right`; an unaligned column has no class.
- A body row with fewer cells than the header gets empty cells; extra cells are dropped (GFM).
- `.md-table-wrap` scrolls horizontally when the table is wider than the page.

### Links

A link destination is the destination after the parser resolved reference links and backslash escapes. Its scheme is the text before the first `:` when that text matches `[A-Za-z][A-Za-z0-9+.-]*` and no `/`, `?` or `#` comes before the `:`.

| Destination                                                                                            | Accepted | `href`          |
| ------------------------------------------------------------------------------------------------------ | -------- | --------------- |
| empty                                                                                                  | no       | —               |
| starts with `#`                                                                                        | yes      | the destination |
| scheme `http` or `https` (any case)                                                                    | yes      | the destination |
| scheme `file`                                                                                          | yes      | the destination |
| starts with `//`                                                                                       | no       | —               |
| any other scheme: `mailto`, `tel`, `javascript`, `data`, `vbscript`, `hephaestus-file` and every other | no       | —               |
| no scheme: a relative or `/`-absolute path, with an optional `?query` and `#fragment`                  | yes      | the destination |

The renderer only filters; what a click does is decided when the link is activated ([Link activation](#link-activation)). Refusing `mailto` keeps the rule "other links do nothing" of every Markdown view. Default chosen at design time.

The links of ticket and bundle ids are not written by the text: the renderer makes them from the ids it finds ([Ticket and bundle ids](#ticket-and-bundle-ids)). A Markdown link whose destination has the scheme `hephaestus-id` is refused like every other scheme, so text cannot make an id link of its own.

### Images

| Source                                                                                       | `src`                                                                               |
| -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| scheme `http` or `https`                                                                     | the source, loaded from the network by the Mac that shows the page                  |
| no scheme, or scheme `file`, that [resolves](#path-resolution) to a project path P           | `hephaestus-file://project/` followed by P [percent-encoded](#resource-url-schemes) |
| anything else (`data:`, other schemes, `//…`, a path that does not resolve, an empty source) | refused: `<span class="md-image-blocked">`                                          |

Query and fragment of a project image are dropped. Loading remote images is a design-time choice. Default chosen at design time.

In a chat, Claude shows an image that lies outside the project folder, such as a file it rendered in `/tmp`, with the MCP tool `show_image`, which copies the image into the chat (Chats); a Markdown image to that file is refused, as the table says.


### Ticket and bundle ids

When the options have `projectIdentifiers`, the renderers turn the ticket and bundle ids of these projects into links. The callers that set it give the identifiers of every project of the device the window shows, sub projects included (Chats, Tickets); with an empty set, which the doc preview uses, no id is linked.

- An id has the ticket form `<IDENT>-<n>` or the bundle form `<IDENT>-B<n>` of Tickets › Identifiers: 2 to 8 letters `A`–`Z`, `-`, `B` for a bundle, and a number that starts with a digit other than `0`, all in uppercase. Its `<IDENT>` is in `projectIdentifiers`.
- It is a whole word: the character before it and the character after it, when there are any, are not letters, digits, `_` or `-`. `HEPH-21.`, `(HEPH-21)` and `HEPH-21,` link `HEPH-21`; `HEPH-21a`, `XHEPH-21`, `HEPH-21-3`, `HEPH-021` and `heph-21` link nothing. `UTF-8`, `SHA-256` and `ABC-3` link only when a project of the device has the identifier `UTF`, `SHA` or `ABC`. Default chosen at design time.
- Text: ids are found in text outside links, after the [extended URL autolinks](#renderer), so an id inside a link or an autolink keeps that link. Text split by the parser, for example around a backslash escape, is joined first.
- Code spans: a code span whose content is exactly an id becomes a link around the code span. A code span that holds an id among other text stays code.
- Ids are left as text in fenced and indented code blocks, HTML blocks, inline HTML, image alt texts and links. Heading anchors are computed from the text as written, so they do not change.

Block model: `.itemID("HEPH-21", code: false)` and `.itemID("HEPH-21", code: true)` ([Block model](#block-model)).

`MarkdownItemIDs` finds ids in plain text with the same rules, for the texts that callers show outside Markdown: tool card summaries and results, permission lines and the option lines and answers of the chat transcript, and the pinned permission card (Chats). `renderCodeBlock` links the ids of its code with the same rules; the code blocks of Markdown text never do. In highlighted code, the id is written without token spans, so that it has the style of a link, and a token span that crosses an end of the id is closed before the link and opened again after it, for example `<span class="tok-string">&quot;</span><a class="md-id" href="hephaestus-id:HEPH-21">HEPH-21</a><span class="tok-string">&quot;</span>` for the JSON string `"HEPH-21"`.

```swift
public enum MarkdownItemIDs {
    /// The plain text as `.text` and `.itemID` inlines.
    public static func inlines(in text: String, projectIdentifiers: Set<String>) -> [MarkdownInline]
    /// The `href` of an id link: `hephaestus-id:` followed by the id.
    public static func href(for id: String) -> String
    /// The id of an id link's `href`; nil for any other `href`.
    public static func id(fromHref href: String) -> String?
    /// Whether an id has the bundle form `<IDENT>-B<n>`.
    public static func isBundleID(_ id: String) -> Bool
    /// The ids that a Markdown text shows as links in the chat transcript, whatever their identifier.
    public static func linkedIDs(inMarkdown markdown: String) -> Set<String>
}
```

`linkedIDs(inMarkdown:)` renders the text to the block model with the transcript's rules and returns the ids of its `.itemID` inlines. It counts every identifier: an identifier is a run of 2 to 8 letters `A`–`Z` written before a `-`, a `\` or a `&`, so a text without such a run is not parsed. The engine uses it to find the ids that a chat mentions (Mentioned ids).

The class `md-id`, the scheme `hephaestus-id` and the word rule are Default chosen at design time. A click on an id link is handled by the view that shows it ([Link activation](#link-activation)).

### Path resolution

Images and links to project files resolve a reference R (without scheme, or a `file` URL) to a project path. Default chosen at design time.

1. Remove the fragment (from the first `#`, kept for links, percent-decoded) and the query (from the first `?`). When nothing remains (a reference made of a fragment or a query only), it resolves to nothing. Percent-decode what remains; invalid percent-encoding resolves to nothing.
2. A `file` URL: its host must be empty or `localhost` (`file:///…`, `file://localhost/…`), and its path must equal `projectRootPath` or start with `projectRootPath` followed by `/`; the rest, without its leading `/`, is the relative path. Otherwise nothing.
3. R starting with `/`: when it equals `projectRootPath` or starts with it followed by `/`, the rest is the relative path; otherwise R without its leading `/` is relative to the project root, as on GitHub.
4. Any other R is relative to `baseDirectory`: `baseDirectory/R`, or `R` when `baseDirectory` is `""`.
5. Split on `/`, drop empty and `.` components, and let each `..` remove the component before it; a `..` with nothing before it resolves to nothing. The remaining components joined with `/` are the project path (`""` is the project root).

With `baseDirectory` `docs` and `projectRootPath` `/Users/example/Developer/App`:

| Reference                                        | Project path                    |
| ------------------------------------------------ | ------------------------------- |
| `images/flow.png`                                | `docs/images/flow.png`          |
| `../README.md#install`                           | `README.md`, fragment `install` |
| `/Sources/App/main.swift`                        | `Sources/App/main.swift`        |
| `/Users/example/Developer/App/Package.swift`     | `Package.swift`                 |
| `file:///Users/example/Developer/App/docs/ui.md` | `docs/ui.md`                    |
| `my%20notes.md`                                  | `docs/my notes.md`              |
| `file:///etc/hosts`                              | nothing                         |
| `../../outside.md`                               | nothing                         |


### Block model

`MarkdownView` draws `MarkdownBlockRenderer`'s output. `CodeLanguage` and `HighlightToken` are the highlighter's types (Code editor).

```swift
public indirect enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, id: String, content: [MarkdownInline])
    case paragraph([MarkdownInline])
    case blockQuote([MarkdownBlock])
    case list(MarkdownList)
    case codeBlock(language: CodeLanguage, label: String?, code: String, tokens: [HighlightToken])
    case table(MarkdownTable)
    case thematicBreak
    case rawHTML(String)                 // the source, shown as plain text
}

public struct MarkdownList: Sendable, Equatable {
    public var ordered: Bool
    public var start: Int                // 1 for bullet lists
    public var tight: Bool
    public var items: [MarkdownListItem]
}

public struct MarkdownListItem: Sendable, Equatable {
    public var checkbox: Bool?           // nil: not a task item; true: checked
    public var blocks: [MarkdownBlock]
}

public struct MarkdownTable: Sendable, Equatable {
    public enum Alignment: String, Sendable { case left, center, right }
    public var alignments: [Alignment?]
    public var header: [[MarkdownInline]]
    public var rows: [[[MarkdownInline]]] // padded or cut to the header's cell count
}

public indirect enum MarkdownInline: Sendable, Equatable {
    case text(String)
    case code(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case link(destination: String, title: String?, content: [MarkdownInline]) // accepted destinations only
    case image(source: MarkdownImageSource, alt: String, title: String?)
    case itemID(String, code: Bool)      // a ticket or bundle id of a project of the device; code: written as a code span
    case softBreak
    case lineBreak
}

public enum MarkdownImageSource: Sendable, Equatable {
    case remote(String)                  // http or https URL
    case projectFile(String)             // project path, read with files.read
    case blocked
}
```

A refused link becomes its content; inline HTML becomes `.text` with its source; HTML comments are left out; e-mail autolinks are `.text`; a linked ticket or bundle id is `.itemID` ([Ticket and bundle ids](#ticket-and-bundle-ids)). Code block tokens are empty for plain code and for blocks longer than 200,000 characters.


## Resource URL schemes

Web views never read files directly: project files and attachments are loaded through two custom URL schemes whose handler asks the engine of the window's device. The same URL therefore works in a local window and in a window showing a remote device, where the bytes come from the main device through the sync connection.

| Scheme                  | URL                                                              | Engine call                                                 | Used by                                                         |
| ----------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------- | --------------------------------------------------------------- |
| `hephaestus-file`       | `hephaestus-file://project/<percent-encoded project path>`       | `files.read` with the web view's project and the path       | images of rendered Markdown (doc preview, chats, tickets)       |
| `hephaestus-attachment` | `hephaestus-attachment://attachment/<percent-encoded data path>` | `attachments.read` with the web view's project and the path | attachments in chats (Chats) |

- Percent-encoding: each path component is UTF-8 encoded and every byte outside `A`–`Z`, `a`–`z`, `0`–`9`, `-`, `.`, `_` and `~` is written as `%` and two uppercase hexadecimal digits; the components are joined with `/`. Example: `docs/my notes/flow chart.png` → `hephaestus-file://project/docs/my%20notes/flow%20chart.png`.
- The project is not part of the URL: every web view that shows rendered Markdown belongs to one project, and its handler knows it.


## Syntax highlighting

### Highlighter API

The highlighter is in TextFormats (`Sources/TextFormats/Highlighting/`, one tokenizer per language). It imports only Foundation, returns token kinds with their ranges, and is shared by the editor and the Markdown renderers (Documentation viewer).

```swift
public enum CodeLanguage: String, Sendable, Codable, CaseIterable {
    case go, swift, markdown, json, yaml, shell, plain
}

public enum TokenKind: String, Sendable, Codable, CaseIterable {
    case keyword, type, builtin, function, property, variable
    case string, escape, interpolation, number
    case comment, docComment, attribute, directive
    case heading, emphasis, strong, link, code
}

public struct HighlightToken: Sendable, Equatable {
    public var range: Range<Int>            // UTF-16 offsets, as NSString and NSTextView count
    public var kind: TokenKind
}

public enum SyntaxHighlighter {
    public static func language(forFileName name: String, firstLine: String?) -> CodeLanguage
    public static func tokens(in text: String, language: CodeLanguage) -> [HighlightToken]
}

public struct TokenStyle: Sendable, Equatable {
    public enum Weight: String, Sendable { case regular, semibold, bold }
    public var light: String                // "#RRGGBB"
    public var dark: String
    public var weight: Weight
    public var italic: Bool
}

extension TokenKind {
    public var style: TokenStyle { get }    // the table of Token kinds and colors
    public var cssClass: String { get }     // "tok-" + the kind in kebab case
}
```

- Tokens are sorted, never empty and never overlap. Text that no token covers is plain text.
- `tokens(in:language:)` is a pure function: the same text and language always give the same tokens. `.plain` gives no token.
- The tokenizers scan Unicode scalars from left to right; at each position the first rule of the language's rule table that matches is applied, and a position where no rule matches is plain text of one scalar.
- `MarkdownView` (TicketsKit) turns a `TokenStyle` into SwiftUI colors and fonts for code blocks; `cssClass` is kept from V2, which also wrote HTML.

### Language detection

`language(forFileName:firstLine:)` applies the first matching row; extensions are compared case-insensitively. Default chosen at design time.

| File                                                                                                                                                                | Language |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| ends in `.go`                                                                                                                                                       | go       |
| ends in `.swift`                                                                                                                                                    | swift    |
| ends in `.md`, `.markdown`, `.mdown` or `.mkd`                                                                                                                      | markdown |
| ends in `.json`, `.jsonc`, `.jsonl` or `.json5`                                                                                                                     | json     |
| ends in `.yml` or `.yaml`                                                                                                                                           | yaml     |
| ends in `.sh`, `.bash`, `.zsh`, `.ksh` or `.command`, or is named `.bashrc`, `.bash_profile`, `.profile`, `.zshrc`, `.zprofile` or `.zshenv`                        | shell    |
| the first line starts with `#!` and names the interpreter `sh`, `bash`, `zsh`, `ksh` or `dash` (the last path component of the first word, or the word after `env`) | shell    |
| the first line starts with `#!` and names the interpreter `swift`                                                                                                   | swift    |
| any other file                                                                                                                                                      | plain    |

An OpenAPI contract keeps the language `yaml` or `json` and its highlighting in Source; whether its tab shows the Contract view is decided from its text (OpenAPI contracts › Detection).

### Token kinds and colors

One table for the editor, the chat transcript and the doc preview (Brief §9.3, §9.4). CSS classes are used in rendered HTML; `semibold` is CSS weight 600, `bold` 700. Default chosen at design time.

| Kind            | CSS class           | Light     | Dark      | Font     | Used for                                                              |
| --------------- | ------------------- | --------- | --------- | -------- | --------------------------------------------------------------------- |
| `keyword`       | `tok-keyword`       | `#9B2393` | `#FF7AB2` | semibold | keywords, literal keywords, Markdown and YAML markers                 |
| `type`          | `tok-type`          | `#3900A0` | `#DABAFF` | regular  | type names                                                            |
| `builtin`       | `tok-builtin`       | `#6C36A9` | `#B281EB` | regular  | predeclared functions and constants, shell builtins                   |
| `function`      | `tok-function`      | `#326D74` | `#67B7A4` | regular  | declared and called functions                                         |
| `property`      | `tok-property`      | `#0B4F79` | `#6BDFFF` | regular  | JSON and YAML keys                                                    |
| `variable`      | `tok-variable`      | `#0F68A0` | `#4EB0CC` | regular  | shell variables                                                       |
| `string`        | `tok-string`        | `#C41A16` | `#FF8170` | regular  | strings, runes, raw strings, regex literals                           |
| `escape`        | `tok-escape`        | `#A3410B` | `#FFB38A` | regular  | escape sequences inside strings                                       |
| `interpolation` | `tok-interpolation` | `#9B2393` | `#FF7AB2` | regular  | interpolation and command substitution delimiters                     |
| `number`        | `tok-number`        | `#1C00CF` | `#D9C97C` | regular  | numbers                                                               |
| `comment`       | `tok-comment`       | `#5D6C79` | `#7F8C98` | regular  | comments                                                              |
| `docComment`    | `tok-doc-comment`   | `#5D6C79` | `#7F8C98` | italic   | Swift documentation comments                                          |
| `attribute`     | `tok-attribute`     | `#815F03` | `#CC9768` | regular  | Swift attributes, YAML anchors, aliases and tags                      |
| `directive`     | `tok-directive`     | `#643820` | `#FFA14F` | regular  | Go directives, Swift `#` directives and macros, YAML document markers |
| `heading`       | `tok-heading`       | `#0B4F79` | `#6BDFFF` | bold     | Markdown headings                                                     |
| `emphasis`      | `tok-emphasis`      | `#1F1F24` | `#DFDFE0` | italic   | Markdown emphasis                                                     |
| `strong`        | `tok-strong`        | `#1F1F24` | `#DFDFE0` | bold     | Markdown strong emphasis                                              |
| `link`          | `tok-link`          | `#0E0EFF` | `#5482FF` | regular  | Markdown links and autolinks                                          |
| `code`          | `tok-code`          | `#1C00CF` | `#D9C97C` | regular  | Markdown code spans and code blocks                                   |

In the editor the font is SF Mono 13 with the table's weight (`.regular`, `.semibold`, `.bold`) and the italic trait where marked.

### Common definitions

| Term            | Definition                                                                                                                  |
| --------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Line terminator | `\n`, `\r\n` or `\r`. A token that runs "to the end of the line" stops before the terminator.                               |
| Blank           | Space (U+0020) and tab (U+0009).                                                                                            |
| Letter          | A scalar of Unicode general category L (Lu, Ll, Lt, Lm, Lo).                                                                |
| Identifier      | A letter or `_`, followed by any number of letters, `_`, decimal digits (Nd) and, in Swift, marks (Mn, Mc).                 |
| Previous token  | The nearest token or identifier before the current position, skipping blanks, line terminators and comments.                |
| Unterminated    | A construct whose closing delimiter is missing ends where its rule says (end of line or end of text); it is never an error. |

Inside strings, escapes are their own `escape` tokens and interpolation delimiters their own `interpolation` tokens; the remaining parts of the string are `string` tokens. Example: `"a\nb"` gives `string` `"a`, `escape` `\n`, `string` `b"`.

## Go

The Go rules follow the Go specification (go.dev/ref/spec) for lexical elements.

### Go rules

| Order | Rule                      | Match                                                                                                               | Kind                                                                 |
| ----- | ------------------------- | ------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| 1     | Line comment or directive | `//` to the end of the line                                                                                         | `directive` when it is a [directive](#go-directives), else `comment` |
| 2     | Block comment             | `/*` to the first `*/` included, across lines; not nested; unterminated: to the end of the text                     | `directive` when it starts with `/*line `, else `comment`            |
| 3     | Interpreted string        | `"` to the next `"` not consumed by an escape; unterminated: to the end of the line                                 | `string` with `escape` parts                                         |
| 4     | Raw string                | a backquote (U+0060) to the next backquote included, across lines, no escapes; unterminated: to the end of the text | `string`                                                             |
| 5     | Rune                      | `'` to the next `'` not consumed by an escape; unterminated: to the end of the line                                 | `string` with `escape` parts                                         |
| 6     | Number                    | at a digit, or at `.` followed by a digit: [Go numbers](#go-numbers)                                                | `number`                                                             |
| 7     | Identifier                | an identifier                                                                                                       | [Go identifiers](#go-identifiers)                                    |
| 8     | Anything else             | one scalar (operators, punctuation, blanks)                                                                         | plain                                                                |

### Go directives

A line comment is a directive when its text, from the `//`, starts with `//go:` followed by a lowercase letter `a`–`z` (`//go:build`, `//go:generate`, `//go:embed`, `//go:noinline`, `//go:linkname`), with `//line `, `//export ` or `//extern `, or is `// +build` followed by a blank or the end of the line. The whole comment is one `directive` token.

### Go escapes

In interpreted strings and runes, a backslash starts an escape:

| Form                                                               | Escape token                                                                                |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `\` followed by `a`, `b`, `f`, `n`, `r`, `t`, `v`, `\`, `'` or `"` | 2 scalars                                                                                   |
| `\x` followed by exactly 2 hexadecimal digits                      | 4 scalars                                                                                   |
| `\u` followed by exactly 4 hexadecimal digits                      | 6 scalars                                                                                   |
| `\U` followed by exactly 8 hexadecimal digits                      | 10 scalars                                                                                  |
| `\` followed by exactly 3 octal digits `0`–`7`                     | 4 scalars                                                                                   |
| `\` followed by any other scalar, or an incomplete form            | no escape token: the backslash and the next scalar stay `string` and cannot end the literal |

### Go numbers

At the start position the first of these patterns that matches is taken, as long as possible (`_` is accepted anywhere after the first digit, which over-accepts some invalid literals on purpose). The bar in row 4 is the alternation of the regular expression:

| Order | Pattern (regular expression)                                      | Examples                                                                  |
| ----- | ----------------------------------------------------------------- | ------------------------------------------------------------------------- |
| 1     | `0[xX][0-9a-fA-F_]*(\.[0-9a-fA-F_]*)?([pP][+-]?[0-9_]+)?i?`       | `0x1F`, `0X_ff`, `0x1.8p-3`, `0x1p4i`                                     |
| 2     | `0[bB][01_]+i?`                                                   | `0b1010`, `0B_1_0`                                                        |
| 3     | `0[oO][0-7_]+i?`                                                  | `0o755`, `0O_17`                                                          |
| 4     | `([0-9][0-9_]*(\.[0-9_]*)?\|\.[0-9][0-9_]*)([eE][+-]?[0-9_]+)?i?` | `42`, `0755`, `1_000_000`, `3.`, `.5`, `6.02e23`, `1E-9`, `2i`, `3.5e-2i` |

The `-` or `+` before a number is an operator, never part of the token.

### Go identifiers

| Order | Condition                                                                | Kind       |
| ----- | ------------------------------------------------------------------------ | ---------- |
| 1     | one of the 25 keywords                                                   | `keyword`  |
| 2     | one of the predeclared types                                             | `type`     |
| 3     | one of the predeclared constants, `nil`, or one of the builtin functions | `builtin`  |
| 4     | the previous token is the keyword `func`                                 | `function` |
| 5     | the previous token is the keyword `type`                                 | `type`     |
| 6     | directly followed by `(` (no blank between)                              | `function` |
| 7     | anything else                                                            | plain      |

| Group                 | Words                                                                                                                                                                                                                               |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keywords              | `break`, `case`, `chan`, `const`, `continue`, `default`, `defer`, `else`, `fallthrough`, `for`, `func`, `go`, `goto`, `if`, `import`, `interface`, `map`, `package`, `range`, `return`, `select`, `struct`, `switch`, `type`, `var` |
| Predeclared types     | `any`, `bool`, `byte`, `comparable`, `complex64`, `complex128`, `error`, `float32`, `float64`, `int`, `int8`, `int16`, `int32`, `int64`, `rune`, `string`, `uint`, `uint8`, `uint16`, `uint32`, `uint64`, `uintptr`                 |
| Predeclared constants | `true`, `false`, `iota`, and the zero value `nil`                                                                                                                                                                                   |
| Builtin functions     | `append`, `cap`, `clear`, `close`, `complex`, `copy`, `delete`, `imag`, `len`, `make`, `max`, `min`, `new`, `panic`, `print`, `println`, `real`, `recover`                                                                          |

Predeclared names are highlighted even where a program shadows them. Default chosen at design time.

### Go example

```go
//go:build darwin
package main

import "fmt"

// Answer is documented.
func Answer[T any](v T) (int, error) {
	s := `raw\n`
	r := '\''
	fmt.Println(len(s), 0x1F, 1_000, 3.5e-2i, r)
	return 42, nil
}
```

gives these tokens, one per line as kind, a tab and the token text as a JSON string (the format of the highlighter fixtures, [Conformance](#conformance)):

```text
directive	"//go:build darwin"
keyword	"package"
keyword	"import"
string	"\"fmt\""
comment	"// Answer is documented."
keyword	"func"
function	"Answer"
type	"any"
type	"int"
type	"error"
string	"`raw\\n`"
string	"'"
escape	"\\'"
string	"'"
function	"Println"
builtin	"len"
number	"0x1F"
number	"1_000"
number	"3.5e-2i"
keyword	"return"
number	"42"
builtin	"nil"
```

## Swift

The Swift rules follow the lexical structure of The Swift Programming Language (Swift 6).

### Swift rules

| Order | Rule                           | Match                                                                                                                                                       | Kind                                    |
| ----- | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 1     | Shebang                        | `#!` at the very start of the text, to the end of the line                                                                                                  | `comment`                               |
| 2     | Documentation line comment     | `///` not followed by `/`, to the end of the line                                                                                                           | `docComment`                            |
| 3     | Line comment                   | `//` to the end of the line                                                                                                                                 | `comment`                               |
| 4     | Documentation block comment    | `/**` not followed by `*` or `/`, nested as in rule 5                                                                                                       | `docComment`                            |
| 5     | Block comment                  | `/*` to its matching `*/`, across lines; comments nest: each `/*` inside opens a level and each `*/` closes one; unterminated: to the end of the text       | `comment`                               |
| 6     | String literal                 | zero or more `#`, then `"""` or `"`: [Swift strings](#swift-strings)                                                                                        | `string`, `escape`, `interpolation`     |
| 7     | Extended regex literal         | one or more `#`, then `/`: [Swift regex literals](#swift-regex-literals)                                                                                    | `string`                                |
| 8     | Directive or macro             | `#` followed by an identifier: the `#` and the identifier; for `#if` and `#elseif` the token continues to the end of the line, stopping before `//` or `/*` | `directive`                             |
| 9     | Attribute                      | `@` followed by an identifier: the `@` and the identifier (`@MainActor`, `@available`, `@objc`)                                                             | `attribute`                             |
| 10    | Escaped identifier             | a backquote, one or more scalars other than backquotes and line terminators, a backquote                                                                    | plain                                   |
| 11    | Implicit parameter, projection | `$` followed by decimal digits, or by an identifier                                                                                                         | plain                                   |
| 12    | Number                         | at a digit: [Swift numbers](#swift-numbers)                                                                                                                 | `number`                                |
| 13    | Identifier                     | an identifier                                                                                                                                               | [Swift identifiers](#swift-identifiers) |
| 14    | Anything else                  | one scalar (operators, punctuation, blanks)                                                                                                                 | plain                                   |

### Swift strings

Let n be the number of `#` before the opening quote (0 for an ordinary string, 1 or more for a string with extended delimiters).

| Element            | Rule                                                                                                                                                                                                                                                                                                                        |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Single-line string | Opens with `"` that is not the start of `"""`. Ends with the first `"` that is followed by n `#` and is not part of an escape; the quote and the `#` belong to the token. A line terminator first ends it unterminated, also inside an interpolation.                                                                       |
| Multi-line string  | Opens with `"""`. Ends with the first `"""` followed by n `#`, across lines. Unterminated: to the end of the text.                                                                                                                                                                                                          |
| Escape introducer  | `\` followed by n `#`. With n = 0, the backslash alone.                                                                                                                                                                                                                                                                     |
| Escapes            | The introducer followed by `0`, `\`, `t`, `n`, `r`, `"` or `'`; the introducer followed by `u{`, 1 to 8 hexadecimal digits and `}`; in a multi-line string, the introducer followed by blanks and a line terminator (line continuation: the token covers the introducer and the blanks).                                    |
| Other backslashes  | The introducer followed by any other scalar, and a backslash not followed by n `#`, are string text and never end the literal.                                                                                                                                                                                              |
| Interpolation      | The introducer followed by `(` is an `interpolation` token. Swift code follows, tokenized with all Swift rules (strings, comments and interpolations nest), while the `(` and `)` that are plain punctuation are counted; the `)` that brings the count back to zero is an `interpolation` token, and the string continues. |

### Swift regex literals

An extended regex literal starts with n `#` (n ≥ 1) and `/`. When the `/` is directly followed by a line terminator, the literal spans lines and ends with the first `/` followed by n `#`; unterminated, it runs to the end of the text. Otherwise it ends with the first `/` followed by n `#` on the same line; unterminated, it runs to the end of the line. The whole literal is one `string` token. Bare `/…/` regex literals are not recognized, because telling them from division needs a parser; they appear as operators and text. Default chosen at design time.

### Swift numbers

| Order | Pattern (regular expression)                                                      | Examples                                 |
| ----- | --------------------------------------------------------------------------------- | ---------------------------------------- |
| 1     | `0x[0-9a-fA-F][0-9a-fA-F_]*(\.[0-9a-fA-F][0-9a-fA-F_]*)?([pP][+-]?[0-9][0-9_]*)?` | `0xFF`, `0x1F`, `0x1p-2`, `0xC.3p0`      |
| 2     | `0o[0-7][0-7_]*`                                                                  | `0o755`                                  |
| 3     | `0b[01][01_]*`                                                                    | `0b1010_0101`                            |
| 4     | `[0-9][0-9_]*(\.[0-9][0-9_]*)?([eE][+-]?[0-9][0-9_]*)?`                           | `42`, `1_000`, `3.14`, `6.02e23`, `1e-9` |

A fraction needs a digit after the dot, so `0..<5` and `1...3` give the numbers `0`, `5`, `1` and `3`. Prefixes are lowercase, as in Swift. The sign before a number is an operator.

### Swift identifiers

| Order | Condition                                                                                                                                                                                                 | Kind       |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| 1     | Directly preceded by `.` (member access): `self`, `init`, `Type` and `Protocol` are `keyword`; any other word skips rows 2 to 5 (`.default`, `.open(url)`, `.async`)                                      | see text   |
| 2     | The previous token is the keyword `func`                                                                                                                                                                  | `function` |
| 3     | Argument label: the previous token is `(` or `,`, the word is in the label list, and it is directly followed by `:`, or by blanks, an identifier and `:` (`contains(where:)`, `func f(for name: String)`) | plain      |
| 4     | A keyword                                                                                                                                                                                                 | `keyword`  |
| 5     | A contextual keyword whose next scalar, after blanks on the same line, is in its follower set                                                                                                             | `keyword`  |
| 6     | Starts with an uppercase letter (Lu or Lt)                                                                                                                                                                | `type`     |
| 7     | Directly followed by `(`                                                                                                                                                                                  | `function` |
| 8     | Anything else                                                                                                                                                                                             | plain      |

| Group                                                       | Words                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keywords                                                    | `associatedtype`, `class`, `deinit`, `enum`, `extension`, `fileprivate`, `func`, `import`, `init`, `inout`, `internal`, `let`, `operator`, `precedencegroup`, `private`, `protocol`, `public`, `rethrows`, `static`, `struct`, `subscript`, `typealias`, `var`, `break`, `case`, `catch`, `continue`, `default`, `defer`, `do`, `else`, `fallthrough`, `for`, `guard`, `if`, `in`, `repeat`, `return`, `switch`, `throw`, `where`, `while`, `Any`, `as`, `async`, `await`, `false`, `is`, `nil`, `self`, `Self`, `super`, `throws`, `true`, `try`, `some`, `any`, and `_` alone |
| Label list (row 3)                                          | The keywords except `let`, `var`, `case`, `inout`, `true`, `false`, `nil`, `self`, `Self`, `super`, `try`, `await`, `some`, `any` and `_`                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Contextual, followed by an identifier, `@` or `{`           | `actor`, `borrowing`, `consume`, `consuming`, `convenience`, `copy`, `discard`, `distributed`, `dynamic`, `each`, `final`, `indirect`, `infix`, `isolated`, `lazy`, `macro`, `mutating`, `nonmutating`, `open`, `optional`, `override`, `package`, `postfix`, `prefix`, `required`, `sending`, `unsafe`, `weak`                                                                                                                                                                                                                                                                 |
| Contextual, followed by an identifier, `@`, `{` or `(`      | `nonisolated`, `unowned`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Contextual, followed by an identifier, `{`, `}` or `(`      | `get`, `willSet`, `didSet`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Contextual, followed by an identifier, `{`, `}`, `(` or `)` | `set` (also inside `private(set)`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |

"Followed by an identifier" means that the next scalar is a letter or `_`, so it also covers a following keyword. Examples: `actor Engine {` is a keyword but `actor: Actor` and `let actor = x` are not; `let package = Package(` is not; `{ get set }` gives two keywords. The contextual rules and the label rule are design-time choices that approximate the Swift grammar without a parser. Default chosen at design time.

### Swift example

```swift
#!/usr/bin/swift
import Foundation

/// Greets someone.
@MainActor final class Greeter: Sendable {
    nonisolated(unsafe) var count = 0x1F
    func greet(for name: String) async throws -> String {
        let text = #"Hello \#(name) "\(raw)""#
        /* outer /* inner */ still comment */
        return "Count: \(count + 1)\n"
    }
}
```

gives:

```text
comment	"#!/usr/bin/swift"
keyword	"import"
type	"Foundation"
docComment	"/// Greets someone."
attribute	"@MainActor"
keyword	"final"
keyword	"class"
type	"Greeter"
type	"Sendable"
keyword	"nonisolated"
keyword	"var"
number	"0x1F"
keyword	"func"
function	"greet"
type	"String"
keyword	"async"
keyword	"throws"
type	"String"
keyword	"let"
string	"#\"Hello "
interpolation	"\\#("
interpolation	")"
string	" \"\\(raw)\"\"#"
comment	"/* outer /* inner */ still comment */"
keyword	"return"
string	"\"Count: "
interpolation	"\\("
number	"1"
interpolation	")"
escape	"\\n"
string	"\""
```

`unsafe` inside `nonisolated(unsafe)` is plain (followed by `)`), `for` is an argument label, `name`, `text`, `raw` and `count` are plain identifiers, and `\(raw)` is text because the string has one `#`.

## Basic languages

Markdown, JSON, YAML and Shell get the basic rules below (Brief §9.4); plain files get no token. Default chosen at design time.

### Markdown

Line rules are checked at the start of each line, in order; the rest of a line that no line rule consumed gets the inline rules.

| Order | Line rule                 | Match                                                                                                                                                                                                                                                                            | Kind      |
| ----- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| 1     | Front matter              | The text starts with a line `---`: that line through the next line that is `---` or `...`; without a closing line, no front matter                                                                                                                                               | `comment` |
| 2     | Fenced code block         | A line with at most 3 spaces of indentation and a fence of 3 or more backquotes or of 3 or more `~`, through the closing fence line (same character, at least as long, at most 3 spaces of indentation, then only blanks), fences included; unterminated: to the end of the text | `code`    |
| 3     | HTML comment              | `<!--` to the next `-->`, across lines; unterminated: to the end of the text                                                                                                                                                                                                     | `comment` |
| 4     | ATX heading               | At most 3 spaces, 1 to 6 `#`, then a blank or the end of the line: the whole line                                                                                                                                                                                                | `heading` |
| 5     | Thematic break            | A line made of 3 or more of the same character `-`, `*` or `_`, with optional blanks between: the whole line                                                                                                                                                                     | `keyword` |
| 6     | Block quote markers       | At most 3 spaces and `>`, repeated (`> >`): each `>`                                                                                                                                                                                                                             | `keyword` |
| 7     | List marker               | After any indentation and quote markers: `-`, `*`, `+`, or 1 to 9 digits and `.` or `)`, followed by a blank: the marker; then a task box `[ ]`, `[x]` or `[X]` followed by a blank: the box                                                                                     | `keyword` |
| 8     | Link reference definition | At most 3 spaces, `[label]:` and a destination: the whole line                                                                                                                                                                                                                   | `link`    |

| Order | Inline rule | Match                                                                                                                                           | Kind       |
| ----- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| 1     | Code span   | A run of n backquotes to the next run of exactly n backquotes on the same line                                                                  | `code`     |
| 2     | Link, image | An optional `!`, `[`, text without `]`, `](`, a destination without `)`, `)`; or `[text][label]`; on one line                                   | `link`     |
| 3     | Autolink    | `<`, a scheme, `:`, non-blank scalars, `>`; or `http://` or `https://` followed by non-blank scalars, without a final `.`, `,`, `:`, `;` or `)` | `link`     |
| 4     | Strong      | `**text**` or `__text__` on one line, the text not empty and not starting or ending with a blank                                                | `strong`   |
| 5     | Emphasis    | `*text*` or `_text_` with the same conditions; an `_` between two letters or digits neither opens nor closes                                    | `emphasis` |

Each delimiter of rules 4 and 5 is a whole run of `*` or `_`: strong opens and closes with a run of exactly two, emphasis with a run of exactly one, and a run of three or more neither opens nor closes (`**a*b**` is one strong token).

### JSON

| Order | Rule    | Match                                                                                                                                                               | Kind                                                                                                                                            |
| ----- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | Comment | `//` to the end of the line; `/*` to the next `*/`, across lines, unterminated: to the end of the text (both accepted for JSONC files)                              | `comment`                                                                                                                                       |
| 2     | String  | `"` to the next `"` not consumed by an escape (`\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, `\u` and 4 hexadecimal digits); unterminated: to the end of the line | `property` for the whole string when the next scalar after blanks, line terminators and comments is `:`; otherwise `string` with `escape` parts |
| 3     | Number  | `-?(0\|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`                                                                                                                   | `number`                                                                                                                                        |
| 4     | Literal | `true`, `false`, `null` as whole words                                                                                                                              | `keyword`                                                                                                                                       |
| 5     | Other   | one scalar                                                                                                                                                          | plain                                                                                                                                           |

### YAML

| Order | Rule                 | Match                                                                                                                                                                                                           | Kind        |
| ----- | -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| 1     | Comment              | `#` at the start of a line or after a blank, outside quoted scalars, to the end of the line                                                                                                                     | `comment`   |
| 2     | Directive            | A line starting with `%`                                                                                                                                                                                        | `directive` |
| 3     | Document marker      | `---` or `...` at the start of a line, followed by a blank or the end of the line: the marker                                                                                                                   | `directive` |
| 4     | Block scalar content | The lines after a line whose value is a block indicator (row 9), as long as they are blank or more indented than that line: each line without its indentation                                                   | `string`    |
| 5     | Sequence marker      | `-` followed by a blank or the end of the line, at the start of a line after indentation or after another sequence marker                                                                                       | `keyword`   |
| 6     | Key                  | After indentation and sequence markers, a plain scalar that contains no `: ` and no ` #`, or a quoted scalar, followed by `:` and a blank or the end of the line: the scalar (the `:` is plain)                 | `property`  |
| 7     | Quoted scalar        | `'…'` (two quotes `''` inside stand for one) or `"…"` (backslash escapes are `escape` parts), on one line; unterminated: to the end of the line                                                                 | `string`    |
| 8     | Anchor, alias, tag   | `&` or `*` followed by a name, or `!` followed by non-blank scalars                                                                                                                                             | `attribute` |
| 9     | Block indicator      | `\|` or `>`, with an optional `+` or `-` and an optional digit, as a value followed only by blanks or a comment                                                                                                 | `keyword`   |
| 10    | Literal value        | A whole plain scalar value (after `: `, after `- `, between flow delimiters `[`, `]`, `{`, `}`, `,`, or a whole line) equal to `true`, `false`, `True`, `False`, `TRUE`, `FALSE`, `null`, `Null`, `NULL` or `~` | `keyword`   |
| 11    | Number value         | A whole plain scalar value matching one of the YAML number patterns below                                                                                                                                       | `number`    |
| 12    | Other                | one scalar                                                                                                                                                                                                      | plain       |

Rules 7 and 8 apply only where a scalar starts: at the start of a value, after a `:` value indicator, after `,`, `[` or `{` in a flow collection, and after an anchor or a tag. Inside a plain scalar `'`, `"`, `&`, `*` and `!` stay plain (`don't`, `a*b`, `hi!`).

In a double-quoted scalar a backslash starts an escape (YAML 1.2): `\x`, `\u` and `\U` followed by 2, 4 and 8 hexadecimal digits give an escape of 4, 6 and 10 scalars; any other backslash, an incomplete form included, gives an escape of 2 scalars (the backslash and the next scalar).

YAML number patterns (regular expressions): `[-+]?(0|[1-9][0-9_]*)(\.[0-9_]*)?([eE][-+]?[0-9]+)?`, `[-+]?\.[0-9]+([eE][-+]?[0-9]+)?`, `0x[0-9a-fA-F_]+`, `0o[0-7_]+`, `0b[01_]+`, `[-+]?\.(inf|Inf|INF)`, `\.(nan|NaN|NAN)`.

### Shell

| Order | Rule                   | Match                                                                                                                                                                                                                             | Kind                                                         |
| ----- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| 1     | Shebang                | `#!` at the very start of the text, to the end of the line                                                                                                                                                                        | `comment`                                                    |
| 2     | Comment                | `#` at the start of a word (start of a line, or after a blank, `;`, `&`, `\|` or `(`), to the end of the line                                                                                                                     | `comment`                                                    |
| 3     | Single-quoted string   | `'` to the next `'`, across lines, no escapes; unterminated: to the end of the text                                                                                                                                               | `string`                                                     |
| 4     | ANSI-C string          | `$'` to the next `'` not consumed by an escape; a backslash and the scalar after it are an escape; unterminated: to the end of the text                                                                                           | `string` with `escape` parts                                 |
| 5     | Double-quoted string   | `"` to the next `"` not consumed by an escape, across lines; unterminated: to the end of the text. Inside: a backslash followed by `$`, a backquote, `"`, a backslash or a line terminator is an escape; rows 6 to 8 apply        | `string` with `escape`, `variable` and `interpolation` parts |
| 6     | Variable               | `$` followed by a name (a letter or `_`, then letters, digits and `_`); `$` followed by one of `0`–`9`, `#`, `?`, `*`, `@`, `$`, `!`, `-`; `${` to the matching `}` (nested braces counted; unterminated: to the end of the text) | `variable`                                                   |
| 7     | Substitution           | `$((` or `$(` to the matching `))` or `)`, counting nested parentheses (a single `)` that brings the count back to zero also closes `$((`): the delimiters are `interpolation` tokens and the content follows the Shell rules     | `interpolation` delimiters                                   |
| 8     | Backquote substitution | A backquote to the next backquote not preceded by a backslash: the whole construct; unterminated: to the end of the text                                                                                                          | `interpolation`                                              |
| 9     | Assignment             | A word that starts with a name directly followed by `=`: the name                                                                                                                                                                 | `variable`                                                   |
| 10    | Word                   | A run of scalars other than blanks, line terminators, `;`, `&`, `\|`, `(`, `)`, `<`, `>`, quotes, backquotes and `$`: a keyword is `keyword`, a builtin `builtin`, digits only `number`, anything else plain                      | `keyword`, `builtin`, `number`                               |
| 11    | Other                  | one scalar                                                                                                                                                                                                                        | plain                                                        |

| Group    | Words                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keywords | `if`, `then`, `else`, `elif`, `fi`, `case`, `esac`, `for`, `select`, `while`, `until`, `do`, `done`, `in`, `function`, `time`, `coproc`, `[[`, `]]`                                                                                                                                                                                                                                                                                                                                                                                    |
| Builtins | `alias`, `bg`, `bind`, `break`, `builtin`, `caller`, `cd`, `command`, `compgen`, `complete`, `continue`, `declare`, `dirs`, `disown`, `echo`, `enable`, `eval`, `exec`, `exit`, `export`, `false`, `fc`, `fg`, `getopts`, `hash`, `help`, `history`, `jobs`, `kill`, `let`, `local`, `logout`, `mapfile`, `popd`, `printf`, `pushd`, `pwd`, `read`, `readarray`, `readonly`, `return`, `set`, `shift`, `shopt`, `source`, `suspend`, `test`, `times`, `trap`, `true`, `type`, `typeset`, `ulimit`, `umask`, `unalias`, `unset`, `wait` |

Here-document bodies follow the ordinary rules.

## Conformance

- Highlighter fixtures: `Tests/TextFormatsTests/Fixtures/highlight/<name>.<extension>` with the expected tokens in `<name>.<extension>.tokens`, one line per token: the kind, a tab, the token text as a JSON string. The Go and Swift examples of this document are the fixtures `go-example.go` and `swift-example.swift`; further fixtures cover every row of the rule tables of every language.
- A docs conformance test in TextFormatsTests reads the table of [Token kinds and colors](#token-kinds-and-colors) in this document and compares it with `TokenKind.allCases`, `TokenKind.style` and `TokenKind.cssClass`.
- The keyword, type, builtin and contextual word lists of this document are compared with the tokenizers' lists.

These tests are design-time additions to the conformance tests of CI. Default chosen at design time.

