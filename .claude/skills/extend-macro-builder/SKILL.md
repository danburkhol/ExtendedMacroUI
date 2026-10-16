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
  `"C:/Users/agent/tools/luacheck/luacheck.exe" Core.lua MacroData.lua Messages.lua Editor.lua MessageEditor.lua MainFrame.lua IconPicker.lua MacroBuilder.lua`
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

- `MacroBuilder.Compose(action, name, target, modifier, rankN, rankPrefix)` →
  the command string (e.g. `/cast [@mouseover,mod:alt] Fireball`). Pure.
- `MacroBuilder.Describe(...)` → the plain-language line under the preview.
  Pure. Keep it in sync with Compose.
- `MacroBuilder:EffectiveName()` → the name box text (the single source of
  truth for both spells and items).
- `MacroBuilder:CurrentLine()` → calls Compose with the current state.
- `MacroBuilder:UpdatePreview()` → sets the preview + explanation + Insert
  enabled state. Called on every change.
- `MacroBuilder:UpdateVisibility()` → labels the name box per action and shows
  the Rank box only for a `/cast` whose spell has ranks.
- `MacroBuilder:RefreshList()` → fills the scrolling list for the current
  action (filtered by the search box via `ns.MacroData.Filter`).

State fields: `self.action`, `self.target`, `self.modifier`, `self.rankN`,
`self.rankPrefix`, `self.selectedKey`.

## Task: add a Target option

1. Add an entry to the `TARGETS` table: `{ key, text, desc }`. `key` becomes
   the `@<key>` token in the clause (so it must be a valid unit id — verify in
   the source, e.g. `pet`, `targettarget`). `text` is the dropdown label;
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

1. **`ACTIONS` table** — add `{ key, text }`.
2. **Data source** — add a pure enumerator like `MacroBuilder.KnownSpells()` /
   `MacroBuilder.BagItems()` that returns sorted
   `{ key, name, icon, ... }` items. Verify any API (spellbook, bags, etc.)
   against the source first. De-dupe; keep it UI-free.
3. **`RefreshList`** — branch on `self.action` to call your new enumerator.
4. **`Compose`** — add the verb/formatting for the new action (follow the
   `/cast` vs `/use` branch). Keep it pure.
5. **`Describe`** — add the matching human phrasing.
6. **`UpdateVisibility`** — set the name-box label for the action, and show/hide
   any action-specific extras (the Rank box is the existing example; it keys off
   `self.action ~= "use"` and `self.rankPrefix`).
7. **Name box `OnTextChanged`** — if the action needs something derived from the
   typed name (as `/cast` derives `rankPrefix` via `MacroBuilder.RankPrefix`),
   add it there, guarded by `self.action`.
8. **Shift-click** (optional) — the hook on `ChatFrameUtil.InsertLink` fills the
   name box from `|Hitem:|`/`|Hspell:|` links. Extend it if the new action has a
   natural shift-click source; keep it a `hooksecurefunc` post-hook (no taint).

## Insertion into the macro

The builder never saves. `MacroBuilder:Insert()` calls
`ns.Editor:InsertBodyLine(line)` (in [`Editor.lua`](../../../Editor.lua)), which
appends a new line to the draft and refuses if it would exceed the 255-char
limit. Don't bypass this.

## Finish

Run luacheck (0 warnings, addon files only), then hand the user a short in-game
checklist: `/reload`, open the builder on a macro, exercise the new option, and
confirm the preview, the explanation line, Insert, and that nothing shows in
combat beyond the usual (Save stays disabled in combat).
