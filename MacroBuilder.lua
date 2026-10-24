local ADDON_NAME, ns = ...

-- Macro Builder: a guided side panel that composes a macro command (/cast,
-- /use, /equip, /emu send or /itemrack equip, with one optional targeting + one
-- optional modifier conditional) and inserts it into the macro being edited. It
-- never writes macros itself -- it only appends text to the editor's draft, so
-- the normal dirty/Save flow applies. Not used by Saved Messages.
--
-- The data helpers at the top are pure (no UI): spell/bag enumeration and the
-- command-composition string builder.

local CreateFrame = CreateFrame
local CreateDataProvider = CreateDataProvider
local C_Spell = C_Spell
local C_SpellBook = C_SpellBook
local C_Item = C_Item
local C_Container = C_Container
local AuraUtil = AuraUtil
local ChatFrameUtil = ChatFrameUtil
local hooksecurefunc = hooksecurefunc
local GetNumSpellTabs = GetNumSpellTabs
local GetSpellTabInfo = GetSpellTabInfo
local GetSpellBookItemInfo = GetSpellBookItemInfo
local GetSpellBookItemName = GetSpellBookItemName
local GetSpellTexture = GetSpellTexture
local IsPassiveSpell = IsPassiveSpell
local GetInventoryItemID = GetInventoryItemID
local GetInventoryItemLink = GetInventoryItemLink
local GetInventoryItemTexture = GetInventoryItemTexture
local C_AddOns = C_AddOns
local GameTooltip = GameTooltip
local concat = table.concat
local strtrim = strtrim

local BOOKTYPE_SPELL = BOOKTYPE_SPELL or "spell"
local BACKPACK = BACKPACK_CONTAINER or 0
local NUM_BAGS = NUM_BAG_SLOTS or 4
local FIRST_EQUIPPED = INVSLOT_FIRST_EQUIPPED or 1
local LAST_EQUIPPED = INVSLOT_LAST_EQUIPPED or 19

local BUILDER_WIDTH, BUILDER_HEIGHT = 380, 560
local ROW_HEIGHT = 20

-- The window's height follows the list's contents (ns.SetInsetContentHeight).
-- Fixed inset space above the list (action dropdown + search box) and below it
-- (name box, target/modifier/rank rows and the preview; the saved-message
-- action hides everything but the preview), plus the list box's own padding.
local LIST_TOP = 91
local BELOW_LIST_FULL = 248
local BELOW_LIST_MESSAGE = 90
local LIST_CHROME = 12
local MIN_LIST_ROWS, MAX_LIST_ROWS = 4, 8
-- Height of the Target row, collapsed for actions that take no target.
local TARGET_ROW_HEIGHT = 48
-- The preview is one line for composed commands; a library pick shows its whole
-- (multi-line) body, so the preview and window grow to fit it, capped.
local PREVIEW_SINGLE_HEIGHT = 24
local PREVIEW_LINE_HEIGHT = 13
local MAX_PREVIEW_LINES = 12
local QUESTION_MARK_ICON = ns.QUESTION_MARK_ICON

local MacroBuilder = ns.RegisterDockPanel({})
ns.MacroBuilder = MacroBuilder

-- One of the ACTIONS keys.
MacroBuilder.action = "cast"
MacroBuilder.target = "none"
MacroBuilder.modifier = "none"
MacroBuilder.previewHeight = PREVIEW_SINGLE_HEIGHT

local ACTIONS = {
	{ key = "library", text = "Macro Library" },
	{ key = "cast",    text = "Cast Spell" },
	{ key = "use",     text = "Use Item" },
	{ key = "equip",   text = "Equip Item" },
	{ key = "cancelaura", text = "Cancel Buff" },
	{ key = "message", text = "Saved Message" },
	{ key = "itemrack", text = "ItemRack: Equip Set", requiresAddOn = "ItemRack",
		disabledDesc = "Requires the ItemRack addon to be installed and enabled." },
}

-- Which conditionals each action supports. /emu send and /itemrack equip take
-- a plain name (their handlers don't parse [conditionals]); /equip and
-- /cancelaura honor modifiers but a target is meaningless for them
-- (/cancelaura always acts on your own buffs).
local ACTION_TARGETS = { cast = true, use = true }
local ACTION_MODIFIERS = { cast = true, use = true, equip = true, cancelaura = true }

-- Equip locations that fit two slots: these get a slot choice and an
-- /equipslot command. Every other wearable location has exactly one slot,
-- which /equip finds by itself.
local SLOT_CHOICES = {
	INVTYPE_WEAPON = {
		{ slot = INVSLOT_MAINHAND or 16, text = "Main hand", phrase = "main hand" },
		{ slot = INVSLOT_OFFHAND or 17, text = "Off hand", phrase = "off hand" },
	},
	INVTYPE_TRINKET = {
		{ slot = INVSLOT_TRINKET1 or 13, text = "Trinket 1", phrase = "first trinket slot" },
		{ slot = INVSLOT_TRINKET2 or 14, text = "Trinket 2", phrase = "second trinket slot" },
	},
	INVTYPE_FINGER = {
		{ slot = INVSLOT_FINGER1 or 11, text = "Ring 1", phrase = "first ring slot" },
		{ slot = INVSLOT_FINGER2 or 12, text = "Ring 2", phrase = "second ring slot" },
	},
}

-- Equippable locations that aren't worn gear (bag/ammo slots), so they're
-- neither listed for Equip Item nor treated as needing to be worn to /use.
local NOT_WORN = {
	[""] = true,
	INVTYPE_BAG = true,
	INVTYPE_QUIVER = true,
	INVTYPE_AMMO = true,
	INVTYPE_NON_EQUIP_IGNORE = true,
}

-- True if an item with this equip location must be worn to be used.
local function NeedsEquip(equipLoc)
	return equipLoc ~= nil and not NOT_WORN[equipLoc]
end
MacroBuilder.NeedsEquip = NeedsEquip

-- Targeting choices. The macro clause uses "@<key>" (except "none").
local TARGETS = {
	{ key = "none",         text = "None",                            desc = "No targeting clause: acts on your current target (or self-casts, depending on the spell)." },
	{ key = "player",       text = "Player (@player)",                desc = "@player: always affects you, whatever you have targeted." },
	{ key = "target",       text = "Target (@target)",                desc = "@target: your current target." },
	{ key = "targettarget", text = "Target's target (@targettarget)", desc = "@targettarget: whatever your target is targeting (e.g. the tank's target)." },
	{ key = "focus",        text = "Focus (@focus)",                  desc = "@focus: your saved focus target (set with /focus)." },
	{ key = "focustarget",  text = "Focus's target (@focustarget)",   desc = "@focustarget: whatever your focus is targeting." },
	{ key = "mouseover",    text = "Mouse-over (@mouseover)",         desc = "@mouseover: the unit your cursor is over (a unit frame or 3D model)." },
	{ key = "pet",          text = "Pet (@pet)",                      desc = "@pet: your pet." },
	{ key = "cursor",       text = "Cursor (@cursor)",                desc = "@cursor: places a ground-targeted spell or item (e.g. Blizzard, Flare) at your mouse cursor without the targeting circle." },
}

-- Modifier choices mapped to their macro conditional token.
local MODIFIERS = {
	{ key = "none", text = "None",                         desc = "No modifier condition: the command always runs." },
	{ key = "any",  text = "Any modifier",   cond = "mod",       desc = "mod: runs while any of Alt, Ctrl or Shift is held." },
	{ key = "alt",  text = "Alt",            cond = "mod:alt",   desc = "mod:alt: only runs while the Alt key is held." },
	{ key = "ctrl", text = "Ctrl",           cond = "mod:ctrl",  desc = "mod:ctrl: only runs while the Ctrl key is held." },
	{ key = "shift", text = "Shift",         cond = "mod:shift", desc = "mod:shift: only runs while the Shift key is held." },
	{ key = "btn1", text = "Mouse Button 1", cond = "btn:1",     desc = "btn:1: only runs when triggered with mouse button 1 (left)." },
	{ key = "btn2", text = "Mouse Button 2", cond = "btn:2",     desc = "btn:2: only runs when triggered with mouse button 2 (right)." },
	{ key = "btn3", text = "Mouse Button 3", cond = "btn:3",     desc = "btn:3: only runs when triggered with mouse button 3 (middle)." },
	{ key = "btn4", text = "Mouse Button 4", cond = "btn:4",     desc = "btn:4: only runs when triggered with mouse button 4." },
	{ key = "btn5", text = "Mouse Button 5", cond = "btn:5",     desc = "btn:5: only runs when triggered with mouse button 5." },
}

local MOD_COND = {}
for _, m in ipairs(MODIFIERS) do
	MOD_COND[m.key] = m.cond
end

-- Prebuilt macros offered by the "Macro Library" action. Unlike the other
-- actions (which compose one command from live game data), each library entry
-- is a fixed, ready-to-use macro body that Insert/New Macro drop in whole.
-- Every button name below is verified against the classic_era UI source.
-- Keep bodies within the 255-char macro limit.
--   key: stable id. name: list label + default macro name (<= 16 shows cleanly).
--   note: muted suffix in the list. icon: list-row texture (New Macro still
--   gets the "?" icon). body: the macro text. desc: the explanation line.
local CLICK_THROUGH_LINES = {
	"/click StaticPopup1Button1",
	"/click QuestFrameAcceptButton",
	"/click QuestFrameCompleteQuestButton",
	"/click QuestFrameCompleteButton",
	"/click QuestTitleButton1",
	"/click TradeFrameTradeButton",
	"/click BattlefieldFrameJoinButton",
	"/click PVPReadyDialogEnterBattleButton",
}

local LIBRARY = {
	{
		key = "clickthrough",
		name = "Click-Through",
		note = "(quests, trade, BG)",
		icon = "Interface\\ICONS\\INV_Misc_Note_01",
		body = concat(CLICK_THROUGH_LINES, "\n"),
		desc = "One key for quest accept/turn-in, trade confirm, Battleground "
			.. "join and enter, and the first confirmation popup.",
	},
}

local LIBRARY_BY_KEY = {}
for _, entry in ipairs(LIBRARY) do
	LIBRARY_BY_KEY[entry.key] = entry
end

-- The library entries as a fresh sorted { key, name, icon, note } list for the
-- selector (a copy, so SortByName never reorders LIBRARY itself).
function MacroBuilder.LibraryEntries()
	local list = {}
	for _, entry in ipairs(LIBRARY) do
		list[#list + 1] = {
			key = entry.key,
			name = entry.name,
			icon = entry.icon or QUESTION_MARK_ICON,
			note = entry.note,
		}
	end
	return ns.SortByName(list)
end

--------------------------------------------------------------------------------
-- Data (pure)
--------------------------------------------------------------------------------

-- Legacy spellbook API (Classic Era / Anniversary): spell tabs and book slots.
-- Calls add(name, spellID, icon, bookSlot) for each castable spell.
local function LegacyKnownSpells(add)
	for tab = 1, GetNumSpellTabs() do
		local _, _, offset, numSpells = GetSpellTabInfo(tab)
		if offset and numSpells then
			for slot = offset + 1, offset + numSpells do
				local spellType, id = GetSpellBookItemInfo(slot, BOOKTYPE_SPELL)
				if spellType == "SPELL" and not IsPassiveSpell(slot, BOOKTYPE_SPELL) then
					add(GetSpellBookItemName(slot, BOOKTYPE_SPELL), id, GetSpellTexture(slot, BOOKTYPE_SPELL), slot)
				end
			end
		end
	end
end

-- C_SpellBook API, for clients that dropped the legacy globals above (WoW
-- Forever / Camelot). No book slot is passed, so the hover tooltip falls back
-- to the spell id.
local function SpellBookKnownSpells(add)
	local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
	local spellItem = Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1
	for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
		local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(line)
		if lineInfo and lineInfo.itemIndexOffset and lineInfo.numSpellBookItems and not lineInfo.shouldHide then
			local offset = lineInfo.itemIndexOffset
			for slot = offset + 1, offset + lineInfo.numSpellBookItems do
				local info = C_SpellBook.GetSpellBookItemInfo(slot, bank)
				if info and info.itemType == spellItem and not info.isPassive and not info.isOffSpec then
					add(info.name, info.spellID, info.iconID, nil)
				end
			end
		end
	end
end

-- Every castable spell the player knows, at its highest rank, as sorted
-- { key = spellID, name, icon, spellID }. De-duplicated by name (a spell line
-- appears once). Skips passives, not-yet-learned and flyout entries. Uses
-- whichever spellbook API this client has; with neither, the list is empty.
function MacroBuilder.KnownSpells()
	local list, seen = {}, {}
	local function add(name, id, icon, bookSlot)
		if name and name ~= "" and not seen[name:lower()] then
			seen[name:lower()] = true
			list[#list + 1] = {
				key = id or name,
				name = name,
				icon = icon or QUESTION_MARK_ICON,
				spellID = id,
				bookSlot = bookSlot, -- for the hover tooltip
			}
		end
	end
	if GetNumSpellTabs then
		LegacyKnownSpells(add)
	elseif C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
		SpellBookKnownSpells(add)
	end
	return ns.SortByName(list)
end

-- Extracts the item name from a container item's hyperlink ("[Name]"). The
-- link is always present for an occupied slot, so this avoids item-cache races.
local function NameFromLink(link)
	return link and link:match("%[(.-)%]") or nil
end

-- Items the player is wearing plus everything in their bags, filtered by
-- `accept(entry)`, as sorted { key = itemID, name, icon, itemID, equipLoc,
-- worn, wornSlot, note }. De-duplicated by itemID (a worn copy wins over a
-- bag copy).
local function InventoryItems(accept)
	local list, seen = {}, {}
	local function add(itemID, link, icon, wornSlot, bag, bagSlot)
		if not itemID or seen[itemID] then
			return
		end
		local name = NameFromLink(link)
		if not name then
			return
		end
		local entry = {
			key = itemID,
			name = name,
			icon = icon or QUESTION_MARK_ICON,
			itemID = itemID,
			equipLoc = select(4, C_Item.GetItemInfoInstant(itemID)),
			worn = wornSlot ~= nil,
			wornSlot = wornSlot,
			bag = bag, -- bag + bagSlot: where it sits, for the hover tooltip
			bagSlot = bagSlot,
			note = wornSlot and "(equipped)" or nil,
		}
		if accept(entry) then
			seen[itemID] = true
			list[#list + 1] = entry
		end
	end
	for slot = FIRST_EQUIPPED, LAST_EQUIPPED do
		local itemID = GetInventoryItemID("player", slot)
		if itemID then
			add(itemID, GetInventoryItemLink("player", slot), GetInventoryItemTexture("player", slot), slot)
		end
	end
	for bag = BACKPACK, NUM_BAGS do
		local slots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info then
				add(info.itemID, info.hyperlink, info.iconFileID, nil, bag, slot)
			end
		end
	end
	return ns.SortByName(list)
end

-- Every item (worn or in bags) with an on-use spell (C_Item.GetItemSpell
-- returns one), so reagents, plain armor and other non-/use items are skipped.
function MacroBuilder.UsableItems()
	return InventoryItems(function(e)
		return C_Item.GetItemSpell(e.itemID) ~= nil
	end)
end

-- Every wearable item the player has, worn or in bags.
function MacroBuilder.EquippableItems()
	return InventoryItems(function(e)
		return C_Item.IsEquippableItem(e.itemID) and NeedsEquip(e.equipLoc)
	end)
end

-- Buffs players commonly want to click off, listed for Cancel Buff even when
-- they aren't on the player right now (so the macro can be built ahead of
-- time -- most come from other players). /cancelaura works by name, so the
-- name is the source of truth; the spellID only resolves an icon, so a wrong
-- or unknown id just falls back to the question mark.
local COMMON_AURAS = {
	{ name = "Blessing of Salvation", spellID = 1038 },
	{ name = "Greater Blessing of Salvation", spellID = 25895 },
	{ name = "Blessing of Protection", spellID = 1022 },
	{ name = "Blessing of Freedom", spellID = 1044 },
}

-- The icon for a spellID, or nil if the client can't resolve one.
local function SpellIcon(spellID)
	if spellID and C_Spell and C_Spell.GetSpellTexture then
		return C_Spell.GetSpellTexture(spellID)
	end
	return nil
end

-- Buffs the player can cancel: everything helpful on them right now, plus the
-- common click-off buffs that aren't currently active, as sorted
-- { key, name, icon, spellID, note }. De-duplicated by lowercased name (an
-- active buff wins over its common-list twin, keeping its real icon and the
-- "(active)" note). Uses AuraUtil.ForEachAura -- the same enumeration the
-- Blizzard buff frame uses -- with the packed aura table (name/icon/spellId).
function MacroBuilder.CancelableBuffs()
	local list, seen = {}, {}
	local function add(name, icon, spellID, note)
		if not name or name == "" then
			return
		end
		local lname = name:lower()
		if seen[lname] then
			return
		end
		seen[lname] = true
		list[#list + 1] = {
			key = lname,
			name = name,
			icon = icon or QUESTION_MARK_ICON,
			spellID = spellID, -- for the hover tooltip and icon
			note = note,
		}
	end
	if AuraUtil and AuraUtil.ForEachAura then
		AuraUtil.ForEachAura("player", "HELPFUL", nil, function(aura)
			if aura then
				add(aura.name, aura.icon, aura.spellId, "(active)")
			end
		end, true)
	end
	for _, b in ipairs(COMMON_AURAS) do
		add(b.name, SpellIcon(b.spellID), b.spellID)
	end
	return ns.SortByName(list)
end

-- True if ItemRack is loaded (its action is grayed out in the menu otherwise).
function MacroBuilder.HasItemRack()
	return (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("ItemRack")) and true or false
end

-- ItemRack's per-character set table, or nil if it can't be read (ItemRack not
-- loaded, or a version that stores sets differently -- the builder then falls
-- back to typing the set name).
local function ItemRackSetTable()
	local user = MacroBuilder.HasItemRack() and _G.ItemRackUser
	if type(user) == "table" and type(user.Sets) == "table" then
		return user.Sets
	end
	return nil
end

-- True if ItemRack's sets can be listed (so the set is picked from the list
-- instead of typed).
function MacroBuilder.CanListItemRackSets()
	return ItemRackSetTable() ~= nil
end

-- The player's ItemRack sets as sorted { key, name, icon }. Names starting with
-- "~" are ItemRack's internal sets (~Unequip, ~CombatQueue) and are skipped.
function MacroBuilder.ItemRackSets()
	local list = {}
	local sets = ItemRackSetTable()
	if not sets then
		return list
	end
	for name, set in pairs(sets) do
		if type(name) == "string" and not name:match("^~") then
			local icon = type(set) == "table" and set.icon or nil
			list[#list + 1] = { key = name, name = name, icon = icon or QUESTION_MARK_ICON }
		end
	end
	return ns.SortByName(list)
end

-- The equip location for an item name, plus the slot it's worn in (if worn):
-- first among the listed items (so typed or shift-clicked names resolve
-- without a cache lookup), then the item API, which accepts names of items the
-- client already knows.
function MacroBuilder.EquipLocFor(name, items)
	if not name or name == "" then
		return nil
	end
	local lname = name:lower()
	for _, item in ipairs(items or {}) do
		if item.name:lower() == lname then
			return item.equipLoc, item.wornSlot
		end
	end
	return select(4, C_Item.GetItemInfoInstant(name))
end

-- The localized rank prefix for a spell (e.g. "Rank " from "Rank 6"), or nil if
-- the spell has no rank subtext. Lets us build "(Rank N)" without hardcoding the
-- English word. `identifier` is a spell name or id (GetSpellSubtext accepts
-- either); the result is empty until the spell's data loads.
function MacroBuilder.RankPrefix(identifier)
	if not identifier or identifier == "" or not (C_Spell and C_Spell.GetSpellSubtext) then
		return nil
	end
	local sub = C_Spell.GetSpellSubtext(identifier)
	if not sub or sub == "" then
		return nil
	end
	return sub:match("^(%D+)%d")
end

-- The "[...] " conditional clause for a target/modifier pair ("" for none).
local function Clause(target, modifier)
	local conds = {}
	if target and target ~= "none" then
		conds[#conds + 1] = "@" .. target
	end
	local modCond = MOD_COND[modifier]
	if modCond then
		conds[#conds + 1] = modCond
	end
	return (#conds > 0) and ("[" .. concat(conds, ",") .. "] ") or ""
end

-- Builds the command text from the current choices. Pure; returns "" when
-- there's no name to act on. `o` holds: action, name, target, modifier,
-- rankN + rankPrefix (spells), equipLoc + equipSlot (items). May return two
-- lines (Use Item on gear that has to be worn first).
function MacroBuilder.Compose(o)
	local name = o.name and strtrim(o.name) or ""
	if name == "" then
		return ""
	end
	local action = o.action

	-- A library pick is a fixed, prebuilt macro body; emit it verbatim.
	if action == "library" then
		return o.libraryBody or ""
	end

	-- Saved messages and ItemRack sets go through slash commands that take
	-- only a name (no [@target,mod] conditionals), so emit them plainly.
	if action == "message" then
		return "/emu send " .. name
	elseif action == "itemrack" then
		return "/itemrack equip " .. name
	end

	local target = ACTION_TARGETS[action] and o.target or "none"
	local modifier = ACTION_MODIFIERS[action] and o.modifier or "none"
	local clause = Clause(target, modifier)

	if action == "cancelaura" then
		return "/cancelaura " .. clause .. name
	elseif action == "equip" then
		if o.equipSlot then
			return "/equipslot " .. clause .. o.equipSlot .. " " .. name
		end
		return "/equip " .. clause .. name
	elseif action == "use" then
		local line = "/use " .. clause .. name
		if NeedsEquip(o.equipLoc) then
			-- Gear has to be worn to be used, so equip it first (into the chosen
			-- slot for two-slot items). Equipping an item where it's already
			-- worn does nothing, so this only swaps it in when needed. Same
			-- modifier as the /use.
			local mod = Clause("none", modifier)
			local equip = o.equipSlot and ("/equipslot " .. mod .. o.equipSlot .. " " .. name)
				or ("/equip " .. mod .. name)
			return equip .. "\n" .. line
		end
		return line
	end

	local token = name
	if o.rankN and o.rankPrefix then
		token = name .. "(" .. o.rankPrefix .. o.rankN .. ")"
	end
	return "/cast " .. clause .. token
end

local TARGET_PHRASE = {
	player = "on yourself",
	target = "on your target",
	targettarget = "on your target's target",
	focus = "on your focus target",
	focustarget = "on your focus's target",
	mouseover = "on the unit under your cursor",
	pet = "on your pet",
	cursor = "at your mouse cursor",
}

local MOD_PHRASE = {
	any = "while any modifier is held",
	alt = "while Alt is held",
	ctrl = "while Ctrl is held",
	shift = "while Shift is held",
	btn1 = "when triggered with mouse button 1",
	btn2 = "when triggered with mouse button 2",
	btn3 = "when triggered with mouse button 3",
	btn4 = "when triggered with mouse button 4",
	btn5 = "when triggered with mouse button 5",
}

-- The human phrase for a slot number within an item's slot choices.
local function SlotPhrase(equipLoc, slot)
	for _, choice in ipairs(SLOT_CHOICES[equipLoc] or {}) do
		if choice.slot == slot then
			return choice.phrase
		end
	end
	return nil
end

-- A plain-language description of what the composed command does, e.g.
-- "Uses Healthstone on your focus target." Pure; "" when there's no name.
-- Takes the same options table as Compose.
function MacroBuilder.Describe(o)
	local name = o.name and strtrim(o.name) or ""
	if name == "" then
		return ""
	end
	local action = o.action

	if action == "library" then
		return o.libraryDesc or ""
	elseif action == "message" then
		return ("Sends the saved message \"%s\"."):format(name)
	elseif action == "itemrack" then
		return ("Equips the ItemRack set \"%s\" (the name must match exactly)."):format(name)
	end

	local target = ACTION_TARGETS[action] and o.target or "none"
	local modifier = ACTION_MODIFIERS[action] and o.modifier or "none"

	local parts
	if action == "cancelaura" then
		parts = { "Cancels the buff " .. name }
	elseif action == "equip" then
		parts = { "Equips " .. name }
		local slotPhrase = o.equipSlot and SlotPhrase(o.equipLoc, o.equipSlot)
		if slotPhrase then
			parts[#parts + 1] = "in your " .. slotPhrase
		end
	elseif action == "use" then
		if NeedsEquip(o.equipLoc) then
			local slotPhrase = o.equipSlot and SlotPhrase(o.equipLoc, o.equipSlot)
			parts = { "Equips " .. name .. (slotPhrase and (" in your " .. slotPhrase) or "")
				.. " if it isn't there, then uses it" }
		else
			parts = { "Uses " .. name }
		end
	else
		local token = name
		if o.rankN and o.rankPrefix then
			token = name .. " (" .. o.rankPrefix .. o.rankN .. ")"
		end
		parts = { "Casts " .. token }
	end
	if TARGET_PHRASE[target] then
		parts[#parts + 1] = TARGET_PHRASE[target]
	end
	if MOD_PHRASE[modifier] then
		parts[#parts + 1] = MOD_PHRASE[modifier]
	end
	return concat(parts, " ") .. "."
end

--------------------------------------------------------------------------------
-- List
--------------------------------------------------------------------------------

-- Shows the game tooltip for a list entry, docked to the right of the builder
-- so it never covers the list. Uses the most specific source available: the
-- worn slot or bag slot (shows enchants and durability), else the item or
-- spell id. Entries without one (saved messages, ItemRack sets) get none.
local function ShowEntryTooltip(data)
	local frame = MacroBuilder.frame
	if not (frame and data) then
		return
	end
	GameTooltip:SetOwner(frame, "ANCHOR_NONE")
	GameTooltip:ClearAllPoints()
	GameTooltip:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
	if data.wornSlot then
		GameTooltip:SetInventoryItem("player", data.wornSlot)
	elseif data.bag and data.bagSlot then
		GameTooltip:SetBagItem(data.bag, data.bagSlot)
	elseif data.itemID then
		GameTooltip:SetItemByID(data.itemID)
	elseif data.bookSlot then
		GameTooltip:SetSpellBookItem(data.bookSlot, BOOKTYPE_SPELL)
	elseif data.spellID then
		GameTooltip:SetSpellByID(data.spellID)
	else
		GameTooltip:Hide()
		return
	end
	GameTooltip:Show()
end

local function HideEntryTooltip()
	if MacroBuilder.frame and GameTooltip:IsOwned(MacroBuilder.frame) then
		GameTooltip:Hide()
	end
end

local function InitListButton(button, data)
	if not button.created then
		button.created = true

		button.Selected = ns.AddRowHighlight(button)

		button.Icon = button:CreateTexture(nil, "ARTWORK")
		button.Icon:SetSize(16, 16)
		button.Icon:SetPoint("LEFT", 3, 0)
		ns.TrimIcon(button.Icon)

		button.Name = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		button.Name:SetPoint("LEFT", button.Icon, "RIGHT", 6, 0)
		button.Name:SetPoint("RIGHT", button, "RIGHT", -4, 0)
		button.Name:SetJustifyH("LEFT")
		button.Name:SetWordWrap(false)

		button:SetScript("OnClick", function(self)
			MacroBuilder:SelectEntry(self.data)
		end)
		button:SetScript("OnEnter", function(self)
			ShowEntryTooltip(self.data)
		end)
		button:SetScript("OnLeave", HideEntryTooltip)
	end

	button.data = data
	button.Name:ClearAllPoints()
	if data.icon then
		button.Icon:Show()
		button.Icon:SetTexture(data.icon)
		button.Name:SetPoint("LEFT", button.Icon, "RIGHT", 6, 0)
	else
		-- Saved messages have no icon; start the name at the left edge.
		button.Icon:Hide()
		button.Name:SetPoint("LEFT", button, "LEFT", 6, 0)
	end
	button.Name:SetPoint("RIGHT", button, "RIGHT", -4, 0)
	-- A muted note after the name, e.g. "(equipped)" for worn items.
	button.Name:SetText(data.note and (data.name .. " |cff9d9d9d" .. data.note .. "|r") or data.name)
	button.Selected:SetShown(data.key == MacroBuilder.selectedKey)
end

-- What each action lists, and the noun used in its empty-state text.
local LIST_SOURCES = {
	library = { fetch = function() return MacroBuilder.LibraryEntries() end, noun = "library macros" },
	cast = { fetch = function() return MacroBuilder.KnownSpells() end, noun = "spells" },
	use = { fetch = function() return MacroBuilder.UsableItems() end, noun = "usable items" },
	equip = { fetch = function() return MacroBuilder.EquippableItems() end, noun = "equippable items" },
	cancelaura = { fetch = function() return MacroBuilder.CancelableBuffs() end, noun = "buffs" },
	message = { fetch = function() return ns.Messages.ListItems() end, noun = "saved messages" },
	itemrack = { fetch = function() return MacroBuilder.ItemRackSets() end, noun = "ItemRack sets" },
}

-- Rebuilds the list for the current action and search query.
function MacroBuilder:RefreshList()
	if not self.scrollBox then
		return
	end
	local source = LIST_SOURCES[self.action] or LIST_SOURCES.cast
	local items = source.fetch()
	self.allItems = items
	self:UpdateHeight()
	local filtered = ns.MacroData.Filter(items, self.query or "")
	self.scrollBox:SetDataProvider(CreateDataProvider(filtered), true)

	if self.emptyText then
		if #items == 0 then
			self.emptyText:SetText(("No %s found."):format(source.noun))
			self.emptyText:Show()
		elseif #filtered == 0 then
			self.emptyText:SetText(("No %s match your search."):format(source.noun))
			self.emptyText:Show()
		else
			self.emptyText:Hide()
		end
	end
end

-- True if the current action's name is picked from the list only (no name
-- box): saved messages, and ItemRack sets when they can be listed.
function MacroBuilder:IsListOnly()
	return self.action == "message"
		or self.action == "library"
		or (self.action == "itemrack" and MacroBuilder.CanListItemRackSets())
end

-- Sizes the window to the (unfiltered) list, so it fits short lists and doesn't
-- jump while searching; long lists cap at MAX_LIST_ROWS and scroll. Rows hidden
-- for the current action (name box, target) don't take space.
function MacroBuilder:UpdateHeight()
	if not self.frame then
		return
	end
	local count = self.allItems and #self.allItems or 0
	local rows = math.min(math.max(count, MIN_LIST_ROWS), MAX_LIST_ROWS)
	local below
	if self:IsListOnly() then
		-- A tall (library) preview pushes everything above it up, so grow the
		-- window by however much the preview exceeds its single-line height.
		below = BELOW_LIST_MESSAGE + (self.previewHeight - PREVIEW_SINGLE_HEIGHT)
	elseif not ACTION_TARGETS[self.action] then
		below = BELOW_LIST_FULL - TARGET_ROW_HEIGHT
	else
		below = BELOW_LIST_FULL
	end
	ns.SetInsetContentHeight(self.frame, LIST_TOP + rows * ROW_HEIGHT + LIST_CHROME + below)
end

function MacroBuilder:UpdateListSelection()
	if self.scrollBox then
		self.scrollBox:ForEachFrame(function(button)
			button.Selected:SetShown(button.data and button.data.key == self.selectedKey)
		end)
	end
end

--------------------------------------------------------------------------------
-- Selection / preview
--------------------------------------------------------------------------------

function MacroBuilder:SelectEntry(data)
	if not data then
		return
	end
	self.selectedKey = data.key
	if self:IsListOnly() then
		-- List-only actions (no typing); remember the picked name.
		self.selectedListName = data.name
		self:UpdatePreview()
	else
		-- Clicking the list fills the name box, so that box is the single,
		-- visible source of truth. Its OnTextChanged refreshes rank/slot/preview.
		self.nameBox:SetText(data.name)
	end
	self:UpdateListSelection()
end

-- The name the command acts on: the list selection for list-only actions,
-- otherwise the editable name box.
function MacroBuilder:EffectiveName()
	if self:IsListOnly() then
		return self.selectedListName or ""
	end
	return self.nameBox and strtrim(self.nameBox:GetText() or "") or ""
end

-- The current choices as the options table Compose/Describe take.
function MacroBuilder:Options()
	local libEntry = (self.action == "library") and LIBRARY_BY_KEY[self.selectedKey] or nil
	return {
		action = self.action,
		name = self:EffectiveName(),
		target = self.target,
		modifier = self.modifier,
		rankN = (self.action == "cast") and self.rankN or nil,
		rankPrefix = (self.action == "cast") and self.rankPrefix or nil,
		equipLoc = self.equipLoc,
		equipSlot = (self.action == "equip" or self.action == "use") and self.equipSlot or nil,
		libraryBody = libEntry and libEntry.body or nil,
		libraryDesc = libEntry and libEntry.desc or nil,
	}
end

function MacroBuilder:CurrentLine()
	return MacroBuilder.Compose(self:Options())
end

local HINTS = {
	library = "Pick a prebuilt macro from the library to preview and insert it.",
	cast = "Pick a spell to build a /cast command.",
	use = "Pick an item or type its name to build a /use command.",
	equip = "Pick an item or type its name to build an /equip command.",
	cancelaura = "Pick an active or common buff, or type a buff name, to build a /cancelaura command.",
	message = "Pick a saved message to insert an /emu send command.",
	itemrack = "Pick an ItemRack set to build an /itemrack equip command.",
}

-- Grows the preview (and, through UpdateHeight, the window) to fit a multi-line
-- library body, and shrinks it back to one line for composed commands.
function MacroBuilder:ResizePreview(line)
	local height = PREVIEW_SINGLE_HEIGHT
	if self.action == "library" and line ~= "" then
		local lines = 1
		for _ in line:gmatch("\n") do
			lines = lines + 1
		end
		height = math.min(lines, MAX_PREVIEW_LINES) * PREVIEW_LINE_HEIGHT + 6
	end
	if height ~= self.previewHeight then
		self.previewHeight = height
		self.preview:SetHeight(height)
		self:UpdateHeight()
	end
end

function MacroBuilder:UpdatePreview()
	local line = self:CurrentLine()
	local hasLine = line ~= ""
	self:ResizePreview(line)
	if hasLine then
		self.preview:SetText(line)
		self.preview:SetTextColor(1, 1, 1)
		self.explain:SetText(MacroBuilder.Describe(self:Options()))
		self.insertButton:SetEnabled(true)
	else
		self.preview:SetText(HINTS[self.action] or HINTS.cast)
		ns.SetMutedText(self.preview)
		self.explain:SetText("")
		self.insertButton:SetEnabled(false)
	end
	-- New Macro also needs a free slot in the current tab (and no combat).
	if self.newMacroButton then
		self.newMacroButton:SetEnabled(hasLine and ns.MainFrame ~= nil
			and ns.MainFrame:CanCreateMacroHere())
	end
end

local NAME_LABELS = {
	cast = "Spell name (click the list, type, or Shift-click from your spellbook)",
	use = "Item name (click the list, type, or Shift-click an item)",
	equip = "Item name (click the list, type, or Shift-click an item)",
	cancelaura = "Buff name (click one from the list below, or type it exactly)",
	itemrack = "ItemRack set name (type it exactly)",
}

-- Re-derives item details from the name box: the equip location (so Use Item
-- knows the item must be worn, and both item actions know whether to offer a
-- slot choice) and, when a different item is named, a default slot for a
-- two-slot item: the slot it's already worn in (so the macro doesn't move it
-- to the other slot), else the first.
function MacroBuilder:UpdateItemDetails()
	local name, equipLoc, wornSlot
	if self.action == "use" or self.action == "equip" then
		local raw = self:EffectiveName()
		name = raw:lower()
		equipLoc, wornSlot = MacroBuilder.EquipLocFor(raw, self.allItems)
	end
	if name == self.detailsName and equipLoc == self.equipLoc then
		return
	end
	self.detailsName = name
	self.equipLoc = equipLoc
	self.equipSlot = nil
	local choices = SLOT_CHOICES[equipLoc]
	if choices then
		self.equipSlot = choices[1].slot
		for _, choice in ipairs(choices) do
			if choice.slot == wornSlot then
				self.equipSlot = wornSlot
			end
		end
	end
end

-- Shows the per-action controls: name box (unless list-only), target and
-- modifier rows (only where the command honors them), the rank box for a
-- /cast whose spell has ranks, and the slot choice for Equip Item on an item
-- that fits two slots. Re-anchors so hidden rows leave no gap.
function MacroBuilder:UpdateVisibility()
	local action = self.action
	local listOnly = self:IsListOnly()
	local showTarget = ACTION_TARGETS[action] and true or false
	local showModifier = ACTION_MODIFIERS[action] and true or false

	self.nameLabel:SetText(NAME_LABELS[action] or NAME_LABELS.cast)
	self.nameLabel:SetShown(not listOnly)
	self.nameBox:SetShown(not listOnly)

	self.targetLabel:SetShown(showTarget)
	self.targetDropdown:SetShown(showTarget)
	self.modLabel:SetShown(showModifier)
	self.modDropdown:SetShown(showModifier)

	-- The name row sits above the target row, or directly above the modifier
	-- row when there's no target for this action.
	self.nameLabel:ClearAllPoints()
	self.nameLabel:SetPoint("BOTTOMLEFT", showTarget and self.targetLabel or self.modLabel, "TOPLEFT", 0, 40)

	-- List-only actions end the list just above the preview.
	if self.listBox then
		self.listBox:ClearAllPoints()
		self.listBox:SetPoint("TOPLEFT", self.search, "BOTTOMLEFT", -2, -6)
		self.listBox:SetPoint("TOPRIGHT", self.search, "BOTTOMRIGHT", 2, -6)
		self.listBox:SetPoint("BOTTOM", listOnly and self.previewLabel or self.nameLabel, "TOP", 0, 8)
	end

	-- Rank box only for a /cast whose spell actually has ranks.
	local showRank = (action == "cast") and self.rankPrefix ~= nil
	self.rankLabel:SetShown(showRank)
	self.rankBox:SetShown(showRank)
	if not showRank then
		self.rankBox:SetText("")
		self.rankN = nil
	end

	-- Slot choice (same row as Rank) for Equip Item on a two-slot item.
	-- Also for Use Item, where gear is equipped before it's used.
	local choices = (action == "equip" or action == "use") and SLOT_CHOICES[self.equipLoc] or nil
	self.slotLabel:SetShown(choices ~= nil)
	for i, radio in ipairs(self.slotRadios) do
		local choice = choices and choices[i]
		radio:SetShown(choice ~= nil)
		if choice then
			radio.text:SetText(choice.text)
			radio.slot = choice.slot
			radio:SetChecked(self.equipSlot == choice.slot)
		end
	end

	self:UpdateHeight()
end

function MacroBuilder:SetAction(key)
	if self.action == key then
		return
	end
	self.action = key
	self.selectedKey = nil
	self.selectedListName = nil
	self.rankPrefix = nil
	self.rankN = nil
	self.equipLoc = nil
	self.equipSlot = nil
	self.detailsName = nil
	if self.rankBox then self.rankBox:SetText("") end
	if self.nameBox then self.nameBox:SetText("") end
	if self.actionDropdown then self.actionDropdown:GenerateMenu() end
	self:RefreshList()
	self:UpdateVisibility()
	self:UpdatePreview()
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function MacroBuilder:Create()
	local frame = ns.CreatePortraitWindow("ExtendedMacroUIMacroBuilder", BUILDER_WIDTH, BUILDER_HEIGHT, "Macro Builder")
	-- Docks to the main window's top-right -- the same slot as the icon picker,
	-- so the two are mutually exclusive (see Open()).
	frame:SetPoint("TOPLEFT", ns.frame, "TOPRIGHT", 6, 0)
	self.frame = frame

	local inset = frame.Inset

	-- Action dropdown.
	local actionLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	actionLabel:SetPoint("TOPLEFT", inset, "TOPLEFT", 12, -12)
	actionLabel:SetText("What should this command do?")

	local actionDropdown = CreateFrame("DropdownButton", nil, inset, "WowStyle1DropdownTemplate")
	actionDropdown:SetWidth(170)
	actionDropdown:SetPoint("TOPLEFT", actionLabel, "BOTTOMLEFT", 0, -6)
	actionDropdown:SetupMenu(function(_, rootDescription)
		for _, a in ipairs(ACTIONS) do
			local radio = rootDescription:CreateRadio(a.text,
				function() return MacroBuilder.action == a.key end,
				function() MacroBuilder:SetAction(a.key) end)
			-- Actions that drive another addon are grayed out without it.
			if a.requiresAddOn == "ItemRack" and not MacroBuilder.HasItemRack() then
				radio:SetEnabled(false)
				ns.SetMenuTooltip(radio, a.text, a.disabledDesc)
			end
		end
	end)
	self.actionDropdown = actionDropdown

	-- Search box over the list.
	local search = CreateFrame("EditBox", nil, inset, "SearchBoxTemplate")
	search:SetHeight(20)
	search:SetPoint("TOPLEFT", actionDropdown, "BOTTOMLEFT", 2, -10)
	search:SetPoint("RIGHT", inset, "RIGHT", -12, 0)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", function(box)
		MacroBuilder.query = box:GetText()
		MacroBuilder:RefreshList()
	end)
	self.search = search
	ns.RegisterEditBox(search)

	-- Bottom-up block: buttons, preview, conditionals, item-name box.
	local cancel = ns.CreateButton(frame, "Close", 90, 22, function() MacroBuilder:Close() end)
	cancel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 6)

	local insert = ns.CreateButton(frame, "Insert", 90, 22, function() MacroBuilder:Insert() end)
	insert:SetPoint("BOTTOMRIGHT", cancel, "BOTTOMLEFT", -6, 0)
	ns.SetTooltip(insert, "Add this command as a new line in the macro you're editing.")
	self.insertButton = insert

	-- Alternative to Insert: make a brand-new macro from this command instead of
	-- adding it to the one being edited. Disabled (with a reason in the tooltip)
	-- when the current tab is full or we're in combat.
	local newMacro = ns.CreateButton(frame, "New Macro", 96, 22, function() MacroBuilder:CreateNew() end)
	newMacro:SetPoint("BOTTOMRIGHT", insert, "BOTTOMLEFT", -6, 0)
	newMacro:SetMotionScriptsWhileDisabled(true)
	newMacro:SetScript("OnEnter", function(button)
		GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Create a new macro in this tab from this command.", 1, 1, 1, true)
		if not button:IsEnabled() then
			if InCombatLockdown() then
				GameTooltip:AddLine("Can't create macros while in combat.", 1, 0.3, 0.3, true)
			elseif ns.MainFrame and not ns.MainFrame:CanCreateMacroHere() then
				GameTooltip:AddLine("This tab is full -- delete a macro to make room.", 1, 0.3, 0.3, true)
			else
				GameTooltip:AddLine("Pick or name something to build a command first.", 1, 0.3, 0.3, true)
			end
		end
		GameTooltip:Show()
	end)
	newMacro:SetScript("OnLeave", function() GameTooltip:Hide() end)
	self.newMacroButton = newMacro

	-- Preview block, built bottom-up: the plain-language explanation sits at the
	-- very bottom, the composed command above it, and the "Preview" label on top.
	local explain = inset:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	explain:SetPoint("BOTTOMLEFT", inset, "BOTTOMLEFT", 12, 8)
	explain:SetPoint("RIGHT", inset, "RIGHT", -12, 0)
	explain:SetJustifyH("LEFT")
	explain:SetHeight(28)
	self.explain = explain

	local preview = inset:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	preview:SetPoint("BOTTOMLEFT", explain, "TOPLEFT", 0, 6)
	preview:SetPoint("RIGHT", inset, "RIGHT", -12, 0)
	preview:SetJustifyH("LEFT")
	-- Top-aligned so a multi-line library body reads under the "Preview" label;
	-- its height grows to fit the body (ResizePreview).
	preview:SetJustifyV("TOP")
	preview:SetHeight(PREVIEW_SINGLE_HEIGHT)
	self.preview = preview

	local previewLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	previewLabel:SetPoint("BOTTOMLEFT", preview, "TOPLEFT", 0, 4)
	previewLabel:SetText("Preview")
	self.previewLabel = previewLabel

	-- Rank box (spells with ranks only).
	local rankLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	rankLabel:SetPoint("BOTTOMLEFT", previewLabel, "TOPLEFT", 0, 16)
	rankLabel:SetText("Rank (optional)")
	self.rankLabel = rankLabel

	local rankBox = CreateFrame("EditBox", nil, inset, "InputBoxTemplate")
	rankBox:SetSize(40, 20)
	rankBox:SetPoint("LEFT", rankLabel, "RIGHT", 10, 0)
	rankBox:SetAutoFocus(false)
	rankBox:SetNumeric(true)
	rankBox:SetMaxLetters(3)
	rankBox:SetScript("OnEscapePressed", rankBox.ClearFocus)
	rankBox:HookScript("OnTextChanged", function(box)
		local n = tonumber(box:GetText())
		MacroBuilder.rankN = (n and n > 0) and n or nil
		MacroBuilder:UpdatePreview()
	end)
	self.rankBox = rankBox
	ns.RegisterEditBox(rankBox)

	-- Slot choice for Equip Item on an item that fits two slots (one-handed
	-- weapons, trinkets, rings). Shares the Rank row, which /equip never uses.
	local slotLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	slotLabel:SetPoint("BOTTOMLEFT", previewLabel, "TOPLEFT", 0, 16)
	slotLabel:SetText("Equip to")
	slotLabel:Hide()
	self.slotLabel = slotLabel

	self.slotRadios = {}
	for i = 1, 2 do
		local radio = ns.CreateRadio(inset)
		if i == 1 then
			radio:SetPoint("LEFT", slotLabel, "LEFT", 70, 0)
		else
			radio:SetPoint("LEFT", self.slotRadios[1], "RIGHT", 110, 0)
		end
		radio:SetScript("OnClick", function(r)
			MacroBuilder.equipSlot = r.slot
			MacroBuilder:UpdateVisibility()
			MacroBuilder:UpdatePreview()
		end)
		radio:Hide()
		self.slotRadios[i] = radio
	end

	-- Modifier dropdown.
	local modLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	modLabel:SetPoint("BOTTOMLEFT", rankLabel, "TOPLEFT", 0, 18)
	modLabel:SetText("Modifier")
	self.modLabel = modLabel

	local modDropdown = CreateFrame("DropdownButton", nil, inset, "WowStyle1DropdownTemplate")
	modDropdown:SetWidth(190)
	modDropdown:SetPoint("LEFT", modLabel, "LEFT", 70, 0)
	modDropdown:SetupMenu(function(_, rootDescription)
		for _, m in ipairs(MODIFIERS) do
			local radio = rootDescription:CreateRadio(m.text,
				function() return MacroBuilder.modifier == m.key end,
				function()
					MacroBuilder.modifier = m.key
					modDropdown:GenerateMenu()
					MacroBuilder:UpdatePreview()
				end)
			if m.desc then
				ns.SetMenuTooltip(radio, m.text, m.desc)
			end
		end
	end)
	self.modDropdown = modDropdown

	-- Target dropdown.
	local targetLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	targetLabel:SetPoint("BOTTOMLEFT", modLabel, "TOPLEFT", 0, 36)
	targetLabel:SetText("Target")
	self.targetLabel = targetLabel

	local targetDropdown = CreateFrame("DropdownButton", nil, inset, "WowStyle1DropdownTemplate")
	targetDropdown:SetWidth(190)
	targetDropdown:SetPoint("LEFT", targetLabel, "LEFT", 70, 0)
	targetDropdown:SetupMenu(function(_, rootDescription)
		for _, t in ipairs(TARGETS) do
			local radio = rootDescription:CreateRadio(t.text,
				function() return MacroBuilder.target == t.key end,
				function()
					MacroBuilder.target = t.key
					targetDropdown:GenerateMenu()
					MacroBuilder:UpdatePreview()
				end)
			if t.desc then
				ns.SetMenuTooltip(radio, t.text, t.desc)
			end
		end
	end)
	self.targetDropdown = targetDropdown

	-- Name box (spell or item), above the Target row. The list, typing and
	-- Shift-click all fill this one box.
	local nameLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	nameLabel:SetPoint("BOTTOMLEFT", targetLabel, "TOPLEFT", 0, 40)
	nameLabel:SetText("Spell name (click the list, type, or Shift-click from your spellbook)")
	self.nameLabel = nameLabel

	local nameBox = CreateFrame("EditBox", nil, inset, "InputBoxTemplate")
	nameBox:SetHeight(20)
	nameBox:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 6, -4)
	nameBox:SetPoint("RIGHT", inset, "RIGHT", -12, 0)
	nameBox:SetAutoFocus(false)
	nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
	nameBox:HookScript("OnTextChanged", function(editBox)
		-- For a /cast, derive the rank prefix from the typed/filled name so the
		-- rank box appears when the spell actually has ranks.
		if MacroBuilder.action == "cast" then
			MacroBuilder.rankPrefix = MacroBuilder.RankPrefix(strtrim(editBox:GetText() or ""))
		end
		-- For items, find where it's worn (slot choice / equip-before-use).
		MacroBuilder:UpdateItemDetails()
		MacroBuilder:UpdateVisibility()
		MacroBuilder:UpdatePreview()
	end)
	self.nameBox = nameBox
	ns.RegisterEditBox(nameBox)

	-- Scrolling list between the search box and the name row.
	local box, scrollBox, scrollBar = ns.CreateScrollList(inset, 22)
	box:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -2, -6)
	box:SetPoint("TOPRIGHT", search, "BOTTOMRIGHT", 2, -6)
	box:SetPoint("BOTTOM", nameLabel, "TOP", 0, 8)
	self.listBox = box

	self.emptyText = ns.CreateEmptyText(box)

	ns.InitListView(scrollBox, scrollBar, ROW_HEIGHT, InitListButton)
	self.scrollBox = scrollBox

	-- Keep the list fresh while open as the player learns spells, their bags or
	-- worn gear change, or their buffs come and go; rebuild only for the list
	-- currently shown.
	frame:SetScript("OnShow", function()
		frame:RegisterEvent("SPELLS_CHANGED")
		frame:RegisterEvent("BAG_UPDATE_DELAYED")
		frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
		frame:RegisterEvent("UNIT_AURA")
	end)
	frame:SetScript("OnHide", function()
		frame:UnregisterEvent("SPELLS_CHANGED")
		frame:UnregisterEvent("BAG_UPDATE_DELAYED")
		frame:UnregisterEvent("PLAYER_EQUIPMENT_CHANGED")
		frame:UnregisterEvent("UNIT_AURA")
		HideEntryTooltip()
	end)
	frame:SetScript("OnEvent", function(_, event, unit)
		-- UNIT_AURA fires for every unit; only the player's buffs feed the list.
		if event == "UNIT_AURA" and unit ~= "player" then
			return
		end
		MacroBuilder:RefreshList()
	end)

	frame.CloseButton:SetScript("OnClick", function() MacroBuilder:Close() end)

	-- Shift-clicking a spell (spellbook) or item (bags, etc.) fills the name box
	-- while the builder is open. Both funnel through ChatFrameUtil.InsertLink:
	-- items arrive as an |Hitem:| link, spells as an |Hspell:| link (the plain
	-- "name" path is reserved for Blizzard's own MacroFrameText). A post-hook
	-- taints nothing.
	hooksecurefunc(ChatFrameUtil, "InsertLink", function(text)
		if not (MacroBuilder:IsShown() and type(text) == "string") then
			return
		end
		local name = text:match("%[(.-)%]")
		if not name or name == "" then
			return
		end
		if text:match("|Hitem:") then
			-- Items fill Use or Equip as-is; any other action switches to Use.
			if MacroBuilder.action ~= "use" and MacroBuilder.action ~= "equip" then
				MacroBuilder:SetAction("use")
			end
			MacroBuilder.nameBox:SetText(name)
		elseif text:match("|Hspell:") then
			if MacroBuilder.action ~= "cast" then
				MacroBuilder:SetAction("cast")
			end
			MacroBuilder.nameBox:SetText(name)
		end
	end)
end

--------------------------------------------------------------------------------
-- Open / close / insert
--------------------------------------------------------------------------------

function MacroBuilder:Open()
	if not self.frame then
		return
	end
	-- One docked side panel at a time.
	ns.CloseDockPanels(self)
	self:RefreshList()
	self:UpdateListSelection()
	self:UpdateVisibility()
	self:UpdatePreview()
	self.frame:Show()
end

-- Appends the composed line to the macro editor's draft body.
function MacroBuilder:Insert()
	local line = self:CurrentLine()
	if line == "" then
		return
	end
	if ns.Editor then
		ns.Editor:InsertBodyLine(line)
	end
end

-- Creates a brand-new macro in the current tab from the composed command (its
-- body), instead of inserting into the macro being edited. The acted-on name
-- (spell/item/buff/message) is a reasonable default macro name, trimmed to the
-- 16-char limit; MainFrame selects the new macro and focuses its name box so the
-- player can rename it. No-op without a command, or when the tab has no free
-- slot (the button is disabled then too).
function MacroBuilder:CreateNew()
	local line = self:CurrentLine()
	if line == "" or not ns.MainFrame then
		return
	end
	local name = ns.NameWithSuffix(strtrim(self:EffectiveName()), "", 16)
	if name == "" then
		name = "New Macro"
	end
	ns.MainFrame:NewMacroFromBuilder(name, line)
end
