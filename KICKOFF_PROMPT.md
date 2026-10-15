Read CLAUDE.md fully, then look at design/reference.png and
design/original-macro-ui.png, and read design/Main.dc.html.
These are the spec for the Extended Macro UI addon, a replacement macro
window for WoW Classic Era.

Before writing any code:

1. Check that ../wow-ui-source exists on the classic_era branch. If it's
   missing, tell me the clone command and wait.
2. Read Interface/AddOns/Blizzard_MacroUI in that checkout. Summarize in a
   short list how this client:
   - creates the macro frame, its tabs and its scrolling list,
   - builds the icon list (GetMacroIcons/GetMacroItemIcons or a provider),
   - handles macro indices after CreateMacro/EditMacro/DeleteMacro,
   - handles combat lockdown.
3. Confirm which of these exist in this flavor: SecureActionButtonTemplate,
   UIPanelButtonTemplate, InputBoxTemplate, SearchBoxTemplate, the
   portrait/button frame templates, WowScrollBoxList + ScrollUtil +
   CreateDataProvider, and a grid ScrollBox view. List any gaps and your
   fallback for each.
4. Propose your strategy for the secure Run Macro button and combat
   (including the parent-protection problem described in CLAUDE.md).

Then ask me for the Interface version (I'll run
`/dump select(4, GetBuildInfo())` in game). After that, build Milestone 1
only: TOC, Core.lua, .luacheckrc, and a `/emu` command that toggles an
empty, movable, Escape-closable "Create Macros" window with its position
saved.

Run luacheck, give me the in-game test checklist, and stop.