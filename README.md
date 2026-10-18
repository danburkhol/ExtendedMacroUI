# Extended Macro UI

A replacement macro window for World of Warcraft Classic (Classic Era /
Anniversary). It provides a tabbed, two-pane layout:

- **General Macros** and **Character Macros** — a searchable A–Z list with a
  rich editor, an icon picker, drag-to-action-bar, and per-row duplicate.
- **Saved Messages** — reusable chat messages that broadcast to multiple
  channels at once (outside the macro system, so they don't consume macro
  slots), callable from `/emu send <name>`, with a global anti-spam interval.
- **Macro Builder** — a guided side panel that composes `/cast`, `/use`, or
  `/emu send` commands (with targeting/modifier conditionals) and inserts them
  into the macro being edited.

Open it with `/emu`. See `/emu help` for the other sub-commands.

## Known issues

- **Run Macro button layers above other `DIALOG`-strata windows.** The editor's
  "Run Macro" button is a secure button parented to `UIParent` and placed at
  `DIALOG` strata so it stays visible above Blizzard's full-screen
  `TimerTracker` frame (which is also `DIALOG`). As a side effect it can render
  on top of other `DIALOG`-strata addon windows (e.g. TradeSkillMaster) even
  when they're focused over the macro window. This is a known edge case we may
  revisit; it does not affect functionality.
