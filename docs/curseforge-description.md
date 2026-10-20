# Extended Macro UI

A replacement macro window for World of Warcraft Classic (Classic Era / Anniversary) with a tabbed, two-pane layout: a searchable A–Z list of macros on the left and a rich editor on the right.

Open it with **/emu**.

![Extended Macro UI main window](https://raw.githubusercontent.com/danburkhol/ExtendedMacroUI/main/docs/screenshots/01-overview.png)

## Features

### General & Character macros

A searchable A–Z list with a rich editor, an icon picker, drag-to-action-bar, and per-row duplicate. The search box fuzzy-matches by name, so typing a few letters narrows the list instantly.

![Fuzzy search filtering the macro list](https://raw.githubusercontent.com/danburkhol/ExtendedMacroUI/main/docs/screenshots/02-search.png)

### Macro Builder

A guided side panel that composes `/cast`, `/use`, `/equip` or `/emu send` commands — with targeting and modifier conditionals — and inserts them into the macro being edited, with a live preview of the generated line.

![Macro Builder composing an Equip Item command](https://raw.githubusercontent.com/danburkhol/ExtendedMacroUI/main/docs/screenshots/03-macro-builder.png)

### Change Name / Icon

A docked picker for renaming a macro and choosing its icon, filterable by All / Spell / Item icons, with the name synced live to the editor.

![Icon picker window with the icon grid](https://raw.githubusercontent.com/danburkhol/ExtendedMacroUI/main/docs/screenshots/04-icon-picker.png)

### Saved Messages

Reusable chat messages that broadcast to multiple channels at once — outside the macro system, so they don't consume macro slots. Call one from `/emu send <name>`, with a global anti-spam interval.

![Saved Messages tab with channel selection](https://raw.githubusercontent.com/danburkhol/ExtendedMacroUI/main/docs/screenshots/05-saved-messages.png)

### Import / Export

A wizard that exports all or selected General macros, Character macros and Saved Messages to a shareable text string, and imports such a string with per-item selection, a preview, and an overwrite-or-copy policy for name conflicts.

![Import / Export wizard choosing what to export](https://raw.githubusercontent.com/danburkhol/ExtendedMacroUI/main/docs/screenshots/06-import-export.png)

### Minimap button / data broker

A LibDataBroker launcher (shown by Titan Panel and other broker displays) plus an optional LibDBIcon minimap button. Left-click opens the window; right-click opens a menu that sends a Saved Message.
