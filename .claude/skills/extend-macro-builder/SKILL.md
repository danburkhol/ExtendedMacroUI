---
name: extend-macro-builder
description: >
  How to add features to the Extended Macro UI Macro Builder — new Target or
  Modifier conditional options, or a whole new action type (like "Cast Spell" /
  "Use Item"). Use when adding to or changing the Macro Builder side panel
  (MacroBuilder.lua) or its composed-command output.
---

# Extending the Macro Builder

The Macro Builder is the side panel that composes one macro command and inserts
it into the macro being edited. All of it lives in
[`MacroBuilder.lua`](../../../MacroBuilder.lua). Read that file before editing —
this skill tells you which piece to touch for each kind of change.

## Ground rules (from CLAUDE.md — always apply)

- **Verify every Blizzard API/template against the source** before using it:
  the `wow-ui-source` clone (branch `classic_era`) nested at
  `wow-ui-source/` in this addon. Grep it; if a symbol isn't there for our
  flavor, don't use it — say so and propose an alternative.
- **luacheck must pass with 0 warnings.** Lint only the addon's own `.lua`
  files, never the clone:
  `"C:/Users/agent/tools/luacheck/luacheck.exe" *.lua`
  Any new global API you call must be added to `read_globals` in `.luacheckrc`.
- **Never taint secure frames.** The builder is unprotected and only edits the
  editor's draft text, so it has no combat restrictions — keep it that way. Do
  not make it call protected functions (`/cast` etc. run only via the Editor's
  SecureActionButton, clicked by the player).
- **You can't run the game.** After changes, run luacheck and give the user a
  short in-game test checklist, then stop and wait.
- **Ask before adding new files, XML or libraries.** Extensions below need none.

## How a command is built (the data flow)

Everything funnels through a few pure functions and one refresh method:

- `MacroBuilder.Compose(o)` → the command text (e.g.
  `/cast [@mouseover,mod:alt] Fireball`). Pure. `o` is an options table:
  `action, name, target, modifier, rankN, rankPrefix, equipLoc, equipSlot`.
  May return more than one line (Use Item on gear prepends an `/equip`).
- `MacroBuilder.Describe(o)` → the plain-language line under the preview.
  Pure, same options table. Keep it in sync with Compose.
- `MacroBuilder:Options()` → builds that table from the current state.
- `MacroBuilder:EffectiveName()` → the name box text, or the list selection
  (`self.selectedListName`) for list-only actions (`MacroBuilder:IsListOnly()`:
  saved messages, and ItemRack sets when they can be read).
- `MacroBuilder:CurrentLine()` → `Compose(self:Options())`.
- `MacroBuilder:UpdatePreview()` → sets the preview + explanation + Insert
  enabled state (hint text per action comes from `HINTS`). Called on every change.
- `MacroBuilder:UpdateItemDetails()` → derives `equipLoc` (and a default
  `equipSlot` for two-slot items via `SLOT_CHOICES`) from the name box.
- `MacroBuilder:UpdateVisibility()` → name-box label (`NAME_LABELS`), shows the
  Target/Modifier rows per `ACTION_TARGETS` / `ACTION_MODIFIERS`, the Rank box
  for a ranked `/cast`, the slot radios for a two-slot `/equip`, re-anchors so
  hidden rows leave no gap, and calls `UpdateHeight()`.
- `MacroBuilder:RefreshList()` → fills the list from `LIST_SOURCES[action]`
  (filtered by the search box via `ns.MacroData.Filter`).
- `MacroBuilder:UpdateHeight()` → sizes the window to the unfiltered list
  (capped at `MAX_LIST_ROWS`) minus any hidden rows.

State fields: `self.action`, `self.target`, `self.modifier`, `self.rankN`,
`self.rankPrefix`, `self.equipLoc`, `self.equipSlot`, `self.selectedKey`,
`self.selectedListName`.

## Task: add a Target option

1. Add an entry to the `TARGETS` table: `{ key, text, desc }`. `key` becomes
   the `@<key>` token in the clause (so it must be a valid unit id — verify in
   the source, e.g. `pet`, `targettarget`, or a special token like `cursor`).
   `text` is the dropdown label;
   `desc` is the hover tooltip.
2. Add a `TARGET_PHRASE[key]` entry (the human phrase for `Describe`, e.g.
   `"on your pet"`).
3. That's it — the dropdown builds from `TARGETS`, and `Compose` emits
   `"@"..key` for any non-`none` target. luacheck + test.

## Task: add a Modifier option

1. Add to `MODIFIERS`: `{ key, text, cond, desc }`. `cond` is the exact
   conditional token (`mod:alt`, `btn:3`, `mod`). `MOD_COND` is built from
   these automatically.
2. Add a `MOD_PHRASE[key]` entry for `Describe`.
3. Dropdown and composition pick it up automatically. luacheck + test.

## Task: add a whole new action type (like Cast Spell / Use Item)

This is the bigger change. An action = a dropdown choice with its own data
list and its own command verb.

1. **`ACTIONS` table** — add `{ key, text }`. For an action that drives
   another addon, add `requiresAddOn` + `disabledDesc`; the dropdown grays it
   out (see the ItemRack entry and `MacroBuilder.HasItemRack`).
2. **Conditionals** — add the key to `ACTION_TARGETS` and/or
   `ACTION_MODIFIERS` only if the command's slash handler parses
   `[conditionals]` (Blizzard's secure commands do; addon commands like
   `/emu send` and `/itemrack` don't).
3. **Data source** — add a pure enumerator like `MacroBuilder.KnownSpells()` /
   `MacroBuilder.UsableItems()` / `MacroBuilder.EquippableItems()` that returns
   sorted `{ key, name, icon, note?, ... }` items (`note` shows muted after the
   name, e.g. "(equipped)"). Verify any API against the source first. De-dupe;
   keep it UI-free.
4. **`LIST_SOURCES`** — add `{ fetch, noun }` for the action.
5. **`Compose`** / **`Describe`** — add the verb/formatting and matching human
   phrasing. Keep both pure.
6. **`HINTS`** and **`NAME_LABELS`** — the empty-preview hint and name-box label.
7. **List-only?** — if the name must come from the list (no typing), extend
   `MacroBuilder:IsListOnly()`.
8. **Extras** — action-specific controls follow the Rank box / slot radios
   pattern: create them in `Create()`, show/hide them in `UpdateVisibility`,
   and derive their state from the name in the name box's `OnTextChanged`
   (as `RankPrefix` and `UpdateItemDetails` do).
9. **Shift-click** (optional) — the hook on `ChatFrameUtil.InsertLink` fills the
   name box from `|Hitem:|`/`|Hspell:|` links. Extend it if the new action has a
   natural shift-click source; keep it a `hooksecurefunc` post-hook (no taint).

## Insertion into the macro

The builder never saves. `MacroBuilder:Insert()` calls
`ns.Editor:InsertBodyLine(line)` (in [`Editor.lua`](../../../Editor.lua)), which
appends the text (one or more lines) to the draft and refuses if it would
exceed the 255-char limit. Don't bypass this.

## Finish

Run luacheck (0 warnings, addon files only), then hand the user a short in-game
checklist: `/reload`, open the builder on a macro, exercise the new option, and
confirm the preview, the explanation line, Insert, and that nothing shows in
combat beyond the usual (Save stays disabled in combat).
