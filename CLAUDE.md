# Extended Macro UI — WoW Classic addon

A replacement macro window for World of Warcraft Classic. It has a tabbed,
two-pane layout: a searchable A–Z list of macros on the left, an editor on
the right, and the icon selector in its own window docked to the right.

The visual spec is in `design/`:
- `reference.png`: a screenshot of the redesigned mockup. This is the
  target look.
- `Main.dc.html`: the mockup's source. Read its markup for layout, sizes
  and colors, and its script for intended behavior. It won't render on its
  own outside the design tool.
- `original-macro-ui.png`: Blizzard's original macro window plus icon
  selector, for reference.

The mockup's HTML/CSS/JS is NOT code to port: rebuild everything with the
WoW UI API in Lua. Its icons are placeholder glyphs; use the game's real
icons.

## Target client

- Primary: Classic Era / Anniversary realms (`_classic_era_` install folder).
  They run on the modern client, so modern UI APIs and templates (ScrollBox,
  DataProvider, mixins, `SetShown`, etc.) are generally present. **Verify
  each one before using it** (see "Source of truth").
- Interface version: ask the user. They get it in game with
  `/dump select(4, GetBuildInfo())`. Never guess it. Use flavor-suffixed TOC
  files (`ExtendedMacroUI_Vanilla.toc`, etc.) if we add more flavors later.
- Lua 5.1 (the WoW dialect). No `goto`, no integer division, no `//`.

## Source of truth for Blizzard APIs

Do not rely on memory for WoW API signatures or template names. Before
using any Blizzard function, template, mixin or global:

1. Check `../wow-ui-source` (a clone of Gethe/wow-ui-source on the branch
   for our flavor, e.g. `classic_era`). If it's missing, ask the user to
   clone it, or clone it yourself if allowed:
   `git clone --depth 1 -b classic_era https://github.com/Gethe/wow-ui-source ../wow-ui-source`
2. Grep for the symbol. `Interface/AddOns/Blizzard_MacroUI/` is the best
   reference for how Blizzard itself drives the macro API and icon picker
   in this client.
3. If it's not in the source for our flavor, don't use it. Say so and
   propose an alternative.

## Hard rules: protected and restricted actions

These are the things most likely to break the addon or cause taint.

- **Running a macro.** Addon code cannot run `/cast`, `/use` etc. directly
  (`RunMacroText` and friends are protected). The "Run Macro" button must be
  a `SecureActionButtonTemplate` button with `type = "macro"` and
  `macrotext = <current draft body>`, clicked by the player.
  - `SetAttribute` on a secure frame is blocked in combat. Update
    `macrotext` only when out of combat (`InCombatLockdown()`). Disable
    the Run button in combat and re-sync on `PLAYER_REGEN_ENABLED`.
  - On the modern client, secure buttons need
    `RegisterForClicks("AnyUp", "AnyDown")` to fire reliably with the
    `ActionButtonUseKeyDown` CVar. Confirm this against the source.
  - A secure child can make its parents protected: showing, hiding or
    moving the main window in combat may be blocked. Decide on and document
    a strategy (e.g. block opening/closing the window in combat with a chat
    message, or keep the secure button parented outside the main frame and
    anchor it out of combat). Test with `/console taintLog 1`.
- **Changing macros.** `CreateMacro`, `EditMacro` and `DeleteMacro` are not
  allowed in combat. Disable New/Save/Delete/icon Okay in combat with a
  tooltip explaining why. Re-enable on `PLAYER_REGEN_ENABLED`.
- **Never** taint Blizzard frames: no overwriting Blizzard globals or
  functions, and no `hooksecurefunc` on anything unless needed. If we later
  take over `/macro`, do it by opening our frame from a post-hook, never by
  replacing `MacroFrame` methods.

## Macro API facts (verify against the source)

- `GetNumMacros()` → numAccount, numCharacter.
- Account macros use indices `1..MAX_ACCOUNT_MACROS`. Character macros use
  `MAX_ACCOUNT_MACROS + 1 .. MAX_ACCOUNT_MACROS + MAX_CHARACTER_MACROS`.
  Use the globals, never hardcode 120/18.
- `GetMacroInfo(index)` → name, icon, body.
- `CreateMacro(name, icon, body, perCharacter)` and
  `EditMacro(index, name, icon, body)` return the macro's **new** index.
  The game keeps macros sorted, so indices shift after every create, edit
  or delete. Never cache indices across those calls. Re-resolve the
  selection from the returned index and refresh on `UPDATE_MACROS`.
- Names may not be unique, so don't use them as keys.
- Limits: name 16 characters, body 255 (`MACROFRAME_CHAR_LIMIT` if
  present). Enforce both with `SetMaxLetters`.
- Icons: `GetMacroIcons(t)` / `GetMacroItemIcons(t)` fill a table (spell
  icons / item icons). Check how Blizzard_MacroUI builds its icon list in
  this client and reuse that approach (there may be an icon data provider).
  The default "?" icon is `134400` (INV_Misc_QuestionMark). Confirm.

## Behavior spec (from the design)

**Window.** Title "Create Macros", close button, movable, clamped to
screen, Escape closes it (`UISpecialFrames`). Position is saved in
SavedVariables. Opened by `/emu` (and later optionally by `/macro`).

**Tabs.** "General Macros" (account) and "Character Specific Macros". Each
label shows a used/max count, e.g. `13/120`.

**Left pane: macro list.**
- Search box at the top (with clear button). It fuzzy-filters by name:
  case-insensitive subsequence match, ignoring spaces (`"hpot"` matches
  "Healing Potion"). Matched characters are highlighted gold with color
  codes. Escape any `|` in names (`||`) before adding color codes.
- Vertical scrolling list, always sorted A–Z, case-insensitive.
- Each row: icon, then name (truncated with ellipsis). The selected row is
  highlighted. A row with unsaved edits shows a small gold dot.
- Empty states: "No macros match “x”." and a no-macros prompt.
- Footer: "n of max slots used" (or "Showing n of m" while filtering),
  plus **New** and **Delete** buttons. Delete asks for confirmation via
  `StaticPopupDialogs`.
- Each tab remembers its own selection and the search text persists across
  tabs.

**Right pane: editor.**
- Large icon preview, then a "Macro Name" box with an `n/16` counter.
- "Change Name/Icon" button toggles the icon picker window.
- "Enter Macro Commands" multi-line box (scrollable EditBox) with an
  `n/255 Characters Used` counter, which turns red-orange at 240+.
- Bottom row: **Run Macro** (secure, runs the current draft even if it
  isn't saved), an "Unsaved changes" label, **Save** (enabled only when
  dirty and the name isn't blank) and **Cancel** (reverts the draft;
  enabled only when dirty).
- Changing selection or tab with unsaved changes → StaticPopup with "Save",
  "Discard" and "Cancel" choices.
- New: creates "New Macro" with the "?" icon and an empty body in the
  current tab (respecting the max), selects it, and opens the icon picker.

**Icon picker window** (separate frame, docked to the main window's
TOPRIGHT, same frame style):
- Title "Change Name/Icon" and a close button.
- "Enter Macro Name (Max 16 Characters):" box, synced live with the
  editor's name box.
- "Currently Selected" icon preview.
- "Choose an Icon:" with a filter dropdown: All Icons / Spell Icons /
  Item Icons.
- Scrolling grid of icons (8 columns), with a highlight on the selection.
- **Okay** applies the icon to the draft (not saved until Save).
  **Cancel** or close discards the pick.

## Look and feel

Match the Classic UI. Prefer stock Blizzard pieces over custom art:

- Fonts: `GameFontNormal` (gold) for labels and titles,
  `GameFontHighlight` (white) for names and body text.
  `NORMAL_FONT_COLOR` is the design's gold `#FFD100`.
- Red panel buttons: `UIPanelButtonTemplate`. Close: `UIPanelCloseButton`.
  Frame: whatever portrait/button frame template exists in this flavor
  (check the source). Tabs: the panel tab template Blizzard_MacroUI uses.
  Inputs: `InputBoxTemplate` / `SearchBoxTemplate` if present.
- Scrolling: `WowScrollBoxList` + `ScrollUtil` + `CreateDataProvider` if
  present in this flavor, else `FauxScrollFrame`.
- Sizes from the mockup (adjust to look right in game): main window about
  780×580, left pane 290 wide, picker about 420×580.
- No custom textures or fonts in v1. No third-party libraries (no Ace) in v1.

## Code layout and conventions

```
ExtendedMacroUI/
  ExtendedMacroUI.toc
  Core.lua         -- namespace, events, slash command, SavedVariables
  MacroData.lua    -- API wrapper, sorting, fuzzy match (no UI code)
  MainFrame.lua    -- window, tabs, list pane
  Editor.lua       -- right pane + secure Run button
  IconPicker.lua   -- picker window
  .luacheckrc
  design/          -- mockup + reference image (not loaded by the TOC)
```

- Start each file with `local ADDON_NAME, ns = ...` and share state
  through `ns`. Only these globals: the SavedVariables table
  (`ExtendedMacroUIDB`), `SLASH_EMU1` / `SlashCmdList.EMU`, named frames
  that need names (the main frame for `UISpecialFrames`, StaticPopup keys),
  and `BINDING_*` if we add bindings.
- Cache hot globals as locals at the top of the file.
- Keep `MacroData.lua` pure: the sort and fuzzy functions must not touch UI
  so they're easy to reason about.
- Build frames in Lua with mixins (`Mixin`, `CreateFromMixins`). Only use
  XML if a template requires it.
- No `print` spam. User-facing messages go to `DEFAULT_CHAT_FRAME` with an
  `|cffffd100Extended Macro UI:|r` prefix.

## Workflow

- You cannot run the game. After each milestone:
  1. Run `luacheck .` (std `lua51`, WoW globals listed in `.luacheckrc`)
     and fix every warning.
  2. Give the user a short in-game test checklist (what to `/reload`,
     click and type, what should happen, and what to try in combat).
  3. **Stop and wait** for their results before starting the next
     milestone.
- If the user reports an error, ask for the full BugSack/BugGrabber
  output, or for `/console scriptErrors 1` to be on.
- For taint issues, ask the user to enable `/console taintLog 1` and share
  `Logs/taint.log`.
- Keep changes small and in the milestone's scope. Ask before adding
  libraries, XML or new files outside the layout above.

## Milestones

1. **Skeleton.** TOC, Core, `/emu` toggles an empty movable window with
   title, close button, Escape-to-close and a saved position. luacheck
   config.
2. **Data and list.** MacroData wrapper. Tabs plus an A–Z list of real
   macros with icons, selection and counts. Refresh on `UPDATE_MACROS`.
3. **Search.** Fuzzy filter with highlighted matches, clear button, empty
   state, "Showing n of m".
4. **Editor.** Name and body boxes with counters, dirty tracking,
   Save/Cancel through `EditMacro` (re-resolving the index), New and
   Delete with confirmation, the unsaved-changes popup, combat lockouts.
5. **Run Macro.** Secure button wired to the draft text, plus the combat
   handling and parent-protection strategy. Test in and out of combat.
6. **Icon picker.** Docked window, synced name, filter dropdown, icon
   grid, Okay/Cancel.
7. **Polish.** Tooltips (including combat-disabled reasons), keyboard
   focus (Tab between name and body, Enter in search selects the first
   result), and an optional `/macro` takeover setting.