# System Prompts

System Prompts is where the user writes what the app's own Claude skills say (the user's request, 17 November
2026). The app's code defines these **internal skills**, each with a name; the user edits their content. The
list holds the internal skills only: not the user's or the projects' own Claude skills.

![System Prompts: set-ticket-title selected in the list, its name, and its empty content](images/system-prompts.png)
*System Prompts with `set-ticket-title`, which is empty and which nothing uses yet.*

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
| **Content** | `systemPrompts.content` | A `TextEditor` in the monospaced body font, on `surfaceSunken`, filling the rest. While empty: "Empty: Claude gets nothing from this skill." in `textSecondary`. Its VoiceOver label is "Content". |
| **Status** | `systemPrompts.status` | Under the content, in `callout`: "Saved" or "Editing…" in `textSecondary`; after a failed save, `exclamationmark.triangle.fill` and "Not saved: <reason>" in `danger`. |
| **Nothing selected** | `systemPrompts.nothing` | "No Skill Selected", "Select an internal skill to edit its content." |

The window's title is "System Prompts". In narrow windows the list folds behind the sidebar button, as every
split view does.

## Saving

- A change shows at once and is saved one second after the last keystroke (default chosen at design time),
  to `skills/<name>/SKILL.md` in the data folder ([Data › Internal skills](../data.md#internal-skills)).
- Selecting another skill, or leaving the tab, saves every change at once.
- A save that fails keeps the text, shows "Not saved: <reason>", and is tried again at the next change; the
  next save that works clears the message.
- The file is read when the tab opens: a change made to it outside the app shows the next time.

## Internal skills

| Name | Default content | Used by |
| --- | --- | --- |
| `set-ticket-title` | Empty | Nothing yet (the user's request). |

The names are in Claude's skill name format: lowercase letters, digits and hyphens, 1 to 64 characters, no
hyphen at either end or twice in a row. The user doesn't add, rename or remove internal skills (the user's
choice): the code does, and each feature that uses one names it.

## Previews

`SystemPromptsView` on a `SystemPromptsModel` over `SampleInternalSkillStore`, 900 × 560 pt: "Empty", "Written,
Dark", "Not Saved".
