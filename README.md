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
- **Import / Export** — a wizard (header button next to the settings gear) that
  exports all or selected General macros, Character macros and Saved Messages
  to a shareable text string, and imports such a string with per-item
  selection, a preview, and an overwrite-or-copy policy for name conflicts.
  The string is `!EMU:<version>!` followed by Base64(Deflate(CBOR(payload))),
  built with the client's own `C_EncodingUtil`; the payload records the
  exporting character, realm, timestamp and addon version.

- **Minimap button / data broker** — a LibDataBroker launcher (shown by Titan
  Panel and other broker displays) plus an optional LibDBIcon minimap button
  (on by default; toggle it in the EMU settings). Left-click opens the window;
  right-click opens a menu that sends a Saved Message.

Open it with `/emu`.

## Embedded libraries

`Libs/` holds unmodified copies of LibStub, CallbackHandler-1.0,
LibDataBroker-1.1 and LibDBIcon-1.0, loaded by the TOC. LibStub loads only the
newest copy across all installed addons, so these never conflict with other
addons' copies. See `/emu help` for the other sub-commands.

## Known issues

- **Run Macro button layers above other `DIALOG`-strata windows.** The editor's
  "Run Macro" button is a secure button parented to `UIParent` and placed at
  `DIALOG` strata so it stays visible above Blizzard's full-screen
  `TimerTracker` frame (which is also `DIALOG`). As a side effect it can render
  on top of other `DIALOG`-strata addon windows (e.g. TradeSkillMaster) even
  when they're focused over the macro window. This is a known edge case we may
  revisit; it does not affect functionality.
