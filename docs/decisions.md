# Decisions

The open questions met while bringing HephaestusV2 over, each answered with the recommended default so that
the work goes on. The owner reviews them whenever they like; the page that applies each one says "default
chosen at design time" beside it. Newest phase last.

## Phase 0: Foundation (13 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| Where in the App Group container does the data go? | At the container's root, `~/Library/Group Containers/group.fr.azavech.hephaestusv3/`, as V2 kept its files at the root of its data folder. | [Data › Data folder](data.md#data-folder) |
| What does the import from V2 bring? | The project list and the chosen environments, nothing else: V2's other files on this Mac (settings, secrets, plan usage) are V2's own. | [Data › Import from HephaestusV2](data.md#import-from-hephaestusv2) |
| When does the import run? | When the data folder has no `registry.yml`; it always writes one, so it runs once. | same |
| Which project is V2's own? | The folder whose project file has the identifier `HEPH`, V2's reserved identifier. A folder whose file can't be read is kept. | same |
| Where do V2's keys that V3 doesn't use go when V3 writes a file? | At their place in V2's order, as read; V3 never adds one. | [Data › Unknown keys](data.md#unknown-keys) |
| In what order are unknown keys written? | The order they were read in, rather than V2's sorted order, so a file edited by hand keeps its order. | same |
| How does V3 store a project's color? | The name of a tint (`accent`, `accentSecondary`, `info`, `success`, `warning`); V2's `#RRGGBB` still reads. | [Data › Project color](data.md#project-color) |
| How does V3 store a library? | A fourth `type` value, `library`. | [Data › Project kind](data.md#project-kind) |
| How long may a kubectl command run? | 15 seconds: the commands V3 runs now are short reads (V2 allowed 60 s for its tools). | [Architecture › ExternalTools](architecture.md#externaltools) |
| Are the data targets' messages localized? | No: they are technical details in English, shown under a window's localized sentence. Rule errors are cases the windows word themselves. | [Data › Validation](data.md#validation) |

## Phase 1: Projects (13 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| Does V3 keep V2's reserved identifier `HEPH`? | No: V3 doesn't carry V2's own project, so `HEPH` is an identifier like any other once the import is done. | [Data › Changes](data.md#changes) |
| How are outside changes applied? | A batch that matters loads the whole tree again and compares it with memory, rather than V2's path-by-path processing: the projects are few and their files small, and one rule covers renames, moves and dropped events. | [Data › Outside changes](data.md#outside-changes) |
| What does a project whose file became invalid show? | The version loaded before, with a file issue giving the reason, as V2 kept it in memory; V2 only logged it. | same |
