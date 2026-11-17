# System Prompts

System Prompts is where the user writes what the app's own Claude skills say (the user's request, 17 November
2026). The app's code defines these **internal skills**, each with a name; the user edits their content, and
the model and effort the app runs each with when no chat calls it. The list holds the internal skills only: not
the user's or the projects' own Claude skills.

![System Prompts: set-ticket-title selected in the list, its name, Model Haiku and Effort Low, and its empty content](images/system-prompts.png)
*System Prompts with `set-ticket-title`: Haiku at a low effort, empty, and used by nothing yet.*

## Opening it

| From | Does |
| --- | --- |
| **Hephaestus V3 ▸ System Prompts…** (⌥⌘,), after Settings… | Selects the System Prompts tab, or opens it ([Navigation › Tabs](navigation.md#tabs)). |

It is a tab, one in the whole app, like Projects and Virtual Machines (the user's choice): it has the window's
chat panel beside it, on the last project the window showed, and the chat panel button last in its toolbar.
Its tab reads "System Prompts", with `text.book.closed`.

## Anatomy

A `NavigationSplitView`, inside the tab:

| Part | Identifier | Contents |
| --- | --- | --- |
| **List** | `systemPrompts.list` | Every internal skill, in the code's order: `text.book.closed` and the name in the monospaced font (`systemPrompts.skill.<name>`). The first is selected when the tab opens. 200 to 360 pt wide, 240 by default. |
| **Name** | `systemPrompts.name` | "Name" and the selected skill's name, monospaced, selectable, not editable. Help: "The app defines this skill and its name." |
| **Model** and **Effort** | `systemPrompts.model`, `systemPrompts.effort` | Settings ▸ Chat's pickers, side by side: the CLI's models (its fallback list until the CLI has answered), then the selected model's effort levels (none for a model without effort). They set the model and effort the app uses when it runs the skill itself; a chat that calls the skill keeps its own (the user's request). Under them, in `caption` and `textSecondary`: "Used when the app runs this skill itself; a chat that calls it keeps its own model and effort." |
| **Content** | `systemPrompts.content` | A `TextEditor` in the monospaced body font, on `surfaceSunken`, filling the rest. While empty: "Empty: Claude gets nothing from this skill." in `textSecondary`. Its VoiceOver label is "Content". |
| **Status** | `systemPrompts.status` | Under the content, in `callout`: "Saved" or "Editing…" in `textSecondary`; after a failed save, `exclamationmark.triangle.fill` and "Not saved: <reason>" in `danger`. |
| **Nothing selected** | `systemPrompts.nothing` | "No Skill Selected", "Select an internal skill to edit its content." |

The window's title is "System Prompts". In narrow windows the list folds behind the sidebar button, as every
split view does.

## Saving

- A change of content shows at once and is saved one second after the last keystroke (default chosen at design
  time), to `skills/<name>/SKILL.md` in the data folder ([Data › Internal skills](../data.md#internal-skills)).
  A change of model or effort is saved at once, with the content as shown.
- Selecting another skill, or leaving the tab, saves every change at once.
- A save that fails keeps the text, shows "Not saved: <reason>", and is tried again at the next change; the
  next save that works clears the message.
- The file is read when the tab opens: a change made to it outside the app shows the next time.

## Internal skills

**Running a skill.** The app runs a skill as the Claude CLI in print mode, once, without a chat: the skill's
model and effort, its content as the system prompt (left out while it is blank), the input as the message, and
nothing else of the app's: no tools, no MCP server, no saved session, in an empty folder. Claude's answer is
taken as it comes ([Data › Internal skills](../data.md#internal-skills)). So until the content says how to
answer, the answer is what the model makes of the input alone.

| Name | Default content | Default model and effort | Used by |
| --- | --- | --- | --- |
| `set-ticket-title` | Empty | Haiku, Low: a short answer (default chosen at design time) | A ticket created without a title (feedback, Claude's `create_ticket`), and **Generate Title**, in New Ticket and in the ticket editor ([Tickets › Titles written by Claude](tickets.md#titles-written-by-claude)). Its input is the ticket's description. |

A skill the code adds without its own defaults runs on the CLI's `default` model at High effort, as a new chat
does.

The names are in Claude's skill name format: lowercase letters, digits and hyphens, 1 to 64 characters, no
hyphen at either end or twice in a row. The user doesn't add, rename or remove internal skills (the user's
choice): the code does, and each feature that uses one names it.

## Previews

`SystemPromptsView` on a `SystemPromptsModel` over `SampleInternalSkillStore`, 900 × 560 pt: "Empty", "Written,
Dark", "Not Saved".
